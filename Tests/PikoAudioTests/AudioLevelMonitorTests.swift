import AVFAudio
import Foundation
import Testing
import PikoKit
@testable import PikoAudio

@Suite("Voice amplitude processing")
struct AudioLevelMonitorTests {
    @Test(arguments: [false, true])
    func rmsUsesPowerAcrossChannelsAndValidFrames(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 64
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<128 {
                data[channel][frame * buffer.stride] = frame < 64 ? (channel == 0 ? 0.25 : -0.25) : 1
            }
        }
        #expect(abs(AudioLevelMonitor.measure(buffer).rms - 0.25) < 0.000_001)
    }

    @Test func silenceAndInvalidSamplesAreSafe() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        #expect(AudioLevelMonitor.measure(buffer).rms == 0)
        buffer.frameLength = 4
        let data = try #require(buffer.floatChannelData)
        data[0][0] = .nan
        data[0][1] = .infinity
        data[0][2] = 0
        data[0][3] = 0
        #expect(AudioLevelMonitor.measure(buffer).rms == 0)
    }

    @Test func noiseGateAndHysteresis() {
        var envelope = AudioLevelEnvelope()
        for _ in 0..<100 {
            #expect(envelope.process(rms: pow(10, -50.0 / 20), elapsed: 0.02) == 0)
        }
        #expect(envelope.process(rms: pow(10, -46.0 / 20), elapsed: 0.1) > 0)
        // Once opened, the gate stays open through the narrow hysteresis band.
        for _ in 0..<30 { _ = envelope.process(rms: pow(10, -50.0 / 20), elapsed: 0.02) }
        #expect(envelope.level > 0.04)
        for _ in 0..<100 { _ = envelope.process(rms: pow(10, -55.0 / 20), elapsed: 0.02) }
        #expect(envelope.level == 0)
    }

    @Test func fastAttackGentleReleaseAndBoundedRapidChanges() {
        var envelope = AudioLevelEnvelope()
        let attack = envelope.process(rms: 1, elapsed: 0.045)
        #expect(attack > 0.6 && attack < 0.7)
        let released = envelope.process(rms: 0, elapsed: 0.045)
        #expect(released > attack * 0.8 && released < attack)
        for index in 0..<1000 {
            let value = envelope.process(rms: index.isMultiple(of: 2) ? 2 : 0, elapsed: 0.01)
            #expect(value.isFinite && (0...1).contains(value))
        }
        for _ in 0..<200 { _ = envelope.process(rms: .nan, elapsed: 0.02) }
        #expect(envelope.level == 0)
    }

    @Test func smoothingIsIndependentOfBufferCadence() {
        var small = AudioLevelEnvelope()
        var large = AudioLevelEnvelope()
        for _ in 0..<100 { _ = small.process(rms: 0.05, elapsed: 0.01) }
        for _ in 0..<20 { _ = large.process(rms: 0.05, elapsed: 0.05) }
        #expect(abs(small.level - large.level) < 0.000_001)
    }

    @MainActor @Test func stopRejectsQueuedReadingsAndRestartResetsEnvelope() async throws {
        let monitor = AudioLevelMonitor()
        let first = monitor.start()
        first.yield(.init(rms: 1, time: 10, capturedAt: .now))
        let deadline = ContinuousClock.now + .seconds(1)
        while monitor.level == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(monitor.level > 0)
        monitor.stop()
        #expect(monitor.level == 0)
        first.yield(.init(rms: 1, time: 11, capturedAt: .now))
        let second = monitor.start()
        second.yield(.init(rms: 0, time: 12, capturedAt: .now))
        try await Task.sleep(for: .milliseconds(20))
        #expect(monitor.level == 0)
        monitor.stop()
    }
}
