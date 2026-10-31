import Foundation
import PikoBrain
import PikoBridge
import PikoKit
import PikoMemory
import Testing
@testable import Piko

#if DEBUG && targetEnvironment(simulator)
private actor CountingDecider: AssistantDeciding {
    private(set) var calls = 0
    func decide(_ request: String, context: DecisionContext, tools: [ToolDescriptor], now: Date) async throws -> DecisionResult {
        calls += 1
        return .init(decision: .unknown("No evidence."), source: .rules(reason: "Fixture"))
    }
}

@Suite("Native context loop", .serialized)
@MainActor struct ContextLoopHomeTests {
    private func fixture(writer: PublishingMemory.Writer? = nil) throws
        -> (URL, URL, AppComposition, HomeViewModel, CountingDecider) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let decider = CountingDecider()
        let app = try AppComposition.isolatedForTests(historyPath: path, decider: decider,
                  suggestionsContainer: container, writer: writer)
        return (path, container, app, HomeViewModel(app: app), decider)
    }
    private func clean(_ path: URL, _ container: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path.path + suffix) }
        try? FileManager.default.removeItem(at: container)
    }
    private func voice(_ text: String, app: AppComposition, model: HomeViewModel) async {
        let capture = CaptureResult(raw: text, shipped: text)
        await app.memory.record(capture)
        await model.respond(to: capture)
    }

    @Test func loopStartsWithUnwrittenCard() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        #expect(await model.submitTypedRequest("Riya's usual is a flat white, and we meet on Fridays"))
        guard case .contextProposals(let card) = model.assistant else { Issue.record("Expected proposal card"); return }
        #expect(card.items.count == 2)
        #expect(await decider.calls == 0)
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
        await model.saveProposalCard(card.id)
        #expect(try await app.memory.fact(forKey: "person/riya/usual")?.value == "a flat white")
        #expect(try await app.memory.fact(forKey: "person/riya/meets")?.value == "Fridays")
        #expect(SuggestionSnapshotStore(containerURL: container).read().entries.contains { $0.key == "person/riya/usual" && $0.value == "a flat white" })
        #expect(await model.submitTypedRequest("what does Riya drink?"))
        guard case .personalAnswer(let answer, let source) = model.assistant else {
            Issue.record("Expected grounded answer"); return
        }
        #expect(answer.contains("flat white"))
        #expect(source?.contains("Riya") == true && source?.contains("flat white") == true)
        let settings = PersonalMemorySettingsModel(memory: app.memory)
        await settings.load()
        let fact = try #require(settings.facts.first(where: { $0.key == "person/riya/usual" }))
        settings.selectForForget(fact)
        await settings.confirmForget()
        #expect(await model.submitTypedRequest("what does Riya drink?"))
        #expect(model.assistant == .personalAnswer("I don't know that yet. Tell me and I can save it.", source: nil))
        #expect(!SuggestionSnapshotStore(containerURL: container).read().entries.contains { $0.key == "person/riya/usual" })
        #expect(await decider.calls == 0)
    }

    @Test func conflictKeepReplaceAndStaleCAS() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is a flat white"))
        guard case .contextProposals(let first) = model.assistant else { Issue.record("Card"); return }
        await model.saveProposalCard(first.id)
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is a cortado"))
        guard case .contextProposals(let second) = model.assistant,
              let row = second.items.first else { Issue.record("Conflict"); return }
        #expect(row.status == .conflict)
        await model.resolveProposal(second.id, row: row.id, decision: .keep)
        #expect(try await app.memory.fact(forKey: "person/riya/usual")?.value == "a flat white")
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is a cortado"))
        guard case .contextProposals(let third) = model.assistant,
              let replacement = third.items.first else { Issue.record("Replacement"); return }
        await model.resolveProposal(third.id, row: replacement.id, decision: .replace)
        #expect(try await app.memory.fact(forKey: "person/riya/usual")?.value == "a cortado")
        #expect(SuggestionSnapshotStore(containerURL: container).read().entries.contains { $0.key == "person/riya/usual" && $0.value == "a cortado" })
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is a latte"))
        guard case .contextProposals(let stale) = model.assistant,
              let staleRow = stale.items.first else { Issue.record("Stale card"); return }
        let current = try #require(try await app.memory.fact(forKey: "person/riya/usual"))
        _ = try await app.memory.setFact(.init(key: current.key, value: "tea", sourceTurn: try #require(current.sourceTurn),
                     confidence: 1, lastUsed: .now, entityID: current.entityID), ifLSN: current.lsn)
        await model.resolveProposal(stale.id, row: staleRow.id, decision: .replace)
        guard case .contextProposals(let refreshed) = model.assistant else { Issue.record("Restage"); return }
        #expect(refreshed.items.first?.changed == true)
        #expect(refreshed.items.first?.existing?.value == "tea")
        #expect(try await app.memory.fact(forKey: "person/riya/usual")?.value == "tea")
        #expect(await decider.calls == 0)
    }

    @Test func deletedConflictNeedsAnotherExplicitTap() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is tea"))
        guard case .contextProposals(let initial) = model.assistant else { Issue.record("Initial card"); return }
        await model.saveProposalCard(initial.id)
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is coffee"))
        guard case .contextProposals(let staged) = model.assistant,
              let row = staged.items.first else { Issue.record("Conflict card"); return }
        let old = try #require(try await app.memory.fact(forKey: "person/riya/usual"))
        try await app.memory.forgetFact(forKey: old.key, ifLSN: old.lsn)
        await model.resolveProposal(staged.id, row: row.id, decision: .replace)
        guard case .contextProposals(let refreshed) = model.assistant else { Issue.record("Restage"); return }
        #expect(refreshed.items.first?.changed == true)
        #expect(refreshed.items.first?.status == .pending)
        #expect(try await app.memory.fact(forKey: old.key) == nil)
        await model.saveProposal(refreshed.id, row: row.id)
        #expect(try await app.memory.fact(forKey: old.key)?.value == "coffee")
        #expect(await decider.calls == 0)
    }

    @Test func sensitiveStatementRefusedWithoutDecider() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is 4111 1111 1111 1111"))
        #expect(model.assistant == .answer("Piko doesn't save passwords, payment, codes or ID numbers."))
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
        #expect(await decider.calls == 0)
    }

    @Test func typedIsolationAndTypedYes() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is tea"))
        #expect(await model.submitTypedRequest("What is a haiku?"))
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is coffee"))
        #expect(await model.submitTypedRequest("yes"))
        #expect(try await app.memory.fact(forKey: "person/riya/usual")?.value == "coffee")
        #expect(await decider.calls == 1)
    }

    @Test func voiceOnlyConfirmsNewFactsWithExactAnswer() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        model.suppressAutomaticCaptureForTests = true
        model.setSpokenReplies(false)
        model.setQuietMode(false)
        model.setCompanionActive(true)
        defer { model.setCompanionActive(false) }
        await voice("Riya\u{27}s usual is tea", app: app, model: model)
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
        await voice("yes please", app: app, model: model)
        #expect(try await app.memory.fact(forKey: "person/riya/usual")?.value == "tea")
        await voice("Riya\u{27}s usual is coffee", app: app, model: model)
        guard case .contextProposals(let conflict) = model.assistant else {
            Issue.record("Expected conflict card"); return
        }
        #expect(conflict.items.first?.status == .conflict)
        await voice("yes", app: app, model: model)
        #expect(try await app.memory.fact(forKey: "person/riya/usual")?.value == "tea")
        await voice("no thanks", app: app, model: model)
        #expect(model.assistant == nil)
        #expect(await decider.calls == 0)
    }

    @Test func dismissAndDuplicateDoNotCreateAnotherFact() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is tea"))
        model.dismissAssistant()
        #expect(await model.submitTypedRequest("yes"))
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is tea"))
        guard case .contextProposals(let card) = model.assistant else { Issue.record("Card"); return }
        await model.saveProposalCard(card.id)
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is tea"))
        #expect(model.assistant == .answer("I already have that."))
        #expect(await decider.calls == 1)
    }

    @Test func typedInputAndNewVoiceTurnDiscardVoiceCard() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        model.suppressAutomaticCaptureForTests = true
        model.setSpokenReplies(false)
        model.setQuietMode(false)
        model.setCompanionActive(true)
        defer { model.setCompanionActive(false) }
        await voice("Riya\u{27}s usual is tea", app: app, model: model)
        guard case .contextProposals = model.assistant else { Issue.record("Voice card"); return }
        #expect(await model.submitTypedRequest("yes"))
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
        #expect(await decider.calls == 1)
        await voice("Riya\u{27}s usual is coffee", app: app, model: model)
        guard case .contextProposals = model.assistant else { Issue.record("New voice card"); return }
        model.beginVoiceTurn()
        #expect(model.assistant == nil)
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
    }

    @Test func stopAndBackgroundDiscardVoiceCard() async throws {
        let (path, container, app, model, _) = try fixture()
        defer { clean(path, container) }
        model.suppressAutomaticCaptureForTests = true
        model.setSpokenReplies(false)
        model.setQuietMode(false)
        model.setCompanionActive(true)
        await voice("Riya\u{27}s usual is tea", app: app, model: model)
        guard case .contextProposals = model.assistant else { Issue.record("Voice card"); return }
        app.onStopRequested?()
        #expect(model.assistant == nil)
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
        model.beginVoiceTurn()
        await voice("Riya\u{27}s usual is tea", app: app, model: model)
        guard case .contextProposals = model.assistant else { Issue.record("Second voice card"); return }
        model.setCompanionActive(false)
        #expect(model.assistant == nil)
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
    }

    @Test func publishFailureDoesNotRollBackFact() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let store = SuggestionSnapshotStore(containerURL: container)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let app = try AppComposition.isolatedForTests(historyPath: path, suggestionsContainer: container,
            writer: { snapshot in
                if !snapshot.entries.isEmpty { throw PublishFixtureFailure.failed }
                try store.write(snapshot)
            })
        let model = HomeViewModel(app: app)
        let noticeDelivery = AsyncStream<Void>.makeStream()
        let originalHandler = app.onPublishFailure
        app.onPublishFailure = { message in
            originalHandler?(message)
            noticeDelivery.continuation.yield(())
        }
        defer { clean(path, container); noticeDelivery.continuation.finish() }
        #expect(await model.submitTypedRequest("Riya\u{27}s usual is tea"))
        guard case .contextProposals(let card) = model.assistant else { Issue.record("Card"); return }
        await model.saveProposalCard(card.id)
        #expect(try await app.memory.fact(forKey: "person/riya/usual")?.value == "tea")
        var notices = noticeDelivery.stream.makeAsyncIterator()
        _ = await notices.next()
        #expect(model.notice?.contains("keyboard suggestions") == true)
        #expect(store.read() == .empty)
        let publishError = await app.publishingMemory.publishError
        #expect(publishError != nil)
        let settings = PersonalMemorySettingsModel(memory: app.memory)
        await settings.load()
        #expect(settings.errorMessage == publishError)
        #expect(settings.facts.count == 1)
    }

    @Test func missingCaptureFallsThroughToDecider() async throws {
        let (path, container, _, model, decider) = try fixture()
        defer { clean(path, container) }
        // Simulates a swallowed history insert: the response has no source turn.
        await model.respond(to: CaptureResult(raw: "hello", shipped: "hello"), voiceFollowUp: false)
        #expect(await decider.calls == 1)
        #expect(model.assistant == .answer("No evidence."))
    }

    @Test func voiceYesWithFailedSaveReportsFailure() async throws {
        let (path, container, app, model, _) = try fixture()
        defer { clean(path, container) }
        model.suppressAutomaticCaptureForTests = true
        model.setSpokenReplies(false)
        model.setQuietMode(false)
        model.setCompanionActive(true)
        defer { model.setCompanionActive(false) }
        await voice("Riya\u{27}s usual is tea", app: app, model: model)
        guard case .contextProposals = model.assistant else { Issue.record("Voice card"); return }
        let capture = try #require(await app.memory.search("Riya", limit: 1).first)
        await app.memory.delete(capture.id) // Source disappears after staging; confirm fails.
        await voice("yes", app: app, model: model)
        #expect(model.assistant == .answer("Could not save 1."))
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
    }

    @Test func keyboardDictationProducesNoCard() async throws {
        let (path, container, app, model, decider) = try fixture()
        defer { clean(path, container) }
        try? await app.captureCoordinator.startCapture(fromKeyboard: true)
        app.channel.writeResult(CaptureResult(raw: "Riya\u{27}s usual is tea", shipped: "Riya\u{27}s usual is tea"))
        let observer = Task { await model.observe() }
        await Task.yield()
        observer.cancel()
        #expect(model.assistant == nil)
        #expect(await decider.calls == 0)
        #expect(try await app.memory.fact(forKey: "person/riya/usual") == nil)
    }

    @Test func oldRememberToolRepublishes() async throws {
        let (path, container, app, model, _) = try fixture()
        defer { clean(path, container) }
        #expect(await model.submitTypedRequest("Remember my sister is Riya"))
        #expect(await model.submitTypedRequest("yes"))
        #expect(try await app.memory.fact(forKey: "my/sister")?.value == "Riya")
        #expect(SuggestionSnapshotStore(containerURL: container).read().entries.contains { $0.key == "my/sister" && $0.value == "Riya" })
    }

    @Test func listingOrdersRecentUseAndPublishesRecentFact() async throws {
        let (path, container, app, _, _) = try fixture()
        defer { clean(path, container) }
        let source = try await app.memory.appendTurn(session: UUID(), role: .user, text: "old and new", at: .now)
        let old = try await app.memory.setFact(.init(key: "my/old", value: "old", sourceTurn: source.lsn,
                     confidence: 1, lastUsed: Date(timeIntervalSince1970: 100), entityID: nil), ifLSN: nil)
        let newest = try await app.memory.setFact(.init(key: "my/new", value: "new", sourceTurn: source.lsn,
                     confidence: 1, lastUsed: Date(timeIntervalSince1970: 200), entityID: nil), ifLSN: nil)
        let listed = try await app.memory.facts(matching: nil, limit: 100)
        #expect(listed.map(\.key) == [newest.key, old.key])
        #expect(SuggestionSnapshotStore(containerURL: container).read().entries.first?.key == newest.key)
    }
    @Test func newestRevisionSurvivesLastUsedCapAndRelaunch() async throws {
        let (path, container, app, _, _) = try fixture()
        defer { clean(path, container) }
        let source = try await app.memory.appendTurn(session: UUID(), role: .user, text: "my facts", at: .now)
        for index in 0..<100 {
            _ = try await app.memory.setFact(.init(key: "my/older-\(index)", value: "value-\(index)",
                sourceTurn: source.lsn, confidence: 1, lastUsed: .now), ifLSN: nil)
        }
        let newest = try await app.memory.setFact(.init(key: "my/newest", value: "fresh",
            sourceTurn: source.lsn, confidence: 1, lastUsed: Date(timeIntervalSince1970: 1)), ifLSN: nil)
        let listed = try await app.memory.facts(matching: nil, limit: 100)
        #expect(!listed.contains { $0.key == newest.key }) // SQLite lists by lastUsed, not LSN.
        let snapshot = SuggestionSnapshotStore(containerURL: container)
        #expect(snapshot.read().entries.contains { $0.key == newest.key && $0.factLSN == newest.lsn })
        let reopened = try AppComposition.isolatedForTests(historyPath: path, suggestionsContainer: container)
        await reopened.publishingMemory.republish()
        #expect(snapshot.read().entries.contains { $0.key == newest.key })
    }
}
private enum PublishFixtureFailure: Error { case failed }
#endif
