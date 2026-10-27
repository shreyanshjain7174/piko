#if os(iOS) && DEBUG
import AVFAudio
import Foundation
import PikoKit
import CryptoKit
import UIKit

public struct SpeechFixtureReport: Encodable, Sendable {
    public let engine: String
    public let fixture: String
    public let platform: String
    public let locale: String
    public let audioSHA256: String
    public let osVersion: String
    public let transcript: String
    public let inputDurationMS: Int
    public let preparationMS: Int
    public let firstHypothesisFromFileStartMS: Int?
    public let finalizationMS: Int
    public let microphoneOpened = false
    public let deviceAcceptanceVerified = false

    enum CodingKeys: String, CodingKey {
        case engine, fixture, platform, locale, audioSHA256, osVersion, transcript, inputDurationMS, preparationMS
        case firstHypothesisFromFileStartMS, finalizationMS, microphoneOpened, deviceAcceptanceVerified
    }
}

public enum SpeechFixtureBenchmark {
    public static func feed(
        fixture: URL, to output: AsyncStream<AVAudioPCMBuffer>.Continuation,
        started: ContinuousClock.Instant
    ) -> Task<Void, any Error> {
        Task.detached {
            defer { output.finish() }
            let input = try AVAudioFile(forReading: fixture)
            guard input.processingFormat.sampleRate > 0, input.length > 0 else {
                throw PikoError.audioUnavailable
            }
            let clock = ContinuousClock()
            while input.framePosition < input.length {
                try Task.checkCancellation()
                let remaining = AVAudioFrameCount(min(1024, input.length - input.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: remaining) else {
                    throw PikoError.audioUnavailable
                }
                try input.read(into: buffer, frameCount: remaining)
                guard buffer.frameLength > 0 else { throw PikoError.audioUnavailable }
                let elapsed = Double(input.framePosition) / input.processingFormat.sampleRate
                try await clock.sleep(until: started.advanced(by: .seconds(elapsed)))
                output.yield(buffer)
            }
        }
    }

    public static func run(
        transcriber: any AudioTranscriber, fixture: URL, locale: Locale, sessionEpoch: Int = 1
    ) async throws -> SpeechFixtureReport {
        let file = try AVAudioFile(forReading: fixture)
        guard file.processingFormat.sampleRate > 0, file.length > 0 else {
            throw PikoError.audioUnavailable
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let audioSHA256 = try fixtureHash(fixture)
        let clock = ContinuousClock()
        let preparationStart = clock.now
        try await transcriber.prepare(locale: locale, allowDownload: false)
        let preparationMS = milliseconds(clock.now - preparationStart)
        let (stream, output) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        await transcriber.configure(buffers: stream, sessionEpoch: sessionEpoch)
        let started = clock.now
        let feed = Self.feed(fixture: fixture, to: output, started: started)
        return try await withTaskCancellationHandler {
            defer { feed.cancel(); output.finish() }
            var firstHypothesis: Int?
            for await draft in transcriber.hypotheses() {
                try Task.checkCancellation()
                if firstHypothesis == nil, !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    firstHypothesis = milliseconds(clock.now - started)
                }
            }
            try await feed.value
            if let error = await transcriber.recognitionFailure() { throw error }
            let finalText = await transcriber.finish()
            let total = milliseconds(clock.now - started)
            #if targetEnvironment(simulator)
            let platform = "simulator"
            #else
            let platform = "physical"
            #endif
            return SpeechFixtureReport(
                engine: String(describing: type(of: transcriber)), fixture: fixture.lastPathComponent,
                platform: platform, locale: locale.identifier, audioSHA256: audioSHA256,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString, transcript: finalText,
                inputDurationMS: Int(duration * 1000), preparationMS: preparationMS,
                firstHypothesisFromFileStartMS: firstHypothesis,
                finalizationMS: max(0, total - Int(duration * 1000))
            )
        } onCancel: {
            feed.cancel()
            output.finish()
            Task { await transcriber.cancel(sessionEpoch: sessionEpoch) }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func fixtureHash(_ fixture: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: fixture)
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        try file.close()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
