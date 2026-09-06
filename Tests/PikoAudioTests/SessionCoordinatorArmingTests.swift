#if os(iOS)
import Foundation
import Testing
@testable import PikoAudio
@testable import PikoKit

@Suite("SessionCoordinator arming", .serialized)
struct SessionCoordinatorArmingTests {

    @Test @MainActor
    func armTransitionsIdleToArmed() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let coordinator = SessionCoordinator(
                channel: MockSessionChannel(),
                interruptions: MockInterruptionSource(),
                isForeground: { true })

            var iterator = coordinator.phase.makeAsyncIterator()
            try await coordinator.arm()

            #expect(await iterator.next() == .armed)
            await coordinator.disarm()
        }
    }

    @Test @MainActor
    func twoSimultaneousPhaseSubscribersBothSeeEveryTransition() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            // Reproduces the real-world shape: AppComposition's LiveActivityController
            // observation loop and ArmView's own phase-observing task both subscribe to
            // `session.phase` at the same time. Before the broadcast fix, `phase` was a
            // single shared `AsyncStream` continuation — two concurrent `for await`
            // consumers raced for each yielded value instead of both receiving it.
            let coordinator = SessionCoordinator(
                channel: MockSessionChannel(),
                interruptions: MockInterruptionSource(),
                isForeground: { true })

            var firstSubscriber = coordinator.phase.makeAsyncIterator()
            var secondSubscriber = coordinator.phase.makeAsyncIterator()

            try await coordinator.arm()

            #expect(await firstSubscriber.next() == .armed)
            #expect(await secondSubscriber.next() == .armed)

            try await coordinator.startCapture()

            #expect(await firstSubscriber.next() == .capturing)
            #expect(await secondSubscriber.next() == .capturing)

            await coordinator.disarm()
        }
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
    func stopCaptureTransitionsThroughTidyingBeforeArmed() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
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
            #expect(await iterator.next() == .tidying)
            await coordinator.finishTidying()
            #expect(await iterator.next() == .armed)
            await coordinator.disarm()
        }
    }

    @Test @MainActor
    func armPreservesAgentProfileRatherThanResettingToMessage() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let channel = MockSessionChannel()
            let priorHeartbeat = Date(timeIntervalSinceNow: -1)
            channel.writeState(SessionState(
                phase: .idle,
                heartbeat: priorHeartbeat,
                skin: .hero,
                profile: .agent))

            let coordinator = SessionCoordinator(
                channel: channel,
                interruptions: MockInterruptionSource(),
                isForeground: { true })

            try await coordinator.arm()
            let armed = try #require(channel.readState())
            #expect(armed.profile == .agent)
            #expect(armed.skin == .hero)
            #expect(armed.phase == .armed)

            await coordinator.disarm()
            let idle = try #require(channel.readState())
            #expect(idle.profile == .agent)
            #expect(idle.skin == .hero)
            #expect(idle.phase == .idle)
        }
    }

    @Test @MainActor
    func heartbeatPublicationPreservesSelectedAgentProfile() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let channel = MockSessionChannel()
            channel.writeState(SessionState(
                phase: .idle,
                heartbeat: Date(timeIntervalSinceNow: -1),
                skin: .sparkle,
                profile: .agent))

            let coordinator = SessionCoordinator(
                channel: channel,
                interruptions: MockInterruptionSource(),
                isForeground: { true })

            try await coordinator.arm()
            let armedHeartbeat = try #require(channel.readState()).heartbeat

            try await Task.sleep(for: .seconds(2.5))
            let later = try #require(channel.readState())
            #expect(later.profile == .agent)
            #expect(later.skin == .sparkle)
            #expect(later.phase == .armed)
            #expect(later.heartbeat > armedHeartbeat)

            await coordinator.disarm()
        }
    }
}
#endif
