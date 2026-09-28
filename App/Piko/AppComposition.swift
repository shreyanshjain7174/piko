import Foundation
import AVFAudio
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
    public let askCoordinator: AskCoordinator
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
        if ProcessInfo.processInfo.arguments.contains("-pikoRealSpeech") {
            transcriber = SpeechTranscriberEngine()
        } else if ProcessInfo.processInfo.arguments.contains("-pikoSarvam") {
            // Simulator-only test hook: the key can come from environment for
            // scripted runs (never a real device path). Falls back to on-device
            // when the env var is missing, so a broken flag never yields a broken engine.
            let envKey = ProcessInfo.processInfo.environment["SARVAM_API_KEY"]
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            if let envKey {
                let sarvamLang = ProcessInfo.processInfo.environment["SARVAM_LANGUAGE"] ?? "unknown"
                transcriber = SarvamTranscriberEngine(apiKey: envKey, languageCode: sarvamLang)
            } else {
                transcriber = SpeechTranscriberEngine()
            }
        } else {
            transcriber = MockTranscriber()
        }
        #else
        // Production path: backend choice lives in App Group settings; the key
        // lives in the App Group Keychain. If the user picked Sarvam but never
        // stored a key, degrade to on-device rather than construct a broken engine —
        // the Settings UI is the place where a missing key becomes visible.
        switch CaptureModeStore.readBackend() {
        case .sarvamCloud:
            if let key = SarvamKeyStore.read() {
                transcriber = SarvamTranscriberEngine(apiKey: key, languageCode: "unknown")
            } else {
                transcriber = SpeechTranscriberEngine()
            }
        case .onDevice:
            transcriber = SpeechTranscriberEngine()
        }
        #endif

        let brain: any Brain
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-pikoRealSpeech")
            || ProcessInfo.processInfo.arguments.contains("-pikoSarvam") {
            brain = SystemBrain()
        } else {
            brain = MockBrain()
        }
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
        self.askCoordinator = AskCoordinator(
            agent: PikoAgent(memory: memory),
            memory: memory,
            brain: brain,
            channel: channel
        )
        self.liveActivityController = LiveActivityController()

        // Battery hooks: the notch pet rests (static frame) on Low Power Mode or under
        // 20% battery, and resumes when conditions lift.
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.pushPetAnimated() }
        // Raw C constant: the Swift alias moved in the 26.5 SDK.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.pushPetAnimated() }
        pushPetAnimated()

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

        // Voice levels reach the notch through the same rolling-bucket pipeline as words.
        Task { [weak self] in
            guard let channel = self?.channel else { return }
            for await signal in channel.signals {
                guard let self else { return }
                guard signal == .audioLevelUpdated else { continue }
                if let sample = (self.channel as? any AudioLevelChannel)?.readAudioLevel() {
                    await self.liveActivityController.updateLevels(sample)
                }
            }
        }

        #if DEBUG
        // Screenshot/development hook: `-pikoDemoLevels` synthesizes speech energy on
        // Simulator (whose microphone is silent). Device builds never run this.
        if ProcessInfo.processInfo.arguments.contains("-pikoDemoLevels") {
            startDemoLevelPump()
        }
        // Development/UI-test hook: walk straight into a capture shortly after launch.
        // arm() refuses while the app is still activating, and a wedged host audio device
        // can stall engine start — so keep trying across the whole window and never break
        // on a single throw.
        if ProcessInfo.processInfo.arguments.contains("-pikoAutoStart") {
            Task {
                guard await AVAudioApplication.requestRecordPermission() else { return }
                for _ in 0..<36 {
                    try? await Task.sleep(for: .seconds(0.5))
                    if session.currentPhase == .idle { try? await armSession() }
                    if session.currentPhase == .capturing { break }
                    guard session.currentPhase == .armed, !captureCoordinator.isTidying else { continue }
                    try? await captureCoordinator.startCapture()
                }
            }
        }
        #endif

        // The notch's Stop button is handled by the widget extension while the app is
        // backgrounded; Darwin delivery is best-effort there, so a poll is the fallback —
        // but an ADAPTIVE one: foreground skips it (Darwin is reliable), background
        // polls fast while capturing (stop latency matters) and slow while merely armed.
        Task { [weak self] in
            guard let store = StopRequestStore() else { return }
            while !Task.isCancelled {
                guard let self else { return }
                let background = UIApplication.shared.applicationState != .active
                let interval: Duration = !background
                    ? .seconds(5)
                    : (self.session.currentPhase == .capturing ? .milliseconds(400) : .seconds(3))
                try? await Task.sleep(for: interval)
                guard self.session.currentPhase != .idle else { continue }
                guard store.consumePending() != nil else { continue }
                if self.session.currentPhase == .capturing {
                    await self.captureCoordinator.stopCapture()
                }
                await self.session.disarm()
                await self.liveActivityController.end()
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

    /// The pet sleeps on Low Power Mode or under 20% battery — the notch stays alive,
    /// just still. Conditions lifting wakes it back up.
    private nonisolated func pushPetAnimated() {
        let device = UIDevice.current
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let lowBattery = device.isBatteryMonitoringEnabled
            && device.batteryState != .charging
            && device.batteryLevel >= 0
            && device.batteryLevel <= 0.2
        let animated = !lowPower && !lowBattery
        Task { @MainActor [weak self] in
            await self?.liveActivityController.setPetAnimated(animated)
        }
    }

    #if DEBUG
    /// Synthesizes speech energy through the real channel while capturing, so the orb, the
    /// wave and the notch animate on Simulator exactly as they would from a real microphone.
    private func startDemoLevelPump() {
        let channel = self.channel
        Task {
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(110))
                guard session.currentPhase == .capturing else { continue }
                let t = ProcessInfo.processInfo.systemUptime - start
                let wave = 0.30
                    + 0.30 * abs(sin(t * 2.1))
                    + 0.16 * abs(sin(t * 3.9 + 1.3))
                    + Double.random(in: 0...0.06)
                let sample = AudioLevel(level: min(wave, 1), capturedAt: .now)
                (channel as? any AudioLevelChannel)?.writeAudioLevel(sample)
                channel.post(.audioLevelUpdated)
            }
        }
    }
    #endif

    #if DEBUG
    /// Deep-link steering for development and UI tests: `piko://arm`, `piko://start`,
    /// `piko://stop`, `piko://disarm`. Lets `simctl openurl` and XCUITest drive the capture
    /// state machine without touch synthesis. Never compiled into release.
    func handleDebugURL(_ url: URL) async {
        guard url.scheme == "piko" else { return }
        guard await AVAudioApplication.requestRecordPermission() else { return }
        switch url.host {
        case "arm":
            if session.currentPhase == .idle { try? await armSession() }
        case "start":
            if session.currentPhase == .idle { try? await armSession() }
            if session.currentPhase == .armed, !captureCoordinator.isTidying {
                try? await captureCoordinator.startCapture()
            }
        case "stop":
            if session.currentPhase == .capturing { await captureCoordinator.stopCapture() }
        case "disarm":
            if session.currentPhase == .capturing { await captureCoordinator.stopCapture() }
            await session.disarm()
            await liveActivityController.end()
        default:
            break
        }
    }
    #endif

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
