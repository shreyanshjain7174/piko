#if os(iOS)
import AVFAudio
import Foundation

/// The render thread drops idle audio and forwards only an explicitly opened capture.
final class AudioBufferRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var levels: AsyncStream<AudioLevelMonitor.Reading>.Continuation?

    nonisolated func makeTap() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in receive(buffer) }
    }

    func begin(
        buffers: AsyncStream<AVAudioPCMBuffer>.Continuation,
        levels: AsyncStream<AudioLevelMonitor.Reading>.Continuation
    ) {
        lock.lock()
        self.buffers = buffers
        self.levels = levels
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let previous = buffers
        buffers = nil
        levels = nil
        lock.unlock()
        previous?.finish()
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let output = buffers
        let levelOutput = levels
        lock.unlock()
        guard let output else { return }
        output.yield(buffer)
        levelOutput?.yield(AudioLevelMonitor.measure(buffer))
    }
}
#endif
