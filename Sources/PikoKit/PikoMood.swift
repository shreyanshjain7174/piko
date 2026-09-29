import Foundation

/// What the notch pet is feeling. Derived locally from the session's shape — never from
/// network, never from a profile. The pet's animation set is keyed by this enum.
public enum PikoMood: String, Codable, Sendable, CaseIterable {
    case fresh      // morning / start of a session
    case happy      // words are flowing, a productive session
    case calm       // the resting default
    case sleepy     // armed a long time, unused
}

/// Pure mood derivation so it stays testable and budget-free: the Live Activity only
/// refreshes when something real changes, and the mood changes at most that often.
public enum MoodEngine {
    /// An hour with the session armed and barely a word spoken is a nap, not a failure —
    /// the pet dozes instead of demanding attention (piko-ui-craft: quiet by default).
    public static let sleepyAfterSeconds: TimeInterval = 45 * 60

    public static func mood(phase: SessionPhase, words: Int, armedSeconds: TimeInterval, hour: Int) -> PikoMood {
        switch phase {
        case .capturing, .tidying:
            return words >= 12 ? .happy : .fresh
        case .armed, .idle:
            if armedSeconds >= sleepyAfterSeconds { return .sleepy }
            if (6...9).contains(hour) { return .fresh }
            if words >= 40 { return .happy }
            return .calm
        }
    }
}
