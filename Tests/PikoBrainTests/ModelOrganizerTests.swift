import Foundation
import Testing
import PikoKit
@testable import PikoBrain

@Suite struct ModelOrganizerTests {
    private let now = Date(timeIntervalSince1970: 1_792_550_000)

    @Test func modelDraftsBecomeFiledItemsWithSpokenDatesOnly() async throws {
        let organizer = ModelOrganizer(generate: { _ in [
            .init(kind: "reminder", text: "Call mom", when: "tomorrow at 6 pm"),
            .init(kind: "journal", text: "Felt anxious about the interview", when: nil),
            .init(kind: "shopping", text: "Oat milk", when: nil),
        ] })
        let items = try await organizer.organize(
            "remind me to call mom tomorrow at 6 pm, oat milk, felt anxious about the interview", now: now)
        #expect(items.map(\.kind) == [.reminder, .journal, .note])
        #expect(items[0].due != nil)
        #expect(items[1].due == nil)
    }

    @Test func inventedItemsAreDropped() async throws {
        let organizer = ModelOrganizer(generate: { _ in [
            .init(kind: "reminder", text: "Call mom", when: nil),
            .init(kind: "reminder", text: "Book flights to Paris", when: nil),
        ] })
        let items = try await organizer.organize("remind me to call mom", now: now)
        #expect(items.map(\.text) == ["Call mom"])
    }

    @Test func unavailableModelFallsBackToRules() async throws {
        let organizer = ModelOrganizer(generate: { _ in throw PikoError.brainUnavailable("deviceNotEligible") })
        let items = try await organizer.organize("remind me to buy oat milk", now: now)
        #expect(items.map(\.text) == ["Buy oat milk"])
        #expect(items.map(\.kind) == [.reminder])
    }

    @Test func recallAnswersOnlyFromProvidedHistory() async throws {
        let prompts = PromptLog()
        let organizer = ModelOrganizer(generate: { _ in [] }, answer: { instructions, prompt in
            await prompts.append(instructions + "\n" + prompt)
            return "You felt anxious about the interview."
        })
        let history = [CaptureResult(raw: "felt anxious about the interview", shipped: "Felt anxious about the interview.")]
        let answer = try await organizer.answer("what did I say about the interview?", from: history)
        #expect(answer == "You felt anxious about the interview.")
        let sent = await prompts.all.joined()
        #expect(sent.contains("Felt anxious about the interview."))
        #expect(sent.contains("Only use the notes"))
    }

    @Test func recallWithNoHistoryNeverCallsModel() async throws {
        let organizer = ModelOrganizer(generate: { _ in [] }, answer: { _, _ in
            Issue.record("model must not be called without history")
            return ""
        })
        let answer = try await organizer.answer("what did I say about Goa?", from: [])
        #expect(answer == "I couldn't find anything you said about that yet.")
    }
}

private actor PromptLog {
    var all: [String] = []
    func append(_ value: String) { all.append(value) }
}
