#if os(iOS)
import Speech
import AVFAudio
import OSLog
import PikoKit

extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

/// One-shot flag for `AVAudioConverter` input blocks (runs off actor isolation).
private final class ConverterOnce: @unchecked Sendable {
    var done = false
}

/// Sendable box for `SFSpeechAudioBufferRecognitionRequest`, whose append/endAudio are
/// safe to call from arbitrary queues but whose type predates Sendable annotations.
private final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
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
    /// Every refusal below is a silent stream-finish by contract, so each gate logs
    /// where recognition stopped — otherwise a dead microphone path is undebuggable.
    private static let log = Logger(subsystem: "dev.piko", category: "transcribe")
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
            Self.log.fault("recognition refused: no buffers configured")
            continuation.finish()
            return
        }

        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard status == .authorized else {
            Self.log.error("recognition refused: speech authorization \(status.rawValue, privacy: .public)")
            continuation.finish()
            return
        }

        // T-05-04: refuse to start when the recognizer or transcriber is unavailable.
        let transcriberAvailable = SpeechTranscriber.isAvailable
        let recognizerAvailable = SFSpeechRecognizer()?.isAvailable == true
        guard transcriberAvailable || recognizerAvailable else {
            Self.log.error("recognition refused: transcriberAvailable=\(transcriberAvailable, privacy: .public) recognizerAvailable=\(recognizerAvailable, privacy: .public)")
            continuation.finish()
            return
        }
        // Simulators ship no SpeechTranscriber dictation assets; the older Speech
        // recognizer sometimes works there. Keep recognition fully on-device either way —
        // a server fallback would break the nothing-leaves-the-device contract.
        if !transcriberAvailable {
            await runOnDeviceFallbackRecognition(continuation: continuation, buffers: buffers)
            return
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            Self.log.error("recognition refused: no supported locale for \(Locale.current.identifier, privacy: .public)")
            continuation.finish()
            return
        }
        Self.log.info("recognition starting: locale=\(locale.identifier(.bcp47), privacy: .public)")

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Self.log.info("asset install required; downloading")
                try await request.downloadAndInstall()
                Self.log.info("asset install finished")
            }
        } catch {
            Self.log.error("asset install failed: \(error, privacy: .public)")
            continuation.finish()
            return
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        do {
            try await analyzer.prepareToAnalyze(in: audioFormat)
        } catch {
            Self.log.error("prepareToAnalyze failed: \(error, privacy: .public)")
            continuation.finish()
            return
        }
        Self.log.info("analyzer prepared: \(self.describe(audioFormat), privacy: .public)")

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        final class FedCount: @unchecked Sendable { var value = 0 }
        let fed = FedCount()
        let feedTask = Task {
            for await buffer in buffers {
                fed.value += 1
                let toYield: AVAudioPCMBuffer
                if let audioFormat, let converted = Self.convert(buffer, to: audioFormat) {
                    toYield = converted
                } else {
                    toYield = buffer
                }
                inputBuilder.yield(AnalyzerInput(buffer: toYield))
            }
            Self.log.info("buffer stream ended after \(fed.value, privacy: .public) buffers")
            inputBuilder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        let analyzeTask = Task {
            do {
                try await analyzer.start(inputSequence: inputSequence)
                Self.log.info("analyzer started")
            } catch {
                Self.log.error("analyzer.start failed: \(error, privacy: .public)")
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
                if sequence == 1 {
                    Self.log.info("first recognition result received")
                }
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
            Self.log.error("results sequence failed: \(error, privacy: .public)")
        }

        feedTask.cancel()
        analyzeTask.cancel()
        _ = await feedTask.result
        _ = await analyzeTask.result
        continuation.finish()
    }

    private func describe(_ format: AVAudioFormat?) -> String {
        guard let format else { return "nil" }
        return "\(format.sampleRate)Hz x\(format.channelCount)"
    }

    public func finish() async -> String { accumulatedText }

    /// `SFSpeechRecognizer` with on-device recognition required. The Simulator-only
    /// lifeline when `SpeechTranscriber` assets are missing; never a server path.
    private func runOnDeviceFallbackRecognition(
        continuation: AsyncStream<CaptureDraft>.Continuation,
        buffers: AsyncStream<AVAudioPCMBuffer>
    ) async {
        Self.log.info("falling back to SFSpeechRecognizer (on-device required)")
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            Self.log.error("fallback refused: no recognizer for \(Locale.current.identifier, privacy: .public)")
            continuation.finish()
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            Self.log.error("fallback refused: on-device recognition unsupported here")
            continuation.finish()
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true

        // The request type predates Sendable; its append(_:)/endAudio() are documented
        // as safe to call from any queue, which is exactly what audio callbacks do.
        let boxedRequest = RequestBox(request)
        let feedTask = Task {
            for await buffer in buffers {
                boxedRequest.request.append(buffer)
            }
            boxedRequest.request.endAudio()
            Self.log.info("fallback buffer stream ended")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let finished = ConverterOnce()
            recognizer.recognitionTask(with: request) { [weak self] result, error in
                // Unpack the non-Sendable result here; only Sendable values cross
                // into the actor.
                let failure = error.map { "\($0)" }
                if let failure {
                    Self.log.error("fallback recognition failed: \(failure, privacy: .public)")
                }
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                if let text, !text.isEmpty {
                    Task { await self?.applyFallbackText(text, isFinal: isFinal, continuation: continuation) }
                }
                if (failure != nil || isFinal), !finished.done {
                    finished.done = true
                    cont.resume()
                }
            }
        }

        feedTask.cancel()
        continuation.finish()
    }

    private func applyFallbackText(
        _ text: String,
        isFinal: Bool,
        continuation: AsyncStream<CaptureDraft>.Continuation
    ) {
        accumulatedText = text
        sequence += 1
        if sequence == 1 {
            Self.log.info("first fallback recognition result received")
        }
        continuation.yield(CaptureDraft(
            sessionEpoch: sessionEpoch,
            sequence: sequence,
            text: text,
            stablePrefix: isFinal ? text.count : accumulatedText.count,
            startedAt: startedAt ?? .now
        ))
    }

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

