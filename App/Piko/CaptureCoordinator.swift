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

    private var transcriptionTask: Task<Void, Never>?
    private var sessionEpoch = 0

    public init(session: SessionCoordinator,
                channel: any SessionChannel,
                transcriber: any Transcriber) {
        self.session = session
        self.channel = channel
        self.transcriber = transcriber
    }

    /// Start capture: begin audio recording and transcription pipeline.
    public func startCapture() async throws {
        sessionEpoch += 1
        try await session.startCapture()

        // SpeechTranscriberEngine.configure(buffers:sessionEpoch:) is the real
        // 05-02 entrypoint (no AnalyzerInputConverter). MockTranscriber ignores
        // PCM and plays a script from hypotheses(), so configure is engine-only.
        if let engine = transcriber as? SpeechTranscriberEngine {
            await engine.configure(buffers: session.buffers, sessionEpoch: sessionEpoch)
        }

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            for await draft in self.transcriber.hypotheses() {
                self.channel.writeDraft(draft)
                self.channel.post(.draftUpdated)
            }
        }
    }

    /// Stop capture: finalize transcription and write result.
    public func stopCapture() async {
        await session.stopCapture()
        transcriptionTask?.cancel()
        transcriptionTask = nil

        let finalText = await transcriber.finish()

        let result = CaptureResult(
            raw: finalText,
            shipped: finalText,  // TODO(phase 6): Brain rewrites this
            route: .write
        )
        channel.writeResult(result)
        channel.post(.resultReady)
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
        default:
            break
        }
    }
}
#endif
