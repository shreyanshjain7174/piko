import Foundation
import Testing
import PikoKit
@testable import PikoBrain

@Suite struct PlannerEvalTests {
    private func corpus() throws -> [PlannerEval.Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/planner-eval.json")
        return try JSONDecoder().decode([PlannerEval.Case].self, from: Data(contentsOf: url))
    }

    @Test func scorerCatchesTheNoonBug() {
        let friday = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 12, weekday: 6),
                                               matchingPolicy: .nextTime)!
        let noon = [ToolCall(tool: ToolName.calendar, text: "Dentist", when: friday)]
        let want = [PlannerEval.Step(tools: [ToolName.calendar], hour: 16, day: "friday")]
        #expect(PlannerEval.check(noon, against: want, now: .now)?.contains("wanted 16:00, got 12:00") == true)
    }

    /// Baseline for the free tier on every iPhone. Reported, not gated: the model tier is
    /// scored on the device with `-PikoPlanEval`.
    @Test func ruleTierBaselineIsReported() async throws {
        let cases = try corpus()
        #expect(cases.count >= 25)
        let tools = ToolName.all.filter { $0 != ToolName.search }.map { ToolDescriptor(name: $0, summary: "", risk: .local) }
        var passed = 0
        for item in cases {
            let plan = try await OrganizerPlanner(organizer: RuleOrganizer()).plan(item.say, tools: tools, now: .now)
            if let problem = PlannerEval.check(plan, against: item.expect, now: .now) {
                print("RULE_EVAL fail \"\(item.say)\" -> \(problem)")
            } else {
                passed += 1
            }
        }
        print("RULE_EVAL passed \(passed)/\(cases.count)")
    }
}

#if os(iOS)
import FoundationModels

/// Scores Apple's on-device model on the same corpus when it is available (Simulator on an
/// Apple Intelligence Mac, or a device). Reported, not gated; skipped when unavailable.
@Suite struct ModelTierEvalTests {
    @Test func modelTierScoreIsReported() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            print("MODEL_EVAL skipped: model unavailable")
            return
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/planner-eval.json")
        let cases = try JSONDecoder().decode([PlannerEval.Case].self, from: Data(contentsOf: url))
        let tools = ToolName.all.filter { $0 != ToolName.search }.map { ToolDescriptor(name: $0, summary: "", risk: .local) }
        var passed = 0
        for item in cases {
            let clock = ContinuousClock()
            let start = clock.now
            let plan = try await ModelPlanner().plan(item.say, tools: tools, now: .now)
            let elapsed = clock.now - start
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            if let problem = PlannerEval.check(plan, against: item.expect, now: .now) {
                print("MODEL_EVAL fail ms=\(ms) \"\(item.say)\" -> \(problem)")
            } else {
                passed += 1
                print("MODEL_EVAL pass ms=\(ms) \"\(item.say)\" -> \(PlannerEval.describe(plan))")
            }
        }
        print("MODEL_EVAL passed \(passed)/\(cases.count)")
    }
}
#endif
