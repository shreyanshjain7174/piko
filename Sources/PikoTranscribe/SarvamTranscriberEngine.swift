#if os(iOS)
import Speech
import AVFAudio
import OSLog
import PikoKit

public actor SarvamTranscriberEngine: Transcriber {
    private static let log = Logger(subsystem: "dev.piko", category: "sarvam-transcribe")

    private let sarvamClient: SarvamAPIClient
    private let languageCode: String

    private var sequence = 0
    private var sessionEpoch = 0
    private var startedAt: Date?
    private var buffers: AsyncStream<AVAudioPCMBuffer>?
    private var accumulatedText = ""
    private var recordedAudioData = Data()
    private var recordingFormat: AVAudioFormat?

    public init(apiKey: String, languageCode: String = "unknown") {
        self.sarvamClient = SarvamAPIClient(apiKey: apiKey)
        self.languageCode = languageCode
    }

    public func setLexicon(_ words: [String]) {}

    public func configure(buffers: AsyncStream<AVAudioPCMBuffer>, sessionEpoch: Int) {
        self.buffers = buffers
        self.sessionEpoch = sessionEpoch
        self.sequence = 0
        self.startedAt = .now
        self.accumulatedText = ""
        self.recordedAudioData = Data()
        self.recordingFormat = nil
    }

    nonisolated public func hypotheses() -> AsyncStream<CaptureDraft> {
        AsyncStream { continuation in
            Task { await self.runHybridRecognition(continuation: continuation) }
        }
    }

    private func runHybridRecognition(continuation: AsyncStream<CaptureDraft>.Continuation) async {
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

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable else {
            Self.log.error("on-device recognizer unavailable, streaming partials disabled")
            await runRecordOnly(continuation: continuation, buffers: buffers)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true

        let feedTask = Task {
            for await buffer in buffers {
                request.append(buffer)
                await self.appendToRecording(buffer)
            }
            request.endAudio()
            Self.log.info("buffer stream ended")
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            final class FinishOnce: @unchecked Sendable { var done = false }
            let finished = FinishOnce()
            recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error {
                    Self.log.error("Apple STT partial error: \(error.localizedDescription, privacy: .public)")
                }
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                if let text, !text.isEmpty {
                    Task { await self?.emitPartial(text, isFinal: isFinal, continuation: continuation) }
                }
                if (error != nil || isFinal), !finished.done {
                    finished.done = true
                    cont.resume()
                }
            }
        }

        feedTask.cancel()
        continuation.finish()
    }

    private func runRecordOnly(
        continuation: AsyncStream<CaptureDraft>.Continuation,
        buffers: AsyncStream<AVAudioPCMBuffer>
    ) async {
        for await buffer in buffers {
            await appendToRecording(buffer)
        }
        continuation.finish()
    }

    private func appendToRecording(_ buffer: AVAudioPCMBuffer) {
        if recordingFormat == nil {
            recordingFormat = buffer.format
        }
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                var sample = channelData[channel][frame]
                let scaled = Int16(clamping: Int32(sample * 32767))
                withUnsafeBytes(of: scaled) { recordedAudioData.append(contentsOf: $0) }
            }
        }
    }

    private func emitPartial(_ text: String, isFinal: Bool, continuation: AsyncStream<CaptureDraft>.Continuation) {
        accumulatedText = text
        sequence += 1
        if sequence == 1 {
            Self.log.info("first Apple STT partial received")
        }
        continuation.yield(CaptureDraft(
            sessionEpoch: sessionEpoch,
            sequence: sequence,
            text: text,
            stablePrefix: isFinal ? text.count : 0,
            startedAt: startedAt ?? .now
        ))
    }

    public func finish() async -> String {
        guard !recordedAudioData.isEmpty else {
            Self.log.info("no audio data recorded, returning Apple STT result")
            return accumulatedText
        }

        let sampleRate = recordingFormat?.sampleRate ?? 16000
        let channelCount = recordingFormat?.channelCount ?? 1
        let wavData = Self.createWAV(
            from: recordedAudioData,
            sampleRate: Int(sampleRate),
            channels: Int(channelCount)
        )

        Self.log.info("sending \(wavData.count) bytes to Sarvam STT")
        let start = ContinuousClock.now
        do {
            let result = try await sarvamClient.transcribe(
                audioData: wavData,
                languageCode: languageCode,
                mode: "transcribe"
            )
            let elapsed = ContinuousClock.now - start
            let ms = Int(elapsed.components.seconds * 1000
                         + elapsed.components.attoseconds / 1_000_000_000_000_000)
            Self.log.info("Sarvam STT returned in \(ms)ms: lang=\(result.languageCode, privacy: .public) prob=\(result.languageProbability, privacy: .public)")

            let sarvamText = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sarvamText.isEmpty {
                accumulatedText = sarvamText
            }
        } catch {
            Self.log.error("Sarvam STT failed: \(error, privacy: .public) — falling back to Apple STT result")
        }

        return accumulatedText
    }

    private static func createWAV(from pcmData: Data, sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = pcmData.count
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        header.append(pcmData)
        return header
    }
}
#endif
