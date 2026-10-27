#if os(iOS)
import Foundation
import Testing
@testable import PikoAudio
@testable import PikoKit

@Suite("SessionCoordinator idle release", .serialized)
struct SessionCoordinatorIdleTests {
    @MainActor
    private func makeCoordinator(idle: Duration) -> SessionCoordinator {
        SessionCoordinator(
            channel: MockSessionChannel(),
            interruptions: MockInterruptionSource(),
            audioSession: .init(activate: {}, deactivate: {}),
            idleTimeout: idle,
            isForeground: { true })
    }

    @Test @MainActor
    func idleArmedSessionReleasesMicrophone() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let coordinator = makeCoordinator(idle: .milliseconds(150))
            try await coordinator.arm()
            try await Task.sleep(for: .milliseconds(600))
            #expect(coordinator.currentPhase == .idle)
        }
    }

    @Test @MainActor
    func captureKeepsSessionAndTidyingRestartsIdleClock() async throws {
        try await AudioSessionTestGate.shared.run { @MainActor in
            let coordinator = makeCoordinator(idle: .milliseconds(150))
            try await coordinator.arm()
            try await coordinator.startCapture()
            try await Task.sleep(for: .milliseconds(400))
            #expect(coordinator.currentPhase == .capturing)
            await coordinator.stopCapture()
            coordinator.finishTidying()
            #expect(coordinator.currentPhase == .armed)
            try await Task.sleep(for: .milliseconds(600))
            #expect(coordinator.currentPhase == .idle)
        }
    }
}
#endif
