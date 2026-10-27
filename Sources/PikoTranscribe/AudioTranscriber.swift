#if os(iOS)
import AVFAudio
import Foundation
import PikoKit

public protocol AudioTranscriber: Transcriber {
    func prepare(locale: Locale, allowDownload: Bool) async throws
    func configure(buffers: AsyncStream<AVAudioPCMBuffer>, sessionEpoch: Int) async
    func cancel(sessionEpoch: Int) async
    func recognitionFailure() async -> PikoError?
}

extension MockTranscriber: AudioTranscriber {
    public func prepare(locale: Locale, allowDownload: Bool) {}
    public func configure(buffers: AsyncStream<AVAudioPCMBuffer>, sessionEpoch: Int) {
        resetCancellation(sessionEpoch: sessionEpoch)
    }
    public func recognitionFailure() -> PikoError? { nil }
}
#endif
