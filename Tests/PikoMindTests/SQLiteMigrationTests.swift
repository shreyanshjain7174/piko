import Foundation
import SQLite3
import Testing
import PikoKit
import PikoMemory
import PikoMind

private struct DatabaseError: Error {
    let message: String
}

/// A separate SQLite connection: assertions inspect the file, not a mocked store.
private final class Database {
    let handle: OpaquePointer

    init(_ path: URL) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
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
        #expect(try db.rows("SELECT lsn, id, createdAt FROM turns ORDER BY lsn") == [
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

    @Test("A future schema is rejected without changing its version, schema or data")
    func rejectsFutureVersion() throws {
        let path = databaseURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try Database(path)
        try seedLegacy(db)
        try db.execute("PRAGMA user_version = 99")
        let schema = try db.rows("SELECT type, name, sql FROM sqlite_master ORDER BY name")
        let results = try db.rows("SELECT rowid, * FROM results ORDER BY rowid")
        var failed = false
        do {
            _ = try SQLiteMemory(path: path)
        } catch {
            failed = true
            #expect(String(describing: error).contains("99"))
        }
        #expect(failed)
        #expect(try db.rows("PRAGMA user_version") == [["99"]])
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
        #expect(try db.rows("SELECT count(*) FROM turns") == [["2"]])
        let replacement = CaptureResult(id: firstID, raw: "replacementraw", shipped: "Replacement keepsake")
        await memory.record(replacement)
        await memory.recordEdit(EditPair(raw: "new", shipped: "new", final: "corrected"))
        await memory.save([DumpItem(kind: .note, text: "A new note")])
        #expect(await memory.search("replacementraw", limit: 10).map(\.id) == [firstID])
        #expect(await memory.search("legacyraw", limit: 10).isEmpty)
        #expect(await memory.nearestEdits(to: "", limit: 1).first?.final == "corrected")
        #expect(await memory.items(kind: .note, limit: 10).first?.text == "A new note")
        #expect(try db.rows("SELECT lsn FROM turns ORDER BY lsn") == [["1"], ["2"], ["3"]])
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
        #expect(try db.rows("SELECT lsn, id FROM turns ORDER BY lsn") == [
            ["1", first.id.uuidString], ["2", second.id.uuidString],
        ])
        for sql in [
            "UPDATE turns SET createdAt = 0",
            "DELETE FROM turns",
            "INSERT OR REPLACE INTO turns (lsn, id, createdAt) VALUES (1, 'rewrite', 0)",
        ] {
            var failed = false
            do { try db.execute(sql) } catch { failed = true }
            #expect(failed)
        }
        await memory.delete(first.id)
        await memory.record(CaptureResult(raw: "three", shipped: "three"))
        #expect(try db.rows("SELECT lsn FROM turns ORDER BY lsn") == [["1"], ["2"], ["3"]])
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
        #expect(try db.rows("SELECT lsn FROM turns") == [["1"]])
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
}
