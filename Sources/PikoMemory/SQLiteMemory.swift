import Foundation
import NaturalLanguage
import SQLite3
import PikoKit

// SQLite's destructor macros are C preprocessor tokens the Clang importer does not expose to
// Swift. This is the same bitcast pattern used by stephencelis/SQLite.swift's Statement.swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteMemoryError: Error, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
}

/// Local index. SQLite with FTS5.
///
/// Retrieval, never a growing prompt — the on-device context window is 8,192 tokens and months
/// of sessions will not fit. `nearestEdits` is what makes Piko sound more like the user over
/// time: the closest past corrections become few-shot examples for the next rewrite.
public actor SQLiteMemory: Memory {
    // OpaquePointer isn't Sendable; deinit is nonisolated, so this needs the escape hatch.
    // Safe here: only ever mutated once (init) and read while the actor serializes all other
    // access, or in deinit after the last reference (and thus all other access) is gone.
    nonisolated(unsafe) private var db: OpaquePointer?

    public init(path: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteMemoryError.openFailed(message)
        }
        self.db = handle

        // A synchronous, non-delegating actor init is nonisolated w.r.t. calling other
        // actor-isolated instance methods, so the schema DDL is inlined here rather than
        // routed through an isolated helper.
        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS results (
            id TEXT NOT NULL UNIQUE, raw TEXT NOT NULL, shipped TEXT NOT NULL,
            route TEXT NOT NULL, profile TEXT NOT NULL, createdAt REAL NOT NULL,
            firstWordMS INTEGER NOT NULL, transcribeMS INTEGER NOT NULL, brainMS INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS results_fts USING fts5(
            raw, shipped, content='results', content_rowid='rowid'
        );
        CREATE TRIGGER IF NOT EXISTS results_ai AFTER INSERT ON results BEGIN
            INSERT INTO results_fts(rowid, raw, shipped) VALUES (new.rowid, new.raw, new.shipped);
        END;
        CREATE TRIGGER IF NOT EXISTS results_ad AFTER DELETE ON results BEGIN
            INSERT INTO results_fts(results_fts, rowid, raw, shipped)
            VALUES ('delete', old.rowid, old.raw, old.shipped);
        END;
        CREATE TABLE IF NOT EXISTS edits (
            raw TEXT NOT NULL, shipped TEXT NOT NULL, final TEXT NOT NULL,
            profile TEXT NOT NULL, createdAt REAL NOT NULL
        );
        -- Schema v2: the derived memory graph (see docs/MEMORY-ARCHITECTURE.md).
        -- results stays the journal; these tables are a rebuildable projection.
        CREATE TABLE IF NOT EXISTS entities (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            kind TEXT NOT NULL,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            hit_count INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS edges (
            id INTEGER PRIMARY KEY,
            src INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            dst INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            relation TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1,
            last_seen REAL NOT NULL,
            UNIQUE(src, dst, relation)
        );
        CREATE INDEX IF NOT EXISTS idx_entities_last_seen ON entities(last_seen);
        CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src);
        CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst);
        CREATE TABLE IF NOT EXISTS memory_meta (
            key TEXT PRIMARY KEY, value TEXT NOT NULL
        );
        """
        guard sqlite3_exec(handle, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw SQLiteMemoryError.stepFailed(message)
        }

        // MEMORY-ARCHITECTURE.md budgets: WAL for lock-free reads during capture,
        // a capped 2 MB page cache, and NORMAL sync — durable enough for a derived
        // projection that the journal can always rebuild.
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2000; PRAGMA temp_store=MEMORY;", nil, nil, nil)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Write path

    public func record(_ result: CaptureResult) async {
        do {
            try insert(result)
        } catch {
            print("SQLiteMemory: record failed: \(error)")
        }
    }

    private func insert(_ result: CaptureResult) throws {
        let sql = """
        INSERT INTO results (id, raw, shipped, route, profile, createdAt, firstWordMS, transcribeMS, brainMS)
        VALUES (?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteMemoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, result.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, result.raw, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, result.shipped, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, result.route.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, result.profile.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, result.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 7, Int32(result.timings.firstWordMS))
        sqlite3_bind_int(stmt, 8, Int32(result.timings.transcribeMS))
        sqlite3_bind_int(stmt, 9, Int32(result.timings.brainMS))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteMemoryError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func recordEdit(_ pair: EditPair) async {
        do {
            try insertEdit(pair)
        } catch {
            print("SQLiteMemory: recordEdit failed: \(error)")
        }
    }

    public func delete(_ id: UUID) async {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM results WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteMemory: delete failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("SQLiteMemory: delete failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func insertEdit(_ pair: EditPair) throws {
        let sql = """
        INSERT INTO edits (raw, shipped, final, profile, createdAt)
        VALUES (?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteMemoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, pair.raw, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, pair.shipped, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, pair.final, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, pair.profile.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, pair.createdAt.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteMemoryError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Read path

    /// No lexicon data source (Contacts/Calendar/user-corrections) exists yet — building one is
    /// out of scope for this phase. Matches EphemeralMemory's own current always-[] behavior.
    public func lexicon(limit: Int) async -> [String] { [] }

    public func nearestEdits(to text: String, limit: Int) async -> [EditPair] {
        // `text` is intentionally ignored — semantic nearness is a future learning-loop phase.
        let sql = "SELECT raw, shipped, final, profile, createdAt FROM edits ORDER BY rowid DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteMemory: nearestEdits prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var edits: [EditPair] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let pair = decodeEditPair(from: stmt) {
                edits.append(pair)
            }
        }
        // Query runs newest-first to correctly select "the last N"; reverse to restore
        // EphemeralMemory's Array(edits.suffix(limit)) ascending order.
        return edits.reversed()
    }

    private func decodeEditPair(from stmt: OpaquePointer?) -> EditPair? {
        guard let rawC = sqlite3_column_text(stmt, 0),
              let shippedC = sqlite3_column_text(stmt, 1),
              let finalC = sqlite3_column_text(stmt, 2),
              let profileC = sqlite3_column_text(stmt, 3),
              let profile = Profile(rawValue: String(cString: profileC)) else { return nil }

        return EditPair(
            raw: String(cString: rawC),
            shipped: String(cString: shippedC),
            final: String(cString: finalC),
            profile: profile,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        )
    }

    public func search(_ query: String, limit: Int) async -> [CaptureResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Never hand FTS5 an empty MATCH expression — bypass MATCH entirely for the
            // "no query typed" case, reproducing EphemeralMemory's "show everything" behavior.
            return queryRecent(limit: limit)
        }
        return queryMatch(Self.sanitizedMatchExpression(for: trimmed), limit: limit)
    }

    /// Quotes every whitespace-separated token so FTS5-reserved syntax (colons, asterisks,
    /// AND/OR/NOT) is always treated as a literal, never parsed as query-operator syntax.
    static func sanitizedMatchExpression(for query: String) -> String {
        let tokens = query.split(separator: " ").map { token -> String in
            "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return tokens.joined(separator: " AND ")
    }

    private func queryRecent(limit: Int) -> [CaptureResult] {
        let sql = """
        SELECT id, raw, shipped, route, profile, createdAt, firstWordMS, transcribeMS, brainMS
        FROM results ORDER BY createdAt DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteMemory: queryRecent prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [CaptureResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let result = decodeCaptureResult(from: stmt) {
                results.append(result)
            }
        }
        return results
    }

    private func queryMatch(_ ftsQuery: String, limit: Int) -> [CaptureResult] {
        let sql = """
        SELECT r.id, r.raw, r.shipped, r.route, r.profile, r.createdAt,
               r.firstWordMS, r.transcribeMS, r.brainMS
        FROM results_fts f JOIN results r ON r.rowid = f.rowid
        WHERE results_fts MATCH ? ORDER BY rank LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteMemory: queryMatch prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [CaptureResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let result = decodeCaptureResult(from: stmt) {
                results.append(result)
            }
        }
        return results
    }

    // MARK: - Memory graph (schema v2)

    private static let watermarkKey = "index_watermark"

    private func decodeCaptureResult(from stmt: OpaquePointer?) -> CaptureResult? {
        guard let idC = sqlite3_column_text(stmt, 0),
              let rawC = sqlite3_column_text(stmt, 1),
              let shippedC = sqlite3_column_text(stmt, 2),
              let routeC = sqlite3_column_text(stmt, 3),
              let profileC = sqlite3_column_text(stmt, 4),
              let id = UUID(uuidString: String(cString: idC)),
              let route = Route(rawValue: String(cString: routeC)),
              let profile = Profile(rawValue: String(cString: profileC)) else { return nil }

        return CaptureResult(
            id: id,
            raw: String(cString: rawC),
            shipped: String(cString: shippedC),
            route: route,
            profile: profile,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            timings: CaptureResult.Timings(
                firstWordMS: Int(sqlite3_column_int(stmt, 6)),
                transcribeMS: Int(sqlite3_column_int(stmt, 7)),
                brainMS: Int(sqlite3_column_int(stmt, 8))
            )
        )
    }

    /// Tier-0 extraction over results recorded since the last watermark — the whole
    /// `remember` operation. One transaction: a crash mid-batch rolls back and retries
    /// the same rows on the next call. Idempotent by construction.
    public func indexNewResults() async {
        guard let hits = unindexedResults(), !hits.isEmpty else { return }
        do {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteMemoryError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }

            var idsByName: [String: Int64] = [:]
            var newWatermark: Int64 = 0
            for (rowid, shipped, createdAt) in hits {
                let extracted = EntityExtractor.extract(from: shipped)
                var lastID: Int64?
                for hit in extracted {
                    let id = try upsertEntity(hit, at: createdAt, idsByName: &idsByName)
                    if let previous = lastID, previous != id {
                        try bumpEdge(from: previous, to: id, at: createdAt)
                    }
                    lastID = id
                }
                newWatermark = max(newWatermark, rowid)
            }
            try setMeta(Self.watermarkKey, "\(newWatermark)")
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteMemoryError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            print("SQLiteMemory: indexNewResults failed: \(error)")
        }
    }

    private func unindexedResults() -> [(Int64, String, Date)]? {
        let watermark = Int64(meta(Self.watermarkKey) ?? "0") ?? 0
        let sql = "SELECT rowid, shipped, createdAt FROM results WHERE rowid > ? ORDER BY rowid"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, watermark)

        var rows: [(Int64, String, Date)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 1) else { continue }
            rows.append((sqlite3_column_int64(stmt, 0), String(cString: text),
                         Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))))
        }
        return rows
    }

    private func upsertEntity(_ hit: EntityExtractor.Hit, at date: Date,
                              idsByName: inout [String: Int64]) throws -> Int64 {
        // Always execute the upsert — the increment IS the frequency signal. Only the
        // id lookup is cacheable; skipping the upsert for same-batch repeats would
        // flatten "said it three times" into "said it once".
        let sql = """
        INSERT INTO entities (name, kind, first_seen, last_seen, hit_count)
        VALUES (?,?,?,?,1)
        ON CONFLICT(name) DO UPDATE SET
            hit_count = hit_count + 1,
            last_seen = MAX(last_seen, excluded.last_seen),
            kind = CASE WHEN excluded.kind != 'topic' THEN excluded.kind ELSE entities.kind END
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteMemoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, hit.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, hit.kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteMemoryError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }

        if let cached = idsByName[hit.name] { return cached }
        var lookup: OpaquePointer?
        let idSQL = "SELECT id FROM entities WHERE name = ? COLLATE NOCASE"
        guard sqlite3_prepare_v2(db, idSQL, -1, &lookup, nil) == SQLITE_OK else {
            sqlite3_finalize(lookup)
            throw SQLiteMemoryError.stepFailed("entity id lookup prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_bind_text(lookup, 1, hit.name, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(lookup) == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(lookup)
            throw SQLiteMemoryError.stepFailed("entity id lookup failed for '\(hit.name)': \(message)")
        }
        let id = sqlite3_column_int64(lookup, 0)
        sqlite3_finalize(lookup)
        idsByName[hit.name] = id
        return id
    }

    private func bumpEdge(from src: Int64, to dst: Int64, at date: Date) throws {
        let sql = """
        INSERT INTO edges (src, dst, relation, weight, last_seen)
        VALUES (?, ?, 'co_mentioned', 1, ?)
        ON CONFLICT(src, dst, relation) DO UPDATE SET
            weight = weight + 1, last_seen = MAX(last_seen, excluded.last_seen)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteMemoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, src)
        sqlite3_bind_int64(stmt, 2, dst)
        sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteMemoryError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func setMeta(_ key: String, _ value: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO memory_meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteMemoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteMemoryError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func meta(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM memory_meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: value)
    }

    public func rememberedEntities(limit: Int) async -> [RememberedEntity] {
        // Frequency over recency: hit_count halved per 14 idle days. Pure SQL, no model.
        let sql = """
        SELECT name, kind, hit_count, last_seen FROM entities
        ORDER BY hit_count / (1 + (julianday('now') - julianday(last_seen, 'unixepoch')) / 14.0) DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return collectEntities(stmt)
    }

    public func forget(entity name: String) async {
        // ON DELETE CASCADE covers the edges; the explicit deletes keep the intent obvious.
        sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM entities WHERE name = ? COLLATE NOCASE", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("SQLiteMemory: forget failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// The `recall` operation, interactive-grade: one prepared statement for the line,
    /// one for the entities. Query-matched packets filter entities to those actually
    /// present in the matched text.
    public func recall(query: String) async -> MemoryPacket? {
        let lastSaid = await search("", limit: 1).first?.shipped
        let entities = await rememberedEntities(limit: 200)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible: [RememberedEntity]
        if trimmed.isEmpty {
            visible = Array(entities.prefix(8))
        } else {
            let matched = await search(trimmed, limit: 20).map { $0.shipped.localizedLowercase }
            visible = Array(entities.filter { entity in
                matched.contains { $0.contains(entity.name.localizedLowercase) }
            }.prefix(8))
        }
        return MemoryPacket(lastSaid: lastSaid, entities: visible)
    }

    /// Drop the projection, keep the journal, re-derive. The recovery path of last
    /// resort — and how an improved extractor ships safely to existing devices.
    public func rebuildGraph() async {
        sqlite3_exec(db, "DELETE FROM edges; DELETE FROM entities; DELETE FROM memory_meta WHERE key = '\(Self.watermarkKey)';", nil, nil, nil)
        await indexNewResults()
    }

    private func collectEntities(_ stmt: OpaquePointer?) -> [RememberedEntity] {
        var entities: [RememberedEntity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(stmt, 0),
                  let kindC = sqlite3_column_text(stmt, 1),
                  let kind = RememberedEntity.Kind(rawValue: String(cString: kindC)) else { continue }
            entities.append(RememberedEntity(
                name: String(cString: nameC),
                kind: kind,
                hitCount: Int(sqlite3_column_int(stmt, 2)),
                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            ))
        }
        return entities
    }
}

/// Tier-0 extractor: on-device `NLTagger` NER for people/places/orgs plus noun
/// frequency for themes. Milliseconds per result, no model load, no weights — the
/// "activate only necessary things" tier. Runs identically on macOS for tests.
struct EntityExtractor {
    struct Hit: Equatable {
        let name: String
        let kind: RememberedEntity.Kind
    }

    private static let topicStopwords: Set<String> = [
        "this", "that", "with", "about", "from", "have", "will", "would", "there",
        "their", "them", "then", "when", "what", "where", "which", "while", "these",
        "those", "being", "because", "tonight", "today", "tomorrow", "morning",
        "night", "thing", "things", "stuff", "gonna", "wanna", "maybe", "little",
        "couple", "minutes", "thanks", "thank", "please", "sorry", "again",
    ]

    /// Kinship and close-relation words the NER tagger treats as common nouns. For a
    /// personal assistant these are the highest-value entities in the graph — "call mom"
    /// must remember Mom even though no tagger on earth labels lowercase "mom" a name.
    static let kinshipTerms: Set<String> = [
        "mom", "mum", "mother", "dad", "father", "papa", "sis", "bro", "sister",
        "brother", "babe", "boss", "aunt", "uncle", "nana", "grandma", "grandpa",
    ]

    static func extract(from text: String, maxTopics: Int = 3) -> [Hit] {
        var hits: [Hit] = []

        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: [.joinNames, .omitWhitespace]) { tag, range in
            let word = String(text[range]).trimmedName
            switch tag {
            case .personalName: hits.append(Hit(name: word, kind: .person))
            case .placeName: hits.append(Hit(name: word, kind: .place))
            case .organizationName: hits.append(Hit(name: word, kind: .organization))
            case .other, .none:
                if kinshipTerms.contains(word.lowercased()) {
                    hits.append(Hit(name: word, kind: .person))
                }
            default: break
            }
            return true
        }

        var nounCounts: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard tag == .noun else { return true }
            let word = text[range].localizedLowercase
            if kinshipTerms.contains(word) {
                hits.append(Hit(name: word, kind: .person))
                return true
            }
            guard word.count >= 4, !topicStopwords.contains(word),
                  !hits.contains(where: { $0.name.localizedCaseInsensitiveCompare(word) == .orderedSame }) else { return true }
            nounCounts[word, default: 0] += 1
            return true
        }

        let topics = nounCounts.sorted { $0.value > $1.value }.prefix(maxTopics)
            .map { Hit(name: $0.key, kind: .topic) }

        // De-duplicate case-insensitively while keeping first-seen order for edge chaining.
        var seen: Set<String> = []
        return (hits + topics).filter { seen.insert($0.name.localizedLowercase).inserted }
    }
}

extension String {
    /// NER ranges can carry leading articles/possessives ("the park", "mom's") — trim to
    /// the visual name the user would expect to see in Settings.
    var trimmedName: String {
        let tokens = split(separator: " ").drop { $0.lowercased() == "the" }
        let joined = tokens.joined(separator: " ")
        return joined.split(separator: "'").first.map(String.init) ?? joined
    }
}

/// In-memory implementation for tests and previews.
public actor EphemeralMemory: Memory {
    private var results: [CaptureResult] = []
    private var edits: [EditPair] = []
    public init() {}

    public func record(_ result: CaptureResult) { results.append(result) }
    public func recordEdit(_ pair: EditPair) { edits.append(pair) }
    public func delete(_ id: UUID) { results.removeAll { $0.id == id } }
    public func lexicon(limit: Int) -> [String] { [] }
    public func nearestEdits(to text: String, limit: Int) -> [EditPair] { Array(edits.suffix(limit)) }
    public func search(_ query: String, limit: Int) -> [CaptureResult] {
        results.filter { $0.shipped.localizedCaseInsensitiveContains(query) }.suffix(limit).reversed()
    }
}
