import AVFAudio
import Combine
import Foundation
import PikoKit

/// Consumes measurements from the existing engine tap, never opens another microphone.
/// Only RMS runs on the render thread; smoothing, publication and IPC run on the main actor.
@MainActor
public final class AudioLevelMonitor: ObservableObject {
    @Published public private(set) var level: Double = 0

    public struct Reading: Sendable {
        let rms: Double
        let time: TimeInterval
        let capturedAt: Date
    }

    private let channel: (any AudioLevelChannel)?
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<Reading>.Continuation?
    private var envelope = AudioLevelEnvelope()
    private var previousTime: TimeInterval?
    private var lastPublication: TimeInterval?

    public init(channel: (any AudioLevelChannel)? = nil) {
        self.channel = channel
    }

    /// Called alongside capture startup. The bounded mailbox drops obsolete measurements.
    @discardableResult
    public func start() -> AsyncStream<Reading>.Continuation {
        stop()
        let (stream, continuation) = AsyncStream<Reading>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        task = Task { [weak self] in
            for await reading in stream {
                guard !Task.isCancelled, let self else { return }
                self.consume(reading)
            }
        }
        return continuation
    }

    public func stop() {
        continuation?.finish()
        continuation = nil
        task?.cancel()
        task = nil
        envelope = AudioLevelEnvelope()
        previousTime = nil
        lastPublication = nil
        level = 0
        channel?.writeAudioLevel(AudioLevel())
    }

    private func consume(_ reading: Reading) {
        let elapsed = previousTime.map { reading.time - $0 } ?? (1.0 / 50)
        previousTime = reading.time
        let smoothed = envelope.process(rms: reading.rms, elapsed: elapsed)
        // At most 20 small IPC writes per second, independent of the audio sample rate.
        guard lastPublication.map({ reading.time - $0 >= 0.05 }) ?? true else { return }
        lastPublication = reading.time
        level = smoothed
        channel?.writeAudioLevel(AudioLevel(level: smoothed, capturedAt: reading.capturedAt))
    }

    /// Read all channels by power, so stereo phase cancellation cannot hide speech.
    /// Respect frameLength and stride for both planar and interleaved Float32 PCM.
    nonisolated public static func measure(_ buffer: AVAudioPCMBuffer) -> Reading {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var power = 0.0
        if frames > 0, channels > 0, let data = buffer.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    let sample = Double(data[channel][frame * buffer.stride])
                    if sample.isFinite { power += sample * sample }
                }
            }
            power /= Double(frames * channels)
        }
        return Reading(rms: sqrt(power), time: ProcessInfo.processInfo.systemUptime, capturedAt: .now)
    }
}

/// Time-based attack/release stays consistent across buffer sizes and sample rates.
struct AudioLevelEnvelope {
    private(set) var level = 0.0
    private var gateOpen = false

    mutating func process(rms: Double, elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return level }
        let db = 20 * log10(max(rms.isFinite ? rms : 0, 0.000_001))
        // Hysteresis prevents chatter near the noise floor. Tune on real microphones.
        gateOpen = db > (gateOpen ? -52 : -48)
        let target = gateOpen ? min(max((db + 52) / 40, 0), 1) : 0
        let timeConstant = target > level ? 0.045 : 0.24
        level += (target - level) * (1 - exp(-min(elapsed, 1) / timeConstant))
        if level < 0.0001 { level = 0 }
        return level
    }
}
