import Foundation

/// What the world is doing to Lop this frame. Everything here comes from data Piko already has:
/// the mic level, the session phase, the user's finger. Nothing is measured just for the pet.
public struct LopInputs: Equatable, Sendable {
    /// Button held: ears go up and follow `loudness`.
    public var listening: Bool
    /// 0...1, the same normalised level the voice orb uses.
    public var loudness: Double
    /// A finger is stroking Lop.
    public var patting: Bool
    /// Where Lop should look, in its own 120-unit space. `nil` lets the eyes wander.
    public var lookAt: CGPoint?
    /// Slow-moving mood, stored on device by whoever owns the pet's memory.
    public var mood: LopMood

    public init(listening: Bool = false, loudness: Double = 0, patting: Bool = false,
                lookAt: CGPoint? = nil, mood: LopMood = .calm) {
        self.listening = listening
        self.loudness = loudness
        self.patting = patting
        self.lookAt = lookAt
        self.mood = mood
    }
}

public enum LopMood: String, CaseIterable, Sendable {
    case calm, happy, sleepy
}

/// One damped spring. Under-damped on purpose: the overshoot is the follow-through that makes an
/// ear look like it has weight.
struct Spring: Equatable, Sendable {
    var value: Double
    var velocity: Double = 0
    var stiffness: Double
    var damping: Double

    mutating func step(toward target: Double, dt: Double) {
        let force = stiffness * (target - value) - damping * velocity
        velocity += force * dt
        value += velocity * dt
    }
}

/// The drawable result of one simulation step. Angles are degrees in the same convention as the
/// sketch canvas: 0 is straight up, positive is clockwise, ears hang from the top of the head.
public struct LopPose: Equatable, Sendable {
    public var earLeft: Double
    public var earRight: Double
    public var foldLeft: Double
    public var foldRight: Double
    /// Body scale. `squashY` < 1 flattens, `squashX` widens to keep volume.
    public var squashX: Double
    public var squashY: Double
    /// 0 open, 1 shut.
    public var eyelid: Double
    /// Eyes are happy arcs instead of dots.
    public var happyEyes: Bool
    /// Pupil offset in units, clamped to the eye.
    public var gaze: CGPoint
    /// Vertical nose offset in units.
    public var nose: Double
}

/// Lop's body as a handful of springs and timers. Pure value type with an injected random source,
/// so tests can step it deterministically and the view can step it once per display frame.
public struct LopPhysics: Sendable {
    private var earL = Spring(value: -150, stiffness: 140, damping: 9)
    // The far ear is a touch softer, so the pair never moves in lockstep.
    private var earR = Spring(value: 150, stiffness: 118, damping: 8)
    private var foldL = Spring(value: 10, stiffness: 90, damping: 7)
    private var foldR = Spring(value: -10, stiffness: 80, damping: 6.5)
    private var squash = Spring(value: 1, stiffness: 260, damping: 14)
    private var gazeX = Spring(value: 0, stiffness: 60, damping: 11)
    private var gazeY = Spring(value: 0, stiffness: 60, damping: 11)

    private var time: Double = 0
    private var nextBlink: Double
    private var blinkStart: Double = -1
    private var nextGlance: Double
    private var glance = CGPoint.zero
    private var noseBurstEnd: Double = 0
    private var nextNoseBurst: Double
    private var lastLoudness: Double = 0
    private var startleEnd: Double = -1

    private var random: SplitMix

    public init(seed: UInt64 = 0x5EED) {
        random = SplitMix(seed: seed)
        nextBlink = 2
        nextGlance = 3
        nextNoseBurst = 1
    }

    /// Advances the simulation. Large gaps (app backgrounded) are split into small steps so the
    /// springs never explode.
    public mutating func step(dt rawDt: Double, inputs: LopInputs) -> LopPose {
        var remaining = min(rawDt, 0.5)
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 120)
            advance(dt: dt, inputs: inputs)
            remaining -= dt
        }
        return pose(inputs: inputs)
    }

    private mutating func advance(dt: Double, inputs: LopInputs) {
        time += dt

        // A sudden jump from quiet to loud is a startle: ears pinned back, a hard squash (the thump).
        if inputs.listening, inputs.loudness > 0.85, lastLoudness < 0.4 {
            startleEnd = time + 0.45
            squash.velocity -= 6
        }
        lastLoudness = inputs.loudness
        let startled = time < startleEnd

        let target = earTargets(inputs: inputs, startled: startled)
        earL.step(toward: target.left, dt: dt)
        earR.step(toward: target.right, dt: dt)
        foldL.step(toward: target.foldLeft, dt: dt)
        foldR.step(toward: target.foldRight, dt: dt)

        let breathRate = inputs.mood == .sleepy ? 0.22 : 0.32
        let breath = sin(time * 2 * .pi * breathRate) * 0.018
        let squashTarget = (inputs.patting ? 0.92 : startled ? 0.86 : 1) + breath
        squash.step(toward: squashTarget, dt: dt)

        if time >= nextBlink {
            blinkStart = time
            // Natural blinks bunch up: sometimes a double, mostly long gaps.
            nextBlink = time + (random.unit() < 0.2 ? 0.35 : 2.2 + random.unit() * 4)
        }
        if time >= nextGlance {
            glance = random.unit() < 0.4 ? .zero : CGPoint(x: random.unit() * 5 - 2.5, y: random.unit() * 2 - 1)
            nextGlance = time + 1.5 + random.unit() * 3
        }
        if time >= nextNoseBurst {
            noseBurstEnd = time + 0.6
            nextNoseBurst = time + 1.5 + random.unit() * 2.5
        }

        let look = inputs.lookAt.map { CGPoint(x: ($0.x - 60) / 12, y: ($0.y - 82) / 16) } ?? glance
        gazeX.step(toward: max(-2.6, min(2.6, look.x)), dt: dt)
        gazeY.step(toward: max(-1.4, min(1.4, look.y)), dt: dt)
    }

    private func earTargets(inputs: LopInputs, startled: Bool) -> (left: Double, right: Double, foldLeft: Double, foldRight: Double) {
        if startled || inputs.patting { return (-118, 118, 18, -18) }
        if inputs.listening {
            let level = max(0, min(1, inputs.loudness))
            let angle = 40 - 36 * level
            let fold = 55 - 49 * level
            return (-angle, angle, -fold, fold)
        }
        if inputs.mood == .sleepy { return (-128, 128, -18, 18) }
        return (-150, 150, 10, -10)
    }

    private func pose(inputs: LopInputs) -> LopPose {
        let blinkT = blinkStart < 0 ? 1 : (time - blinkStart) / 0.14
        let blink = blinkT < 1 ? sin(blinkT * .pi) : 0
        let lid = inputs.mood == .sleepy ? max(0.55, blink) : blink
        let noseOn = time < noseBurstEnd
        return LopPose(
            earLeft: earL.value, earRight: earR.value,
            foldLeft: foldL.value, foldRight: foldR.value,
            squashX: 1 + (1 - squash.value) * 0.8, squashY: squash.value,
            eyelid: lid,
            happyEyes: inputs.patting || inputs.mood == .happy,
            gaze: CGPoint(x: gazeX.value, y: gazeY.value),
            nose: noseOn ? sin(time * 2 * .pi * 9) * 0.6 : 0
        )
    }
}

/// Tiny deterministic PRNG so a seeded Lop always blinks on the same schedule in tests.
struct SplitMix: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
