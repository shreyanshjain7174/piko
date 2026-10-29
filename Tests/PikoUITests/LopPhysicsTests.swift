import Testing
import Foundation
@testable import PikoUI

@Suite("Lop physics")
struct LopPhysicsTests {

    private func run(_ physics: inout LopPhysics, seconds: Double, _ inputs: LopInputs) -> LopPose {
        var pose = physics.step(dt: 0, inputs: inputs)
        var t = 0.0
        while t < seconds {
            pose = physics.step(dt: 1.0 / 60, inputs: inputs)
            t += 1.0 / 60
        }
        return pose
    }

    @Test("ears rest down and rise when listening")
    func earsRiseWhenListening() {
        var physics = LopPhysics(seed: 1)
        let idle = run(&physics, seconds: 2, LopInputs())
        #expect(abs(idle.earLeft) > 140)
        let loud = run(&physics, seconds: 2, LopInputs(listening: true, loudness: 0.7))
        #expect(abs(loud.earLeft) < 20)
    }

    @Test("louder speech stands the ears straighter")
    func loudnessStraightensEars() {
        var quiet = LopPhysics(seed: 2), loud = LopPhysics(seed: 2)
        let q = run(&quiet, seconds: 2, LopInputs(listening: true, loudness: 0.1))
        let l = run(&loud, seconds: 2, LopInputs(listening: true, loudness: 0.8))
        #expect(abs(l.earRight) < abs(q.earRight))
        #expect(abs(l.foldRight) < abs(q.foldRight))
    }

    @Test("ears overshoot their target before settling, so they read as having weight")
    func earsFollowThrough() {
        var physics = LopPhysics(seed: 3)
        _ = run(&physics, seconds: 1, LopInputs(listening: true, loudness: 0.5))
        var maxRight = -Double.infinity
        var t = 0.0
        while t < 1.5 {
            maxRight = max(maxRight, physics.step(dt: 1.0 / 60, inputs: LopInputs()).earRight)
            t += 1.0 / 60
        }
        #expect(maxRight > 150)
    }

    @Test("a sudden loud sound flattens the body: the thump")
    func startleSquashes() {
        var physics = LopPhysics(seed: 4)
        _ = run(&physics, seconds: 1, LopInputs(listening: true, loudness: 0.1))
        let hit = run(&physics, seconds: 0.12, LopInputs(listening: true, loudness: 0.95))
        #expect(hit.squashY < 0.95)
        #expect(abs(hit.earLeft) > 90)
    }

    @Test("a bang that ramps up over a few frames still thumps, the way a real level meter reports it")
    func rampedStartleSquashes() {
        var physics = LopPhysics(seed: 8)
        _ = run(&physics, seconds: 1, LopInputs(listening: true, loudness: 0.05))
        var lowest = 1.0
        for level in [0.2, 0.45, 0.7, 0.9, 1.0] {
            lowest = min(lowest, physics.step(dt: 1.0 / 60, inputs: LopInputs(listening: true, loudness: level)).squashY)
        }
        var t = 0.0
        while t < 0.2 {
            lowest = min(lowest, physics.step(dt: 1.0 / 60, inputs: LopInputs(listening: true, loudness: 1)).squashY)
            t += 1.0 / 60
        }
        #expect(lowest < 0.95)
    }

    @Test("getting louder slowly does not startle")
    func slowRiseDoesNotStartle() {
        var physics = LopPhysics(seed: 9)
        _ = run(&physics, seconds: 1, LopInputs(listening: true, loudness: 0.05))
        var lowest = 1.0
        var level = 0.05
        while level < 1 {
            level += 0.01
            lowest = min(lowest, physics.step(dt: 1.0 / 60, inputs: LopInputs(listening: true, loudness: level)).squashY)
        }
        #expect(lowest > 0.95)
    }

    @Test("patting closes the eyes happily and presses the ears back")
    func pattingMelts() {
        var physics = LopPhysics(seed: 5)
        let pose = run(&physics, seconds: 1, LopInputs(patting: true))
        #expect(pose.happyEyes)
        #expect(abs(pose.earLeft) < 130)
    }

    @Test("Lop blinks within a few seconds and the schedule is reproducible from the seed")
    func blinksDeterministically() {
        func firstBlink(seed: UInt64) -> Double? {
            var physics = LopPhysics(seed: seed)
            var t = 0.0
            while t < 8 {
                if physics.step(dt: 1.0 / 60, inputs: LopInputs()).eyelid > 0.5 { return t }
                t += 1.0 / 60
            }
            return nil
        }
        let a = firstBlink(seed: 9)
        #expect(a != nil)
        #expect(a == firstBlink(seed: 9))
    }

    @Test("ears never cross when they swing from pressed back to fully up")
    func earsNeverCross() {
        var physics = LopPhysics(seed: 7)
        _ = run(&physics, seconds: 1, LopInputs(patting: true))
        var t = 0.0
        while t < 2 {
            let pose = physics.step(dt: 1.0 / 60, inputs: LopInputs(listening: true, loudness: 1))
            #expect(pose.earLeft < 0 && pose.earRight > 0)
            t += 1.0 / 60
        }
    }

    @Test("a long frame gap, like returning from background, stays finite")
    func longGapIsStable() {
        var physics = LopPhysics(seed: 6)
        let pose = physics.step(dt: 30, inputs: LopInputs(listening: true, loudness: 1))
        #expect(pose.earLeft.isFinite && pose.squashY.isFinite)
    }
}
