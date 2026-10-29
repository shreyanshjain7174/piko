import Foundation
import Testing
import PikoKit
@testable import PikoBrain

@Suite struct RuleOrganizerTests {
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 21
        components.hour = 9; components.minute = 0
        return Calendar.current.date(from: components)!
    }()

    @Test func sentencesAreFiledByCue() async throws {
        let items = try await RuleOrganizer().organize(
            "Remind me to call mom at 6 pm tomorrow. Buy oat milk. I felt anxious about the interview today.",
            now: now)
        #expect(items.map(\.kind) == [.reminder, .reminder, .journal])
        #expect(items[0].text == "Call mom")
        let due = try #require(items[0].due)
        #expect(Calendar.current.component(.hour, from: due) == 18)
        #expect(Calendar.current.component(.day, from: due) == 22)
        #expect(items[1].text == "Buy oat milk")
        #expect(items[1].due == nil)
        #expect(items[2].text == "I felt anxious about the interview today.")
    }

    @Test func runOnRambleSplitsAtCuedCommaClauses() async throws {
        let items = try await RuleOrganizer().organize(
            "remind me to call mom at 6 pm, buy oat milk, and I felt anxious about the interview",
            now: now)
        #expect(items.map(\.kind) == [.reminder, .reminder, .journal])
        #expect(items.map(\.text) == ["Call mom", "Buy oat milk", "I felt anxious about the interview."])
    }

    @Test func plainThoughtIsOneNoteAndCommasStayTogether() async throws {
        let items = try await RuleOrganizer().organize(
            "App idea: a cute planner, with stickers, for students", now: now)
        #expect(items.count == 1)
        #expect(items[0].kind == .note)
        #expect(items[0].text == "App idea: a cute planner, with stickers, for students.")
    }

    @Test func silenceFilesNothing() async throws {
        #expect(try await RuleOrganizer().organize("  ", now: now).isEmpty)
    }

    @Test func recallAnswerQuotesMatchingHistoryOnly() async throws {
        let history = [
            CaptureResult(raw: "I felt anxious about the interview", shipped: "I felt anxious about the interview."),
        ]
        let answer = try await RuleOrganizer().answer("what did I say about the interview?", from: history)
        #expect(answer.contains("I felt anxious about the interview."))
        let none = try await RuleOrganizer().answer("what did I say about Goa?", from: [])
        #expect(none == "I couldn't find anything you said about that yet.")
    }

    @Test func recallKeywordsDropQuestionWords() {
        #expect(RecallQuery.keywords(from: "What did I say about the interview with Riya?")
                == ["interview", "riya"])
    }
}
