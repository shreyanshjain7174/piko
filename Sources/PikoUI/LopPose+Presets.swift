import Foundation

/// Deterministic held frames using the same angles, folds and squash as the fluid rig.
public extension LopPose {
    static let rest = LopPose(
        earLeft: -150, earRight: 150, foldLeft: 10, foldRight: -10,
        squashX: 1, squashY: 1, eyelid: 0, happyEyes: false, gaze: .zero, nose: 0)

    static let blink = changingRest { $0.eyelid = 1 }

    static let earTwitch = changingRest {
        $0.earLeft = -122
        $0.foldLeft = -24
    }

    static let glanceLeft = changingRest { $0.gaze = CGPoint(x: -2.6, y: 0) }
    static let glanceRight = changingRest { $0.gaze = CGPoint(x: 2.6, y: 0) }
    static let nose = changingRest { $0.nose = -1.2 }

    static let flop = changingRest {
        $0.earLeft = -125
        $0.earRight = 125
        $0.foldLeft = -18
        $0.foldRight = 18
        $0.squashX = 1.16
        $0.squashY = 0.8
        $0.eyelid = 0.55
    }

    /// Listening ears, from quiet (0) to fully raised (1), matching the physics targets.
    /// Out-of-range levels are clamped; NaN is treated as quiet.
    static func earsUp(level: Double) -> LopPose {
        let level = level.isNaN ? 0 : max(0, min(1, level))
        return changingRest {
            $0.earLeft = -(40 - 36 * level)
            $0.earRight = 40 - 36 * level
            $0.foldLeft = -(55 - 49 * level)
            $0.foldRight = 55 - 49 * level
        }
    }

    static let thump = changingRest {
        $0.earLeft = -118
        $0.earRight = 118
        $0.foldLeft = 18
        $0.foldRight = -18
        $0.squashX = 1.144
        $0.squashY = 0.82
    }

    static let tilt = changingRest {
        $0.earLeft = -138
        $0.earRight = 112
        $0.foldRight = 28
        $0.gaze = CGPoint(x: 1.4, y: -1)
    }

    static let swivelLeft = changingRest {
        $0.earLeft = -112
        $0.earRight = 165
        $0.gaze = CGPoint(x: -2.6, y: -0.5)
    }

    static let swivelRight = changingRest {
        $0.earLeft = -165
        $0.earRight = 112
        $0.gaze = CGPoint(x: 2.6, y: -0.5)
    }

    static let binky1: LopPose = {
        var pose = earsUp(level: 0.5)
        pose.squashX = 1.15
        pose.squashY = 0.82
        pose.happyEyes = true
        return pose
    }()

    static let binky2: LopPose = {
        var pose = earsUp(level: 1)
        pose.squashX = 0.86
        pose.squashY = 1.16
        pose.happyEyes = true
        return pose
    }()

    private static func changingRest(_ change: (inout LopPose) -> Void) -> LopPose {
        var pose = rest
        change(&pose)
        return pose
    }
}
