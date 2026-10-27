#if os(iOS) && DEBUG
import AVFAudio
import Foundation
import Testing
@testable import PikoTranscribe

@Suite struct SpeechFixtureBenchmarkTests {
    @Test func replayReportsItsSourceAndNeverClaimsDeviceAcceptance() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record("Could not remove generated fixture: \(error)") }
        }
        try createSilence(at: url)
        let mock = MockTranscriber()
        await mock.setScript(.init(drafts: [
            .init(sessionEpoch: 1, sequence: 1, text: "Fixture result.", stablePrefix: 15),
        ], delayBetween: .milliseconds(10)))
        let report = try await SpeechFixtureBenchmark.run(
            transcriber: mock, fixture: url, locale: Locale(identifier: "en-IN"))
        #expect(report.engine == "MockTranscriber")
        #expect(report.audioSHA256.count == 64)
        #expect(!report.osVersion.isEmpty)
        #expect(report.transcript == "Fixture result.")
        #expect(report.inputDurationMS == 100)
        #expect(report.firstHypothesisFromFileStartMS != nil)
        #expect(!report.microphoneOpened)
        #expect(!report.deviceAcceptanceVerified)
    }

    @Test func silentFixtureCanFinishWithoutInventingAnUtterance() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record("Could not remove generated fixture: \(error)") }
        }
        try createSilence(at: url)
        let report = try await SpeechFixtureBenchmark.run(
            transcriber: MockTranscriber(), fixture: url, locale: Locale(identifier: "en-IN"))
        #expect(report.transcript.isEmpty)
        #expect(report.firstHypothesisFromFileStartMS == nil)
        #expect(!report.deviceAcceptanceVerified)
    }

    private func createSilence(at url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 1600)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
#endif
