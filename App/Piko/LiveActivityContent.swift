import Foundation
import PikoKit

/// Pure decision logic for Live Activity content — no ActivityKit dependency, so it can be
/// unit-tested on macOS and iOS alike. `LiveActivityController` is the only consumer.
public enum LiveActivityContent {
    /// Counts words in `text`, discarding empty substrings from irregular whitespace.
    public static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Stub per 07-RESEARCH.md — real waveform-accurate levels are out of scope for this plan.
    public static func placeholderLevels() -> [Int] {
        Array(repeating: 0, count: 8)
    }

    /// The Level Activity's bars. A normalized level (0...1) becomes one of eleven
    /// buckets so the widget extension renders identical bars from identical states.
    public static func bucket(of level: Double) -> Int {
        guard level.isFinite else { return 0 }
        return min(max(Int((level * 10).rounded()), 0), 10)
    }

    /// Oldest bucket falls off the left, the newest sample enters on the right —
    /// the bars scroll like speech, not like a meter that twitches in place.
    public static func rolled(_ levels: [Int], with newBucket: Int) -> [Int] {
        let next = bucket(of: Double(newBucket) / 10)
        var result = levels
        if result.count >= 8 {
            result.removeFirst(result.count - 7)
        }
        result.append(next)
        return result
    }

    /// `.idle` ends the Activity; every other phase updates it.
    public static func shouldEndActivity(for phase: SessionPhase) -> Bool {
        phase == .idle
    }

    /// The only place `.tidying` is ever produced — `SessionPhase` itself never emits it.
    /// A real `.idle` always wins over a stale tidying override.
    public static func effectivePhase(sessionPhase: SessionPhase, isTidying: Bool) -> SessionPhase {
        if sessionPhase == .idle { return .idle }
        return isTidying ? .tidying : sessionPhase
    }

    /// The pet's feeling, from the session's shape alone. Routed through here so the
    /// controller, tests and any future surface share one derivation.
    public static func mood(phase: SessionPhase, words: Int, armedSeconds: TimeInterval, hour: Int = Calendar.current.component(.hour, from: Date())) -> PikoMood {
        MoodEngine.mood(phase: phase, words: words, armedSeconds: armedSeconds, hour: hour)
    }
}
