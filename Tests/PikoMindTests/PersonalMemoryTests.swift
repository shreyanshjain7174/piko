import Foundation
import SQLite3
import Testing
import PikoKit
import PikoMemory
@testable import PikoMind

private func temporaryFactsURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
}

private final class RawDatabase {
    let handle: OpaquePointer

    init(_ url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            defer { sqlite3_close(db) }
            throw SQLiteStoreError.openFailed("Synthetic test database did not open")
        }
        handle = db
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func rows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "<NULL>"
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return result
    }
}

@Suite struct PersonalMemoryTests {
    @Test("Fact provenance, confidence, last use, entity and aliases survive a new adapter and store")
    func reopenWithRealEvidence() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let session = UUID()
        let turn = try await store.appendTurn(
            session: session, role: .user, text: "Remember my sister is Riya",
            at: Date(timeIntervalSince1970: 123)
        )
        let entity = MemoryEntity(
            id: "riya", name: "Riya", kind: "person",
            createdAt: Date(timeIntervalSince1970: 124),
            aliases: ["Ri"], contactID: "local-contact"
        )
        try await store.createEntity(entity)
        let input = MemoryFactInput(
            key: "owner/sister/name", value: "Riya", sourceTurn: turn.lsn,
            confidence: 0.875, lastUsed: Date(timeIntervalSince1970: 125), entityID: entity.id
        )
        let saved = try await store.setFact(input, ifLSN: nil)
        #expect(saved.key == input.key && saved.value == input.value)
        #expect(saved.sourceTurn == turn.lsn && saved.lsn > turn.lsn)
        #expect(saved.confidence == 0.875 && saved.lastUsed == input.lastUsed)
        #expect(saved.entityID == entity.id)

        let reopened = try SQLiteMemory(path: path)
        #expect(try await reopened.fact(forKey: input.key) == saved)
        #expect(try await reopened.turn(lsn: turn.lsn) == turn)
        #expect(try await reopened.turns(in: session, limit: 1) == [turn])
        #expect(try await reopened.entity(id: entity.id) == entity)
        #expect(try await reopened.facts(matching: "sister", limit: 3).map(\.key) == [input.key])
        #expect(try await reopened.facts(matching: "Ri", limit: 3).map(\.key) == [input.key])
        #expect(try await reopened.entities(matching: "Ri", limit: 3) == [entity])
        let anotherStore = try SQLiteStore(path: path)
        #expect(try await anotherStore.fact(forKey: input.key) == saved)
    }

    @Test("A stale expected LSN cannot overwrite another writer, even across store instances")
    func concurrentCAS() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let first = try SQLiteStore(path: path)
        let second = try SQLiteMemory(path: path)
        let turn = try await first.appendTurn(session: UUID(), role: .user, text: "My sister is Riya", at: .now)
        let key = "owner/sister/name"

        for generation in 0..<4 {
            let expected: Int64? = generation == 0 ? nil : Int64(generation + 1)
            let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
                for index in 0..<16 {
                    group.addTask {
                        let input = MemoryFactInput(
                            key: key, value: "candidate-\(generation)-\(index)",
                            sourceTurn: turn.lsn, confidence: 1
                        )
                        do {
                            let writer: any Memory = index.isMultiple(of: 2) ? first : second
                            let saved = try await writer.setFact(input, ifLSN: expected)
                            return "saved:\(saved.lsn)"
                        } catch PersonalMemoryError.factConflict {
                            return "conflict"
                        } catch {
                            return "unexpected:\(error)"
                        }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(outcomes.filter { $0 == "saved:\(generation + 2)" }.count == 1)
            #expect(outcomes.filter { $0 == "conflict" }.count == 15, "\(outcomes)")
            #expect(try await second.fact(forKey: key)?.lsn == Int64(generation + 2))
        }
        let reopened = try SQLiteStore(path: path)
        #expect(try await reopened.facts(matching: nil, limit: 10).count == 1)
    }

    @Test("Fact updates and forget invalidate every owned vector, not unrelated owners")
    func factEmbeddingsAndAtomicFailures() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let turn = try await memory.appendTurn(session: UUID(), role: .user, text: "My sister is Riya", at: .now)
        let input = MemoryFactInput(key: "owner/sister/name", value: "Riya", sourceTurn: turn.lsn, confidence: 1)
        let first = try await memory.setFact(input, ifLSN: nil)
        let keeper = try await memory.setFact(
            MemoryFactInput(key: "owner/city", value: "Pune", sourceTurn: turn.lsn, confidence: 1),
            ifLSN: nil
        )
        let db = try RawDatabase(path)
        let turnsBeforeFailure = try db.rows("SELECT lsn,role,text FROM turns ORDER BY lsn")
        try db.execute("""
            INSERT INTO embeddings(ownerKind,ownerID,model,dimensions,vector)
            VALUES ('fact','owner/sister/name','a',2,x'0000'),
                   ('fact','owner/sister/name','b',2,x'0000'),
                   ('fact','owner/city','a',2,x'0000'),
                   ('turn','\(turn.lsn)','a',2,x'0000');
            CREATE TRIGGER reject_vector_delete BEFORE DELETE ON embeddings
            WHEN old.ownerID = 'owner/sister/name' AND old.model = 'b'
            BEGIN SELECT RAISE(ABORT, 'synthetic vector failure'); END;
            """)
        let changed = MemoryFactInput(key: input.key, value: "Riya Jain", sourceTurn: turn.lsn, confidence: 0.9)
        do {
            _ = try await memory.setFact(changed, ifLSN: first.lsn)
            Issue.record("Expected an injected vector-delete failure")
        } catch is SQLiteStoreError {}
        #expect(try await memory.fact(forKey: input.key) == first)
        #expect(try db.rows("SELECT count(*) FROM embeddings") == [["4"]])
        #expect(try db.rows("SELECT lsn,role,text FROM turns ORDER BY lsn") == turnsBeforeFailure)
        do {
            try await memory.forgetFact(forKey: first.key, ifLSN: first.lsn)
            Issue.record("Expected an injected vector-delete failure")
        } catch is SQLiteStoreError {}
        #expect(try await memory.fact(forKey: first.key) == first)
        #expect(try db.rows("SELECT lsn,role,text FROM turns ORDER BY lsn") == turnsBeforeFailure)
        try db.execute("DROP TRIGGER reject_vector_delete")

        let updated = try await memory.setFact(changed, ifLSN: first.lsn)
        #expect(updated.lsn == keeper.lsn + 1, "Failed transactions must not consume a turn LSN")
        #expect(updated.lsn > first.lsn && updated.value == changed.value)
        #expect(try db.rows("SELECT ownerKind, ownerID FROM embeddings ORDER BY 1, 2") == [
            ["fact", keeper.key], ["turn", String(turn.lsn)],
        ])
        try db.execute("""
            INSERT INTO embeddings(ownerKind,ownerID,model,dimensions,vector)
            VALUES ('fact','owner/sister/name','a',2,x'0000'),
                   ('fact','owner/sister/name','b',2,x'0000');
            """)
        do {
            try await memory.forgetFact(forKey: first.key, ifLSN: first.lsn)
            Issue.record("Expected a stale-version conflict")
        } catch let error as PersonalMemoryError {
            #expect(error == .factConflict(key: first.key, expectedLSN: first.lsn, actualLSN: updated.lsn))
        }
        #expect(try db.rows("SELECT count(*) FROM embeddings") == [["4"]])
        try await memory.forgetFact(forKey: first.key, ifLSN: updated.lsn)
        #expect(try await memory.fact(forKey: first.key) == nil)
        #expect(try await memory.fact(forKey: keeper.key) == keeper)
        #expect(try db.rows("SELECT ownerKind, ownerID FROM embeddings ORDER BY 1, 2") == [
            ["fact", keeper.key], ["turn", String(turn.lsn)],
        ])
    }

    @Test("Deleting and recreating a key never accepts a stale confirmed forget or update")
    func deleteRecreateABA() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let originalTurn = try await memory.appendTurn(
            session: UUID(), role: .user, text: "My sister is Riya", at: Date(timeIntervalSince1970: 123)
        )
        let key = "my/sister"
        let first = try await memory.setFact(
            MemoryFactInput(key: key, value: "Riya", sourceTurn: originalTurn.lsn, confidence: 1), ifLSN: nil
        )
        try await memory.forgetFact(forKey: key, ifLSN: first.lsn)
        let newTurn = try await memory.appendTurn(
            session: UUID(), role: .user, text: "My sister is Anya", at: Date(timeIntervalSince1970: 124)
        )
        let second = try await memory.setFact(
            MemoryFactInput(key: key, value: "Anya", sourceTurn: newTurn.lsn, confidence: 1), ifLSN: nil
        )
        #expect(second.lsn > first.lsn && second.sourceTurn == newTurn.lsn)
        await #expect(throws: PersonalMemoryError.factConflict(
            key: key, expectedLSN: first.lsn, actualLSN: second.lsn
        )) {
            try await memory.forgetFact(forKey: key, ifLSN: first.lsn)
        }
        await #expect(throws: PersonalMemoryError.factConflict(
            key: key, expectedLSN: first.lsn, actualLSN: second.lsn
        )) {
            try await memory.setFact(
                MemoryFactInput(key: key, value: "stale", sourceTurn: originalTurn.lsn, confidence: 1),
                ifLSN: first.lsn
            )
        }
        #expect(try await SQLiteMemory(path: path).fact(forKey: key) == second)
        let db = try RawDatabase(path)
        #expect(try db.rows("SELECT role,text FROM turns WHERE lsn = \(second.lsn)") == [
            ["tool", "memory.fact.set"],
        ])
        #expect(try db.rows("SELECT role,text FROM turns WHERE lsn = \(originalTurn.lsn)") == [
            ["user", "My sister is Riya"],
        ])
    }

    @Test("Fact revisions are globally increasing across different keys and reopen")
    func globalFactRevisions() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let source = try await store.appendTurn(
            session: UUID(), role: .user, text: "My city is Pune and my sister is Riya",
            at: Date(timeIntervalSince1970: 123)
        )
        let city = try await store.setFact(
            MemoryFactInput(key: "my/city", value: "Pune", sourceTurn: source.lsn, confidence: 1), ifLSN: nil
        )
        let reopened = try SQLiteMemory(path: path)
        let sister = try await reopened.setFact(
            MemoryFactInput(key: "my/sister", value: "Riya", sourceTurn: source.lsn, confidence: 1),
            ifLSN: nil
        )
        let used = try await store.touchFact(
            forKey: city.key, ifLSN: city.lsn, at: Date(timeIntervalSince1970: 200)
        )
        #expect(source.lsn < city.lsn && city.lsn < sister.lsn && sister.lsn < used.lsn)
        #expect(try await reopened.turn(lsn: used.lsn)?.role == .tool)
        #expect(try await reopened.fact(forKey: city.key)?.sourceTurn == source.lsn)
        #expect(try await reopened.fact(forKey: sister.key)?.sourceTurn == source.lsn)
    }

    @Test("A failed fact insert rolls back its tool result and does not consume an LSN")
    func insertionRollbackIncludesMutationTurn() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let source = try await store.appendTurn(
            session: UUID(), role: .user, text: "My sister is Riya", at: Date(timeIntervalSince1970: 123)
        )
        let input = MemoryFactInput(key: "my/sister", value: "Riya", sourceTurn: source.lsn, confidence: 1)
        let db = try RawDatabase(path)
        try db.execute("""
            CREATE TRIGGER reject_fact_insert BEFORE INSERT ON facts
            BEGIN SELECT RAISE(ABORT, 'synthetic fact failure'); END;
            """)
        do {
            _ = try await store.setFact(input, ifLSN: nil)
            Issue.record("Expected an injected fact-insert failure")
        } catch is SQLiteStoreError {}
        #expect(try db.rows("SELECT lsn,role,text FROM turns") == [
            [String(source.lsn), "user", source.text],
        ])
        #expect(try await store.fact(forKey: input.key) == nil)
        try db.execute("DROP TRIGGER reject_fact_insert")
        let created = try await store.setFact(input, ifLSN: nil)
        #expect(created.lsn == source.lsn + 1)
        #expect(try db.rows("SELECT role,text FROM turns WHERE lsn = \(created.lsn)") == [
            ["tool", "memory.fact.set"],
        ])
    }

    @Test("An inherited fact revision ahead of the actual turn log is rejected, never rewritten")
    func rejectsUnbackedLegacyRevision() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let source = try await store.appendTurn(
            session: UUID(), role: .user, text: "My sister is Riya", at: Date(timeIntervalSince1970: 123)
        )
        let db = try RawDatabase(path)
        try db.execute("""
            INSERT INTO facts(key,value,lsn,sourceTurn,confidence)
            VALUES ('legacy','Riya',99,\(source.lsn),1);
            """)
        do {
            _ = try await store.setFact(
                MemoryFactInput(key: "my/city", value: "Pune", sourceTurn: source.lsn, confidence: 1),
                ifLSN: nil
            )
            Issue.record("Expected the unsupported pre-API revision to be refused")
        } catch let error as SQLiteStoreError {
            guard case .revisionNotAhead(let allocated, let existing) = error else {
                Issue.record("Wrong storage error: \(error)")
                return
            }
            #expect(allocated == source.lsn + 1 && existing == 99)
        }
        #expect(try db.rows("SELECT lsn,role FROM turns") == [[String(source.lsn), "user"]])
        #expect(try await store.facts(matching: nil, limit: 10).map(\.key) == ["legacy"])
    }

    @Test("Queries are bounded; invalid sources, keys, confidence, timestamps and entity links fail without writes")
    func validationsAndQueries() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteStore(path: path)
        let user = try await memory.appendTurn(session: UUID(), role: .user, text: "Live in Pune", at: .now)
        let assistant = try await memory.appendTurn(session: UUID(), role: .assistant, text: "Okay", at: .now)
        let invalid: [(MemoryFactInput, PersonalMemoryError)] = [
            (.init(key: "bad", value: "not a user", sourceTurn: assistant.lsn, confidence: 1),
             .sourceTurnNotUser(assistant.lsn)),
            (.init(key: "missing", value: "none", sourceTurn: 900, confidence: 1),
             .sourceTurnMissing(900)),
            (.init(key: " ", value: "empty key", sourceTurn: user.lsn, confidence: 1),
             .invalidKey),
            (.init(key: "invalid", value: "bad confidence", sourceTurn: user.lsn, confidence: .nan),
             .invalidConfidence),
            (.init(key: "invalid", value: "bad time", sourceTurn: user.lsn, confidence: 1,
                   lastUsed: Date(timeIntervalSince1970: .infinity)),
             .invalidTimestamp),
            (.init(key: "invalid", value: "zero source", sourceTurn: 0, confidence: 1),
             .invalidSourceTurn(0)),
            (.init(key: "invalid", value: "bad\0value", sourceTurn: user.lsn, confidence: 1),
             .invalidValue),
            (.init(key: "invalid", value: "missing entity", sourceTurn: user.lsn,
                   confidence: 1, entityID: "not-here"),
             .entityMissing("not-here")),
        ]
        for (input, failure) in invalid {
            await #expect(throws: failure) { try await memory.setFact(input, ifLSN: nil) }
        }
        await #expect(throws: (any Error).self) {
            try await memory.appendTurn(session: UUID(), role: .user, text: "  ", at: .now)
        }
        await #expect(throws: PersonalMemoryError.invalidLimit(0)) {
            try await memory.facts(matching: nil, limit: 0)
        }
        await #expect(throws: PersonalMemoryError.invalidLimit(101)) {
            try await memory.entities(matching: nil, limit: 101)
        }
        await #expect(throws: PersonalMemoryError.invalidQuery) {
            try await memory.facts(matching: "  ", limit: 2)
        }
        #expect(try await memory.facts(matching: nil, limit: 10).isEmpty)
        let input = MemoryFactInput(key: "owner/city", value: "Pune", sourceTurn: user.lsn, confidence: 1)
        let fact = try await memory.setFact(input, ifLSN: nil)
        await #expect(throws: PersonalMemoryError.sourceTurnNotUser(fact.lsn)) {
            try await memory.setFact(
                MemoryFactInput(key: "owner/false-source", value: "false",
                                sourceTurn: fact.lsn, confidence: 1),
                ifLSN: nil
            )
        }
        #expect(try await memory.facts(matching: "' OR 1=1 --", limit: 5).isEmpty)
        #expect(try await memory.facts(matching: "Pune", limit: 1) == [fact])
        let latest = try await memory.setFact(
            MemoryFactInput(key: "owner/color", value: "Indigo", sourceTurn: user.lsn,
                            confidence: 0.8, lastUsed: Date(timeIntervalSince1970: 100)),
            ifLSN: nil
        )
        let oldest = try await memory.setFact(
            MemoryFactInput(key: "owner/food", value: "Mango", sourceTurn: user.lsn,
                            confidence: 0.8, lastUsed: Date(timeIntervalSince1970: 50)),
            ifLSN: nil
        )
        #expect(try await memory.facts(matching: nil, limit: 2).map(\.key) == [latest.key, oldest.key])
        #expect(try await memory.facts(matching: "INDIGO", limit: 1) == [latest])
        let touched = try await memory.touchFact(
            forKey: input.key, ifLSN: fact.lsn, at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(touched.lastUsed == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(touched.lsn > oldest.lsn && touched.sourceTurn == user.lsn)
        #expect(try await memory.facts(matching: nil, limit: 2).map(\.key) == [fact.key, latest.key])
        let db = try RawDatabase(path)
        #expect(try db.rows("SELECT count(*) FROM facts") == [["3"]])
        #expect(try db.rows("SELECT lsn,role FROM turns WHERE lsn <= 2 ORDER BY lsn")
                == [["1", "user"], ["2", "assistant"]])
    }

    @Test("Deleting an entity cleans its vectors and linked fact vectors, retaining facts without a false link")
    func entityDeletion() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let source = try await store.appendTurn(session: UUID(), role: .user, text: "Riya is my sister", at: .now)
        let entity = MemoryEntity(
            id: "riya", name: "Riya", kind: "person",
            createdAt: Date(timeIntervalSince1970: 123), aliases: ["Ri"]
        )
        try await store.createEntity(entity)
        let fact = try await store.setFact(
            MemoryFactInput(key: "owner/sister/name", value: "Riya", sourceTurn: source.lsn,
                            confidence: 1, entityID: entity.id),
            ifLSN: nil
        )
        let db = try RawDatabase(path)
        try db.execute("""
            INSERT INTO embeddings(ownerKind,ownerID,model,dimensions,vector)
            VALUES ('entity','riya','a',2,x'0000'),
                   ('fact','owner/sister/name','a',2,x'0000'),
                   ('turn','\(source.lsn)','a',2,x'0000');
            CREATE TRIGGER reject_entity_vector BEFORE DELETE ON embeddings
            WHEN old.ownerKind = 'entity' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;
            """)
        do {
            try await store.forgetEntity(id: entity.id)
            Issue.record("Expected an injected entity-vector failure")
        } catch is SQLiteStoreError {}
        #expect(try await store.entity(id: entity.id) == entity)
        #expect(try await store.fact(forKey: fact.key) == fact)
        #expect(try db.rows("SELECT count(*) FROM embeddings") == [["3"]])
        try db.execute("DROP TRIGGER reject_entity_vector")
        try await store.forgetEntity(id: entity.id)
        #expect(try await store.entity(id: entity.id) == nil)
        #expect(try await store.fact(forKey: fact.key)?.entityID == nil)
        #expect(try await store.fact(forKey: fact.key)?.lsn == fact.lsn + 1)
        #expect(try await store.fact(forKey: fact.key)?.sourceTurn == source.lsn)
        #expect(try db.rows("SELECT ownerKind FROM embeddings") == [["turn"]])
        await #expect(throws: PersonalMemoryError.factConflict(
            key: fact.key, expectedLSN: fact.lsn, actualLSN: fact.lsn + 1
        )) {
            try await store.forgetFact(forKey: fact.key, ifLSN: fact.lsn)
        }
        await #expect(throws: PersonalMemoryError.entityMissing(entity.id)) {
            try await store.forgetEntity(id: entity.id)
        }
    }

    @Test("Expiring a source turn makes provenance unavailable, never a fabricated citation")
    func expiredProvenance() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let turn = try await store.appendTurn(session: UUID(), role: .user, text: "My sister is Riya", at: .now)
        let fact = try await store.setFact(
            MemoryFactInput(key: "owner/sister/name", value: "Riya", sourceTurn: turn.lsn, confidence: 1),
            ifLSN: nil
        )
        let db = try RawDatabase(path)
        try db.execute("PRAGMA foreign_keys = ON; DELETE FROM turns WHERE lsn = \(turn.lsn)")
        #expect(try await store.turn(lsn: turn.lsn) == nil)
        #expect(try await store.fact(forKey: fact.key)?.sourceTurn == nil)
    }

    @Test("An existing final-v1 fact at default revision zero can be read and conditionally updated")
    func legacyFactRevision() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let memory = try SQLiteMemory(path: path)
        let source = try await memory.appendTurn(session: UUID(), role: .user, text: "My sister is Riya", at: .now)
        let db = try RawDatabase(path)
        try db.execute("""
            INSERT INTO facts(key,value,sourceTurn,confidence)
            VALUES ('owner/sister/name','Riya',\(source.lsn),0.7);
            """)
        let original = try #require(try await memory.fact(forKey: "owner/sister/name"))
        #expect(original.lsn == 0 && original.sourceTurn == source.lsn)
        let updated = try await memory.setFact(
            MemoryFactInput(key: original.key, value: "Riya Jain", sourceTurn: source.lsn, confidence: 1),
            ifLSN: original.lsn
        )
        #expect(updated.lsn > source.lsn && updated.value == "Riya Jain")
        #expect(try db.rows("SELECT lsn,sourceTurn,confidence FROM facts") == [
            [String(updated.lsn), String(source.lsn), "1.0"],
        ])
    }

    @Test("A rejected direct turn append consumes no LSN and can be retried")
    func failedTurnAppendKeepsSequence() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let db = try RawDatabase(path)
        try db.execute("""
            CREATE TRIGGER reject_personal_turn BEFORE INSERT ON turns
            BEGIN SELECT RAISE(ABORT, 'synthetic append failure'); END;
            """)
        let session = UUID()
        do {
            _ = try await store.appendTurn(session: session, role: .user, text: "My sister is Riya", at: .now)
            Issue.record("Expected an injected turn failure")
        } catch is SQLiteStoreError {}
        #expect(try db.rows("SELECT count(*) FROM turns") == [["0"]])
        try db.execute("DROP TRIGGER reject_personal_turn")
        let turn = try await store.appendTurn(
            session: session, role: .user, text: "My sister is Riya", at: Date(timeIntervalSince1970: 123)
        )
        #expect(turn.lsn == 1)
        #expect(try await store.turns(in: session, limit: 1) == [turn])
    }

    @Test("An orphan or manually appended user turn cannot stand in for a real capture ID")
    func originRequiresCapture() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let session = UUID()
        let turn = try await store.appendTurn(
            session: session, role: .user, text: "Remember my sister is Riya", at: Date(timeIntervalSince1970: 123)
        )
        await #expect(throws: PersonalMemoryError.sourceCaptureMissing(session)) {
            try await store.captureTurn(forCapture: session)
        }
        let capture = CaptureResult(id: session, raw: "Remember my sister is Riya",
                                    shipped: "Remember my sister is Riya",
                                    createdAt: Date(timeIntervalSince1970: 124))
        await store.record(capture)
        let source = try await store.captureTurn(forCapture: session)
        #expect(source.lsn > turn.lsn && source.text == capture.shipped && source.at == capture.createdAt)
        let reopened = try SQLiteMemory(path: path)
        #expect(try await reopened.captureTurn(forCapture: session) == source)
        await store.delete(session)
        await #expect(throws: PersonalMemoryError.sourceCaptureMissing(session)) {
            try await reopened.captureTurn(forCapture: session)
        }
    }

    @Test("Broken SQL read surfaces an error instead of pretending there are no facts")
    func brokenReadThrows() async throws {
        let path = temporaryFactsURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteStore(path: path)
        let db = try RawDatabase(path)
        try db.execute("DROP TABLE facts")
        do {
            _ = try await store.facts(matching: nil, limit: 2)
            Issue.record("Expected the SQL prepare failure to propagate")
        } catch is SQLiteStoreError {}
    }
}
