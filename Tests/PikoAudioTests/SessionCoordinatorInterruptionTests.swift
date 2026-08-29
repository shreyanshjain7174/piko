#if os(iOS)
import Foundation
import Testing
@testable import PikoAudio

/// Proves every SESS-04 recovering interruption type drives `SessionCoordinator`'s `phase` to
/// `.idle` deterministically via the shared `disarm()` path, and that the two non-recovering
/// event variants do not -- confirming Plan 03-01's Open-Question-1 design choice (no auto-resume,
/// re-arming is user-initiated) is what the code does, not just what the plan intended. This suite
/// proves the transition occurs deterministically on the first stream element after the
/// triggering event; it does not and cannot certify the literal "within 1 second" wall-clock
/// figure -- that remains a manual, physical-device entry in docs/SPIKES.md Spike 2.
@Suite("SessionCoordinator interruption recovery")
struct SessionCoordinatorInterruptionTests {

    @Test @MainActor
    func beganDrivesPhaseToIdle() async throws {
        let interruptions = MockInterruptionSource()
        let coordinator = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: interruptions,
            isForeground: { true })

        var iterator = coordinator.phase.makeAsyncIterator()
        try await coordinator.arm()
        #expect(await iterator.next() == .armed)

        interruptions.send(.began)
        #expect(await iterator.next() == .idle)
    }

    @Test @MainActor
    func routeChangedDrivesPhaseToIdle() async throws {
        let interruptions = MockInterruptionSource()
        let coordinator = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: interruptions,
            isForeground: { true })

        var iterator = coordinator.phase.makeAsyncIterator()
        try await coordinator.arm()
        #expect(await iterator.next() == .armed)

        interruptions.send(.routeChanged)
        #expect(await iterator.next() == .idle)
    }

    @Test @MainActor
    func lowPowerModeEnabledDrivesPhaseToIdle() async throws {
        let interruptions = MockInterruptionSource()
        let coordinator = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: interruptions,
            isForeground: { true })

        var iterator = coordinator.phase.makeAsyncIterator()
        try await coordinator.arm()
        #expect(await iterator.next() == .armed)

        interruptions.send(.lowPowerModeChanged(enabled: true))
        #expect(await iterator.next() == .idle)
    }

    @Test @MainActor
    func nonRecoveringEventsDoNotDisarm() async throws {
        let interruptions = MockInterruptionSource()
        let coordinator = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: interruptions,
            isForeground: { true })
        let stream = coordinator.phase

        var iterator = stream.makeAsyncIterator()
        try await coordinator.arm()
        #expect(await iterator.next() == .armed)

        interruptions.send(.lowPowerModeChanged(enabled: false))
        interruptions.send(.ended(shouldResume: true))

        enum ProbeResult { case observed(SessionPhase), timedOut }

        // Prove neither non-recovering event drove a transition: race a fresh read of the same
        // shared stream against a bounded wait. If either had wrongly disarmed, .idle would
        // already be queued and this task would return it well before the timeout wins.
        let probe = try await withThrowingTaskGroup(of: ProbeResult.self) { group in
            group.addTask {
                for await phase in stream { return .observed(phase) }
                return .timedOut
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(200))
                return .timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        if case .observed(let phase) = probe {
            Issue.record("non-recovering event unexpectedly drove a phase transition to \(phase)")
        }

        // Now prove the coordinator is still armed and listening by disarming for real.
        interruptions.send(.began)
        #expect(await iterator.next() == .idle)
    }
}
#endif
