import Foundation
import Testing
import PikoKit
@testable import PikoBrain

private struct FakeCalendar: CalendarContext {
    var busyHours: [Int: String] = [:]
    func busy(from start: Date, to end: Date) async -> [String] {
        busyHours[Calendar.current.component(.hour, from: start)].map { [$0] } ?? []
    }
}

@Suite struct ConversationTests {
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 21
        components.hour = 21; components.minute = 52
        return Calendar.current.date(from: components)!
    }()
    private var friday: Date { Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))! }
    private func at(_ day: Date, _ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }
    private func hour(_ date: Date?) -> Int? { date.map { Calendar.current.component(.hour, from: $0) } }

    @Test func dayWithoutTimeAsksThenUsesTheAnswer() async {
        var talk = Conversation()
        let first = await talk.begin([ToolCall(tool: ToolName.calendar, text: "Dentist",
                                               when: at(friday, 9), timeKnown: false)],
                                     context: FakeCalendar(), now: now)
        guard case .ask(let question) = first else { Issue.record("expected a question"); return }
        #expect(question.contains("What time"))
        #expect(question.contains("Dentist"))
        let second = await talk.hear("at four", context: FakeCalendar(), now: now)
        guard case .confirm(let summary) = second else { Issue.record("expected a confirmation"); return }
        #expect(summary.contains("Dentist"))
        #expect(hour(talk.plan.first?.when) == 16)
        #expect(Calendar.current.isDate(talk.plan.first!.when!, inSameDayAs: friday))
        #expect(await talk.hear("yes please", context: FakeCalendar(), now: now) == .run("On it."))
    }

    @Test func clashIsRaisedAndANewTimeResolvesIt() async {
        var talk = Conversation()
        let calendar = FakeCalendar(busyHours: [16: "Team sync"])
        let first = await talk.begin([ToolCall(tool: ToolName.calendar, text: "Dentist", when: at(friday, 16))],
                                     context: calendar, now: now)
        guard case .ask(let question) = first else { Issue.record("expected a clash question"); return }
        #expect(question.contains("Team sync"))
        let second = await talk.hear("no, make it 5", context: calendar, now: now)
        guard case .confirm = second else { Issue.record("expected confirmation after moving"); return }
        #expect(hour(talk.plan.first?.when) == 17)
    }

    @Test func clashCanBeAcceptedAnyway() async {
        var talk = Conversation()
        let calendar = FakeCalendar(busyHours: [16: "Team sync"])
        _ = await talk.begin([ToolCall(tool: ToolName.calendar, text: "Dentist", when: at(friday, 16))],
                             context: calendar, now: now)
        guard case .confirm = await talk.hear("add it anyway", context: calendar, now: now) else {
            Issue.record("expected confirmation"); return
        }
        #expect(hour(talk.plan.first?.when) == 16)
    }

    @Test func localOnlyPlansRunWithoutAQuestion() async {
        var talk = Conversation()
        let reply = await talk.begin([ToolCall(tool: ToolName.note, text: "Planner app with stickers"),
                                      ToolCall(tool: ToolName.journal, text: "Anxious about the interview")],
                                     context: FakeCalendar(), now: now)
        #expect(reply == .run("Saved."))
        #expect(!talk.isWaiting)
    }

    @Test func noCancelsAndUnrelatedSpeechIsANewRequest() async {
        var talk = Conversation()
        _ = await talk.begin([ToolCall(tool: ToolName.reminder, text: "Buy oat milk")], context: nil, now: now)
        #expect(await talk.hear("nope", context: nil, now: now) == .cancelled("Okay, I won't do that."))
        #expect(!talk.isWaiting)
        _ = await talk.begin([ToolCall(tool: ToolName.reminder, text: "Buy oat milk")], context: nil, now: now)
        #expect(await talk.hear("also what did I say about Riya", context: nil, now: now) == nil)
        #expect(!talk.isWaiting)
    }

    @Test func confirmationReadsBackTheWholePlan() async {
        var talk = Conversation()
        let reply = await talk.begin([
            ToolCall(tool: ToolName.calendar, text: "Dentist", when: at(friday, 16)),
            ToolCall(tool: ToolName.reminder, text: "Buy oat milk"),
            ToolCall(tool: ToolName.checkIn, text: "Time to journal", when: at(Calendar.current.startOfDay(for: now), 21)),
        ], context: FakeCalendar(), now: now)
        guard case .confirm(let summary) = reply else { Issue.record("expected confirmation"); return }
        #expect(summary.hasPrefix("I'll add Dentist to your calendar on Friday"))
        #expect(summary.contains("remind you to buy oat milk"))
        #expect(summary.hasSuffix("Shall I go ahead?"))
    }

    @Test func unclearAnswerIsAskedOnceMoreThenDropped() async {
        var talk = Conversation()
        _ = await talk.begin([ToolCall(tool: ToolName.calendar, text: "Dentist", when: at(friday, 9), timeKnown: false)],
                             context: nil, now: now)
        guard case .ask = await talk.hear("hmm", context: nil, now: now) else { Issue.record("expected retry"); return }
        #expect(await talk.hear("whatever", context: nil, now: now) == .cancelled("Okay, I won't do that."))
    }
}
