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
    case unsupportedSchemaVersion(Int)
    case rollbackFailed(migration: String, rollback: String)
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
