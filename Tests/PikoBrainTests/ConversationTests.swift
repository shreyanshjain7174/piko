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

    @Test func personalWritesAlwaysReadBackAndNoCancelsWithoutRunning() async {
        for (tool, text, readback) in [
            (ToolName.remember, "Remember my sister is Riya.", "remember that your sister is Riya"),
            (ToolName.forget, "Forget my sister.", "forget what I saved about your sister"),
        ] {
            var talk = Conversation()
            let call = ToolCall(tool: tool, text: text, sourceCaptureID: UUID(), expectedFactLSN: 12)
            let reply = await talk.begin([call], context: nil, now: now)
            guard case .confirm(let prompt) = reply else { Issue.record("Expected read-back"); return }
            #expect(prompt.contains(readback))
            #expect(talk.plan == [call])
            #expect(await talk.hear("no thanks", context: nil, now: now)
                    == .cancelled("Okay, I won't do that."))
            #expect(talk.plan.isEmpty)
            #expect(!talk.isWaiting)
            _ = await talk.begin([call], context: nil, now: now)
            #expect(await talk.hear("nothing", context: nil, now: now)
                    == .cancelled("Okay, I won't do that."))
            #expect(talk.plan.isEmpty)
        }
    }

    @Test func personalYesKeepsTheOriginalOriginAndRevision() async {
        var talk = Conversation()
        let captureID = UUID()
        let call = ToolCall(tool: ToolName.remember, text: "Remember my sister is Riya",
                            sourceCaptureID: captureID, expectedFactLSN: 5)
        _ = await talk.begin([call], context: nil, now: now)
        #expect(await talk.hear("yes", context: nil, now: now) == .run("On it."))
        #expect(talk.plan == [call])
        #expect(talk.plan[0].sourceCaptureID == captureID)
        #expect(talk.plan[0].expectedFactLSN == 5)
    }

    @Test func descriptorRiskRequiresConfirmationForAnUnlistedExternalTool() async {
        let external = ToolCall(tool: "export.send", text: "This week's notes")
        let local = ToolCall(tool: ToolName.note, text: "Keep it here")
        let descriptors = [
            ToolDescriptor(name: "export.send", summary: "Send notes", risk: .external),
            ToolDescriptor(name: ToolName.note, summary: "Save a note", risk: .local),
        ]
        var talk = Conversation()
        guard case .confirm = await talk.begin([external, local], context: nil, now: now,
                                                descriptors: descriptors) else {
            Issue.record("An external descriptor must trigger confirmation"); return
        }
        #expect(talk.confirmedPlan.isEmpty)
        #expect(await talk.hear("no", context: nil, now: now) == .cancelled("Okay, I won't do that."))
        #expect(talk.confirmedPlan.isEmpty)
        _ = await talk.begin([external, local], context: nil, now: now, descriptors: descriptors)
        #expect(await talk.hear("yes", context: nil, now: now) == .run("On it."))
        #expect(talk.confirmedPlan == [external, local])
        #expect(talk.isConfirmed(external))
        var changed = external
        changed.text = "Different notes"
        #expect(!talk.isConfirmed(changed))
        changed = external
        changed.id = UUID()
        #expect(!talk.isConfirmed(changed))
        _ = await talk.begin([local], context: nil, now: now, descriptors: descriptors)
        #expect(talk.confirmedPlan.isEmpty)
        #expect(!talk.isConfirmed(external))
        #expect(talk.waiting == .none)
    }

    @Test func aLocalActionAfterModelClarificationNeedsANewConfirmation() async {
        let local = ToolCall(tool: ToolName.note, text: "Stretching")
        let descriptors = [ToolDescriptor(name: ToolName.note, summary: "Save note", risk: .local)]
        var talk = Conversation()
        guard case .confirm = await talk.begin([local], context: nil, now: now,
                                                descriptors: descriptors, requiresExplicitConfirmation: true) else {
            Issue.record("local follow-up acted without a read-back"); return
        }
        #expect(talk.confirmedPlan.isEmpty)
        #expect(!talk.isConfirmed(local))
        #expect(await talk.hear("yes", context: nil, now: now) == .run("On it."))
        #expect(talk.isConfirmed(local))
        _ = await talk.begin([local], context: nil, now: now, descriptors: descriptors)
        #expect(!talk.requiresConfirmation(local))
    }

    @Test func personalWritesConfirmEvenWhenRegisteredAsLocal() async {
        var talk = Conversation()
        let call = ToolCall(tool: ToolName.forget, text: "Forget my city", sourceCaptureID: UUID())
        let registered = [ToolDescriptor(name: ToolName.forget, summary: "Forget fact", risk: .local)]
        guard case .confirm = await talk.begin([call], context: nil, now: now, descriptors: registered) else {
            Issue.record("Personal memory must always read back"); return
        }
        #expect(talk.confirmedPlan.isEmpty)
        _ = await talk.hear("yes", context: nil, now: now)
        #expect(talk.isConfirmed(call))
    }
}
