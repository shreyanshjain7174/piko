import Foundation
import PikoBrain
import PikoKit
import PikoMemory
import SQLite3
import Testing
@testable import Piko

#if DEBUG
private enum PersonalFixtureError: Error { case sqlite }

private func personalFixturePath() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
}

private func removePersonalFixture(_ path: URL) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path.path + suffix)
    }
}

private func rawFactVectors(_ path: URL, insert: Bool) throws -> Int {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let handle else {
        sqlite3_close(handle)
        throw PersonalFixtureError.sqlite
    }
    defer { sqlite3_close(handle) }
    if insert {
        let sql = """
            INSERT INTO embeddings(ownerKind,ownerID,model,dimensions,vector)
            VALUES ('fact','my/sister','fixture',2,x'0000'),
                   ('fact','my/city','fixture',2,x'0000');
            """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw PersonalFixtureError.sqlite
        }
    }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM embeddings WHERE ownerKind = 'fact'", -1,
                             &stmt, nil) == SQLITE_OK else {
        throw PersonalFixtureError.sqlite
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw PersonalFixtureError.sqlite }
    return Int(sqlite3_column_int(stmt, 0))
}

@Suite("Native personal-memory tools with isolated SQLite", .serialized)
@MainActor
struct PersonalAssistantMemoryToolTests {
    @Test("The write tools are hidden and reject missing, mismatched and deleted captures")
    func originGuards() async throws {
        let path = personalFixturePath()
        defer { removePersonalFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let harness = ToolHarness(tools: AssistantTools.all(memory: memory, items: memory,
                                                            reminders: ReminderWriter()))
        #expect(!harness.descriptors.contains { $0.name == ToolName.remember || $0.name == ToolName.forget })
        #expect(!harness.actionDescriptors.contains { $0.name == ToolName.remember || $0.name == ToolName.forget })
        let tool = try #require(harness.tools[ToolName.remember])
        let text = "Remember my sister is Riya"
        let absent = ToolCall(tool: ToolName.remember, text: text)
        await #expect(throws: PersonalFactToolError.unverifiedOrigin) {
            try await tool.run(absent)
        }
        let failed = await harness.run([absent], approve: { _ in true })
        #expect(failed.first?.status == .failed(PersonalFactToolError.unverifiedOrigin.userMessage))
        let fabricatedSession = UUID()
        _ = try await memory.appendTurn(session: fabricatedSession, role: .user, text: text, at: .now)
        await #expect(throws: PersonalFactToolError.unverifiedOrigin) {
            try await tool.run(ToolCall(tool: ToolName.remember, text: text,
                                        sourceCaptureID: fabricatedSession))
        }
        let capture = CaptureResult(raw: text, shipped: text)
        await memory.record(capture)
        let source = try await memory.captureTurn(forCapture: capture.id)
        await #expect(throws: PersonalFactToolError.unverifiedOrigin) {
            try await tool.run(ToolCall(tool: ToolName.remember, text: text,
                                        sourceCaptureID: UUID()))
        }
        await #expect(throws: PersonalFactToolError.unverifiedOrigin) {
            try await tool.run(ToolCall(tool: ToolName.remember,
                                        text: "Remember my sister is Maya", sourceCaptureID: capture.id))
        }
        #expect(try await memory.fact(forKey: "my/sister") == nil)
        let saved = try await tool.run(ToolCall(tool: ToolName.remember, text: text,
                                                sourceCaptureID: capture.id))
        #expect(saved.contains("Riya"))
        let fact = try #require(try await memory.fact(forKey: "my/sister"))
        #expect(fact.sourceTurn == source.lsn)
        #expect(fact.confidence == 1)
        await memory.delete(capture.id)
        await #expect(throws: PersonalFactToolError.unverifiedOrigin) {
            try await tool.run(ToolCall(tool: ToolName.remember, text: text,
                                        sourceCaptureID: capture.id, expectedFactLSN: fact.lsn))
        }
        #expect(try await memory.fact(forKey: "my/sister")?.value == "Riya")
    }

    @Test("Update and forget bind the revision shown before confirmation")
    func staleRevisionNeedsFreshConfirmation() async throws {
        let path = personalFixturePath()
        defer { removePersonalFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let harness = ToolHarness(tools: AssistantTools.all(memory: memory, items: memory,
                                                            reminders: ReminderWriter()))
        let remember = try #require(harness.tools[ToolName.remember])
        let forget = try #require(harness.tools[ToolName.forget])
        let initial = CaptureResult(raw: "Remember my sister is Riya", shipped: "Remember my sister is Riya")
        let update = CaptureResult(raw: "Remember my sister is Maya", shipped: "Remember my sister is Maya")
        let removal = CaptureResult(raw: "Forget my sister", shipped: "Forget my sister")
        for capture in [initial, update, removal] { await memory.record(capture) }
        _ = try await remember.run(ToolCall(tool: ToolName.remember, text: initial.shipped,
                                            sourceCaptureID: initial.id))
        let first = try #require(try await memory.fact(forKey: "my/sister"))
        _ = try await remember.run(ToolCall(tool: ToolName.remember, text: update.shipped,
                                            sourceCaptureID: update.id, expectedFactLSN: first.lsn))
        await #expect(throws: PersonalFactToolError.changedSinceConfirmation) {
            try await forget.run(ToolCall(tool: ToolName.forget, text: removal.shipped,
                                          sourceCaptureID: removal.id, expectedFactLSN: first.lsn))
        }
        await #expect(throws: PersonalFactToolError.changedSinceConfirmation) {
            try await remember.run(ToolCall(tool: ToolName.remember, text: initial.shipped,
                                            sourceCaptureID: initial.id, expectedFactLSN: first.lsn))
        }
        #expect(try await memory.fact(forKey: "my/sister")?.value == "Maya")
        let current = try #require(try await memory.fact(forKey: "my/sister"))
        _ = try await forget.run(ToolCall(tool: ToolName.forget, text: removal.shipped,
                                          sourceCaptureID: removal.id, expectedFactLSN: current.lsn))
        #expect(try await memory.fact(forKey: "my/sister") == nil)
    }

    @Test("Confirm, reopen and forget purge only the fact's vectors, not its capture history")
    func storedFactReopensAndForgets() async throws {
        let path = personalFixturePath()
        defer { removePersonalFixture(path) }
        let memory = try SQLiteMemory(path: path)
        let harness = ToolHarness(tools: AssistantTools.all(memory: memory, items: memory,
                                                            reminders: ReminderWriter()))
        let text = "Remember my sister is Riya"
        let capture = CaptureResult(raw: text, shipped: text)
        let city = CaptureResult(raw: "Remember my city is Pune", shipped: "Remember my city is Pune")
        let removal = CaptureResult(raw: "Forget my sister", shipped: "Forget my sister")
        for item in [capture, city, removal] { await memory.record(item) }
        let remember = try #require(harness.tools[ToolName.remember])
        let forget = try #require(harness.tools[ToolName.forget])
        _ = try await remember.run(ToolCall(tool: ToolName.remember, text: capture.shipped,
                                            sourceCaptureID: capture.id))
        _ = try await remember.run(ToolCall(tool: ToolName.remember, text: city.shipped,
                                            sourceCaptureID: city.id))
        let reopened = try SQLiteMemory(path: path)
        let fact = try #require(try await reopened.fact(forKey: "my/sister"))
        let source = try await memory.captureTurn(forCapture: capture.id)
        #expect(fact.sourceTurn == source.lsn)
        #expect(try await reopened.turn(lsn: source.lsn) == source)
        #expect(try rawFactVectors(path, insert: true) == 2)
        _ = try await forget.run(ToolCall(tool: ToolName.forget, text: removal.shipped,
                                          sourceCaptureID: removal.id, expectedFactLSN: fact.lsn))
        #expect(try await reopened.fact(forKey: "my/sister") == nil)
        #expect(try await reopened.fact(forKey: "my/city")?.value == "Pune")
        #expect(try rawFactVectors(path, insert: false) == 1)
        #expect(await memory.search("Remember my sister is Riya", limit: 5).contains { $0.id == capture.id })
    }
}

#if targetEnvironment(simulator)
@Suite("Native Home personal flow with isolated history", .serialized)
@MainActor
struct PersonalAssistantHomeTests {
    @Test("Typed remember, no/yes, reopen, answer, unknown, forget and unknown after history remains")
    func confirmedPersonalFlow() async throws {
        let path = personalFixturePath()
        defer { removePersonalFixture(path) }
        let app = try AppComposition.isolatedForTests(historyPath: path)
        let model = HomeViewModel(app: app)
        let request = "Remember my sister is Riya"
        #expect(await model.submitTypedRequest(request))
        guard case .proposed(let firstPlan, let prompt, let canConfirm) = model.assistant else {
            Issue.record("Remember should present a confirmation"); return
        }
        #expect(canConfirm && prompt.contains("your sister is Riya"))
        #expect(firstPlan.count == 1 && firstPlan[0].tool == ToolName.remember)
        #expect(try await app.memory.fact(forKey: "my/sister") == nil)
        #expect(await model.submitTypedRequest("no"))
        #expect(try await app.memory.fact(forKey: "my/sister") == nil)
        #expect(await model.submitTypedRequest(request))
        guard case .proposed(let plan, _, true) = model.assistant,
              let captureID = plan.first?.sourceCaptureID else {
            Issue.record("Remember should bind its original capture"); return
        }
        let source = try await app.memory.captureTurn(forCapture: captureID)
        #expect(source.text == request && source.role == .user)
        await model.runPlan() // The card button uses the same confirmation and harness as spoken yes.
        guard case .done(let saved) = model.assistant,
              case .done(let message) = saved.first?.status else {
            Issue.record("Remember should show an actual saved outcome"); return
        }
        #expect(message.contains("Riya"))
        let reopened = try SQLiteMemory(path: path)
        #expect(try await reopened.fact(forKey: "my/sister")?.sourceTurn == source.lsn)
        #expect(await model.submitTypedRequest("Who is my sister?"))
        guard case .personalAnswer(let known, let citation) = model.assistant else {
            Issue.record("Known fact should answer from memory"); return
        }
        #expect(known == "Your sister is Riya.")
        #expect(citation != nil)
        #expect(await model.submitTypedRequest("What's my blood type?"))
        #expect(model.assistant == .personalAnswer("I don't know your blood type yet.", source: nil))
        #expect(await model.submitTypedRequest("Forget my sister"))
        guard case .proposed(_, let forgetPrompt, true) = model.assistant else {
            Issue.record("Forget should ask before deleting"); return
        }
        #expect(forgetPrompt.contains("forget what I saved about your sister"))
        #expect(try await app.memory.fact(forKey: "my/sister") != nil)
        #expect(await model.submitTypedRequest("yes"))
        #expect(try await reopened.fact(forKey: "my/sister") == nil)
        #expect(await app.memory.search(request, limit: 5).contains { $0.id == captureID })
        #expect(await model.submitTypedRequest("Who is my sister?"))
        #expect(model.assistant == .personalAnswer("I don't know your sister yet.", source: nil))
        #expect(model.phase != .capturing)
    }

    @Test("An update conflict stays visible and needs a fresh read-back")
    func staleUpdateConfirmation() async throws {
        let path = personalFixturePath()
        defer { removePersonalFixture(path) }
        let app = try AppComposition.isolatedForTests(historyPath: path)
        let model = HomeViewModel(app: app)
        #expect(await model.submitTypedRequest("Remember my sister is Riya"))
        #expect(await model.submitTypedRequest("yes"))
        let original = try #require(try await app.memory.fact(forKey: "my/sister"))
        #expect(await model.submitTypedRequest("Remember my sister is Priya"))
        guard case .proposed(let proposed, let readback, true) = model.assistant else {
            Issue.record("Update should be confirmed"); return
        }
        #expect(proposed.first?.expectedFactLSN == original.lsn)
        #expect(readback.contains("saved as Riya") && readback.contains("your sister is Priya"))

        // A second real user capture changes the fact before the pending "yes".
        let competing = CaptureResult(raw: "Remember my sister is Maya", shipped: "Remember my sister is Maya")
        await app.memory.record(competing)
        let source = try await app.memory.captureTurn(forCapture: competing.id)
        _ = try await app.memory.setFact(
            MemoryFactInput(key: "my/sister", value: "Maya", sourceTurn: source.lsn, confidence: 1),
            ifLSN: original.lsn
        )
        #expect(await model.submitTypedRequest("yes"))
        guard case .done(let conflict) = model.assistant else {
            Issue.record("A stale approval should show the failure"); return
        }
        #expect(conflict.first?.status == .failed(PersonalFactToolError.changedSinceConfirmation.userMessage))
        #expect(try await app.memory.fact(forKey: "my/sister")?.value == "Maya")
        #expect(await model.submitTypedRequest("Remember my sister is Priya"))
        guard case .proposed(_, let latestReadback, true) = model.assistant else {
            Issue.record("A fresh request should read the latest fact"); return
        }
        #expect(latestReadback.contains("saved as Maya"))
        #expect(await model.submitTypedRequest("yes"))
        #expect(try await app.memory.fact(forKey: "my/sister")?.value == "Priya")
        #expect(model.phase != .capturing)
    }

    @Test("A saved fact still answers without inventing a citation when its source is deleted")
    func deletedSourceHasNoCitation() async throws {
        let path = personalFixturePath()
        defer { removePersonalFixture(path) }
        let app = try AppComposition.isolatedForTests(historyPath: path)
        let model = HomeViewModel(app: app)
        #expect(await model.submitTypedRequest("Remember my city is Pune"))
        guard case .proposed(let plan, _, true) = model.assistant,
              let captureID = plan.first?.sourceCaptureID else {
            Issue.record("Remember should bind its capture"); return
        }
        #expect(await model.submitTypedRequest("yes"))
        await app.memory.delete(captureID)
        #expect(try await app.memory.fact(forKey: "my/city")?.sourceTurn == nil)
        #expect(await model.submitTypedRequest("What's my city?"))
        #expect(model.assistant == .personalAnswer("Your city is Pune.", source: nil))
        #expect(model.phase != .capturing)
    }
}
#endif
#endif
