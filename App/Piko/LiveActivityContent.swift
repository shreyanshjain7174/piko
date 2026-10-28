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

    /// How long Piko holds each frame in the Dynamic Island. Slow while waiting, so the island
    /// reads as alive without fidgeting; quicker while listening or thinking. `nil` means no
    /// heartbeat at all. These are local updates from the running app, which ActivityKit may
    /// still coalesce; a dropped beat just holds the current face a little longer.
    public static func beatInterval(for phase: SessionPhase) -> Duration? {
        switch phase {
        case .idle:      nil
        case .armed:     .seconds(3)
        case .capturing: .milliseconds(1200)
        case .tidying:   .seconds(1)
        }
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
}
