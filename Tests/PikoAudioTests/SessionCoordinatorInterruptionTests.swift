#if os(iOS)
import Foundation
import Testing
@testable import PikoAudio
@testable import PikoKit

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

        var iterator = coordinator.phase.makeAsyncIterator()
        try await coordinator.arm()
        #expect(await iterator.next() == .armed)

        interruptions.send(.lowPowerModeChanged(enabled: false))
        interruptions.send(.ended(shouldResume: true))

        // Give the coordinator's internal interruption-consuming loop a bounded real-time window
        // to (wrongly) process the two non-recovering events above before we act further.
        try await Task.sleep(for: .milliseconds(200))

        // Now prove the coordinator is still armed and listening by disarming for real.
        interruptions.send(.began)
        #expect(await iterator.next() == .idle)

        // Finally, prove the two non-recovering events above produced no extra queued transition:
        // if either had wrongly disarmed, TWO `.idle` values would now be queued (the wrongful one
        // plus the real one from `.began` above), and this second read would return `.idle` again
        // immediately instead of timing out. Deliberately the LAST use of `iterator` in this test:
        // cancelling a losing race against `AsyncStream.next()` returns nil to end *that specific
        // call*, but the underlying stream storage is shared across every copy of the iterator, so
        // any later `.next()` call (even via a distinct struct copy) would also see nil forever
        // after -- racing must happen only once `iterator` is no longer needed for anything else.
        // Boxed as `@unchecked Sendable` purely to satisfy the compiler's `sending`-closure check
        // for crossing into `TaskGroup.addTask`; safe because nothing reads `iterator` afterward.
        final class IteratorBox: @unchecked Sendable {
            var iterator: AsyncStream<SessionPhase>.AsyncIterator
            init(_ iterator: AsyncStream<SessionPhase>.AsyncIterator) { self.iterator = iterator }
        }
        let box = IteratorBox(iterator)
        enum ProbeResult { case observed(SessionPhase), timedOut }
        let probe = try await withThrowingTaskGroup(of: ProbeResult.self) { group -> ProbeResult in
            group.addTask {
                if let phase = await box.iterator.next() { return .observed(phase) }
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
            Issue.record("non-recovering event unexpectedly drove an extra phase transition to \(phase)")
        }
    }
}
#endif
