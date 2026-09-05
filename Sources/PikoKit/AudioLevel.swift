import Foundation

/// A disposable visualization sample. Audio and transcripts never cross this channel.
public struct AudioLevel: Codable, Sendable, Equatable {
    public let level: Double
    public let capturedAt: Date

    public init(level: Double = 0, capturedAt: Date = .now) {
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.capturedAt = capturedAt
    }

    public func isFresh(at date: Date = .now) -> Bool {
        let age = date.timeIntervalSince(capturedAt)
        return age >= -0.1 && age < 0.5 && level.isFinite
    }
}

/// Optional capability, separate from durable session / transcription state.
public protocol AudioLevelChannel: Sendable {
    func readAudioLevel() -> AudioLevel?
    func writeAudioLevel(_ sample: AudioLevel)
}
