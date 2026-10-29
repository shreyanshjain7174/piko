import AVFAudio
import Testing
@testable import PikoTranscribe

@Suite struct StreamingAudioConverterTests {
    private static func sineChunks(rate: Double, frames: Int, chunk: Int) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        var chunks: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < frames {
            let count = min(chunk, frames - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                buffer.floatChannelData![0][index] = Float(sin(2 * .pi * 440 * Double(offset + index) / rate)) * 0.5
            }
            chunks.append(buffer)
            offset += count
        }
        return chunks
    }

    @Test func resamplingMicChunksKeepsEveryFrameAndContinuity() throws {
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let converter = StreamingAudioConverter()
        var samples: [Int16] = []
        for chunk in Self.sineChunks(rate: 48_000, frames: 48_000, chunk: 4_800) {
            let out = try #require(converter.convert(chunk, to: target))
            samples += UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength))
        }
        #expect(abs(samples.count - 16_000) <= 32)
        let maxStep = zip(samples, samples.dropFirst()).map { abs(Int($0) - Int($1)) }.max() ?? 0
        // A 440Hz sine at 16kHz and half scale changes by at most ~2830 per sample.
        #expect(maxStep < 4_000)
    }
}
