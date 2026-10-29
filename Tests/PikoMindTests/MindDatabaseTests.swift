import Testing
import Foundation
import SQLite3
@testable import PikoMind

@Suite("PikoMind schema and migrations")
struct MindDatabaseTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    private func names(in db: MindDatabase) -> Set<String> {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db.handle, "SELECT name FROM sqlite_master WHERE type IN ('table','trigger','index')", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return names
    }

    private func count(_ table: String, in db: MindDatabase) -> Int {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db.handle, "SELECT count(*) FROM \(table)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// A file exactly as PikoMemory wrote it before versioning: tables present, user_version 0.
    private func makeLegacyFile(at url: URL, shipped: [String]) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, MindSchema.v1CaptureHistory, nil, nil, nil) == SQLITE_OK)
        for (index, text) in shipped.enumerated() {
            let sql = """
            INSERT INTO results VALUES ('\(UUID().uuidString)', 'raw', '\(text)', 'write', 'message',
            \(1_000 + index), 1, 2, 3)
            """
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    @Test("a fresh file is created at the current version with every memory table")
    func freshFile() throws {
        let db = try MindDatabase(path: temporaryURL())
        #expect(db.userVersion == MindDatabase.schemaVersion)
        let expected: Set = ["results", "results_fts", "items", "edits", "turns", "turns_fts",
                             "entities", "entity_aliases", "facts", "embeddings",
                             "turns_ai", "turns_ad", "facts_ad", "turns_session", "turns_source"]
        #expect(expected.isSubset(of: names(in: db)))
    }

    @Test("an unversioned file from an older build keeps its history and gains turns for it")
    func migratesLegacyFileInPlace() throws {
        let url = temporaryURL()
        try makeLegacyFile(at: url, shipped: ["Lunch with Riya on Friday", "Call the dentist"])

        let db = try MindDatabase(path: url)
        #expect(db.userVersion == MindDatabase.schemaVersion)
        #expect(count("results", in: db) == 2)
        let turns = try db.turns(session: MindDatabase.dictationSession, last: 10)
        #expect(turns.map(\.text) == ["Lunch with Riya on Friday", "Call the dentist"])
        #expect(turns.allSatisfy { $0.role == .user && $0.sourceID != nil })
        #expect(count("turns_fts WHERE turns_fts MATCH 'riya'", in: db) == 1)
    }

    @Test("reopening a migrated file changes nothing")
    func reopenIsIdempotent() throws {
        let url = temporaryURL()
        try makeLegacyFile(at: url, shipped: ["Only once"])
        _ = try MindDatabase(path: url)
        let reopened = try MindDatabase(path: url)
        #expect(count("turns", in: reopened) == 1)
    }

    @Test("a failing step rolls back and leaves the file at the last good version")
    func failedMigrationRollsBack() throws {
        let url = temporaryURL()
        let broken = [MindSchema.v1CaptureHistory, "CREATE TABLE half (x); NOT VALID SQL"]
        #expect(throws: MindError.self) { try MindDatabase(path: url, migrations: broken) }

        let db = try MindDatabase(path: url, migrations: [MindSchema.v1CaptureHistory])
        #expect(db.userVersion == 1)
        #expect(!names(in: db).contains("half"))
        // And the real schema still applies on the next launch.
        #expect(try MindDatabase(path: url).userVersion == MindDatabase.schemaVersion)
    }

    @Test("turn LSNs only grow, even after a turn is forgotten")
    func lsnNeverReused() throws {
        let db = try MindDatabase(path: temporaryURL())
        let first = try db.appendTurn(session: "s", role: .user, text: "one", sourceID: "a")
        try db.forgetTurns(sourceID: "a")
        let second = try db.appendTurn(session: "s", role: .assistant, text: "two")
        #expect(second > first)
        #expect(try db.turns(session: "s", last: 10).map(\.text) == ["two"])
    }

    @Test("turns come back oldest first, limited to the last N")
    func lastTurnsInOrder() throws {
        let db = try MindDatabase(path: temporaryURL())
        for word in ["a", "b", "c", "d"] {
            try db.appendTurn(session: "chat", role: .user, text: word)
        }
        try db.appendTurn(session: "other", role: .user, text: "x")
        #expect(try db.turns(session: "chat", last: 2).map(\.text) == ["c", "d"])
    }

    @Test("forgetting a turn removes its search entry and its vector")
    func forgetCascades() throws {
        let db = try MindDatabase(path: temporaryURL())
        let lsn = try db.appendTurn(session: "s", role: .user, text: "secret plan", sourceID: "x")
        try db.execute("INSERT INTO embeddings VALUES ('turn', '\(lsn)', 'test', 1, x'01')")
        try db.forgetTurns(sourceID: "x")
        #expect(count("turns_fts WHERE turns_fts MATCH 'secret'", in: db) == 0)
        #expect(count("embeddings", in: db) == 0)
    }

    @Test("a fact loses its source link, not itself, when that turn is forgotten")
    func factOutlivesSourceTurn() throws {
        let db = try MindDatabase(path: temporaryURL())
        let lsn = try db.appendTurn(session: "s", role: .user, text: "Riya is my sister", sourceID: "t")
        try db.execute("INSERT INTO facts (key, value, lsn, sourceLSN, createdAt) VALUES ('person/riya/relation', 'sister', 1, \(lsn), 0)")
        try db.forgetTurns(sourceID: "t")
        #expect(count("facts WHERE sourceLSN IS NULL", in: db) == 1)
    }
}
