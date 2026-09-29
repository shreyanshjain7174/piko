import Testing
import Foundation
import SQLite3
@testable import PikoMemory
import PikoKit

@Test("PikoMemoryTests target compiles and runs")
func targetIsWired() {
    #expect(EphemeralMemory.self is (any Memory.Type))
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
}

private func assertRecordAndSearchRoundTrips(_ memory: some Memory) async {
    // Match by id, not full struct equality: createdAt round-trips through
    // timeIntervalSince1970 (REAL storage), which is not guaranteed bit-exact
    // due to floating-point precision loss in the epoch-offset conversion.
    let result = CaptureResult(raw: "raw text", shipped: "a distinctive phrase here")
    await memory.record(result)
    let found = await memory.search("distinctive", limit: 10)
    #expect(found.contains(where: { $0.id == result.id }))

    let pair = EditPair(raw: "raw", shipped: "shipped", final: "final")
    await memory.recordEdit(pair)
    let edits = await memory.nearestEdits(to: "x", limit: 1)
    #expect(edits.count == 1)
}

// MARK: - Task 1: schema, init, record, recordEdit — the write path

@Test("SQLiteMemory(path:) creates the results/results_fts/edits/results_ai schema objects")
func schemaObjectsExist() throws {
    let path = temporaryDatabaseURL()
    _ = try SQLiteMemory(path: path)

    var db: OpaquePointer?
    // Read-write: the database is in WAL mode, and read-only connections cannot read
    // WAL databases without their -shm sidecar.
    #expect(sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    let sql = """
    SELECT name FROM sqlite_master WHERE type IN ('table','trigger')
    AND name IN ('results','results_fts','edits','results_ai')
    """
    #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }

    var names: Set<String> = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let name = sqlite3_column_text(stmt, 0) {
            names.insert(String(cString: name))
        }
    }
    #expect(names == ["results", "results_fts", "edits", "results_ai"])
}

@Test("record() persists a real row visible via a raw SQLite query")
func recordPersistsRow() async throws {
    let path = temporaryDatabaseURL()
    let memory = try SQLiteMemory(path: path)
    await memory.record(CaptureResult(raw: "let's grab lunch", shipped: "Let's grab lunch tomorrow"))

    var db: OpaquePointer?
    // Read-write: the database is in WAL mode, and read-only connections cannot read
    // WAL databases without their -shm sidecar.
    #expect(sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM results", -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    #expect(sqlite3_step(stmt) == SQLITE_ROW)
    #expect(sqlite3_column_int(stmt, 0) == 1)
}

@Test("recordEdit() persists a real row visible via a raw SQLite query")
func recordEditPersistsRow() async throws {
    let path = temporaryDatabaseURL()
    let memory = try SQLiteMemory(path: path)
    await memory.recordEdit(EditPair(raw: "hey", shipped: "Hey", final: "Hey!"))

    var db: OpaquePointer?
    // Read-write: the database is in WAL mode, and read-only connections cannot read
    // WAL databases without their -shm sidecar.
    #expect(sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM edits", -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    #expect(sqlite3_step(stmt) == SQLITE_ROW)
    #expect(sqlite3_column_int(stmt, 0) == 1)
}

// MARK: - Task 2: search, sanitizer, nearestEdits, lexicon — the read path

@Test("search finds a recorded result by a word from its shipped text")
func searchFindsWordInShippedText() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    let result = CaptureResult(raw: "raw", shipped: "Let's grab lunch tomorrow")
    await memory.record(result)

    // Match by id: createdAt's REAL round-trip through timeIntervalSince1970 is not
    // guaranteed bit-exact (floating-point precision loss in the epoch-offset conversion).
    let found = await memory.search("lunch", limit: 10)
    #expect(found.contains(where: { $0.id == result.id }))
}

@Test("multi-word query uses AND semantics; a never-recorded word returns empty")
func multiWordSearchUsesAndSemantics() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    let result = CaptureResult(raw: "raw", shipped: "Let's grab lunch tomorrow")
    await memory.record(result)

    let found = await memory.search("grab lunch", limit: 10)
    #expect(found.contains(where: { $0.id == result.id }))

    let notFound = await memory.search("giraffe", limit: 10)
    #expect(notFound.isEmpty)
}

@Test("FTS5 tokenizer does not match a mid-word partial substring")
func partialWordDoesNotMatch() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    await memory.record(CaptureResult(raw: "raw", shipped: "Let's grab lunch tomorrow"))

    let found = await memory.search("lun", limit: 10)
    #expect(found.isEmpty)
}

@Test("reserved FTS5 syntax in a query never throws or crashes")
func reservedSyntaxNeverCrashes() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    await memory.record(CaptureResult(raw: "raw", shipped: "call John: urgent"))

    _ = await memory.search("call John: urgent", limit: 10)
    _ = await memory.search("NOT", limit: 10)
    _ = await memory.search("*", limit: 10)
    // Reaching this line without a crash/throw is the assertion.
    #expect(Bool(true))
}

@Test("empty query returns every recorded result, most-recent-first")
func emptyQueryReturnsAllMostRecentFirst() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    await memory.record(CaptureResult(raw: "1", shipped: "first", createdAt: Date(timeIntervalSince1970: 1)))
    await memory.record(CaptureResult(raw: "2", shipped: "second", createdAt: Date(timeIntervalSince1970: 2)))
    await memory.record(CaptureResult(raw: "3", shipped: "third", createdAt: Date(timeIntervalSince1970: 3)))

    let all = await memory.search("", limit: 10)
    #expect(all.map(\.shipped) == ["third", "second", "first"])
}

@Test("nearestEdits ignores text and returns the last N in ascending order")
func nearestEditsReturnsLastNAscending() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    let one = EditPair(raw: "1", shipped: "one", final: "One")
    let two = EditPair(raw: "2", shipped: "two", final: "Two")
    let three = EditPair(raw: "3", shipped: "three", final: "Three")
    await memory.recordEdit(one)
    await memory.recordEdit(two)
    await memory.recordEdit(three)

    let lastTwo = await memory.nearestEdits(to: "irrelevant", limit: 2)
    // Compare by `raw` order, not full struct equality: EditPair has no id and its
    // createdAt round-trips through timeIntervalSince1970 (REAL storage), which is not
    // guaranteed bit-exact due to floating-point precision loss in the epoch-offset conversion.
    #expect(lastTwo.map(\.raw) == [two.raw, three.raw])
}

@Test("lexicon returns [] regardless of what has been recorded")
func lexiconAlwaysEmpty() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    await memory.record(CaptureResult(raw: "raw", shipped: "shipped"))
    let words = await memory.lexicon(limit: 10)
    #expect(words.isEmpty)
}

// MARK: - Task 3: reopen durability, concurrency, protocol-conformance parity

@Test("a brand-new SQLiteMemory instance opened at the same path sees prior writes")
func reopenSeesEveryPriorRecordedResult() async throws {
    let path = temporaryDatabaseURL()
    let instanceA = try SQLiteMemory(path: path)
    await instanceA.record(CaptureResult(raw: "1", shipped: "first result"))
    await instanceA.record(CaptureResult(raw: "2", shipped: "second result"))

    let instanceB = try SQLiteMemory(path: path)
    let all = await instanceB.search("", limit: 10)
    #expect(all.count == 2)
}

@Test("concurrent record/search from many tasks never crashes and yields an exact final count")
func concurrentRecordAndSearchIsSafe() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    let writeCount = 25

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<writeCount {
            group.addTask {
                await memory.record(CaptureResult(raw: "\(index)", shipped: "message \(index)"))
            }
            group.addTask {
                _ = await memory.search("", limit: 100)
            }
        }
    }

    let final = await memory.search("", limit: 100)
    #expect(final.count == writeCount)
}

@Test("EphemeralMemory and SQLiteMemory both satisfy the shared record/search/recordEdit/nearestEdits contract")
func protocolConformanceParity() async throws {
    await assertRecordAndSearchRoundTrips(EphemeralMemory())
    await assertRecordAndSearchRoundTrips(try SQLiteMemory(path: temporaryDatabaseURL()))
}

// MARK: - Deletion, so a privacy product can actually forget something

@Test("delete removes a result from both the table and the FTS index")
func deleteRemovesFromTableAndIndex() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    let keep = CaptureResult(raw: "keep raw", shipped: "a keepable phrase")
    let drop = CaptureResult(raw: "drop raw", shipped: "a droppable phrase")
    await memory.record(keep)
    await memory.record(drop)

    #expect(await memory.search("droppable", limit: 10).count == 1)

    await memory.delete(drop.id)

    #expect(await memory.search("droppable", limit: 10).isEmpty)
    #expect(await memory.search("keepable", limit: 10).contains { $0.id == keep.id })
}

@Test("deleting an unknown id changes nothing")
func deleteUnknownIDIsHarmless() async throws {
    let memory = try SQLiteMemory(path: temporaryDatabaseURL())
    let result = CaptureResult(raw: "raw", shipped: "a distinctive phrase here")
    await memory.record(result)

    await memory.delete(UUID())

    #expect(await memory.search("distinctive", limit: 10).count == 1)
}

@Test("EphemeralMemory.delete matches the SQLite behaviour")
func ephemeralDeleteMatches() async {
    let memory = EphemeralMemory()
    let result = CaptureResult(raw: "raw", shipped: "a distinctive phrase here")
    await memory.record(result)

    await memory.delete(result.id)

    #expect(await memory.search("distinctive", limit: 10).isEmpty)
}

