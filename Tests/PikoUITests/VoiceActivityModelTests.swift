import Foundation
import Testing
import PikoKit
import PikoUI

@MainActor
@Suite("Voice orb interpolation and lifecycle")
struct VoiceActivityModelTests {
    let now = Date(timeIntervalSinceReferenceDate: 100)

    @Test func continuousUpdatesAndStaleDecay() {
        let model = VoiceActivityModel()
        model.setActive(true)
        model.receive(AudioLevel(level: 1, capturedAt: now), now: now, uptime: 10)
        #expect(model.level(at: 10) == 0)
        #expect(model.level(at: 10.1) > 0.8)
        let before = model.level(at: 10.1)
        model.receive(AudioLevel(level: 0.2, capturedAt: now.addingTimeInterval(0.1)),
                      now: now.addingTimeInterval(0.1), uptime: 10.1)
        #expect(abs(model.level(at: 10.1) - before) < 0.000_001)
        #expect(model.level(at: 11.5) < 0.001)
    }

    @Test func staleDuplicateAndOutOfOrderLevelsDoNotRestartAnimation() {
        let model = VoiceActivityModel()
        model.setActive(true)
        model.receive(AudioLevel(level: 1, capturedAt: now.addingTimeInterval(-1)), now: now, uptime: 10)
        #expect(model.level(at: 10.1) == 0)
        let sample = AudioLevel(level: 1, capturedAt: now)
        model.receive(sample, now: now, uptime: 10)
        let expected = model.level(at: 10.2)
        model.receive(sample, now: now.addingTimeInterval(0.2), uptime: 10.2)
        model.receive(AudioLevel(level: 0, capturedAt: now.addingTimeInterval(-0.1)),
                      now: now.addingTimeInterval(0.2), uptime: 10.2)
        #expect(model.level(at: 10.2) == expected)
    }

    @Test func leavingCaptureClearsEnergyAndIgnoresLateNotifications() {
        let model = VoiceActivityModel()
        model.setActive(true)
        model.receive(AudioLevel(level: 1, capturedAt: now), now: now, uptime: 10)
        model.setActive(false)
        model.receive(AudioLevel(level: 1, capturedAt: now), now: now, uptime: 10)
        #expect(model.level(at: 10.1) == 0)
        model.setActive(true)
        #expect(model.level(at: 10.1) == 0)
    }
}
