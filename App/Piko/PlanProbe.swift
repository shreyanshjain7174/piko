#if DEBUG
import Foundation
import FoundationModels
import PikoBrain
import PikoKit

/// Developer-only: runs the planner on this device over `|`-separated requests and prints
/// the plan, latency and whether Apple's model was available. No microphone, no tools run.
@MainActor
enum PlanProbe {
    static func run(_ requests: String, app: AppComposition) async {
        let availability = String(describing: SystemLanguageModel.default.availability)
        print("PIKO_PLAN_MODEL availability=\(availability)")
        let tools = app.harness.actionDescriptors
        let rules = OrganizerPlanner(organizer: RuleOrganizer())
        for request in requests.split(separator: "|").map(String.init) {
            let clock = ContinuousClock()
            let start = clock.now
            let plan = (try? await app.planner.plan(request, tools: tools, now: .now)) ?? []
            let elapsed = clock.now - start
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            let rulePlan = (try? await rules.plan(request, tools: tools, now: .now)) ?? []
            let steps = plan.map { step in
                "\(step.tool): \(step.text)" + (step.when.map { " @ \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }
            print("PIKO_PLAN ms=\(ms) model_differs_from_rules=\(plan.map(\.tool) != rulePlan.map(\.tool) || plan.map(\.text) != rulePlan.map(\.text)) request=\(request)")
            for step in steps { print("PIKO_PLAN_STEP \(step)") }
        }
        print("PIKO_PLAN_DONE")
    }

    /// Scores the device planner against `scripts/planner-eval.json`, passed as a launch argument.
    static func evaluate(_ json: String, app: AppComposition) async {
        guard let cases = try? JSONDecoder().decode([PlannerEval.Case].self, from: Data(json.utf8)) else {
            print("PIKO_EVAL_BAD_INPUT")
            return
        }
        print("PIKO_EVAL_MODEL availability=\(String(describing: SystemLanguageModel.default.availability))")
        var passed = 0
        var latencies: [Int] = []
        for item in cases {
            let clock = ContinuousClock()
            let start = clock.now
            let plan = (try? await app.planner.plan(item.say, tools: app.harness.actionDescriptors, now: .now)) ?? []
            let elapsed = clock.now - start
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            latencies.append(ms)
            if let problem = PlannerEval.check(plan, against: item.expect, now: .now) {
                print("PIKO_EVAL fail ms=\(ms) say=\"\(item.say)\" -> \(problem)")
            } else {
                passed += 1
                print("PIKO_EVAL pass ms=\(ms) say=\"\(item.say)\" -> \(PlannerEval.describe(plan))")
            }
        }
        let sorted = latencies.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print("PIKO_EVAL_SUMMARY passed=\(passed)/\(cases.count) p50_ms=\(p50) p95_ms=\(p95)")
    }
}
#endif
