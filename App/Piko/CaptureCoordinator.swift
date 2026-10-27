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
    private let transcriber: any AudioTranscriber
    private let brain: any Brain
    private let memory: any Memory

    private var transcriptionTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?
    private var sessionEpoch = 0
    private var isEndingSession = false
    private var isStartingCapture = false
    #if DEBUG
    private var benchmarkFixture: URL?
    private var fixtureFeedTask: Task<Void, any Error>?
    private var microphoneDiscardTask: Task<Void, Never>?

    public func setBenchmarkFixture(_ fixture: URL) throws {
        guard transcriptionTask == nil, !isTidying else { throw PikoError.sessionInterrupted }
        let file = try AVAudioFile(forReading: fixture)
        guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw PikoError.audioUnavailable }
        benchmarkFixture = fixture
    }
    #endif
    public private(set) var isTidying = false

    /// Presentation callback around finalization and optional cleanup.
    /// SessionCoordinator remains the owner of phase transitions.
    public var onTidyingChange: (@MainActor (Bool) -> Void)?
    public var onFailure: (@MainActor (PikoError) -> Void)?
    /// A capture ended with no words, so there is nothing to file or type.
    public var onNothingHeard: (@MainActor () -> Void)?
    public var onCleanupBypassed: (@MainActor (String) -> Void)?

    public init(session: SessionCoordinator,
                channel: any SessionChannel,
                transcriber: any AudioTranscriber,
                brain: any Brain,
                memory: any Memory) {
        self.session = session
        self.channel = channel
        self.transcriber = transcriber
        self.brain = brain
        self.memory = memory
        phaseTask = Task { [weak self, session] in
            for await phase in session.phase {
                guard let self, !Task.isCancelled else { return }
                if phase == .idle, !self.isEndingSession,
                   self.transcriptionTask != nil || self.isTidying {
                    await self.cancelCapture()
                }
            }
        }
    }

    deinit {
        phaseTask?.cancel()
        transcriptionTask?.cancel()
        #if DEBUG
        fixtureFeedTask?.cancel()
        microphoneDiscardTask?.cancel()
        #endif
    }

    #if targetEnvironment(simulator)
    static let simulatorDemoTranscript =
        "um so like can you send me the deck when you get a chance"
    #endif

    /// Start capture: begin audio recording and transcription pipeline.
    /// Keyboard captures type into another app's field; only in-app and shortcut captures are
    /// filed by the assistant.
    public private(set) var lastCaptureFromKeyboard = false

    public func startCapture(fromKeyboard: Bool = false) async throws {
        guard !isTidying, !isStartingCapture else { return }
        lastCaptureFromKeyboard = fromKeyboard
        isStartingCapture = true
        defer { isStartingCapture = false }
        if transcriptionTask != nil {
            // An interruption can disarm SessionCoordinator without flowing through
            // stopCapture(). Once re-armed, discard that obsolete recognition task.
            guard session.currentPhase == .armed else { return }
            transcriptionTask?.cancel()
            transcriptionTask = nil
        }
        sessionEpoch = max(sessionEpoch, channel.readDraft()?.sessionEpoch ?? 0) + 1
        let epoch = sessionEpoch
        try await session.startCapture()
        guard epoch == sessionEpoch, session.currentPhase == .capturing else { return }
        let buffers = session.buffers
        transcriptionTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.sessionEpoch == epoch else { return }
            let input: AsyncStream<AVAudioPCMBuffer>
            #if DEBUG
            var replayOutput: AsyncStream<AVAudioPCMBuffer>.Continuation?
            var replayTask: Task<Void, any Error>?
            if self.benchmarkFixture != nil {
                let pair = AsyncStream<AVAudioPCMBuffer>.makeStream()
                input = pair.stream
                replayOutput = pair.continuation
                self.microphoneDiscardTask = Task {
                    for await _ in buffers {
                        if Task.isCancelled { return }
                    }
                }
            } else {
                input = buffers
            }
            #else
            input = buffers
            #endif
            await self.transcriber.configure(buffers: input, sessionEpoch: epoch)
            guard !Task.isCancelled, self.sessionEpoch == epoch else {
                await self.transcriber.cancel(sessionEpoch: epoch)
                return
            }
            #if DEBUG
            if let fixture = self.benchmarkFixture, let replayOutput {
                if self.isTidying {
                    replayOutput.finish()
                } else {
                    let started = ContinuousClock.now
                    FileHandle.standardOutput.write(Data(
                        "PIKO_FIXTURE_FEED_STARTED: epoch=\(epoch) uptime=\(ProcessInfo.processInfo.systemUptime)\n".utf8))
                    replayTask = SpeechFixtureBenchmark.feed(fixture: fixture, to: replayOutput, started: started)
                    self.fixtureFeedTask = replayTask
                }
            }
            #endif
            #if targetEnvironment(simulator)
            if let mock = self.transcriber as? MockTranscriber {
                await mock.setDefaultScript(.progressive(Self.simulatorDemoTranscript,
                                                         sessionEpoch: epoch))
            }
            #endif
            guard !Task.isCancelled, self.sessionEpoch == epoch else { return }
            for await draft in self.transcriber.hypotheses() {
                guard !Task.isCancelled, self.sessionEpoch == epoch else { return }
                self.channel.writeDraft(draft)
            }
            #if DEBUG
            if let replayTask {
                do { try await replayTask.value }
                catch is CancellationError {
                    guard self.isTidying || self.sessionEpoch != epoch || Task.isCancelled else {
                        self.report(.sessionInterrupted)
                        await self.cancelCapture()
                        return
                    }
                } catch {
                    guard self.sessionEpoch == epoch else { return }
                    self.report(.audioUnavailable)
                    await self.cancelCapture()
                    return
                }
            }
            #endif
            guard !Task.isCancelled, self.sessionEpoch == epoch, !self.isTidying,
                  let failure = await self.transcriber.recognitionFailure() else { return }
            guard self.sessionEpoch == epoch, !Task.isCancelled else { return }
            self.report(failure)
            await self.cancelCapture()
        }
    }

    /// Stop capture: finalize transcription and write result.
    public func stopCapture(endSession: Bool = false) async {
        guard transcriptionTask != nil, !isTidying else { return }
        let epoch = sessionEpoch
        isTidying = true
        isEndingSession = endSession
        #if DEBUG
        fixtureFeedTask?.cancel()
        microphoneDiscardTask?.cancel()
        #endif
        onTidyingChange?(true)
        await session.stopCapture()
        if endSession { await session.disarm() }
        let task = transcriptionTask
        await task?.value
        guard epoch == sessionEpoch else { return }
        transcriptionTask = nil
        defer {
            if epoch == sessionEpoch {
                isTidying = false
                isEndingSession = false
                onTidyingChange?(false)
            }
        }
        let failure = await transcriber.recognitionFailure()
        guard epoch == sessionEpoch else { return }
        if let failure {
            report(failure)
            await session.disarm()
            return
        }

        let finalText = await transcriber.finish()
        guard epoch == sessionEpoch else { return }
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await session.finishTidying()
            onNothingHeard?()
            return
        }
        let profile = channel.readState()?.profile ?? .message
        let route = await brain.route(finalText)
        guard epoch == sessionEpoch else { return }

        let clock = ContinuousClock()
        let start = clock.now
        let shipped: String
        do {
            shipped = try await brain.rewrite(finalText, profile: profile, lexicon: [], examples: [])
        } catch {
            guard epoch == sessionEpoch else { return }
            shipped = finalText
            let message = (error as? PikoError)?.userMessage
                ?? "Tidying was unavailable, so Piko kept your original transcript."
            print("CaptureCoordinator: cleanup bypassed (\(type(of: error)))")
            onCleanupBypassed?(message)
        }
        let elapsed = clock.now - start
        let brainMS = Int(elapsed.components.seconds * 1000
                          + elapsed.components.attoseconds / 1_000_000_000_000_000)

        guard epoch == sessionEpoch else { return }
        let result = CaptureResult(
            raw: finalText,
            shipped: shipped,
            route: route,
            profile: profile,
            timings: .init(brainMS: brainMS)
        )
        await memory.record(result)
        guard epoch == sessionEpoch else { return }
        channel.writeResult(result)
        await session.finishTidying()
    }

    private func cancelCapture() async {
        let cancelledEpoch = sessionEpoch
        sessionEpoch += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTidying = false
        isEndingSession = false
        onTidyingChange?(false)
        #if DEBUG
        fixtureFeedTask?.cancel()
        fixtureFeedTask = nil
        microphoneDiscardTask?.cancel()
        microphoneDiscardTask = nil
        #endif
        await session.disarm()
        await transcriber.cancel(sessionEpoch: cancelledEpoch)
    }

    private func report(_ error: PikoError) {
        print("CaptureCoordinator: \(error.userMessage)")
        onFailure?(error)
    }

    /// Respond to keyboard signals
    public func handleSignal(_ signal: Signal) async {
        switch signal {
        case .captureStart:
            do {
                try await startCapture(fromKeyboard: true)
            } catch {
                report((error as? PikoError) ?? .audioUnavailable)
            }
        case .captureStop:
            await stopCapture()
        case .stopRequested:
            // transcriptionTask is this type's own synchronous liveness flag — unlike
            // channel.readState().phase (heartbeat-refreshed, up to 2s stale), it can never
            // miss a capture that started moments ago and silently leak the task.
            if transcriptionTask != nil {
                await stopCapture(endSession: true)
            }
            await session.disarm()
        default:
            break
        }
    }
}
#endif
