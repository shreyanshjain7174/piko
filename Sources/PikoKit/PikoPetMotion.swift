import Foundation

public enum PikoPetActivity: Sendable, Equatable {
    case idle, listening, thinking, speaking, happy
}

/// Renderer-independent, bounded values. Angles are radians; eye and mouth are 0...1.
public struct PikoPetPose: Sendable, Equatable {
    public let elevation: Double
    public let bodyScale: Double
    public let headTilt: Double
    public let yaw: Double
    public let pitch: Double
    public let leftEarAngle: Double
    public let rightEarAngle: Double
    public let eyeOpenness: Double
    public let mouthOpenness: Double
}

public enum PikoPetMotion {
    /// `elapsed` is time since activity changed; `patElapsed` is nil before a pat.
    /// Invalid levels/touch are neutral. Invalid or negative pat ages are ignored.
    public static func pose(
        activity: PikoPetActivity,
        loudness: Double,
        elapsed: Double,
        patElapsed: Double? = nil,
        touchX: Double = 0,
        touchY: Double = 0,
        reduceMotion: Bool = false
    ) -> PikoPetPose {
        let time = clamp(elapsed, to: 0...86_400)
        let phase = reduceMotion ? 0 : time
        let level = clamp(loudness, to: 0...1)
        let pat: Double
        if let age = patElapsed, age.isFinite, age >= 0, age < 1.4 {
            let remaining = 1 - age / 1.4
            pat = remaining * remaining * (3 - 2 * remaining)
        } else {
            pat = 0
        }
        let celebration: Double
        if activity == .happy, time < 1.6, !reduceMotion {
            celebration = pow(sin(.pi * time / 1.6), 2)
        } else {
            celebration = 0
        }
        let breathe = reduceMotion ? 0 : sin(phase * 1.6)
        let listening = activity == .listening ? level : 0
        let thinking = activity == .thinking
        let speaking = activity == .speaking
        let earSpread = activity == .listening ? 0.1 + (1 - level) * 0.12 : thinking ? 0.42 : 0.66
        let earFlutter = reduceMotion ? 0 : sin(phase * (speaking ? 3.2 : 1.7)) * (speaking ? 0.045 : 0.018)
        let blink = !reduceMotion && phase.truncatingRemainder(dividingBy: 5.8) > 5.65
        let eye = blink ? 0.15 : max(0.23, (thinking ? 0.75 : 1) - pat * 0.72 - celebration * 0.3)
        let mouth = speaking ? min(1, 0.14 + level * 0.55 + (reduceMotion ? 0 : pow(sin(phase * 5), 2) * 0.14)) : 0

        return PikoPetPose(
            elevation: breathe * 0.012 + celebration * 0.065 + (reduceMotion ? 0 : pat * 0.045),
            bodyScale: 1 + breathe * 0.006 + listening * 0.012,
            headTilt: (thinking ? 0.16 + (reduceMotion ? 0 : sin(phase * 1.1) * 0.015) : 0)
                - (reduceMotion ? 0 : pat * 0.12),
            yaw: clamp(touchX, to: -1...1) * 0.25,
            pitch: clamp(touchY, to: -1...1) * 0.12,
            leftEarAngle: earSpread + earFlutter + (reduceMotion ? 0 : pat * 0.18),
            rightEarAngle: -earSpread + earFlutter - (reduceMotion ? 0 : pat * 0.18),
            eyeOpenness: eye,
            mouthOpenness: mouth
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
    }
}
