#if os(iOS)
import Foundation
import Testing
@testable import PikoAudio
@testable import PikoKit

@Suite("Session startup cancellation", .serialized)
@MainActor
struct SessionCoordinatorCancellationTests {
    @Test("An already-cancelled arming task cannot activate audio")
    func cancelledArmingCannotActivateAudio() async {
        var activations = 0
        let channel = MockSessionChannel()
        let session = SessionCoordinator(
            channel: channel,
            interruptions: MockInterruptionSource(),
            audioSession: .init(activate: { activations += 1 }, deactivate: {}),
            isForeground: { true })
        let startup = Task { try await session.arm() }
        startup.cancel()
        var cancelled = false
        do { try await startup.value }
        catch is CancellationError { cancelled = true }
        catch { Issue.record("Unexpected arming error: \(error)") }
        #expect(cancelled)
        #expect(activations == 0)
        #expect(session.currentPhase == .idle)
        #expect(channel.readState()?.phase != .armed)
        await session.disarm()
    }

    @Test("A cancelled capture task cannot leave an armed session recording")
    func cancelledCaptureCannotBeginRecording() async throws {
        let session = SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: MockInterruptionSource(),
            audioSession: .init(activate: {}, deactivate: {}),
            isForeground: { true })
        try await session.arm()
        let capture = Task { try await session.startCapture() }
        capture.cancel()
        var cancelled = false
        do { try await capture.value }
        catch is CancellationError { cancelled = true }
        catch { Issue.record("Unexpected capture error: \(error)") }
        #expect(cancelled)
        #expect(session.currentPhase == .armed)
        await session.disarm()
    }
}
#endif
