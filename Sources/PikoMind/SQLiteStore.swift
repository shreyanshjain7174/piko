import Foundation
import SQLite3
import PikoKit

// SQLite's destructor macros are C preprocessor tokens the Clang importer does not expose to
// Swift. This is the same bitcast pattern used by stephencelis/SQLite.swift's Statement.swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteStoreError: Error, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case invalidRow(String)
    case unsupportedSchemaVersion(Int)
    case rollbackFailed(migration: String, rollback: String)
    case transactionRollbackFailed(operation: String, rollback: String)
    case revisionNotAhead(allocated: Int64, existing: Int64)
}

/// App-only owner of the existing history SQLite file and its versioned memory schema.
/// The compatibility operations deliberately retain the existing Memory/ItemStore behavior.
public actor SQLiteStore: Memory {
    // OpaquePointer isn't Sendable; deinit is nonisolated, so this needs the escape hatch.
    // Safe here: only ever mutated once (init) and read while the actor serializes all other
    // access, or in deinit after the last reference (and thus all other access) is gone.
    nonisolated(unsafe) private let db: OpaquePointer

    public init(path: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteStoreError.openFailed(message)
        }
        do {
            guard sqlite3_busy_timeout(handle, 5_000) == SQLITE_OK else {
                throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
            }
            guard sqlite3_exec(handle, "PRAGMA foreign_keys = ON", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
            }
            try SQLiteSchema.migrate(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        self.db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Write path

    public func record(_ result: CaptureResult) async {
        do {
            try insert(result)
        } catch {
            print("SQLiteStore: record failed: \(error)")
        }
    }

    private func insert(_ result: CaptureResult) throws {
        let sql = """
        INSERT INTO results (id, raw, shipped, route, profile, createdAt, firstWordMS, transcribeMS, brainMS)
        VALUES (?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
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
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func recordEdit(_ pair: EditPair) async {
        do {
            try insertEdit(pair)
        } catch {
            print("SQLiteStore: recordEdit failed: \(error)")
        }
    }

    public func delete(_ id: UUID) async {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM results WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteStore: delete failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("SQLiteStore: delete failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func insertEdit(_ pair: EditPair) throws {
        let sql = """
        INSERT INTO edits (raw, shipped, final, profile, createdAt)
        VALUES (?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, pair.raw, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, pair.shipped, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, pair.final, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, pair.profile.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, pair.createdAt.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
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
            print("SQLiteStore: nearestEdits prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var edits: [EditPair] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let pair = decodeEditPair(from: stmt) {
                edits.append(pair)
            }
            status = sqlite3_step(stmt)
        }
        if status != SQLITE_DONE {
            print("SQLiteStore: nearestEdits failed: \(String(cString: sqlite3_errmsg(db)))")
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
            print("SQLiteStore: queryRecent prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [CaptureResult] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let result = decodeCaptureResult(from: stmt) {
                results.append(result)
            }
            status = sqlite3_step(stmt)
        }
        if status != SQLITE_DONE {
            print("SQLiteStore: queryRecent failed: \(String(cString: sqlite3_errmsg(db)))")
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
            print("SQLiteStore: queryMatch prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [CaptureResult] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let result = decodeCaptureResult(from: stmt) {
                results.append(result)
            }
            status = sqlite3_step(stmt)
        }
        if status != SQLITE_DONE {
            print("SQLiteStore: queryMatch failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return results
    }

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
}

extension SQLiteStore: ItemStore {
    public func save(_ items: [DumpItem]) async {
        let sql = "INSERT OR REPLACE INTO items (id, kind, text, due, createdAt) VALUES (?,?,?,?,?)"
        for item in items {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("SQLiteStore: save item prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, item.text, -1, SQLITE_TRANSIENT)
            if let due = item.due {
                sqlite3_bind_double(stmt, 4, due.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_double(stmt, 5, item.createdAt.timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("SQLiteStore: save item failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        }
    }

    public func items(kind: DumpItem.Kind, limit: Int) async -> [DumpItem] {
        let sql = "SELECT id, kind, text, due, createdAt FROM items WHERE kind = ? ORDER BY createdAt DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteStore: items prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var items: [DumpItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(stmt) }
            guard let idC = sqlite3_column_text(stmt, 0), let kindC = sqlite3_column_text(stmt, 1),
                  let textC = sqlite3_column_text(stmt, 2),
                  let id = UUID(uuidString: String(cString: idC)),
                  let kind = DumpItem.Kind(rawValue: String(cString: kindC)) else { continue }
            let due = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            items.append(DumpItem(id: id, kind: kind, text: String(cString: textC), due: due,
                                  createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))))
        }
        if status != SQLITE_DONE {
            print("SQLiteStore: items failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return items
    }
}

// MARK: - App-only personal memory (final-v1 facts/entities/turns tables)

extension SQLiteStore {
    public func appendTurn(session: UUID, role: MemoryTurn.Role, text: String, at: Date) async throws -> MemoryTurn {
        try MemoryTurn.validate(text: text, at: at)
        try personalStatement("INSERT INTO turns (session,role,text,ts) VALUES (?,?,?,?)") { stmt in
            try bind(session.uuidString, at: 1, in: stmt)
            try bind(role.rawValue, at: 2, in: stmt)
            try bind(text, at: 3, in: stmt)
            try bind(at.timeIntervalSince1970, at: 4, in: stmt)
            try stepDone(stmt)
        }
        return MemoryTurn(lsn: sqlite3_last_insert_rowid(db), session: session, role: role, text: text, at: at)
    }

    public func captureTurn(forCapture id: UUID) async throws -> MemoryTurn {
        let source = try personalStatement("""
            SELECT t.lsn,t.session,t.role,t.text,t.ts FROM turns t
            JOIN results r ON r.id = t.session
            WHERE r.id = ? AND t.role = 'user' AND t.text = r.shipped AND t.ts = r.createdAt
            ORDER BY t.lsn ASC LIMIT 1
            """) { stmt in
            try bind(id.uuidString, at: 1, in: stmt)
            return try firstRow(stmt, decode: decodeTurn)
        }
        guard let source else { throw PersonalMemoryError.sourceCaptureMissing(id) }
        return source
    }

    public func turn(lsn: Int64) async throws -> MemoryTurn? {
        guard lsn > 0 else { throw PersonalMemoryError.invalidSourceTurn(lsn) }
        return try personalStatement("SELECT lsn,session,role,text,ts FROM turns WHERE lsn = ?") { stmt in
            try bind(lsn, at: 1, in: stmt)
            return try firstRow(stmt, decode: decodeTurn)
        }
    }

    public func turns(in session: UUID, limit: Int) async throws -> [MemoryTurn] {
        _ = try PersonalMemoryQuery.validated(nil, limit: limit)
        return try personalStatement("""
            SELECT lsn,session,role,text,ts FROM turns
            WHERE session = ? ORDER BY lsn DESC LIMIT ?
            """) { stmt in
            try bind(session.uuidString, at: 1, in: stmt)
            try bind(Int64(limit), at: 2, in: stmt)
            return try allRows(stmt, decode: decodeTurn)
        }
    }

    public func setFact(_ input: MemoryFactInput, ifLSN expected: Int64?) async throws -> MemoryFact {
        try input.validate()
        try validateExpectedLSN(expected)
        return try personalTransaction {
            try requireUserTurn(input.sourceTurn)
            if let entityID = input.entityID, try readEntity(id: entityID) == nil {
                throw PersonalMemoryError.entityMissing(entityID)
            }
            let current = try readFact(key: input.key)
            guard current?.lsn == expected else {
                throw PersonalMemoryError.factConflict(
                    key: input.key, expectedLSN: expected, actualLSN: current?.lsn
                )
            }
            if let expected {
                guard expected < Int64.max else { throw PersonalMemoryError.revisionExhausted }
                let revision = try appendFactMutation("memory.fact.set")
                try personalStatement("""
                    UPDATE facts SET value = ?, lsn = ?, sourceTurn = ?, confidence = ?,
                                     lastUsed = max(lastUsed, ?), entityID = ?
                    WHERE key = ? AND lsn = ?
                    """) { stmt in
                    try bind(input.value, at: 1, in: stmt)
                    try bind(revision, at: 2, in: stmt)
                    try bind(input.sourceTurn, at: 3, in: stmt)
                    try bind(input.confidence, at: 4, in: stmt)
                    try bind(input.lastUsed.timeIntervalSince1970, at: 5, in: stmt)
                    try bind(input.entityID, at: 6, in: stmt)
                    try bind(input.key, at: 7, in: stmt)
                    try bind(expected, at: 8, in: stmt)
                    try stepDone(stmt)
                }
                guard sqlite3_changes(db) == 1 else {
                    throw PersonalMemoryError.factConflict(
                        key: input.key, expectedLSN: expected, actualLSN: try readFact(key: input.key)?.lsn
                    )
                }
                // A vector of the old value is stale after overwriting the fact.
                try deleteFactEmbeddings(key: input.key)
            } else {
                let revision = try appendFactMutation("memory.fact.set")
                try personalStatement("""
                    INSERT INTO facts (key,value,lsn,sourceTurn,confidence,lastUsed,entityID)
                    VALUES (?,?,?,?,?,?,?)
                    """) { stmt in
                    try bind(input.key, at: 1, in: stmt)
                    try bind(input.value, at: 2, in: stmt)
                    try bind(revision, at: 3, in: stmt)
                    try bind(input.sourceTurn, at: 4, in: stmt)
                    try bind(input.confidence, at: 5, in: stmt)
                    try bind(input.lastUsed.timeIntervalSince1970, at: 6, in: stmt)
                    try bind(input.entityID, at: 7, in: stmt)
                    try stepDone(stmt)
                }
            }
            guard let saved = try readFact(key: input.key) else {
                throw SQLiteStoreError.invalidRow("fact disappeared during set")
            }
            return saved
        }
    }

    public func fact(forKey key: String) async throws -> MemoryFact? {
        try MemoryFact.validateKey(key)
        return try readFact(key: key)
    }

    public func facts(matching query: String?, limit: Int) async throws -> [MemoryFact] {
        let query = try PersonalMemoryQuery.validated(query, limit: limit)
        return try personalStatement("""
            SELECT f.key,f.value,f.lsn,f.sourceTurn,f.confidence,f.lastUsed,f.entityID
            FROM facts f LEFT JOIN entities e ON e.id = f.entityID
            WHERE ?1 IS NULL OR instr(lower(f.key),lower(?1)) > 0
                  OR instr(lower(f.value),lower(?1)) > 0
                  OR instr(lower(e.name),lower(?1)) > 0
                  OR instr(lower(e.aliases),lower(?1)) > 0
            ORDER BY f.lastUsed DESC, f.key ASC LIMIT ?2
            """) { stmt in
            try bind(query, at: 1, in: stmt)
            try bind(Int64(limit), at: 2, in: stmt)
            return try allRows(stmt, decode: decodeFact)
        }
    }

    public func touchFact(forKey key: String, ifLSN expected: Int64, at: Date) async throws -> MemoryFact {
        try MemoryFact.validateKey(key)
        try validateExpectedLSN(expected)
        guard at.timeIntervalSince1970.isFinite else { throw PersonalMemoryError.invalidTimestamp }
        guard expected < Int64.max else { throw PersonalMemoryError.revisionExhausted }
        return try personalTransaction {
            let current = try readFact(key: key)
            guard current?.lsn == expected else {
                throw PersonalMemoryError.factConflict(key: key, expectedLSN: expected, actualLSN: current?.lsn)
            }
            let revision = try appendFactMutation("memory.fact.used")
            try personalStatement("""
                UPDATE facts SET lastUsed = max(lastUsed, ?), lsn = ?
                WHERE key = ? AND lsn = ?
                """) { stmt in
                try bind(at.timeIntervalSince1970, at: 1, in: stmt)
                try bind(revision, at: 2, in: stmt)
                try bind(key, at: 3, in: stmt)
                try bind(expected, at: 4, in: stmt)
                try stepDone(stmt)
            }
            guard sqlite3_changes(db) == 1 else {
                throw PersonalMemoryError.factConflict(
                    key: key, expectedLSN: expected, actualLSN: try readFact(key: key)?.lsn
                )
            }
            guard let touched = try readFact(key: key) else {
                throw SQLiteStoreError.invalidRow("fact disappeared during touch")
            }
            return touched
        }
    }

    public func forgetFact(forKey key: String, ifLSN expected: Int64) async throws {
        try MemoryFact.validateKey(key)
        try validateExpectedLSN(expected)
        try personalTransaction {
            let current = try readFact(key: key)
            guard current?.lsn == expected else {
                throw PersonalMemoryError.factConflict(key: key, expectedLSN: expected, actualLSN: current?.lsn)
            }
            _ = try appendFactMutation("memory.fact.forget")
            try personalStatement("DELETE FROM facts WHERE key = ? AND lsn = ?") { stmt in
                try bind(key, at: 1, in: stmt)
                try bind(expected, at: 2, in: stmt)
                try stepDone(stmt) // The final-v1 trigger purges every fact-owned embedding.
            }
            guard sqlite3_changes(db) == 1 else {
                throw PersonalMemoryError.factConflict(
                    key: key, expectedLSN: expected, actualLSN: try readFact(key: key)?.lsn
                )
            }
        }
    }

    public func createEntity(_ entity: MemoryEntity) async throws {
        try entity.validate()
        let aliases = String(decoding: try JSONEncoder().encode(entity.aliases), as: UTF8.self)
        try personalTransaction {
            if try readEntity(id: entity.id) != nil {
                throw PersonalMemoryError.entityAlreadyExists(entity.id)
            }
            try personalStatement("""
                INSERT INTO entities (id,name,kind,createdAt,aliases,contactID) VALUES (?,?,?,?,?,?)
                """) { stmt in
                try bind(entity.id, at: 1, in: stmt)
                try bind(entity.name, at: 2, in: stmt)
                try bind(entity.kind, at: 3, in: stmt)
                try bind(entity.createdAt.timeIntervalSince1970, at: 4, in: stmt)
                try bind(aliases, at: 5, in: stmt)
                try bind(entity.contactID, at: 6, in: stmt)
                try stepDone(stmt)
            }
        }
    }

    public func entity(id: String) async throws -> MemoryEntity? {
        try MemoryEntity.validateID(id)
        return try readEntity(id: id)
    }

    public func entities(matching query: String?, limit: Int) async throws -> [MemoryEntity] {
        let query = try PersonalMemoryQuery.validated(query, limit: limit)
        return try personalStatement("""
            SELECT id,name,kind,createdAt,aliases,contactID FROM entities
            WHERE ?1 IS NULL OR instr(lower(name),lower(?1)) > 0
                  OR instr(lower(aliases),lower(?1)) > 0
                  OR instr(lower(kind),lower(?1)) > 0
            ORDER BY name ASC, id ASC LIMIT ?2
            """) { stmt in
            try bind(query, at: 1, in: stmt)
            try bind(Int64(limit), at: 2, in: stmt)
            return try allRows(stmt, decode: decodeEntity)
        }
    }

    public func forgetEntity(id: String) async throws {
        try MemoryEntity.validateID(id)
        try personalTransaction {
            guard try readEntity(id: id) != nil else { throw PersonalMemoryError.entityMissing(id) }
            let keys = try personalStatement("SELECT key FROM facts WHERE entityID = ? ORDER BY key") { stmt in
                try bind(id, at: 1, in: stmt)
                return try allRows(stmt, decode: { try text($0, column: 0) })
            }
            // Removing a link changes the fact's meaning; its old vector cannot be reused.
            try personalStatement("""
                DELETE FROM embeddings WHERE ownerKind = 'fact'
                AND ownerID IN (SELECT key FROM facts WHERE entityID = ?)
                """) { stmt in
                try bind(id, at: 1, in: stmt)
                try stepDone(stmt)
            }
            for key in keys {
                let revision = try appendFactMutation("memory.fact.unlinked")
                try personalStatement("UPDATE facts SET entityID = NULL, lsn = ? WHERE key = ? AND entityID = ?") { stmt in
                    try bind(revision, at: 1, in: stmt)
                    try bind(key, at: 2, in: stmt)
                    try bind(id, at: 3, in: stmt)
                    try stepDone(stmt)
                }
                guard sqlite3_changes(db) == 1 else {
                    throw SQLiteStoreError.invalidRow("fact disappeared during entity unlink")
                }
            }
            try personalStatement("DELETE FROM entities WHERE id = ?") { stmt in
                try bind(id, at: 1, in: stmt)
                try stepDone(stmt) // Trigger removes entity-owned vectors.
            }
        }
    }

    private func readFact(key: String) throws -> MemoryFact? {
        try personalStatement("""
            SELECT key,value,lsn,sourceTurn,confidence,lastUsed,entityID FROM facts WHERE key = ?
            """) { stmt in
            try bind(key, at: 1, in: stmt)
            return try firstRow(stmt, decode: decodeFact)
        }
    }

    private func readEntity(id: String) throws -> MemoryEntity? {
        try personalStatement("""
            SELECT id,name,kind,createdAt,aliases,contactID FROM entities WHERE id = ?
            """) { stmt in
            try bind(id, at: 1, in: stmt)
            return try firstRow(stmt, decode: decodeEntity)
        }
    }

    private func requireUserTurn(_ lsn: Int64) throws {
        try personalStatement("SELECT role FROM turns WHERE lsn = ?") { stmt in
            try bind(lsn, at: 1, in: stmt)
            guard let role = try firstRow(stmt, decode: { try text($0, column: 0) }) else {
                throw PersonalMemoryError.sourceTurnMissing(lsn)
            }
            guard role == MemoryTurn.Role.user.rawValue else {
                throw PersonalMemoryError.sourceTurnNotUser(lsn)
            }
        }
    }

    private func deleteFactEmbeddings(key: String) throws {
        try personalStatement("DELETE FROM embeddings WHERE ownerKind = 'fact' AND ownerID = ?") { stmt in
            try bind(key, at: 1, in: stmt)
            try stepDone(stmt)
        }
    }

    /// One actual, committed storage-tool result per fact mutation. Its keyless text preserves
    /// the operation without retaining personal values after a fact is forgotten. The isolated
    /// UUID session keeps internal results out of the user's bounded voice conversation.
    private func appendFactMutation(_ operation: String) throws -> Int64 {
        try personalStatement("INSERT INTO turns (session,role,text,ts) VALUES (?,'tool',?,?)") { stmt in
            try bind(UUID().uuidString, at: 1, in: stmt)
            try bind(operation, at: 2, in: stmt)
            try bind(Date.now.timeIntervalSince1970, at: 3, in: stmt)
            try stepDone(stmt)
        }
        let revision = sqlite3_last_insert_rowid(db)
        let existing = try personalStatement("SELECT coalesce(max(lsn),0) FROM facts") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            return sqlite3_column_int64(stmt, 0)
        }
        // A pre-API fact may carry an arbitrary larger revision. Never lower it or reuse it;
        // roll back this turn and require real turns to advance the durable AUTOINCREMENT log.
        guard revision > existing else {
            throw SQLiteStoreError.revisionNotAhead(allocated: revision, existing: existing)
        }
        return revision
    }

    private func validateExpectedLSN(_ expected: Int64?) throws {
        if let expected, expected < 0 { throw PersonalMemoryError.invalidExpectedLSN(expected) }
    }

    private func decodeTurn(_ stmt: OpaquePointer) throws -> MemoryTurn {
        let session = try text(stmt, column: 1)
        let role = try text(stmt, column: 2)
        guard let session = UUID(uuidString: session), let role = MemoryTurn.Role(rawValue: role) else {
            throw SQLiteStoreError.invalidRow("turn session or role")
        }
        return MemoryTurn(
            lsn: sqlite3_column_int64(stmt, 0), session: session, role: role,
            text: try text(stmt, column: 3), at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        )
    }

    private func decodeFact(_ stmt: OpaquePointer) throws -> MemoryFact {
        MemoryFact(
            key: try text(stmt, column: 0), value: try text(stmt, column: 1),
            lsn: sqlite3_column_int64(stmt, 2),
            sourceTurn: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3),
            confidence: sqlite3_column_double(stmt, 4),
            lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            entityID: try optionalText(stmt, column: 6)
        )
    }

    private func decodeEntity(_ stmt: OpaquePointer) throws -> MemoryEntity {
        let aliases = try text(stmt, column: 4)
        guard let names = try? JSONDecoder().decode([String].self, from: Data(aliases.utf8)) else {
            throw SQLiteStoreError.invalidRow("entity aliases")
        }
        return MemoryEntity(
            id: try text(stmt, column: 0), name: try text(stmt, column: 1),
            kind: try text(stmt, column: 2),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
            aliases: names, contactID: try optionalText(stmt, column: 5)
        )
    }

    private func text(_ stmt: OpaquePointer, column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(stmt, column) else {
            throw SQLiteStoreError.invalidRow("missing text column \(column)")
        }
        let buffer = UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
        guard let decoded = String(bytes: buffer, encoding: .utf8) else {
            throw SQLiteStoreError.invalidRow("invalid UTF-8 column \(column)")
        }
        return decoded
    }

    private func optionalText(_ stmt: OpaquePointer, column: Int32) throws -> String? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : try text(stmt, column: column)
    }

    private func firstRow<T>(_ stmt: OpaquePointer, decode: (OpaquePointer) throws -> T) throws -> T? {
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return try decode(stmt)
    }

    private func allRows<T>(_ stmt: OpaquePointer, decode: (OpaquePointer) throws -> T) throws -> [T] {
        var rows: [T] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            rows.append(try decode(stmt))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    private func personalStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, at index: Int32, in stmt: OpaquePointer) throws {
        guard sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: String?, at index: Int32, in stmt: OpaquePointer) throws {
        if let value {
            try bind(value, at: index, in: stmt)
        } else if sqlite3_bind_null(stmt, index) != SQLITE_OK {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: Int64, at index: Int32, in stmt: OpaquePointer) throws {
        guard sqlite3_bind_int64(stmt, index, value) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: Double, at index: Int32, in stmt: OpaquePointer) throws {
        guard sqlite3_bind_double(stmt, index, value) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func personalTransaction<T>(_ body: () throws -> T) throws -> T {
        try executePersonal("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try executePersonal("COMMIT")
            return result
        } catch {
            let cause = error
            if sqlite3_get_autocommit(db) == 0 {
                do {
                    try executePersonal("ROLLBACK")
                } catch {
                    throw SQLiteStoreError.transactionRollbackFailed(
                        operation: String(describing: cause), rollback: String(describing: error)
                    )
                }
            }
            throw cause
        }
    }

    private func executePersonal(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}
