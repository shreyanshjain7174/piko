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
    static let shared: Result<AppComposition, any Error> = Result { try AppComposition() }

    let channel: any SessionChannel
    let session: SessionCoordinator
    public let captureCoordinator: CaptureCoordinator
    public let liveActivityController: LiveActivityController
    public let memory: any Memory
    let items: any ItemStore
    let organizer: any Organizer = ModelOrganizer()
    let reminders = ReminderWriter()
    let dumpLog = DumpLog()
    let planner: any Planner = ModelPlanner()
    let decider: any AssistantDeciding
    private(set) lazy var harness = ToolHarness(
        tools: AssistantTools.all(memory: memory, items: items, reminders: reminders))
    private let captureLaunchRequestStore: CaptureLaunchRequestStore?
    private var isHandlingCaptureLaunch = false
    private let transcriber: any AudioTranscriber
    let brain: any Brain
    private var armRequestID = UUID()

    var onCaptureLaunchError: (@MainActor (String) -> Void)?
    /// Set by Home so Talk to Piko from Control Center / Action Button runs the same voice turn.
    var onTalkRequested: (@MainActor () async -> Void)?
    var onStopRequested: (@MainActor () -> Void)?
    private(set) var lastCaptureLaunchError: String?

    #if DEBUG
    /// App-native tests use a unique SQLite file; never read or write the owner's real history.
    static func isolatedForTests(historyPath: URL, decider: any AssistantDeciding = ModelDecider()) throws -> AppComposition {
        try AppComposition(historyPath: historyPath, decider: decider)
    }
    #endif

    private init(historyPath: URL? = nil, decider: any AssistantDeciding = ModelDecider()) throws {
        self.decider = decider
        guard let channel = DarwinChannel() else { throw PikoError.sharedContainerUnavailable }
        self.channel = channel
        session = SessionCoordinator(channel: channel, interruptions: AVAudioSessionInterruptionSource(), audioLevels: channel, isForeground: { UIApplication.shared.applicationState == .active })

        let transcriber: any AudioTranscriber
        #if DEBUG
        if let selection = UserDefaults.standard.string(forKey: "PikoBenchmarkEngine") {
            transcriber = try Self.makeBenchmarkTranscriber(selection)
        } else {
        #if targetEnvironment(simulator)
        transcriber = MockTranscriber()
        #else
        transcriber = SpeechTranscriberEngine()
        #endif
        }
        #else
        transcriber = SpeechTranscriberEngine()
        #endif
        self.transcriber = transcriber

        let brain: any Brain
        #if targetEnvironment(simulator)
        brain = MockBrain()
        #else
        brain = SystemBrain()
        #endif
        self.brain = brain

        let sqlite = try SQLiteMemory(path: historyPath ?? Self.historyURL())
        let memory: any Memory = sqlite
        self.memory = memory
        self.items = sqlite
        self.captureLaunchRequestStore = CaptureLaunchRequestStore()

        self.captureCoordinator = CaptureCoordinator(
            session: session,
            channel: channel,
            transcriber: transcriber,
            brain: brain,
            memory: memory
        )
        self.liveActivityController = LiveActivityController()
        #if DEBUG
        if let fixture = UserDefaults.standard.string(forKey: "PikoBenchmarkCaptureFixture") {
            guard fixture == URL(fileURLWithPath: fixture).lastPathComponent,
                  fixture.hasSuffix(".wav"),
                  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw PikoError.audioUnavailable
            }
            try captureCoordinator.setBenchmarkFixture(
                documents.appendingPathComponent("Benchmarks").appendingPathComponent(fixture))
        }
        #endif
        Task { [weak self] in
            guard let channel = self?.channel else { return }
            for await signal in channel.signals {
                guard let self else { return }
                if signal == .stopRequested {
                    await self.stopFromLiveActivity()
                } else {
                    await self.captureCoordinator.handleSignal(signal)
                }
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

    static func historyURL() throws -> URL {
        var appSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        var storageValues = URLResourceValues()
        storageValues.isExcludedFromBackup = true
        try appSupportURL.setResourceValues(storageValues)
        return appSupportURL.appendingPathComponent("history.sqlite")
    }

    /// Arms the session, then starts (or adopts) the Live Activity in the same foreground call path.
    func armSession() async throws {
        try Task.checkCancellation()
        #if DEBUG
        if UserDefaults.standard.string(forKey: "PikoBenchmarkFixtureManifest") != nil
            || UserDefaults.standard.string(forKey: "PikoBenchmarkFixture") != nil {
            throw PikoError.benchmarkInProgress
        }
        #endif
        guard UIApplication.shared.applicationState == .active else { throw PikoError.notForeground }
        let requestID = UUID()
        armRequestID = requestID
        let allowed = await AVAudioApplication.requestRecordPermission()
        try Task.checkCancellation()
        guard armRequestID == requestID else { throw CancellationError() }
        guard allowed else { throw PikoError.microphoneDenied }
        try await prepareSpeech()
        try Task.checkCancellation()
        guard armRequestID == requestID else { throw CancellationError() }
        guard UIApplication.shared.applicationState == .active else { throw PikoError.notForeground }
        try await session.arm()
    }

    /// The Live Activity is only shown while Piko is actively listening or working on a request,
    /// and only for captures started in the foreground (ActivityKit's own rule).
    func showLiveActivity() async {
        guard UIApplication.shared.applicationState == .active else { return }
        await liveActivityController.start(skin: channel.readState()?.skin ?? .cute)
    }

    /// Stop from the Live Activity: end any capture, release the microphone and remove the
    /// activity immediately. Called directly by `StopSessionIntent` in the app process.
    func stopFromLiveActivity() async {
        armRequestID = UUID()
        onStopRequested?()
        if session.currentPhase == .capturing || captureCoordinator.isTidying {
            await captureCoordinator.stopCapture(endSession: true)
        }
        await session.disarm()
        await liveActivityController.end()
    }

    func prepareSpeech(allowDownload: Bool = false) async throws {
        guard UIApplication.shared.applicationState == .active else { throw PikoError.notForeground }
        try await transcriber.prepare(locale: Locale(identifier: "en-IN"), allowDownload: allowDownload)
    }

    #if DEBUG
    private static func makeBenchmarkTranscriber(_ selection: String) throws -> any AudioTranscriber {
        switch selection {
        case "apple":
            return SpeechTranscriberEngine()
        case "whisper":
            let cached = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Benchmarks/Whisper", isDirectory: true)
            guard let folder = Bundle.main.url(forResource: "Whisper", withExtension: nil) ?? cached,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
                throw PikoError.speechAssetsMissing
            }
            return WhisperTranscriberEngine(modelFolder: folder)
        default:
            throw PikoError.speechUnavailable("benchmark engine \(selection)")
        }
    }

    func prepareBenchmarkSpeech() async throws -> String {
        guard !(transcriber is MockTranscriber) else {
            throw PikoError.speechUnavailable("Simulator mock (not a speech model)")
        }
        try await prepareSpeech()
        return String(describing: type(of: transcriber))
    }

    func runBenchmarkFixture(_ name: String) async throws -> String {
        guard UIApplication.shared.applicationState == .active else { throw PikoError.notForeground }
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".wav"),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let selection = UserDefaults.standard.string(forKey: "PikoBenchmarkEngine") else {
            throw PikoError.audioUnavailable
        }
        var folder = documents.appendingPathComponent("Benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let adapter = try Self.makeBenchmarkTranscriber(selection)
        let result = try await SpeechFixtureBenchmark.run(
            transcriber: adapter, fixture: folder.appendingPathComponent(name),
            locale: Locale(identifier: "en-IN"))
        let outputName = String(name.dropLast(4)) + "." + selection + ".json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: folder.appendingPathComponent(outputName), options: .atomic)
        return outputName
    }

    private struct FixtureManifest: Decodable {
        let locale: String
        let files: [String]
    }

    func runBenchmarkManifest(_ name: String) async throws -> String {
        guard UIApplication.shared.applicationState == .active else { throw PikoError.notForeground }
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".json"),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let selection = UserDefaults.standard.string(forKey: "PikoBenchmarkEngine") else {
            throw PikoError.audioUnavailable
        }
        var folder = documents.appendingPathComponent("Benchmarks", isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
        guard !manifest.files.isEmpty, Set(manifest.files).count == manifest.files.count else {
            throw PikoError.audioUnavailable
        }
        let adapter = try Self.makeBenchmarkTranscriber(selection)
        let outputName = String(name.dropLast(5)) + "." + selection + ".results.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var reports: [SpeechFixtureReport] = []
        for (index, file) in manifest.files.enumerated() {
            try Task.checkCancellation()
            guard file == URL(fileURLWithPath: file).lastPathComponent, file.hasSuffix(".wav") else {
                throw PikoError.audioUnavailable
            }
            reports.append(try await SpeechFixtureBenchmark.run(
                transcriber: adapter, fixture: folder.appendingPathComponent(file),
                locale: Locale(identifier: manifest.locale), sessionEpoch: index + 1))
            try encoder.encode(reports).write(to: folder.appendingPathComponent(outputName), options: .atomic)
            FileHandle.standardOutput.write(Data(
                "PIKO_FIXTURE_PROGRESS: \(index + 1)/\(manifest.files.count)\n".utf8))
        }
        return outputName
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
            store.clear(id: request.id)
            if let onTalkRequested {
                await onTalkRequested()
            } else {
                await showLiveActivity()
                try await captureCoordinator.startCapture()
            }
        } catch is CancellationError {
            store.clear(id: request.id)
        } catch {
            store.clear(id: request.id)
            let message = PikoError.userMessage(for: error)
            lastCaptureLaunchError = message
            onCaptureLaunchError?(message)
        }
    }
}
