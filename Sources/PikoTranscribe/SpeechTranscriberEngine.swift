#if os(iOS)
import Speech
import AVFAudio
import PikoKit

extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

/// One-shot flag for `AVAudioConverter` input blocks (runs off actor isolation).
private final class ConverterOnce: @unchecked Sendable {
    var done = false
}

/// Apple's on-device speech stack behind the `Transcriber` protocol.
///
/// Uses iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`. The plan named
/// `AnalyzerInputConverter`; that type is not in the iOS 26.0 Speech
/// swiftinterface. Buffers are converted with `AVAudioConverter` and wrapped
/// as `AnalyzerInput` (the SDK type `SpeechAnalyzer.start` actually accepts).
///
/// `SpeechTranscriber.Result` objects are per-phrase and range-scoped. A
/// single dictation spans many phrases, so `CaptureDraft.text` is the running
/// accumulation of already-finalized phrases plus the current in-progress
/// phrase — never just the latest phrase alone.
public actor SpeechTranscriberEngine: Transcriber {
    private var lexicon: [String] = []
    private var sequence = 0
    private var sessionEpoch = 0
    private var startedAt: Date?
    private var buffers: AsyncStream<AVAudioPCMBuffer>?
    private var accumulatedText = ""

    public init() {}

    public func setLexicon(_ words: [String]) { lexicon = words }

    public func configure(buffers: AsyncStream<AVAudioPCMBuffer>, sessionEpoch: Int) {
        self.buffers = buffers
        self.sessionEpoch = sessionEpoch
        self.sequence = 0
        self.startedAt = .now
        self.accumulatedText = ""
    }

    nonisolated public func hypotheses() -> AsyncStream<CaptureDraft> {
        AsyncStream { continuation in
            Task { await self.runRecognition(continuation: continuation) }
        }
    }

    private func runRecognition(continuation: AsyncStream<CaptureDraft>.Continuation) async {
        guard let buffers else {
            continuation.finish()
            return
        }

        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard status == .authorized else {
            continuation.finish()
            return
        }

        // T-05-04: refuse to start when the recognizer or transcriber is unavailable.
        guard SpeechTranscriber.isAvailable,
              SFSpeechRecognizer()?.isAvailable == true else {
            continuation.finish()
            return
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            continuation.finish()
            return
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            continuation.finish()
            return
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        do {
            try await analyzer.prepareToAnalyze(in: audioFormat)
        } catch {
            continuation.finish()
            return
        }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let feedTask = Task {
            for await buffer in buffers {
                let toYield: AVAudioPCMBuffer
                if let audioFormat, let converted = Self.convert(buffer, to: audioFormat) {
                    toYield = converted
                } else {
                    toYield = buffer
                }
                inputBuilder.yield(AnalyzerInput(buffer: toYield))
            }
            inputBuilder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        let analyzeTask = Task {
            do {
                try await analyzer.start(inputSequence: inputSequence)
            } catch {
                // Sequence finished or cancelled; results stream will terminate.
            }
        }

        do {
            for try await result in transcriber.results {
                let phraseText = String(result.text.characters)
                let isFinal = result.isFinal

                let fullText = accumulatedText.isEmpty ? phraseText : accumulatedText + " " + phraseText

                let stablePrefix: Int
                if isFinal {
                    accumulatedText = fullText
                    stablePrefix = fullText.count
                } else if phraseText.hasSuffix(".") || phraseText.hasSuffix("?") || phraseText.hasSuffix("!") {
                    stablePrefix = fullText.count
                } else {
                    // Only prior finalized phrases are stable; the current phrase is volatile.
                    stablePrefix = accumulatedText.count
                }

                sequence += 1
                let draft = CaptureDraft(
                    sessionEpoch: sessionEpoch,
                    sequence: sequence,
                    text: fullText,
                    stablePrefix: stablePrefix,
                    startedAt: startedAt ?? .now
                )
                continuation.yield(draft)
            }
        } catch {
            // Results sequence failed; still finish the stream.
        }

        feedTask.cancel()
        analyzeTask.cancel()
        _ = await feedTask.result
        _ = await analyzeTask.result
        continuation.finish()
    }

    public func finish() async -> String { accumulatedText }

    /// Convert a PCM buffer into the analyzer's preferred format.
    /// Identity when rates, channels, and common format already match.
    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == format.sampleRate,
           buffer.format.channelCount == format.channelCount,
           buffer.format.commonFormat == format.commonFormat {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(outFrames, 1)) else {
            return nil
        }
        var error: NSError?
        let consumed = ConverterOnce()
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.done = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return nil }
        return out
    }
}
#endif

