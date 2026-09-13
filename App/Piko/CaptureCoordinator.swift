import Foundation

/// Marker so the PikoCaptureCore SwiftPM target still has a source on macOS,
/// where `CaptureCoordinator` is compiled out (`SessionCoordinator` is iOS-only).
public enum PikoCaptureCoreMarker {}

#if os(iOS)
import PikoKit
import PikoBridge
import PikoAudio
import PikoTranscribe
import AVFAudio

/// Orchestrates capture: buffers → transcriber → drafts → channel.
/// Lives in the container app only; the keyboard is just a remote control.
@MainActor
public final class CaptureCoordinator {
    private let session: SessionCoordinator
    private let channel: any SessionChannel
    private let transcriber: any Transcriber
    private let brain: any Brain
    private let memory: any Memory

    private var transcriptionTask: Task<Void, Never>?
    private var sessionEpoch = 0
    public private(set) var isTidying = false

    /// Fires around the post-capture rewrite window: `true` when tidying starts,
    /// `false` once `resultReady` has posted. The only source of a `.tidying`
    /// transition anywhere in this codebase — `SessionPhase` itself never emits it.
    public var onTidyingChange: (@MainActor (Bool) -> Void)?

    public init(session: SessionCoordinator,
                channel: any SessionChannel,
                transcriber: any Transcriber,
                brain: any Brain,
                memory: any Memory) {
        self.session = session
        self.channel = channel
        self.transcriber = transcriber
        self.brain = brain
        self.memory = memory
    }

    #if targetEnvironment(simulator)
    static let simulatorDemoTranscript =
        "um so like can you send me the deck when you get a chance"
    #endif

    /// Start capture: begin audio recording and transcription pipeline.
    public func startCapture() async throws {
        guard !isTidying else { return }
        if transcriptionTask != nil {
            // An interruption can disarm SessionCoordinator without flowing through
            // stopCapture(). Once re-armed, discard that obsolete recognition task.
            guard session.currentPhase == .armed else { return }
            transcriptionTask?.cancel()
            transcriptionTask = nil
        }
        sessionEpoch += 1
        try await session.startCapture()

        // SpeechTranscriberEngine.configure(buffers:sessionEpoch:) is the real
        // 05-02 entrypoint (no AnalyzerInputConverter). MockTranscriber ignores
        // PCM and plays a script from hypotheses(), so configure is engine-only.
        if let engine = transcriber as? SpeechTranscriberEngine {
            await engine.configure(buffers: session.buffers, sessionEpoch: sessionEpoch)
        }

        #if targetEnvironment(simulator)
        if let mock = transcriber as? MockTranscriber {
            // Deliberately slow: keeps the Simulator's capturing state alive long enough
            // to observe the orb, the wave and the notch reacting to demo speech energy.
            await mock.setDefaultScript(MockTranscriber.Script(
                drafts: MockTranscriber.Script.progressive(
                    Self.simulatorDemoTranscript,
                    chunkSize: 3,
                    sessionEpoch: sessionEpoch
                ).drafts,
                delayBetween: .milliseconds(350)))
        }
        #endif

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            for await draft in self.transcriber.hypotheses() {
                self.channel.writeDraft(draft)
            }
        }
    }

    /// Stop capture: finalize transcription and write result.
    public func stopCapture() async {
        guard transcriptionTask != nil, !isTidying else { return }
        isTidying = true
        onTidyingChange?(true)
        await session.stopCapture()
        let task = transcriptionTask
        transcriptionTask = nil
        await task?.value

        let finalText = await transcriber.finish()
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await session.finishTidying()
            isTidying = false
            onTidyingChange?(false)
            return
        }
        let profile = channel.readState()?.profile ?? .message
        let route = await brain.route(finalText)

        let clock = ContinuousClock()
        let start = clock.now
        let shipped = (try? await brain.rewrite(finalText, profile: profile, lexicon: [], examples: [])) ?? finalText
        let elapsed = clock.now - start
        let brainMS = Int(elapsed.components.seconds * 1000
                          + elapsed.components.attoseconds / 1_000_000_000_000_000)

        let result = CaptureResult(
            raw: finalText,
            shipped: shipped,
            route: route,
            profile: profile,
            timings: .init(brainMS: brainMS)
        )
        await memory.record(result)
        channel.writeResult(result)
        await session.finishTidying()
        isTidying = false
        onTidyingChange?(false)
    }

    /// Respond to keyboard signals
    public func handleSignal(_ signal: Signal) async {
        switch signal {
        case .captureStart:
            do {
                try await startCapture()
            } catch {
                print("CaptureCoordinator: startCapture failed: \(error)")
            }
        case .captureStop:
            await stopCapture()
        case .stopRequested:
            // transcriptionTask is this type's own synchronous liveness flag — unlike
            // channel.readState().phase (heartbeat-refreshed, up to 2s stale), it can never
            // miss a capture that started moments ago and silently leak the task.
            if transcriptionTask != nil {
                await stopCapture()
            }
            await session.disarm()
        default:
            break
        }
    }
}
#endif
