#if os(iOS)
import Speech
import AVFAudio
import PikoKit

extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

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
public actor SpeechTranscriberEngine: AudioTranscriber {
    private var lexicon: [String] = []
    private var sequence = 0
    private var sessionEpoch = 0
    private var startedAt: Date?
    private var buffers: AsyncStream<AVAudioPCMBuffer>?
    private var transcript = SpeechTranscript()
    private var preparedLocale: Locale?
    private var analyzer: SpeechAnalyzer?
    private var failure: PikoError?
    private var generation = 0

    public init() {}

    public func setLexicon(_ words: [String]) { lexicon = words }

    public func prepare(locale: Locale, allowDownload: Bool) async throws {
        guard SpeechTranscriber.isAvailable,
              locale.language.languageCode?.identifier == "en",
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw PikoError.speechUnavailable(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard allowDownload else { throw PikoError.speechAssetsMissing }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw PikoError.speechAssetsMissing
        }
        preparedLocale = supported
    }

    public func configure(buffers: AsyncStream<AVAudioPCMBuffer>, sessionEpoch: Int) {
        guard sessionEpoch >= self.sessionEpoch else { return }
        generation += 1
        self.buffers = buffers
        self.sessionEpoch = sessionEpoch
        self.sequence = 0
        self.startedAt = .now
        self.transcript = SpeechTranscript()
        self.failure = nil
    }

    nonisolated public func hypotheses() -> AsyncStream<CaptureDraft> {
        AsyncStream { continuation in
            let task = Task { await self.runRecognition(continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runRecognition(continuation: AsyncStream<CaptureDraft>.Continuation) async {
        let current = generation
        guard let buffers, let locale = preparedLocale else {
            failure = .speechAssetsMissing
            continuation.finish()
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            if generation == current { failure = .speechAssetsMissing }
            continuation.finish()
            return
        }
        guard generation == current, !Task.isCancelled else {
            continuation.finish()
            return
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        do {
            try await analyzer.prepareToAnalyze(in: audioFormat)
            guard generation == current, !Task.isCancelled else {
                await analyzer.cancelAndFinishNow()
                continuation.finish()
                return
            }
            try await analyzer.start(inputSequence: Self.analyzerInput(buffers, format: audioFormat))
        } catch {
            if generation == current { failure = .transcriptionFailed }
            await analyzer.cancelAndFinishNow()
            continuation.finish()
            return
        }
        guard generation == current, !Task.isCancelled else {
            await analyzer.cancelAndFinishNow()
            continuation.finish()
            return
        }

        let finalizeTask = Task {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                if generation == current { failure = .transcriptionFailed }
                await analyzer.cancelAndFinishNow()
            }
        }

        do {
            for try await result in transcriber.results {
                let phraseText = String(result.text.characters)
                let isFinal = result.isFinal

                guard !Task.isCancelled, generation == current else { break }
                transcript.update(phraseText, at: result.range.start.seconds, isFinal: isFinal)

                sequence += 1
                let draft = CaptureDraft(
                    sessionEpoch: sessionEpoch,
                    sequence: sequence,
                    text: transcript.text,
                    stablePrefix: transcript.stablePrefix,
                    startedAt: startedAt ?? .now
                )
                continuation.yield(draft)
            }
        } catch {
            if generation == current { failure = .transcriptionFailed }
        }

        if Task.isCancelled || generation != current { await analyzer.cancelAndFinishNow() }
        await finalizeTask.value
        if generation == current {
            if !transcript.isFinal { failure = .transcriptionFailed }
            self.analyzer = nil
        }
        continuation.finish()
    }

    public func finish() async -> String { transcript.finalText }

    public func recognitionFailure() -> PikoError? { failure }

    public func cancel(sessionEpoch: Int) async {
        guard sessionEpoch == self.sessionEpoch else { return }
        generation += 1
        let active = analyzer
        analyzer = nil
        failure = .sessionInterrupted
        await active?.cancelAndFinishNow()
    }

    private static func analyzerInput(
        _ buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat?
    ) -> AsyncThrowingStream<AnalyzerInput, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let converter = StreamingAudioConverter()
                for await buffer in buffers {
                    guard !Task.isCancelled else { break }
                    if let format {
                        guard let converted = converter.convert(buffer, to: format) else {
                            continuation.finish(throwing: PikoError.audioUnavailable)
                            return
                        }
                        continuation.yield(AnalyzerInput(buffer: converted))
                    } else {
                        continuation.yield(AnalyzerInput(buffer: buffer))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
