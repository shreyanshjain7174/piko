import Foundation
import PikoAudio
import PikoBrain
import PikoBridge
import PikoKit
import PikoTranscribe
import UIKit

/// The one place `PikoBridge` and `PikoAudio` meet. Sole construction site of a real
/// `DarwinChannel` and `SessionCoordinator`.
@MainActor
final class AppComposition {
    static let shared = AppComposition()

    let channel: any SessionChannel
    let session: SessionCoordinator
    public let captureCoordinator: CaptureCoordinator
    public let liveActivityController: LiveActivityController

    private init() {
        let channel = DarwinChannel()!
        self.channel = channel
        session = SessionCoordinator(channel: channel, interruptions: AVAudioSessionInterruptionSource(), isForeground: { UIApplication.shared.applicationState == .active })

        let transcriber: any Transcriber
        #if targetEnvironment(simulator)
        transcriber = MockTranscriber()
        #else
        transcriber = SpeechTranscriberEngine()
        #endif

        let brain: any Brain
        #if targetEnvironment(simulator)
        brain = MockBrain()
        #else
        brain = SystemBrain()
        #endif

        self.captureCoordinator = CaptureCoordinator(
            session: session,
            channel: channel,
            transcriber: transcriber,
            brain: brain
        )
        self.liveActivityController = LiveActivityController()

        Task { [weak self] in
            guard let channel = self?.channel else { return }
            for await signal in channel.signals {
                guard let self else { return }
                await self.captureCoordinator.handleSignal(signal)
            }
        }

        Task { [weak self] in
            guard let session = self?.session else { return }
            for await phase in session.phase {
                guard let self else { return }
                await self.liveActivityController.update(phase: phase)
            }
        }

        Task { [weak self] in
            guard let channel = self?.channel else { return }
            for await signal in channel.signals {
                guard let self else { return }
                guard signal == .draftUpdated else { continue }
                if let draft = self.channel.readDraft() {
                    await self.liveActivityController.updateWords(from: draft.text)
                }
            }
        }

        captureCoordinator.onTidyingChange = { [weak self] isTidying in
            Task { @MainActor in
                await self?.liveActivityController.setTidying(isTidying)
            }
        }
    }

    /// Arms the session, then starts (or adopts) the Live Activity in the same foreground call path.
    func armSession() async throws {
        try await session.arm()
        await liveActivityController.start(skin: channel.readState()?.skin ?? .cute)
    }
}
