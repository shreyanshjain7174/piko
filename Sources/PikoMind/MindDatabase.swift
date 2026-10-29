import Foundation
import SQLite3

// SQLite's destructor macros are C preprocessor tokens the Clang importer does not expose to
// Swift. Same bitcast pattern as PikoMemory's SQLiteMemory.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum MindError: Error, Sendable, Equatable {
    case openFailed(String)
    case migrationFailed(version: Int, message: String)
    case prepareFailed(String)
    case stepFailed(String)
}

/// Piko's one memory file. Owns the SQLite connection and the schema version; everything that
/// remembers anything (capture history, turns, facts, entities, embeddings) lives in here.
///
/// Not thread-safe. Create it inside one actor and use it only from that actor.
public final class MindDatabase {
    public let handle: OpaquePointer

    /// Schema version this build writes. `PRAGMA user_version` holds the version on disk.
    public static var schemaVersion: Int { MindSchema.migrations.count }

    public convenience init(path: URL) throws {
        try self.init(path: path, migrations: MindSchema.migrations)
    }

    /// `migrations` is injectable so tests can prove a failing step rolls back.
    init(path: URL, migrations: [String]) throws {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard opened == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw MindError.openFailed(message)
        }
        handle = db
        do {
            try execute("PRAGMA foreign_keys = ON")
            try migrate(migrations)
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    public var userVersion: Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw MindError.stepFailed(lastError)
        }
    }

    /// Runs `body` in one transaction: all of it lands or none of it does.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    /// Each pending step runs in its own transaction with its version bump, so a failure leaves
    /// the file at the last good version and the next launch retries from there.
    private func migrate(_ migrations: [String]) throws {
        let onDisk = userVersion
        guard onDisk < migrations.count else { return }
        for version in onDisk..<migrations.count {
            do {
                try transaction {
                    try execute(migrations[version])
                    try execute("PRAGMA user_version = \(version + 1)")
                }
            } catch MindError.stepFailed(let message) {
                throw MindError.migrationFailed(version: version + 1, message: message)
            }
        }
    }
}
