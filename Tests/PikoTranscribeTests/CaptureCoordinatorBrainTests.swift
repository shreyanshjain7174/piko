import Foundation
import Testing
import PikoKit
import PikoMemory
@testable import PikoTranscribe
#if os(iOS)
@testable import PikoAudio
@testable import PikoCaptureCore
#endif

#if os(iOS)
@Suite("CaptureCoordinator Brain wiring", .serialized)
struct CaptureCoordinatorBrainTests {

    @Test @MainActor func cleanedTextShipsWhileRawStaysUntouched() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let (coordinator, channel, session) = try await makeCoordinator(
                transcript: "um hello there",
                brain: CleanBrain(output: "Hello there.")
            )
            await coordinator.stopCapture()

            let result = channel.readResult()
            #expect(result?.raw == "um hello there")
            #expect(result?.shipped == "Hello there.")
            await session.disarm()
        }
    }

    @Test @MainActor func budgetExceededShipsRawAndDoesNotThrow() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let (coordinator, channel, session) = try await makeCoordinator(
                transcript: "raw transcript",
                brain: SlowBrain()
            )
            await coordinator.stopCapture()

            let result = channel.readResult()
            #expect(result?.raw == "raw transcript")
            #expect(result?.shipped == "raw transcript")
            #expect(channel.postedSignals.contains(.resultReady))
            await session.disarm()
        }
    }

    @Test @MainActor func unavailableBrainShipsRawLikeBudgetSkip() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let (coordinator, channel, session) = try await makeCoordinator(
                transcript: "heard this",
                brain: UnavailableBrain()
            )
            await coordinator.stopCapture()

            let result = channel.readResult()
            #expect(result?.raw == "heard this")
            #expect(result?.shipped == "heard this")
            await session.disarm()
        }
    }

    @Test @MainActor func resultCarriesBrainRoute() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let (coordinator, channel, session) = try await makeCoordinator(
                transcript: "what did I say",
                brain: RoutingBrain(route: .recall)
            )
            await coordinator.stopCapture()

            #expect(channel.readResult()?.route == .recall)
            await session.disarm()
        }
    }

    @Test @MainActor func resultProfileComesFromPublishedChannelState() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let (coordinator, channel, session) = try await makeCoordinator(
                transcript: "ship this",
                brain: CleanBrain(output: "Ship this.")
            )
            var state = channel.readState() ?? SessionState()
            state.profile = .agent
            channel.writeState(state)

            await coordinator.stopCapture()

            #expect(channel.readResult()?.profile == .agent)
            await session.disarm()
        }
    }

    @Test @MainActor func brainMSIsGreaterThanZeroAfterMeasurableRewrite() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let (coordinator, channel, session) = try await makeCoordinator(
                transcript: "time me",
                brain: DelayedCleanBrain(output: "Time me.", delay: .milliseconds(20))
            )
            await coordinator.stopCapture()

            let brainMS = channel.readResult()?.timings.brainMS ?? 0
            #expect(brainMS > 0)
            await session.disarm()
        }
    }

    @MainActor
    private func makeCoordinator(
        transcript: String,
        brain: any Brain
    ) async throws -> (CaptureCoordinator, MockSessionChannel, SessionCoordinator) {
        let channel = MockSessionChannel()
        let mock = MockTranscriber()
        await mock.setScript(MockTranscriber.Script(drafts: [
            CaptureDraft(sessionEpoch: 1, sequence: 1, text: transcript, stablePrefix: transcript.count),
        ], delayBetween: .milliseconds(5)))

        let session = SessionCoordinator(
            channel: channel,
            interruptions: NullInterruptionSource(),
            isForeground: { true }
        )
        let coordinator = CaptureCoordinator(
            session: session,
            channel: channel,
            transcriber: mock,
            brain: brain,
            memory: EphemeralMemory()
        )
        try await session.arm()
        try await coordinator.startCapture()
        try await Task.sleep(for: .milliseconds(30))
        return (coordinator, channel, session)
    }
}

private struct CleanBrain: Brain {
    let output: String
    func route(_ text: String) async -> Route { .write }
    func rewrite(_ text: String, profile: Profile,
                 lexicon: [String], examples: [EditPair]) async throws -> String {
        output
    }
}

private struct SlowBrain: Brain {
    func route(_ text: String) async -> Route { .write }
    func rewrite(_ text: String, profile: Profile,
                 lexicon: [String], examples: [EditPair]) async throws -> String {
        throw PikoError.brainBudgetExceeded(milliseconds: 600)
    }
}

private struct UnavailableBrain: Brain {
    func route(_ text: String) async -> Route { .write }
    func rewrite(_ text: String, profile: Profile,
                 lexicon: [String], examples: [EditPair]) async throws -> String {
        throw PikoError.brainUnavailable("test")
    }
}

private struct RoutingBrain: Brain {
    let route: Route
    func route(_ text: String) async -> Route { route }
    func rewrite(_ text: String, profile: Profile,
                 lexicon: [String], examples: [EditPair]) async throws -> String {
        text
    }
}

private struct DelayedCleanBrain: Brain {
    let output: String
    let delay: Duration
    func route(_ text: String) async -> Route { .write }
    func rewrite(_ text: String, profile: Profile,
                 lexicon: [String], examples: [EditPair]) async throws -> String {
        try await Task.sleep(for: delay)
        return output
    }
}
#endif
