#if os(iOS)
import AVFAudio
import Testing
@testable import PikoAudio

@Suite struct AudioBufferRelayTests {
    @Test @MainActor func renderCallbackRunsAwayFromTheMainActor() async throws {
        let relay = AudioBufferRelay()
        let (stream, output) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let (_, levels) = AsyncStream<AudioLevelMonitor.Reading>.makeStream()
        relay.begin(buffers: output, levels: levels)
        let tap = relay.makeTap()
        try await Task.detached {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
            buffer.frameLength = 4
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 4)
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }.value
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.frameLength == 4)
        relay.finish()
    }

    @Test func idleAudioIsDiscardedAndStoppingFinishesOnlyCaptureStream() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 4)
        let relay = AudioBufferRelay()
        relay.receive(buffer)
        let (stream, output) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let (_, levels) = AsyncStream<AudioLevelMonitor.Reading>.makeStream()
        relay.begin(buffers: output, levels: levels)
        relay.receive(buffer)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.frameLength == 4)
        relay.finish()
        relay.receive(buffer)
        #expect(await iterator.next() == nil)
    }
}
#endif
