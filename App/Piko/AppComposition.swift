import Foundation
import PikoAudio
import PikoBrain
import PikoBridge
import PikoKit
import PikoMemory
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
    public let memory: any Memory
    private let captureLaunchRequestStore: CaptureLaunchRequestStore?
    private var isHandlingCaptureLaunch = false

    var onCaptureLaunchError: (@MainActor (String) -> Void)?
    private(set) var lastCaptureLaunchError: String?

    private init() {
        let channel = DarwinChannel()!
        self.channel = channel
        session = SessionCoordinator(channel: channel, interruptions: AVAudioSessionInterruptionSource(), audioLevels: channel, isForeground: { UIApplication.shared.applicationState == .active })

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

        let appSupportURL = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dbURL = appSupportURL.appendingPathComponent("history.sqlite")
        let memory: any Memory = try! SQLiteMemory(path: dbURL)
        self.memory = memory
        self.captureLaunchRequestStore = CaptureLaunchRequestStore()

        self.captureCoordinator = CaptureCoordinator(
            session: session,
            channel: channel,
            transcriber: transcriber,
            brain: brain,
            memory: memory
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
                guard signal == .captureRequested, let self else { continue }
                await self.handlePendingCaptureRequest()
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

    /// Consume an intent request only after foreground activation. Keeping the request on disk
    /// until then covers both a running app and a cold process launch without a timing race.
    func handlePendingCaptureRequest() async {
        guard UIApplication.shared.applicationState == .active,
              !isHandlingCaptureLaunch,
              let store = captureLaunchRequestStore,
              let request = store.pending() else {
            return
        }

        isHandlingCaptureLaunch = true
        defer { isHandlingCaptureLaunch = false }
        lastCaptureLaunchError = nil

        if session.currentPhase == .capturing || captureCoordinator.isTidying {
            store.clear(id: request.id)
            return
        }

        do {
            if session.currentPhase == .idle {
                try await armSession()
            }
            guard session.currentPhase == .armed else {
                store.clear(id: request.id)
                return
            }
            try await captureCoordinator.startCapture()
            store.clear(id: request.id)
        } catch {
            store.clear(id: request.id)
            let message = PikoError.userMessage(for: error)
            lastCaptureLaunchError = message
            onCaptureLaunchError?(message)
        }
    }
}
