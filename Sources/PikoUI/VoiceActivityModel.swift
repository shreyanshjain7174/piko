import Combine
import Foundation
import PikoKit

/// The visualization alone observes this object: level traffic must not rebuild the keyboard or
/// recalculate its height. No audio framework or microphone access in this module.
@MainActor
public final class VoiceActivityModel: ObservableObject {
    @Published public private(set) var isActive = false
    @Published private var transition = Transition()
    private var latestCaptureDate: Date?

    public init() {}

    public func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        transition = Transition()
        latestCaptureDate = nil
    }

    public func receive(_ sample: AudioLevel, now: Date = .now,
                        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isActive, sample.isFresh(at: now),
              latestCaptureDate.map({ sample.capturedAt > $0 }) ?? true else { return }
        let current = level(at: uptime)
        latestCaptureDate = sample.capturedAt
        transition = Transition(from: current, to: min(max(sample.level, 0), 1),
                                began: uptime, age: max(0, now.timeIntervalSince(sample.capturedAt)))
    }

    public func level(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard isActive else { return 0 }
        let elapsed = max(0, uptime - transition.began)
        let interpolated = transition.to + (transition.from - transition.to) * exp(-elapsed / 0.055)
        // A missed stop signal or a suspended app must never leave frozen speech energy.
        let staleFor = max(0, elapsed + transition.age - 0.15)
        return interpolated * exp(-staleFor / 0.18)
    }

    private struct Transition {
        var from = 0.0
        var to = 0.0
        var began = 0.0
        var age = 0.0
    }
}
