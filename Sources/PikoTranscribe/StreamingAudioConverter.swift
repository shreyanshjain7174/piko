import AVFAudio

/// Resamples a continuous microphone stream for the speech analyzer.
/// One converter is reused for the whole capture, matching Apple's SpeechAnalyzer sample:
/// a fresh converter per buffer resets resampler state and drops frames at every buffer edge.
final class StreamingAudioConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(outFrames, 1)) else { return nil }
        var error: NSError?
        var offered = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            defer { offered = true }
            outStatus.pointee = offered ? .noDataNow : .haveData
            return offered ? nil : buffer
        }
        guard status != .error else { return nil }
        return out
    }
}
