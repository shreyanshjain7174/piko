#if os(iOS)
import Foundation
import Testing
@testable import PikoTranscribe

@Suite struct WhisperVoiceGateTests {
    @Test func digitalSilenceDoesNotReachTheDecoder() {
        #expect(!WhisperTranscriberEngine.hasVoice(in: []))
        #expect(!WhisperTranscriberEngine.hasVoice(in: [Float](repeating: 0, count: 32_000)))
    }

    @Test func audibleInputIsNotDiscarded() {
        let samples: [Float] = (0..<16_000).map {
            Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.2)
        }
        #expect(WhisperTranscriberEngine.hasVoice(in: samples))
    }
}
#endif
