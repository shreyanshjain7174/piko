#if os(iOS)
import AVFAudio
import Foundation
import Testing
@testable import PikoAudio

/// Proves `AVAudioSessionInterruptionSource`'s notification-translation logic using synthetic
/// `NotificationCenter` posts that fabricate the exact payload shape `AVAudioSession`/`ProcessInfo`
/// supply on a real device -- no audio hardware or device required.
@Suite("AVAudioSessionInterruptionSource notification translation")
struct AVAudioSessionInterruptionSourceTests {

    enum RaceResult { case eventObserved(InterruptionEvent), timedOut }

    /// Races the stream's first element against a 2s CI-safe timeout, mirroring
    /// `RoundTripLatencyTests`' established pattern.
    private func firstEvent(from stream: AsyncStream<InterruptionEvent>, post: @Sendable @escaping () -> Void) async throws -> RaceResult {
        try await withThrowingTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let event = await iterator.next() else { return .timedOut }
                return .eventObserved(event)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                return .timedOut
            }

            // Give the reader task room to actually start running and register its
            // NotificationCenter observer -- Task{} scheduling has no synchronous-start
            // guarantee (unlike DarwinChannel's continuation-based signals in RoundTripLatencyTests).
            try? await Task.sleep(for: .milliseconds(100))
            post()

            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    @Test
    func interruptionBeganTranslatesToBeganEvent() async throws {
        let source = AVAudioSessionInterruptionSource()
        let stream = source.events

        let result = try await firstEvent(from: stream) {
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        }

        guard case .eventObserved(let event) = result else {
            Issue.record("timed out waiting for .began translation")
            return
        }
        #expect(event == .began)
    }

    @Test
    func routeChangeTranslatesToRouteChangedEvent() async throws {
        let source = AVAudioSessionInterruptionSource()
        let stream = source.events

        let result = try await firstEvent(from: stream) {
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        }

        guard case .eventObserved(let event) = result else {
            Issue.record("timed out waiting for .routeChanged translation")
            return
        }
        #expect(event == .routeChanged)
    }

    @Test
    func powerStateChangeTranslatesToLowPowerModeChangedEvent() async throws {
        let source = AVAudioSessionInterruptionSource()
        let stream = source.events

        let result = try await firstEvent(from: stream) {
            NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }

        guard case .eventObserved(let event) = result else {
            Issue.record("timed out waiting for .lowPowerModeChanged translation")
            return
        }
        // The notification itself carries no payload -- the current value must be re-queried
        // from ProcessInfo, so only the case and the live reading are asserted, never a fixed bool.
        #expect(event == .lowPowerModeChanged(enabled: ProcessInfo.processInfo.isLowPowerModeEnabled))
    }
}
#endif
