import Foundation
import Testing
import PikoKit
@testable import PikoBrain

private actor Ledger {
    var ran: [String] = []
    func add(_ value: String) { ran.append(value) }
}

private struct FakeTool: PikoTool {
    let descriptor: ToolDescriptor
    let ledger: Ledger
    var fails = false
    func run(_ call: ToolCall) async throws -> String {
        if fails { throw PikoError.storageUnavailable }
        await ledger.add(call.text)
        return "Did \(call.text)"
    }
}

@Suite struct ToolHarnessTests {
    private func harness(_ ledger: Ledger, failing: Bool = false) -> ToolHarness {
        ToolHarness(tools: [
            FakeTool(descriptor: .init(name: ToolName.note, summary: "", risk: .local), ledger: ledger),
            FakeTool(descriptor: .init(name: ToolName.reminder, summary: "", risk: .external), ledger: ledger,
                     fails: failing),
        ])
    }

    @Test func externalToolsNeedApprovalLocalOnesDoNot() async {
        let ledger = Ledger()
        let outcomes = await harness(ledger).run([
            ToolCall(tool: ToolName.note, text: "idea"),
            ToolCall(tool: ToolName.reminder, text: "call mom"),
        ], approve: { _ in false })
        #expect(await ledger.ran == ["idea"])
        #expect(outcomes.map(\.status) == [.done("Did idea"), .skipped("Not approved")])
    }

    @Test func unknownToolsAndFailuresAreReportedNotRun() async {
        let ledger = Ledger()
        let outcomes = await harness(ledger, failing: true).run([
            ToolCall(tool: "phone.wipe", text: "everything"),
            ToolCall(tool: ToolName.reminder, text: "call mom"),
        ], approve: { _ in true })
        #expect(await ledger.ran.isEmpty)
        #expect(outcomes.map(\.status) == [.skipped("Piko can't do that yet"), .failed("That didn't work")])
    }

    @Test func plannersOnlySeeToolsThatAct() {
        let ledger = Ledger()
        let harness = ToolHarness(tools: [
            FakeTool(descriptor: .init(name: ToolName.search, summary: "", risk: .read), ledger: ledger),
            FakeTool(descriptor: .init(name: ToolName.note, summary: "", risk: .local), ledger: ledger),
        ])
        #expect(harness.actionDescriptors.map(\.name) == [ToolName.note])
    }

    @Test func plansAreCappedAtFiveSteps() async {
        let ledger = Ledger()
        let plan = (1...8).map { ToolCall(tool: ToolName.note, text: "n\($0)") }
        let outcomes = await harness(ledger).run(plan, approve: { _ in true })
        #expect(outcomes.count == 5)
        #expect(await ledger.ran.count == 5)
    }

    @Test func approvalBindsExactRegisteredExternalCallNotJustItsNameOrID() async {
        let ledger = Ledger()
        let harness = ToolHarness(tools: [
            FakeTool(descriptor: .init(name: "export.send", summary: "Send notes", risk: .external),
                     ledger: ledger),
        ])
        #expect(harness.actionDescriptors.map(\.name) == ["export.send"])
        var talk = Conversation()
        let proposed = ToolCall(tool: "export.send", text: "A")
        _ = await talk.begin([proposed], context: nil, now: .now, descriptors: harness.descriptors)
        let beforeApproval = talk.confirmedPlan
        let unconfirmed = await harness.run([proposed], approve: { beforeApproval.contains($0) })
        #expect(unconfirmed.first?.status == .skipped("Not approved"))
        _ = await talk.hear("yes", context: nil, now: .now)
        let confirmed = talk.confirmedPlan
        var changed = proposed
        changed.text = "B"
        var replaced = proposed
        replaced.id = UUID()
        let results = await harness.run([changed, replaced, proposed], approve: { confirmed.contains($0) })
        #expect(results.map(\.status) == [.skipped("Not approved"), .skipped("Not approved"), .done("Did A")])
        #expect(await ledger.ran == ["A"])
    }
}

@Suite struct PlannerTests {
    private let tools = ToolName.all.map { ToolDescriptor(name: $0, summary: "", risk: .local) }

    @Test func organizerPlannerMapsFiledItemsToTools() async throws {
        let calls = try await OrganizerPlanner(organizer: RuleOrganizer()).plan(
            "Remind me to call mom at 6 pm tomorrow. I felt anxious about the interview. Planner app idea.",
            tools: tools, now: .now)
        #expect(calls.map(\.tool) == [ToolName.reminder, ToolName.journal, ToolName.note])
        #expect(calls[0].text == "Call mom")
        #expect(calls[0].when != nil)
    }

    @Test func modelPlannerKeepsOnlyKnownGroundedSteps() async throws {
        let planner = ModelPlanner(generate: { _, _ in [
            .init(tool: ToolName.calendar, text: "Dentist", when: "Friday at 4 pm"),
            .init(tool: ToolName.checkIn, text: "How was today?", when: "9 pm"),
            .init(tool: "phone.wipe", text: "dentist", when: nil),
            .init(tool: ToolName.reminder, text: "Book flights to Paris", when: nil),
        ] })
        let calls = try await planner.plan(
            "put dentist on my calendar Friday at 4 pm and nudge me at 9 pm to ask how was today",
            tools: tools, now: .now)
        #expect(calls.map(\.tool) == [ToolName.calendar, ToolName.checkIn])
        #expect(calls.allSatisfy { $0.when != nil })
    }

    @Test func stepTextDropsSpokenDatesAndShortcutFiller() async throws {
        // Real iPhone 17 Foundation Models output from the on-device plan probe.
        let planner = ModelPlanner(generate: { _, _ in [
            .init(tool: ToolName.reminder, text: "Call mom tomorrow at 6", when: "tomorrow at 6"),
            .init(tool: ToolName.shortcut, text: "My gym shortcut", when: nil),
            .init(tool: ToolName.checkIn, text: "Nudge me at 9 pm to journal", when: "9 pm"),
        ] })
        let calls = try await planner.plan(
            "remind me to call mom tomorrow at 6, run my gym shortcut and nudge me at 9 pm to journal",
            tools: tools, now: .now)
        #expect(calls.map(\.text) == ["Call mom", "Gym", "Time to journal"])
        #expect(calls[0].when != nil)
    }

    @Test func modelPlannerFallsBackToRulesWhenUnavailable() async throws {
        let planner = ModelPlanner(generate: { _, _ in throw PikoError.brainUnavailable("deviceNotEligible") })
        let calls = try await planner.plan("remind me to buy oat milk", tools: tools, now: .now)
        #expect(calls.map(\.tool) == [ToolName.reminder])
        #expect(calls.map(\.text) == ["Buy oat milk"])
    }

    @Test func plannersNeverUseToolsThatAreNotOffered() async throws {
        let onlyNotes = [ToolDescriptor(name: ToolName.note, summary: "", risk: .local)]
        let calls = try await OrganizerPlanner(organizer: RuleOrganizer()).plan(
            "remind me to buy oat milk", tools: onlyNotes, now: .now)
        #expect(calls.map(\.tool) == [ToolName.note])
    }
}
