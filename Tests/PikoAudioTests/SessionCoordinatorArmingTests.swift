#if os(iOS)
import Foundation
import Testing
@testable import PikoAudio
@testable import PikoKit

@Suite("SessionCoordinator arming")
struct SessionCoordinatorArmingTests {

    @Test @MainActor
    func armTransitionsIdleToArmed() async throws {
        let coordinator = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: MockInterruptionSource(),
            isForeground: { true })

        var iterator = coordinator.phase.makeAsyncIterator()
        try await coordinator.arm()

        #expect(await iterator.next() == .armed)
    }

    @Test @MainActor
    func armThrowsNotForegroundWhenBackgrounded() async {
        let coordinator = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: MockInterruptionSource(),
            isForeground: { false })

        do {
            try await coordinator.arm()
            Issue.record("expected arm() to throw PikoError.notForeground")
        } catch PikoError.notForeground {
            // expected
        } catch {
            Issue.record("expected PikoError.notForeground, got \(error)")
        }
    }

    @Test @MainActor
    func startCaptureBeforeArmThrowsNotArmed() async {
        let coordinator = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: MockInterruptionSource(),
            isForeground: { true })

        do {
            try await coordinator.startCapture()
            Issue.record("expected startCapture() to throw PikoError.notArmed")
        } catch PikoError.notArmed {
            // expected
        } catch {
            Issue.record("expected PikoError.notArmed, got \(error)")
        }
    }

    @Test @MainActor
    func stopCaptureReturnsToArmedNotIdle() async throws {
        let coordinator = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: MockInterruptionSource(),
            isForeground: { true })

        var iterator = coordinator.phase.makeAsyncIterator()

        try await coordinator.arm()
        #expect(await iterator.next() == .armed)

        try await coordinator.startCapture()
        #expect(await iterator.next() == .capturing)

        await coordinator.stopCapture()
        #expect(await iterator.next() == .armed)
    }
}
#endif
