import Foundation
import PikoKit

/// Scores a planner against spoken edge cases (`scripts/planner-eval.json`). Used by unit tests
/// for the free rule planner and by the on-device probe for Apple's model or an SLM.
public enum PlannerEval {
    public struct Case: Codable, Sendable {
        public var say: String
        public var expect: [Step]
    }

    public struct Step: Codable, Sendable {
        public var tools: [String]
        public var hour: Int?
        public var day: String?
        public var text: String?
        public var ask: Bool?
        /// The step must not carry a date (e.g. a reminder that borrowed another step's time).
        public var nowhen: Bool?
    }

    /// Nil when the plan matches; otherwise the first mismatch, in words.
    public static func check(_ plan: [ToolCall], against expected: [Step], now: Date) -> String? {
        guard plan.count == expected.count else {
            return "expected \(expected.count) step(s), got \(plan.count): \(describe(plan))"
        }
        let calendar = Calendar.current
        for (index, (step, want)) in zip(plan, expected).enumerated() {
            let label = "step \(index + 1) (\(step.tool): \(step.text))"
            guard want.tools.contains(step.tool) else { return "\(label): wanted \(want.tools.joined(separator: " or "))" }
            if let text = want.text, !step.text.localizedCaseInsensitiveContains(text) {
                return "\(label): text should mention \"\(text)\""
            }
            if want.nowhen == true, let when = step.when {
                return "\(label): should have no date, got \(when.formatted(date: .abbreviated, time: .shortened))"
            }
            if want.ask == true, step.timeKnown {
                return "\(label): should ask for a time, but has one"
            }
            if let hour = want.hour {
                guard let when = step.when, step.timeKnown else { return "\(label): missing time, wanted \(hour):00" }
                let got = calendar.component(.hour, from: when)
                if got != hour { return "\(label): wanted \(hour):00, got \(got):00" }
            }
            if let day = want.day {
                guard let when = step.when else { return "\(label): missing day \(day)" }
                if !matches(day: day, when, now: now) {
                    return "\(label): wanted \(day), got \(when.formatted(.dateTime.weekday(.wide).day().month()))"
                }
            }
        }
        return nil
    }

    static func matches(day: String, _ date: Date, now: Date) -> Bool {
        let calendar = Calendar.current
        switch day.lowercased() {
        case "today": return calendar.isDate(date, inSameDayAs: now)
        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: now).map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date).lowercased() == day.lowercased()
        }
    }

    public static func describe(_ plan: [ToolCall]) -> String {
        plan.isEmpty ? "nothing" : plan.map { step in
            var text = "\(step.tool): \(step.text)"
            if let when = step.when {
                text += " @ " + when.formatted(date: .abbreviated, time: step.timeKnown ? .shortened : .omitted)
                if !step.timeKnown { text += " (no time)" }
            }
            return text
        }.joined(separator: "; ")
    }
}
