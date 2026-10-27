import Foundation
import Testing
import PikoKit
@testable import PikoBrain

/// Each case replays Apple Foundation Models output observed in the 25-case eval.
@Suite struct PlanRepairTests {
    private let tools = ToolName.all.filter { $0 != ToolName.search }.map { ToolDescriptor(name: $0, summary: "", risk: .local) }

    private func plan(_ request: String, _ drafts: [ModelPlanner.Draft]) async throws -> [ToolCall] {
        try await ModelPlanner(generate: { _, _ in drafts }).plan(request, tools: tools, now: .now)
    }

    private func hour(_ call: ToolCall) -> Int? { call.when.map { Calendar.current.component(.hour, from: $0) } }

    @Test func timeFromAnotherClauseIsNotBorrowed() async throws {
        let calls = try await plan(
            "put dentist on my calendar friday at 4 pm, remind me to buy oat milk, and nudge me at 9 pm to journal", [
                .init(tool: ToolName.calendar, text: "Dentist", when: "friday at 4 pm"),
                .init(tool: ToolName.reminder, text: "Buy oat milk", when: "friday at 4 pm"),
                .init(tool: ToolName.checkIn, text: "Journal", when: "9 pm"),
            ])
        #expect(calls.map(\.tool) == [ToolName.calendar, ToolName.reminder, ToolName.checkIn])
        #expect(calls[1].when == nil)
        #expect(hour(calls[0]) == 16)
        #expect(hour(calls[2]) == 21)
    }

    @Test func selfCorrectionKeepsOneStepAtTheCorrectedTime() async throws {
        let calls = try await plan("meeting with Riya tomorrow at 3, no actually 5 pm", [
            .init(tool: ToolName.calendar, text: "Meeting with Riya", when: "tomorrow at 5 pm"),
            .init(tool: ToolName.reminder, text: "Meeting with Riya", when: "tomorrow at 5 pm"),
        ])
        #expect(calls.count == 1)
        #expect(hour(calls[0]) == 17)
    }

    @Test func ideasAreNotesEvenIfTheModelSaysReminder() async throws {
        let calls = try await plan("app idea, a cute planner with stickers for students", [
            .init(tool: ToolName.reminder, text: "App idea, a cute planner with stickers for students", when: nil),
        ])
        #expect(calls.map(\.tool) == [ToolName.note])
    }

    @Test func droppedFeelingIsKeptAsAJournalEntryInOrder() async throws {
        let calls = try await plan("today was good, I finally finished the sketch, and remind me to buy frames", [
            .init(tool: ToolName.reminder, text: "Buy frames", when: nil),
        ])
        #expect(calls.map(\.tool) == [ToolName.journal, ToolName.reminder])
    }

    @Test func feelingSplitIntoANoteIsMergedIntoOneJournalEntry() async throws {
        let calls = try await plan("today was good, I finally finished the sketch, and remind me to buy frames", [
            .init(tool: ToolName.note, text: "Was good, I finally finished the sketch", when: nil),
            .init(tool: ToolName.reminder, text: "Buy frames", when: nil),
        ])
        #expect(calls.map(\.tool) == [ToolName.journal, ToolName.reminder])
        #expect(calls[0].text == "Today was good, I finally finished the sketch.")
    }

    @Test func missingTimeIsReadFromTheStepsOwnClause() async throws {
        let calls = try await plan("remind me to call dad at four", [
            .init(tool: ToolName.reminder, text: "Call dad", when: nil),
        ])
        #expect(hour(calls[0]) == 16)
    }

    @Test func fillerOnlyRequestsDoNothing() async throws {
        #expect(try await plan("hmm", [.init(tool: ToolName.note, text: "Hmm", when: nil)]).isEmpty)
        #expect(try await plan("okay um so yeah", [.init(tool: ToolName.note, text: "Okay um so yeah", when: nil)]).isEmpty)
    }

    @Test func notesAndJournalNeverCarryDates() async throws {
        let calls = try await plan("I felt really anxious about the interview today", [
            .init(tool: ToolName.journal, text: "I felt really anxious about the interview", when: "today"),
        ])
        #expect(calls.first?.when == nil)
    }
}
