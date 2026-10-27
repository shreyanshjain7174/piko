#if os(iOS)
import AVFAudio
import Foundation
import PikoKit
@preconcurrency import WhisperKit

/// Developer comparison adapter. Models and tokenizer must already be staged locally.
private actor WhisperDecoder {
    private var engine: WhisperKit?
    private var isDecoding = false

    func prepare(modelFolder: URL) async throws {
        guard engine == nil else { return }
        let tokenizerFolder = modelFolder.appendingPathComponent("Tokenizer")
        for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
                          "Tokenizer/tokenizer.json", "Tokenizer/tokenizer_config.json"] {
            guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent(component).path) else {
                throw PikoError.speechAssetsMissing
            }
        }
        _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
        engine = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path, tokenizerFolder: tokenizerFolder,
            verbose: false, prewarm: false, load: true, download: false
        ))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let engine else { throw PikoError.speechAssetsMissing }
        guard WhisperTranscriberEngine.hasVoice(in: samples) else { return "" }
        guard !isDecoding else { throw PikoError.sessionInterrupted }
        isDecoding = true
        defer { isDecoding = false }
        try Task.checkCancellation()
        #if DEBUG
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = samples.isEmpty ? 0 : sqrt(energy / Double(samples.count))
        FileHandle.standardOutput.write(Data(
            "PIKO_DECODER_INPUT: samples=\(samples.count) rms=\(rms)\n".utf8))
        #endif
        let options = DecodingOptions(
            language: "en", temperatureFallbackCount: 0,
            skipSpecialTokens: true, withoutTimestamps: true
        )
        let results = try await engine.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public actor WhisperTranscriberEngine: AudioTranscriber {
    private let modelFolder: URL
    // Decoding may block its executor; keep PCM ingestion on a separate actor.
    private let decoder = WhisperDecoder()
    private var isPrepared = false
    private var buffers: AsyncStream<AVAudioPCMBuffer>?
    private var samples: [Float] = []
    private var inputEnded = false
    private var generation = 0
    private var epoch = 0
    private var sequence = 0
    private var text = ""
    private var failure: PikoError?
    private var startedAt = Date.now

    public init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    nonisolated static func hasVoice(in samples: [Float]) -> Bool {
        EnergyVAD().voiceActivity(in: samples).contains(true)
    }

    public func prepare(locale: Locale, allowDownload: Bool) async throws {
        guard locale.language.languageCode?.identifier == "en" else {
            throw PikoError.speechUnavailable(locale.identifier)
        }
        guard !isPrepared else { return }
        try await decoder.prepare(modelFolder: modelFolder)
        isPrepared = true
    }

    public func setLexicon(_ words: [String]) {}

    public func configure(buffers: AsyncStream<AVAudioPCMBuffer>, sessionEpoch: Int) {
        guard sessionEpoch >= epoch else { return }
        generation += 1
        self.buffers = buffers
        epoch = sessionEpoch
        sequence = 0
        samples = []
        inputEnded = false
        text = ""
        failure = nil
        startedAt = .now
    }

    nonisolated public func hypotheses() -> AsyncStream<CaptureDraft> {
        AsyncStream { continuation in
            let task = Task { await self.recognize(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func recognize(_ continuation: AsyncStream<CaptureDraft>.Continuation) async {
        guard isPrepared, let buffers else {
            failure = .speechAssetsMissing
            continuation.finish()
            return
        }
        let current = generation
        let feed = Task {
            for await buffer in buffers {
                guard !Task.isCancelled, generation == current else { return }
                guard let converted = AudioProcessor.resampleAudio(
                    fromBuffer: buffer, toSampleRate: 16_000, channelCount: 1
                ) else {
                    failure = .audioUnavailable
                    inputEnded = true
                    return
                }
                samples.append(contentsOf: AudioProcessor.convertBufferToArray(buffer: converted))
            }
            if generation == current { inputEnded = true }
        }
        defer {
            feed.cancel()
            if generation == current { samples.removeAll() }
            continuation.finish()
        }
        var decodedSamples = 0
        do {
            while generation == current, failure == nil {
                try Task.checkCancellation()
                if inputEnded, samples.count == decodedSamples { break }
                guard samples.count >= decodedSamples + 4_000 || inputEnded else {
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                let snapshot = samples
                guard !snapshot.isEmpty else { break }
                let decoded = try await decoder.transcribe(snapshot)
                try Task.checkCancellation()
                guard generation == current else { return }
                decodedSamples = snapshot.count
                text = decoded
                sequence += 1
                let finalized = inputEnded && decodedSamples == samples.count
                continuation.yield(CaptureDraft(
                    sessionEpoch: epoch, sequence: sequence, text: text,
                    stablePrefix: finalized ? text.count : 0, startedAt: startedAt
                ))
            }
        } catch is CancellationError {
            if generation == current { failure = .sessionInterrupted }
        } catch {
            if generation == current { failure = .transcriptionFailed }
        }
    }

    public func finish() -> String { text }
    public func recognitionFailure() -> PikoError? { failure }
    public func cancel(sessionEpoch: Int) {
        guard sessionEpoch == epoch else { return }
        generation += 1
        samples.removeAll()
        text = ""
        failure = .sessionInterrupted
    }
}
#endif
