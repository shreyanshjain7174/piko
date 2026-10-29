import Foundation
import SQLite3
import Testing
import PikoKit
import PikoMemory
@testable import PikoMind

private struct DatabaseError: Error {
    let message: String
}

#if DEBUG
private func developmentBackupDirectory(_ path: URL) -> URL {
    path.appendingPathExtension("development-backups")
}

private func seedDevelopmentHistory(_ db: Database) throws {
    try seedLegacy(db)
    try db.execute("""
        CREATE TABLE turns (
            lsn INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, createdAt REAL NOT NULL,
            session TEXT NOT NULL, role TEXT NOT NULL CHECK (role IN ('user','assistant','tool','system')),
            text TEXT NOT NULL, ts REAL NOT NULL
        );
        INSERT INTO turns (lsn,id,createdAt,session,role,text,ts)
        SELECT 10, id, createdAt, id, 'user', raw, createdAt FROM results WHERE rowid = 1;
        INSERT INTO turns (lsn,id,createdAt,session,role,text,ts)
        SELECT 11, id, createdAt, id, 'assistant', shipped, createdAt FROM results WHERE rowid = 1;
        INSERT INTO turns (lsn,id,createdAt,session,role,text,ts)
        SELECT 20, id, createdAt, id, 'user', raw, createdAt FROM results WHERE rowid = 2;
        INSERT INTO turns (lsn,id,createdAt,session,role,text,ts)
        SELECT 21, id, createdAt, id, 'assistant', shipped, createdAt FROM results WHERE rowid = 2;
        UPDATE sqlite_sequence SET seq = 99 WHERE name = 'turns';
        CREATE TABLE entities (
            id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
            createdAt REAL NOT NULL, aliases TEXT NOT NULL DEFAULT '[]', contactID TEXT
        );
        CREATE TABLE facts (
            id TEXT NOT NULL PRIMARY KEY, text TEXT NOT NULL, createdAt REAL NOT NULL,
            key TEXT NOT NULL DEFAULT '', value TEXT NOT NULL DEFAULT '',
            lsn INTEGER NOT NULL DEFAULT 0 CHECK (lsn >= 0),
            sourceTurn INTEGER REFERENCES turns(lsn) ON DELETE SET NULL,
            confidence REAL NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 1),
            lastUsed REAL NOT NULL DEFAULT 0,
            entityID TEXT REFERENCES entities(id) ON DELETE SET NULL
        );
        CREATE UNIQUE INDEX facts_key ON facts (key);
        CREATE TABLE embeddings (
            ownerKind TEXT NOT NULL CHECK (ownerKind IN ('turn','fact','entity')),
            ownerID TEXT NOT NULL, model TEXT NOT NULL,
            dimensions INTEGER NOT NULL CHECK (dimensions > 0), vector BLOB NOT NULL,
            encoding TEXT NOT NULL DEFAULT 'float16' CHECK (encoding IN ('float16','int8')),
            PRIMARY KEY (ownerKind,ownerID,model)
        );
        CREATE INDEX turns_capture ON turns (id);
        CREATE TRIGGER turns_no_update BEFORE UPDATE ON turns BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        CREATE TRIGGER turns_no_replace BEFORE INSERT ON turns
        WHEN EXISTS (SELECT 1 FROM turns WHERE lsn = new.lsn) BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        CREATE TRIGGER results_turn AFTER INSERT ON results BEGIN
            INSERT INTO turns (id,createdAt,session,role,text,ts)
            VALUES (new.id,new.createdAt,new.id,'user',new.raw,new.createdAt),
                   (new.id,new.createdAt,new.id,'assistant',new.shipped,new.createdAt);
        END;
        CREATE TRIGGER results_forget AFTER DELETE ON results BEGIN
            DELETE FROM turns WHERE id = old.id;
        END;
        PRAGMA user_version = 2;
        """)
}

private final class DevelopmentRecoveryAuthorizer {
    let authorize: (Int32, UnsafePointer<CChar>?) -> Int32

    init(_ authorize: @escaping (Int32, UnsafePointer<CChar>?) -> Int32) {
        self.authorize = authorize
    }
}

private func withDevelopmentRecoveryAuthorizer<T>(
    _ db: Database,
    authorize: @escaping (Int32, UnsafePointer<CChar>?) -> Int32,
    perform: () throws -> T
) throws -> T {
    let context = Unmanaged.passRetained(DevelopmentRecoveryAuthorizer(authorize))
    defer {
        sqlite3_set_authorizer(db.handle, nil, nil)
        context.release()
    }
    guard sqlite3_set_authorizer(db.handle, { context, action, first, _, _, _ in
        guard let context else { return SQLITE_DENY }
        return Unmanaged<DevelopmentRecoveryAuthorizer>.fromOpaque(context)
            .takeUnretainedValue().authorize(action, first)
    }, context.toOpaque()) == SQLITE_OK else {
        throw DatabaseError(message: String(cString: sqlite3_errmsg(db.handle)))
    }
    return try perform()
}

@Suite struct DevelopmentHistoryRecoveryTests {
    @Test("A WAL writer after backup aborts recovery without losing its new capture")
    func concurrentWALWriterPreservesCapture() throws {
        let path = databaseURL()
        let directory = developmentBackupDirectory(path)
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }
        let db = try Database(path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0")
        try seedDevelopmentHistory(db)
        let writer = try Database(path)
        var inserted = false
        var writerError: (any Error)?
        _ = try withDevelopmentRecoveryAuthorizer(db, authorize: { action, _ in
            guard action == SQLITE_ATTACH else { return SQLITE_OK }
            do {
                try writer.execute("INSERT INTO results VALUES " +
                    "('55555555-5555-5555-5555-555555555555','New raw','New cleaned','write','email',123,1,2,3)")
                inserted = true
                return SQLITE_OK
            } catch {
                writerError = error
                return SQLITE_DENY
            }
        }) {
            // ATTACH is prepared after the backup, before the first source write.
            #expect(throws: (any Error).self) {
                try DevelopmentHistoryRecovery.reconcile(db.handle, backupDirectory: directory)
            }
        }
        #expect(inserted)
        #expect(writerError == nil)
        #expect(sqlite3_get_autocommit(db.handle) == 1)
        #expect(try db.rows("PRAGMA user_version") == [["2"]])
        #expect(try db.rows("SELECT count(*) FROM results") == [["3"]])
        #expect(try db.rows("SELECT count(*) FROM turns") == [["6"]])
        #expect(try db.rows("SELECT role,text FROM turns WHERE session='55555555-5555-5555-5555-555555555555' ORDER BY lsn") == [
            ["user", "New raw"], ["assistant", "New cleaned"],
        ])
        guard case .reconciled(let backup) = try DevelopmentHistoryRecovery.reconcile(path: path) else {
            Issue.record("Expected a fresh-snapshot retry to succeed")
            return
        }
        #expect(try db.rows("SELECT count(*) FROM turns") == [["3"]])
        #expect(try db.rows("SELECT lsn,role,text FROM turns WHERE session='55555555-5555-5555-5555-555555555555'") == [
            ["101", "user", "New cleaned"],
        ])
        let original = try Database(backup)
        #expect(try original.rows("SELECT count(*) FROM results") == [["3"]])
        #expect(try original.rows("SELECT count(*) FROM turns") == [["6"]])
    }

    @Test("A late DDL failure rolls back dropped tables, history and LSN state")
    func lateDDLFailureRollsBack() throws {
        let path = databaseURL()
        let directory = developmentBackupDirectory(path)
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }
        let db = try Database(path)
        try seedDevelopmentHistory(db)
        let schema = try db.rows("SELECT type,name,sql FROM sqlite_schema ORDER BY name")
        let tables = ["results", "items", "edits", "turns", "facts", "entities", "embeddings", "sqlite_sequence"]
        let rows = try tables.map { try db.rows("SELECT rowid,* FROM \($0) ORDER BY rowid") }
        var denied = false
        _ = try withDevelopmentRecoveryAuthorizer(db, authorize: { action, name in
            // facts, embeddings and entities have already been dropped at this point.
            if action == SQLITE_DROP_TABLE, let name, String(cString: name) == "turns" {
                denied = true
                return SQLITE_DENY
            }
            return SQLITE_OK
        }) {
            #expect(throws: (any Error).self) {
                try DevelopmentHistoryRecovery.reconcile(db.handle, backupDirectory: directory)
            }
        }
        #expect(denied)
        #expect(sqlite3_get_autocommit(db.handle) == 1)
        #expect(try db.rows("PRAGMA user_version") == [["2"]])
        #expect(try db.rows("SELECT type,name,sql FROM sqlite_schema ORDER BY name") == schema)
        #expect(try tables.map { try db.rows("SELECT rowid,* FROM \($0) ORDER BY rowid") } == rows)
        #expect(try db.rows("PRAGMA quick_check") == [["ok"]])
        _ = try DevelopmentHistoryRecovery.reconcile(path: path)
        #expect(try db.rows("PRAGMA user_version") == [["1"]])
    }

    @Test("Verification keeps the original backup read-only and byte-for-byte unchanged")
    func verificationDoesNotMutateBackup() throws {
        let path = databaseURL()
        let directory = developmentBackupDirectory(path)
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }
        let db = try Database(path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0")
        try seedDevelopmentHistory(db)
        var capturedURL: URL?
        var bytesBefore: Data?
        var captureError: (any Error)?
        let outcome = try withDevelopmentRecoveryAuthorizer(db, authorize: { action, name in
            guard action == SQLITE_ATTACH, let name else { return SQLITE_OK }
            do {
                var components = URLComponents(string: String(cString: name))
                components?.query = nil
                guard let url = components?.url else {
                    throw DatabaseError(message: "Invalid backup ATTACH URI")
                }
                capturedURL = url
                bytesBefore = try Data(contentsOf: url)
                return SQLITE_OK
            } catch {
                captureError = error
                return SQLITE_DENY
            }
        }) {
            try DevelopmentHistoryRecovery.reconcile(db.handle, backupDirectory: directory)
        }
        #expect(captureError == nil)
        guard case .reconciled(let backup) = outcome else {
            Issue.record("Expected a retained original backup")
            return
        }
        let before = try #require(bytesBefore)
        #expect(capturedURL == backup)
        #expect(try Data(contentsOf: backup) == before)
        #expect(sqlite3_db_readonly(db.handle, "development_original") == 1)
        #expect(sqlite3_exec(db.handle, "DELETE FROM development_original.results", nil, nil, nil) == SQLITE_READONLY)
        #expect(try Data(contentsOf: backup) == before)
    }

    @Test("Empty history preserves its deleted-turn LSN high-water and next allocation")
    func emptyHistoryPreservesHighWater() async throws {
        let path = databaseURL()
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: developmentBackupDirectory(path))
        }
        let db = try Database(path)
        try seedDevelopmentHistory(db)
        try db.execute("DELETE FROM results")
        #expect(try db.rows("SELECT count(*) FROM turns") == [["0"]])
        guard case .reconciled(let backup) = try DevelopmentHistoryRecovery.reconcile(path: path) else {
            Issue.record("Expected empty development history to reconcile")
            return
        }
        #expect(try db.rows("SELECT count(*) FROM turns") == [["0"]])
        #expect(try db.rows("SELECT seq FROM sqlite_sequence WHERE name='turns'") == [["99"]])
        let original = try Database(backup)
        #expect(try original.rows("SELECT count(*) FROM turns") == [["0"]])
        #expect(try original.rows("SELECT seq FROM sqlite_sequence WHERE name='turns'") == [["99"]])
        let memory = try SQLiteMemory(path: path)
        await memory.record(CaptureResult(raw: "Later raw", shipped: "Later cleaned"))
        #expect(try db.rows("SELECT lsn,role,text FROM turns") == [["100", "user", "Later cleaned"]])
    }

    @Test("Explicit development recovery preserves history, duplicates, rowids, backups and LSN high water")
    func preservesHistory() async throws {
        let path = databaseURL()
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: developmentBackupDirectory(path))
        }
        let db = try Database(path)
        try seedDevelopmentHistory(db)
        let results = try db.rows("SELECT rowid,* FROM results ORDER BY rowid")
        let edits = try db.rows("SELECT rowid,* FROM edits ORDER BY rowid")
        let items = try db.rows("SELECT rowid,* FROM items ORDER BY rowid")
        let turns = try db.rows("SELECT * FROM turns ORDER BY lsn")
        let outcome = try DevelopmentHistoryRecovery.reconcile(path: path)
        guard case .reconciled(let backup) = outcome else {
            Issue.record("Expected an on-device backup and reconciliation")
            return
        }
        #expect(try db.rows("SELECT rowid,* FROM results ORDER BY rowid") == results)
        #expect(try db.rows("SELECT rowid,* FROM edits ORDER BY rowid") == edits)
        #expect(try db.rows("SELECT rowid,* FROM items ORDER BY rowid") == items)
        #expect(try db.rows("SELECT lsn,role,text FROM turns ORDER BY lsn") == [
            ["11", "user", "First keepsake"], ["21", "user", "Second keepsake"],
        ])
        let original = try Database(backup)
        #expect(try original.rows("PRAGMA user_version") == [["2"]])
        #expect(try original.rows("SELECT * FROM turns ORDER BY lsn") == turns)
        #expect(try original.rows("SELECT rowid,* FROM results ORDER BY rowid") == results)
        #expect(try original.rows("SELECT rowid,* FROM edits ORDER BY rowid") == edits)
        #expect(try original.rows("SELECT rowid,* FROM items ORDER BY rowid") == items)
        #expect(try original.rows("PRAGMA quick_check") == [["ok"]])
        let memory = try SQLiteMemory(path: path)
        #expect(await memory.search("keepsake", limit: 10).count == 2)
        await memory.record(CaptureResult(raw: "later raw", shipped: "Later clean"))
        #expect(try db.rows("SELECT max(lsn) FROM turns") == [["100"]])
        #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
    }

    @Test("Recovery backs up uncheckpointed WAL history")
    func includesWAL() throws {
        let path = databaseURL()
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: developmentBackupDirectory(path))
        }
        let db = try Database(path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0")
        try seedDevelopmentHistory(db)
        guard case .reconciled(let backup) = try DevelopmentHistoryRecovery.reconcile(path: path) else {
            Issue.record("Expected a complete SQLite backup")
            return
        }
        let original = try Database(backup)
        #expect(try original.rows("SELECT count(*) FROM results") == [["2"]])
        #expect(try original.rows("SELECT count(*) FROM turns") == [["4"]])
    }

    @Test("A commit failure rolls back every change and permits a later retry")
    func rollbackAndRetry() throws {
        let path = databaseURL()
        let directory = developmentBackupDirectory(path)
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }
        let db = try Database(path)
        try seedDevelopmentHistory(db)
        let turns = try db.rows("SELECT * FROM turns ORDER BY lsn")
        sqlite3_commit_hook(db.handle, { _ in 1 }, nil)
        #expect(throws: (any Error).self) {
            try DevelopmentHistoryRecovery.reconcile(db.handle, backupDirectory: directory)
        }
        sqlite3_commit_hook(db.handle, nil, nil)
        #expect(try db.rows("PRAGMA user_version") == [["2"]])
        #expect(try db.rows("SELECT * FROM turns ORDER BY lsn") == turns)
        #expect(try db.rows("SELECT seq FROM sqlite_sequence WHERE name='turns'") == [["99"]])
        _ = try DevelopmentHistoryRecovery.reconcile(path: path)
        #expect(try db.rows("PRAGMA user_version") == [["1"]])
    }

    @Test("Experimental memory is refused, never dropped", arguments: ["facts", "entities", "embeddings"])
    func refusesExperimentalMemory(_ table: String) throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedDevelopmentHistory(db)
        switch table {
        case "facts":
            try db.execute("INSERT INTO facts(id,text,createdAt) VALUES ('f','Important',123)")
        case "entities":
            try db.execute("INSERT INTO entities(id,name,kind,createdAt) VALUES ('e','Person','person',123)")
        default:
            try seedVectors(db, owners: [("turn", "11")])
        }
        let saved = try db.rows("SELECT * FROM \(table)")
        #expect(throws: DevelopmentHistoryRecovery.Failure.experimentalMemoryPresent) {
            try DevelopmentHistoryRecovery.reconcile(path: path)
        }
        #expect(try db.rows("SELECT * FROM \(table)") == saved)
        #expect(try db.rows("PRAGMA user_version") == [["2"]])
        #expect(!FileManager.default.fileExists(atPath: developmentBackupDirectory(path).path))
    }

    @Test("Manual turns and unknown layouts are preserved and refused", arguments: [false, true])
    func refusesUnknownContent(_ extraTable: Bool) throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedDevelopmentHistory(db)
        if extraTable {
            try db.execute("CREATE TABLE experimental(text TEXT); INSERT INTO experimental VALUES ('Keep')")
        } else {
            try db.execute("""
                INSERT INTO turns(id,createdAt,session,role,text,ts)
                VALUES ('manual',123,'manual','assistant','Do not discard',123)
                """)
        }
        let turns = try db.rows("SELECT * FROM turns ORDER BY lsn")
        #expect(throws: (any Error).self) { try DevelopmentHistoryRecovery.reconcile(path: path) }
        #expect(try db.rows("SELECT * FROM turns ORDER BY lsn") == turns)
        #expect(try db.rows("PRAGMA user_version") == [["2"]])
        #expect(!FileManager.default.fileExists(atPath: developmentBackupDirectory(path).path))
    }

    @Test("Unsupported versions are unchanged", arguments: [0, 3])
    func refusesOtherVersions(_ version: Int) throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        try db.execute("PRAGMA user_version = \(version)")
        #expect(throws: (any Error).self) { try DevelopmentHistoryRecovery.reconcile(path: path) }
        #expect(try db.rows("PRAGMA user_version") == [[String(version)]])
    }

    @Test("Already-current recovery is explicit and creates no extra backup")
    func idempotentCurrentStore() throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        _ = try SQLiteMemory(path: path)
        #expect(try DevelopmentHistoryRecovery.reconcile(path: path) == .alreadyCurrent)
        #expect(!FileManager.default.fileExists(atPath: developmentBackupDirectory(path).path))
    }

    @Test("A backup failure cannot change the original")
    func backupMustSucceed() throws {
        let path = databaseURL()
        let directory = developmentBackupDirectory(path)
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: directory)
        }
        let db = try Database(path)
        try seedDevelopmentHistory(db)
        try Data("Occupied backup destination".utf8).write(to: directory)
        #expect(throws: (any Error).self) { try DevelopmentHistoryRecovery.reconcile(path: path) }
        #expect(try db.rows("PRAGMA user_version") == [["2"]])
        #expect(try db.rows("SELECT count(*) FROM turns") == [["4"]])
    }
}
#endif

/// A separate SQLite connection: assertions inspect the file, not a mocked store.
private final class Database {
    let handle: OpaquePointer

    init(_ path: URL) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw DatabaseError(message: message)
        }
        handle = db
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func rows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "<NULL>"
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
        }
        return rows
    }
}

private func databaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
}

private let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

/// The unversioned schema shipped before PikoMind, including its external-content FTS index.
private func seedLegacy(_ db: Database) throws {
    try db.execute("""
        CREATE TABLE results (
            id TEXT NOT NULL UNIQUE, raw TEXT NOT NULL, shipped TEXT NOT NULL,
            route TEXT NOT NULL, profile TEXT NOT NULL, createdAt REAL NOT NULL,
            firstWordMS INTEGER NOT NULL, transcribeMS INTEGER NOT NULL, brainMS INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE results_fts USING fts5(
            raw, shipped, content='results', content_rowid='rowid'
        );
        CREATE TRIGGER results_ai AFTER INSERT ON results BEGIN
            INSERT INTO results_fts(rowid, raw, shipped) VALUES (new.rowid, new.raw, new.shipped);
        END;
        CREATE TRIGGER results_ad AFTER DELETE ON results BEGIN
            INSERT INTO results_fts(results_fts, rowid, raw, shipped)
            VALUES ('delete', old.rowid, old.raw, old.shipped);
        END;
        CREATE TABLE items (
            id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, text TEXT NOT NULL,
            due REAL, createdAt REAL NOT NULL
        );
        CREATE TABLE edits (
            raw TEXT NOT NULL, shipped TEXT NOT NULL, final TEXT NOT NULL,
            profile TEXT NOT NULL, createdAt REAL NOT NULL
        );
        INSERT INTO results VALUES
            ('\(firstID.uuidString)', 'legacyraw café', 'First keepsake', 'write', 'email', 1700000000.25, 11, 22, 33),
            ('\(secondID.uuidString)', 'second raw', 'Second keepsake', 'command', 'code', 1600000000.5, 44, 55, 66);
        INSERT INTO edits VALUES
            ('before', 'shipped', 'corrected café', 'email', 1700000001.25),
            ('before', 'shipped', 'corrected café', 'email', 1700000001.25);
        INSERT INTO items VALUES
            ('33333333-3333-3333-3333-333333333333', 'reminder', 'Call family', 1800000000.5, 1700000002.25),
            ('44444444-4444-4444-4444-444444444444', 'journal', 'A quiet day', NULL, 1700000003.25);
        """)
}

private func seedVectors(_ db: Database, owners: [(String, String)]) throws {
    for (kind, id) in owners {
        try db.execute("""
            INSERT INTO embeddings (ownerKind, ownerID, model, dimensions, vector, encoding)
            VALUES ('\(kind)', '\(id)', 'model-a', 2, X'00000100', 'float16'),
                   ('\(kind)', '\(id)', 'model-b', 2, X'0102', 'int8');
            """)
    }
}

@Suite struct SQLiteMigrationTests {
    @Test("Fresh files contain the versioned foundation and all compatibility objects")
    func freshSchema() throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        _ = try SQLiteMemory(path: path)
        let db = try Database(path)
        #expect(try db.rows("PRAGMA user_version") == [["1"]])
        let names = try db.rows("""
            SELECT name FROM sqlite_master WHERE type = 'table'
            AND name IN ('turns','facts','entities','embeddings','edits','results','results_fts','items')
            ORDER BY name
            """).compactMap(\.first)
        #expect(names == ["edits", "embeddings", "entities", "facts", "items", "results", "results_fts", "turns"])
        #expect(try db.rows("SELECT count(*) FROM turns") == [["0"]])
        #expect(try db.rows("PRAGMA table_info(turns)").map { $0[1] } == [
            "lsn", "session", "role", "text", "ts",
        ])
        #expect(try db.rows("PRAGMA table_info(facts)").map { $0[1] } == [
            "key", "value", "lsn", "sourceTurn", "confidence", "lastUsed", "entityID",
        ])
        #expect(try db.rows("PRAGMA table_info(facts)").first == ["0", "key", "TEXT", "1", "<NULL>", "1"])
    }

    @Test("Migration preserves every legacy value, rowid, duplicate correction and filed item")
    func preservesLegacyData() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        let results = try db.rows("SELECT rowid, * FROM results ORDER BY rowid")
        let edits = try db.rows("SELECT rowid, * FROM edits ORDER BY rowid")
        let items = try db.rows("SELECT rowid, * FROM items ORDER BY rowid")

        let memory = try SQLiteMemory(path: path)
        #expect(try db.rows("SELECT rowid, * FROM results ORDER BY rowid") == results)
        #expect(try db.rows("SELECT rowid, * FROM edits ORDER BY rowid") == edits)
        #expect(try db.rows("SELECT rowid, * FROM items ORDER BY rowid") == items)
        #expect(try db.rows("SELECT lsn, session, ts FROM turns ORDER BY lsn") == [
            ["1", firstID.uuidString, "1700000000.25"],
            ["2", secondID.uuidString, "1600000000.5"],
        ])
        let history = await memory.search("", limit: 10)
        #expect(history.map(\.id) == [firstID, secondID])
        #expect(history.first?.timings == .init(firstWordMS: 11, transcribeMS: 22, brainMS: 33))
        #expect(history.first?.profile == .email)
        #expect(history.last?.route == .command)
        #expect(await memory.search("legacyraw", limit: 10).map(\.id) == [firstID])
        #expect(await memory.search("Second", limit: 10).map(\.id) == [secondID])
        let corrections = await memory.nearestEdits(to: "ignored", limit: 10)
        #expect(corrections.count == 2)
        #expect(corrections.allSatisfy { $0.final == "corrected café" && $0.profile == .email })
        let reminders = await memory.items(kind: .reminder, limit: 10)
        #expect(reminders.first?.id.uuidString == "33333333-3333-3333-3333-333333333333")
        #expect(reminders.first?.due == Date(timeIntervalSince1970: 1_800_000_000.5))
        #expect(await memory.items(kind: .journal, limit: 10).first?.due == nil)
    }

    @Test("An absent legacy FTS index is rebuilt from the preserved content")
    func rebuildsLegacyFTS() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        try db.execute("INSERT INTO results_fts(results_fts) VALUES ('delete-all')")
        let memory = try SQLiteMemory(path: path)
        #expect(await memory.search("keepsake", limit: 10).count == 2)
        try db.execute("INSERT INTO results_fts(results_fts, rank) VALUES ('integrity-check', 1)")
    }

    @Test("Repeated reopen neither duplicates backfill nor consumes an LSN")
    func repeatedReopen() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        let memory = try SQLiteMemory(path: path)
        let appended = CaptureResult(raw: "new", shipped: "new keepsake")
        await memory.record(appended)
        let turns = try db.rows("SELECT * FROM turns ORDER BY lsn")
        let sequence = try db.rows("SELECT seq FROM sqlite_sequence WHERE name = 'turns'")
        for _ in 0..<3 {
            let reopened = try SQLiteMemory(path: path)
            #expect(await reopened.search("keepsake", limit: 10).count == 3)
        }
        #expect(try db.rows("SELECT * FROM turns ORDER BY lsn") == turns)
        #expect(try db.rows("SELECT seq FROM sqlite_sequence WHERE name = 'turns'") == sequence)
        #expect(sequence == [["3"]])
    }

    @Test("A migration error rolls back all DDL, data and version changes, and can be retried")
    func migrationRollbackAndRetry() throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        try db.execute("CREATE VIEW facts AS SELECT id FROM results")
        let schema = try db.rows("SELECT type, name, sql FROM sqlite_master ORDER BY name")
        let results = try db.rows("SELECT rowid, * FROM results ORDER BY rowid")
        var failed = false
        do {
            _ = try SQLiteMemory(path: path)
        } catch {
            failed = true
        }
        #expect(failed)
        #expect(try db.rows("PRAGMA user_version") == [["0"]])
        #expect(try db.rows("SELECT type, name, sql FROM sqlite_master ORDER BY name") == schema)
        #expect(try db.rows("SELECT rowid, * FROM results ORDER BY rowid") == results)
        try db.execute("DROP VIEW facts")
        _ = try SQLiteMemory(path: path)
        #expect(try db.rows("PRAGMA user_version") == [["1"]])
        #expect(try db.rows("SELECT count(*) FROM turns") == [["2"]])
    }

    @Test("Unsupported and future schemas are rejected without changing the file", arguments: [-1, 2, 99])
    func rejectsFutureVersion(version: Int) throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        try db.execute("PRAGMA user_version = \(version)")
        let schema = try db.rows("SELECT type, name, sql FROM sqlite_master ORDER BY name")
        let results = try db.rows("SELECT rowid, * FROM results ORDER BY rowid")
        var failed = false
        do {
            _ = try SQLiteMemory(path: path)
        } catch {
            failed = true
            #expect(String(describing: error).contains(String(version)))
        }
        #expect(failed)
        #expect(try db.rows("PRAGMA user_version") == [[String(version)]])
        #expect(try db.rows("SELECT type, name, sql FROM sqlite_master ORDER BY name") == schema)
        #expect(try db.rows("SELECT rowid, * FROM results ORDER BY rowid") == results)
    }

    @Test("Migrated FTS supports delete, subsequent writes and reuse of a deleted capture ID")
    func migratedDeleteAndWrites() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        let memory = try SQLiteMemory(path: path)
        await memory.delete(firstID)
        await memory.delete(UUID())
        #expect(await memory.search("legacyraw", limit: 10).isEmpty)
        #expect(try db.rows("SELECT count(*) FROM results") == [["1"]])
        #expect(try db.rows("SELECT count(*) FROM turns") == [["1"]])
        let replacement = CaptureResult(id: firstID, raw: "replacementraw", shipped: "Replacement keepsake")
        await memory.record(replacement)
        await memory.recordEdit(EditPair(raw: "new", shipped: "new", final: "corrected"))
        await memory.save([DumpItem(kind: .note, text: "A new note")])
        #expect(await memory.search("replacementraw", limit: 10).map(\.id) == [firstID])
        #expect(await memory.search("legacyraw", limit: 10).isEmpty)
        #expect(await memory.nearestEdits(to: "", limit: 1).first?.final == "corrected")
        #expect(await memory.items(kind: .note, limit: 10).first?.text == "A new note")
        #expect(try db.rows("SELECT lsn FROM turns ORDER BY lsn") == [["2"], ["3"]])
        try db.execute("INSERT INTO results_fts(results_fts, rank) VALUES ('integrity-check', 1)")
    }

    @Test("Turns append in insertion order, reject mutation, and failed duplicate captures consume no LSN")
    func appendOnlyMonotonicTurns() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let db = try Database(path)
        let first = CaptureResult(raw: "one", shipped: "one", createdAt: Date(timeIntervalSince1970: 200))
        let second = CaptureResult(raw: "two", shipped: "two", createdAt: Date(timeIntervalSince1970: 100))
        await memory.record(first)
        await memory.record(first)
        await memory.record(second)
        #expect(try db.rows("SELECT lsn, session FROM turns ORDER BY lsn") == [
            ["1", first.id.uuidString], ["2", second.id.uuidString],
        ])
        for sql in [
            "UPDATE turns SET ts = 0",
            """
            INSERT OR REPLACE INTO turns (lsn, session, role, text, ts)
            VALUES (1, 'rewrite', 'user', 'rewrite', 0)
            """,
        ] {
            var failed = false
            do { try db.execute(sql) } catch { failed = true }
            #expect(failed)
        }
        await memory.delete(first.id)
        await memory.record(CaptureResult(raw: "three", shipped: "three"))
        #expect(try db.rows("SELECT lsn FROM turns ORDER BY lsn") == [["2"], ["3"]])
        #expect(try db.rows("SELECT seq FROM sqlite_sequence WHERE name = 'turns'") == [["3"]])
    }

    @Test("A failed turn append atomically rolls back the capture and FTS insertion")
    func appendFailureRollsBackCapture() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let db = try Database(path)
        try db.execute("""
            CREATE TRIGGER fail_turn BEFORE INSERT ON turns BEGIN
                SELECT RAISE(ABORT, 'injected turn failure');
            END
            """)
        let capture = CaptureResult(raw: "atomic", shipped: "atomic keepsake")
        await memory.record(capture)
        #expect(try db.rows("SELECT count(*) FROM results") == [["0"]])
        #expect(await memory.search("atomic", limit: 10).isEmpty)
        try db.execute("DROP TRIGGER fail_turn")
        await memory.record(capture)
        #expect(try db.rows("SELECT lsn FROM turns ORDER BY lsn") == [["1"]])
        #expect(await memory.search("atomic", limit: 10).map(\.id) == [capture.id])
    }

    @Test("The PikoMind owner and compatibility adapter share one file and concurrent LSN sequence")
    func storeAndAdapterShareFile() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let memory = try SQLiteMemory(path: path)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let capture = CaptureResult(raw: "raw \(index)", shipped: "shared keepsake \(index)")
                    if index.isMultiple(of: 2) {
                        await store.record(capture)
                    } else {
                        await memory.record(capture)
                    }
                }
            }
        }
        let db = try Database(path)
        #expect(await store.search("shared", limit: 100).count == 20)
        #expect(await memory.search("shared", limit: 100).count == 20)
        #expect(try db.rows("SELECT lsn FROM turns ORDER BY lsn") == (1...20).map { [String($0)] })
        let note = DumpItem(kind: .note, text: "Shared note")
        await store.save([note])
        #expect(await memory.items(kind: .note, limit: 1).first?.id == note.id)
        await memory.delete(note.id) // Unknown capture ID must not touch the filed item.
        #expect(await store.items(kind: .note, limit: 1).first?.id == note.id)
    }

    @Test("Each legacy and new capture becomes exactly one shipped/user turn in its own session")
    func modelTurnContent() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        let memory = try SQLiteMemory(path: path)
        #expect(try db.rows("SELECT lsn, session, role, text, ts FROM turns ORDER BY lsn") == [
            ["1", firstID.uuidString, "user", "First keepsake", "1700000000.25"],
            ["2", secondID.uuidString, "user", "Second keepsake", "1600000000.5"],
        ])
        let capture = CaptureResult(raw: "unpolished private raw", shipped: "  user's café\n",
                                    createdAt: Date(timeIntervalSince1970: 1234.125))
        await memory.record(capture)
        #expect(try db.rows("SELECT session, role, text, ts FROM turns WHERE lsn > 2 ORDER BY lsn") == [
            [capture.id.uuidString, "user", capture.shipped, "1234.125"],
        ])
    }

    @Test("Keyed facts retain LSN/provenance/confidence/use, entity links, aliases and vector storage")
    func modelFactEntityAndEmbeddingFields() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let capture = CaptureResult(raw: "Riya is my sister", shipped: "Riya is my sister.")
        await memory.record(capture)
        let db = try Database(path)
        try db.execute("""
            PRAGMA foreign_keys = ON;
            INSERT INTO entities (id, name, kind, createdAt, aliases, contactID)
            VALUES ('riya', 'Riya', 'person', 100, '["Ri","Riya"]', 'contact-123');
            INSERT INTO facts (key, value, lsn, sourceTurn, confidence, lastUsed, entityID)
            VALUES ('person/riya/relation', 'sister', 1, 1, 0.875, 123.5, 'riya');
            INSERT INTO embeddings (rowid, ownerKind, ownerID, model, dimensions, vector, encoding)
            VALUES (9, 'fact', 'person/riya/relation', 'foundation', 512, zeroblob(1024), 'float16'),
                   (10, 'entity', 'riya', 'foundation', 512, zeroblob(512), 'int8');
            """)
        #expect(try db.rows("""
            SELECT f.key, f.value, f.lsn, f.sourceTurn, f.confidence, f.lastUsed,
                   e.aliases, e.contactID, t.role
            FROM facts f JOIN entities e ON e.id = f.entityID JOIN turns t ON t.lsn = f.sourceTurn
            """) == [["person/riya/relation", "sister", "1", "1", "0.875", "123.5",
                      "[\"Ri\",\"Riya\"]", "contact-123", "user"]])
        #expect(try db.rows("SELECT rowid, dimensions, length(vector), encoding FROM embeddings ORDER BY rowid") == [
            ["9", "512", "1024", "float16"], ["10", "512", "512", "int8"],
        ])
        var duplicateFailed = false
        do {
            try db.execute("""
                INSERT INTO facts (key, value, lsn, confidence, lastUsed)
                VALUES ('person/riya/relation', 'other', 1, 1, 123)
                """)
        } catch { duplicateFailed = true }
        #expect(duplicateFailed)
        // Expiring source text must not make an otherwise retained fact block deletion.
        try db.execute("DELETE FROM turns WHERE lsn = 1")
        #expect(try db.rows("SELECT value, sourceTurn FROM facts") == [["sister", "<NULL>"]])
        let next = CaptureResult(raw: "next", shipped: "next")
        await memory.record(next)
        try db.execute("UPDATE facts SET sourceTurn = 2")
        await memory.delete(capture.id)
        await memory.delete(next.id)
        #expect(try db.rows("SELECT value, sourceTurn FROM facts") == [["sister", "<NULL>"]])
        #expect(try db.rows("SELECT count(*) FROM turns") == [["0"]])
        _ = try SQLiteMemory(path: path)
        #expect(try db.rows("SELECT key, value FROM facts") == [["person/riya/relation", "sister"]])
    }

    @Test("History deletion purges its session; explicit turn expiry never reuses LSNs")
    func purgeContentAndPreserveSequence() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        let memory = try SQLiteMemory(path: path)
        let capture = CaptureResult(raw: "new private raw", shipped: "new private reply")
        await memory.record(capture)
        await memory.delete(firstID)
        await memory.delete(capture.id)
        #expect(try db.rows("SELECT text FROM turns ORDER BY lsn") == [["Second keepsake"]])
        #expect(await memory.search("legacyraw", limit: 10).isEmpty)
        #expect(await memory.search("private", limit: 10).isEmpty)
        try db.execute("DELETE FROM turns") // Storage must permit later expired-turn purges.
        _ = try SQLiteMemory(path: path) // Expired turns must not be backfilled again.
        #expect(try db.rows("SELECT count(*) FROM turns") == [["0"]])
        await memory.record(CaptureResult(raw: "after purge", shipped: "after purge"))
        #expect(try db.rows("SELECT lsn FROM turns ORDER BY lsn") == [["4"]])
    }

    @Test("A version-one label without the final schema is rejected, never upgraded or accepted")
    func rejectsNonfinalSchema() throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        try db.execute("PRAGMA user_version = 1")
        let schema = try db.rows("SELECT type, name, sql FROM sqlite_master ORDER BY name")
        let results = try db.rows("SELECT rowid, * FROM results ORDER BY rowid")
        var failed = false
        do {
            _ = try SQLiteMemory(path: path)
        } catch {
            failed = true
            #expect(String(describing: error).contains("unsupportedSchemaVersion(1)"))
        }
        #expect(failed)
        #expect(try db.rows("PRAGMA user_version") == [["1"]])
        #expect(try db.rows("SELECT type, name, sql FROM sqlite_master ORDER BY name") == schema)
        #expect(try db.rows("SELECT rowid, * FROM results ORDER BY rowid") == results)
    }

    @Test("Memory and direct turn deletion remove every model, scoped by owner kind and ID",
          arguments: [false, true])
    func turnEmbeddingCleanup(throughMemory: Bool) async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let capture = CaptureResult(raw: "private raw", shipped: "Private speech")
        let keeper = CaptureResult(raw: "keep raw", shipped: "Keep speech")
        await memory.record(capture)
        await memory.record(keeper)
        let db = try Database(path)
        let keeperLSN = try #require(db.rows("SELECT lsn FROM turns WHERE session = '\(keeper.id.uuidString)'").first?.first)
        try seedVectors(db, owners: [("turn", "1"), ("turn", keeperLSN), ("fact", "1"), ("entity", "1")])
        let before = try db.rows("SELECT ownerKind, ownerID, model, hex(vector) FROM embeddings ORDER BY 1, 2, 3")
        if throughMemory {
            await memory.delete(capture.id)
            #expect(await memory.search("Private", limit: 10).isEmpty)
        } else {
            try db.execute("DELETE FROM turns WHERE lsn = 1")
        }
        #expect(try db.rows("SELECT ownerKind, ownerID, model, hex(vector) FROM embeddings ORDER BY 1, 2, 3")
                == before.filter { !($0[0] == "turn" && $0[1] == "1") })
        #expect(await memory.search("Keep", limit: 10).map(\.id) == [keeper.id])
    }

    @Test("Direct fact/entity deletion removes all its models without touching same-ID owners",
          arguments: ["fact", "entity"])
    func ownerEmbeddingCleanup(kind: String) async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        await memory.record(CaptureResult(raw: "one", shipped: "One"))
        let db = try Database(path)
        try db.execute("""
            PRAGMA foreign_keys = ON;
            INSERT INTO entities (id, name, kind, createdAt) VALUES ('1', 'One', 'person', 100), ('keep', 'Keep', 'person', 100);
            INSERT INTO facts (key, value, lsn, entityID) VALUES ('1', 'one', 1, '1'), ('keep', 'keep', 1, 'keep');
            """)
        try seedVectors(db, owners: [("turn", "1"), ("fact", "1"), ("entity", "1"),
                                    ("fact", "keep"), ("entity", "keep")])
        let before = try db.rows("SELECT ownerKind, ownerID, model, hex(vector) FROM embeddings ORDER BY 1, 2, 3")
        try db.execute(kind == "fact" ? "DELETE FROM facts WHERE key = '1'" : "DELETE FROM entities WHERE id = '1'")
        #expect(try db.rows("SELECT ownerKind, ownerID, model, hex(vector) FROM embeddings ORDER BY 1, 2, 3")
                == before.filter { !($0[0] == kind && $0[1] == "1") })
        if kind == "entity" {
            #expect(try db.rows("SELECT entityID FROM facts WHERE key = '1'") == [["<NULL>"]])
        }
    }

    @Test("An embedding-delete failure rolls back history, turn, FTS and every model")
    func embeddingPurgeFailureIsAtomic() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let capture = CaptureResult(raw: "vectoratomic raw", shipped: "vectoratomic speech")
        await memory.record(capture)
        let db = try Database(path)
        try seedVectors(db, owners: [("turn", "1")])
        try db.execute("""
            CREATE TRIGGER fail_embedding BEFORE DELETE ON embeddings WHEN old.model = 'model-b' BEGIN
                SELECT RAISE(ABORT, 'injected embedding purge failure');
            END;
            """)
        await memory.delete(capture.id)
        #expect(await memory.search("vectoratomic", limit: 10).map(\.id) == [capture.id])
        #expect(try db.rows("SELECT count(*) FROM turns") == [["1"]])
        #expect(try db.rows("SELECT count(*) FROM embeddings") == [["2"]])
        try db.execute("INSERT INTO results_fts(results_fts, rank) VALUES ('integrity-check', 1)")
        try db.execute("DROP TRIGGER fail_embedding")
        await memory.delete(capture.id)
        #expect(await memory.search("vectoratomic", limit: 10).isEmpty)
        #expect(try db.rows("SELECT count(*) FROM turns") == [["0"]])
        #expect(try db.rows("SELECT count(*) FROM embeddings") == [["0"]])
    }

    @Test("A forget-all SQL sweep leaves zero user content, including vector owners and FTS terms")
    func forgetAllSweep() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        _ = try SQLiteMemory(path: path)
        try db.execute("""
            PRAGMA foreign_keys = ON;
            INSERT INTO entities (id, name, kind, createdAt) VALUES ('1', 'Private', 'person', 100);
            INSERT INTO facts (key, value, lsn, sourceTurn, entityID) VALUES ('1', 'private', 1, 1, '1');
            """)
        try seedVectors(db, owners: [("turn", "1"), ("turn", "2"), ("fact", "1"), ("entity", "1")])
        try db.execute("""
            BEGIN;
            DELETE FROM results;
            DELETE FROM turns;
            DELETE FROM facts;
            DELETE FROM entities;
            DELETE FROM edits;
            DELETE FROM items;
            COMMIT;
            CREATE VIRTUAL TABLE temp.forget_vocab USING fts5vocab(main, results_fts, row);
            """)
        for table in ["results", "results_fts", "turns", "facts", "entities", "embeddings", "edits", "items", "forget_vocab"] {
            #expect(try db.rows("SELECT count(*) FROM \(table)") == [["0"]], "Content remains in \(table)")
        }
        try db.execute("INSERT INTO results_fts(results_fts, rank) VALUES ('integrity-check', 1)")
        let memory = try SQLiteMemory(path: path)
        #expect(await memory.search("keepsake", limit: 10).isEmpty)
        await memory.record(CaptureResult(raw: "after forgetting", shipped: "After forgetting"))
        #expect(try db.rows("SELECT lsn FROM turns") == [["3"]])
    }

    @Test("A failed history purge leaves capture, turn and FTS intact")
    func historyPurgeFailureIsAtomic() async throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let db = try Database(path)
        let capture = CaptureResult(raw: "purgeatomic raw", shipped: "purgeatomic reply")
        await memory.record(capture)
        try db.execute("""
            CREATE TRIGGER fail_purge BEFORE DELETE ON turns BEGIN
                SELECT RAISE(ABORT, 'injected purge failure');
            END
            """)
        await memory.delete(capture.id)
        #expect(await memory.search("purgeatomic", limit: 10).map(\.id) == [capture.id])
        #expect(try db.rows("SELECT count(*) FROM turns") == [["1"]])
        try db.execute("DROP TRIGGER fail_purge")
        await memory.delete(capture.id)
        #expect(await memory.search("purgeatomic", limit: 10).isEmpty)
        #expect(try db.rows("SELECT count(*) FROM turns") == [["0"]])
    }
}
