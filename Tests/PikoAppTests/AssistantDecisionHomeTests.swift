import Foundation
import PikoBrain
import PikoKit
import Testing
@testable import Piko

#if DEBUG && targetEnvironment(simulator)
private actor DecisionFixture {
    var responses: [DecisionResult]
    var requests: [(String, DecisionContext)] = []
    init(_ responses: [DecisionResult]) { self.responses = responses }
    func next(_ text: String, context: DecisionContext) -> DecisionResult {
        requests.append((text, context))
        return responses.isEmpty
            ? .init(decision: .unknown("No evidence."), source: .rules(reason: "Fixture empty"))
            : responses.removeFirst()
    }
}

private struct FixtureDecider: AssistantDeciding {
    let fixture: DecisionFixture
    func decide(_ request: String, context: DecisionContext, tools: [ToolDescriptor],
                now: Date) async throws -> DecisionResult {
        await fixture.next(request, context: context)
    }
}

private actor DecisionGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var hasArrived = false
    func pause() async {
        hasArrived = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func arrived() async {
        if hasArrived { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiting?.resume(); waiting = nil }
}

private struct PausedDecider: AssistantDeciding {
    let gate: DecisionGate
    func decide(_ request: String, context: DecisionContext, tools: [ToolDescriptor],
                now: Date) async throws -> DecisionResult {
        await gate.pause()
        return .init(decision: .answer("Late reply"), source: .model)
    }
}

@Suite("Native Home decision routing and voice context", .serialized)
@MainActor
struct AssistantDecisionHomeTests {
    private func makeFixture(_ decider: any AssistantDeciding) throws -> (URL, AppComposition, HomeViewModel) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let app = try AppComposition.isolatedForTests(historyPath: path, decider: decider)
        return (path, app, HomeViewModel(app: app))
    }
    private func clean(_ path: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path.path + suffix)
        }
    }
    private func voice(_ text: String, model: HomeViewModel, app: AppComposition) async {
        let capture = CaptureResult(raw: text, shipped: text)
        await app.memory.record(capture)
        await model.respond(to: capture)
    }

    @Test func typedAnswerAskActionAndRulesCaption() async throws {
        let fixture = DecisionFixture([
            .init(decision: .answer("A gentle answer"), source: .model),
            .init(decision: .ask("Which one?"), source: .model),
            .init(decision: .unknown("I do not know."), source: .rules(reason: "Model unavailable")),
            .init(decision: .act([ToolCall(tool: ToolName.note, text: "Milk")]), source: .model),
        ])
        let (path, _, model) = try makeFixture(FixtureDecider(fixture: fixture))
        defer { clean(path) }
        #expect(await model.submitTypedRequest("What is a haiku?"))
        #expect(model.assistant == .answer("A gentle answer"))
        #expect(model.engineCaption == "On-device model")
        #expect(await model.submitTypedRequest("Help with this"))
        #expect(model.assistant == .clarifying("Which one?"))
        #expect(model.engineCaption == "On-device model")
        #expect(await model.submitTypedRequest("yes"))
        #expect(model.assistant == .answer("I do not know."))
        #expect(model.engineCaption == "Rules · Model unavailable")
        #expect(await model.submitTypedRequest("Save a note about milk"))
        guard case .done(let outcomes) = model.assistant else {
            Issue.record("Act must go through the harness"); return
        }
        #expect(outcomes.first?.status == .done("Saved note") || outcomes.first.map {
            if case .done = $0.status { true } else { false }
        } == true)
        #expect(model.engineCaption == "On-device model")
        #expect(await model.submitTypedRequest("What is my blood type?"))
        #expect(model.engineCaption == "Rules · Personal fact lookup")
        #expect(model.phase != .capturing)
        #expect(await fixture.requests.count == 4)
    }

    @Test func modelQuestionAndPlainYesCannotRunALocalActionWithoutFreshConfirmation() async throws {
        let fixture = DecisionFixture([
            .init(decision: .ask("Should I save a note about stretching?"), source: .model),
            .init(decision: .act([ToolCall(tool: ToolName.note, text: "Stretching")]), source: .model),
        ])
        let (path, _, model) = try makeFixture(FixtureDecider(fixture: fixture))
        defer { clean(path) }
        #expect(await model.submitTypedRequest("save a note about stretching"))
        #expect(model.assistant == .clarifying("Should I save a note about stretching?"))
        #expect(await model.submitTypedRequest("yes"))
        guard case .proposed(_, _, let canConfirm) = model.assistant else {
            Issue.record("local action ran without fresh confirmation"); return
        }
        #expect(canConfirm)
        let requests = await fixture.requests
        #expect(requests.count == 2)
        #expect(requests[1].0 == "save a note about stretching\nyes")
        #expect(requests[1].1.pendingClarification?.question == "Should I save a note about stretching?")
    }

    @Test func voiceKeepsTwoRealExchangesAcrossResponseIDsButTypedDoesNot() async throws {
        let fixture = DecisionFixture((0..<4).map {
            .init(decision: .answer("Actual answer \($0)"), source: .model)
        })
        let (path, app, model) = try makeFixture(FixtureDecider(fixture: fixture))
        defer { clean(path) }
        model.suppressAutomaticCaptureForTests = true
        let spoken = model.spokenRepliesEnabled
        model.setSpokenReplies(false)
        defer { model.setSpokenReplies(spoken) }
        model.setQuietMode(false)
        model.setCompanionActive(true)
        defer { model.setCompanionActive(false) }
        await voice("I am planning a Goa trip", model: model, app: app)
        await voice("What should I pack?", model: model, app: app)
        await voice("remind me to book it tomorrow at 9", model: model, app: app)
        let requests = await fixture.requests
        #expect(requests.count == 3)
        #expect(requests[0].1.recent.isEmpty)
        #expect(requests[1].1.recent == [.init(user: "I am planning a Goa trip", reply: "Actual answer 0")])
        #expect(requests[2].1.recent.count == 2)
        #expect(requests[2].1.recent[0].reply == "Actual answer 0")
        #expect(requests[2].1.recent[1].reply == "Actual answer 1")
        #expect(await model.submitTypedRequest("What now?"))
        #expect(await fixture.requests.last?.1.recent.isEmpty == true)
        #expect(model.phase != .capturing)
    }

    @Test func confirmedForgetPurgesVoiceEvidenceNotOriginalCapture() async throws {
        let fixture = DecisionFixture([
            .init(decision: .unknown("Not in memory"), source: .model),
        ])
        let (path, app, model) = try makeFixture(FixtureDecider(fixture: fixture))
        defer { clean(path) }
        #expect(await model.submitTypedRequest("Remember my sister is Riya"))
        #expect(await model.submitTypedRequest("yes"))
        model.suppressAutomaticCaptureForTests = true
        let spoken = model.spokenRepliesEnabled
        model.setSpokenReplies(false)
        defer { model.setSpokenReplies(spoken) }
        model.setQuietMode(false)
        model.setCompanionActive(true)
        defer { model.setCompanionActive(false) }
        await voice("Who is my sister?", model: model, app: app)
        guard case .personalAnswer(let answer, _) = model.assistant else {
            Issue.record("Personal fact should answer from storage"); return
        }
        #expect(answer.contains("Riya"))
        await voice("Forget my sister", model: model, app: app)
        await voice("yes", model: model, app: app)
        #expect(try await app.memory.fact(forKey: "my/sister") == nil)
        await voice("Tell me a poem", model: model, app: app)
        let last = await fixture.requests.last
        #expect(last?.1.facts.contains { $0.value == "Riya" } == false)
        #expect(last?.1.recent.contains { $0.user.contains("Riya") || $0.reply.contains("Riya") } == false)
        #expect(await app.memory.search("Remember my sister is Riya", limit: 5).count > 0)
    }

    @Test func unavailableDefaultDecisionStillFilesExplicitNote() async throws {
        let (path, _, model) = try makeFixture(ModelDecider())
        defer { clean(path) }
        model.setQuietMode(false)
        model.resetCompanionLearning()
        model.setCompanionActive(true)
        defer { model.setCompanionActive(false) }
        #expect(await model.submitTypedRequest("Make a note native fallback check"))
        #expect(model.isCelebrating, "assistant=\(String(describing: model.assistant)), caption=\(String(describing: model.engineCaption)), notice=\(String(describing: model.notice))")
    }

    @Test(arguments: ["stop", "background", "quiet"])
    func staleAwaitCannotPublish(_ event: String) async throws {
        let gate = DecisionGate()
        let (path, app, model) = try makeFixture(PausedDecider(gate: gate))
        defer { clean(path) }
        model.setQuietMode(false)
        model.setCompanionActive(true)
        let task = Task { await model.submitTypedRequest("Tell me something") }
        await gate.arrived()
        switch event {
        case "stop": app.onStopRequested?()
        case "background": model.setCompanionActive(false)
        default: model.setQuietMode(true)
        }
        await gate.release()
        _ = await task.value
        #expect(model.assistant != .answer("Late reply"))
        #expect(model.engineCaption == nil)
        #expect(model.phase != .capturing)
    }
}
#endif
