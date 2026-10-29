import Testing
import PikoKit

struct PikoPetMotionTests {
    private let activities: [PikoPetActivity] = [.idle, .listening, .thinking, .speaking, .happy]

    @Test func loudnessIsClampedAndNonfiniteSamplesAreSilent() {
        for activity in activities {
            let silent = PikoPetMotion.pose(activity: activity, loudness: 0, elapsed: 0.4)
            for value in [Double.nan, .infinity, -.infinity, -1] {
                #expect(PikoPetMotion.pose(activity: activity, loudness: value, elapsed: 0.4) == silent)
            }
            #expect(PikoPetMotion.pose(activity: activity, loudness: 100, elapsed: 0.4)
                == PikoPetMotion.pose(activity: activity, loudness: 1, elapsed: 0.4))
        }
    }

    @Test func everyActivityHasFiniteBoundedPosesEvenForHostileInputs() {
        let times: [Double] = [.nan, .infinity, -.infinity, -100, 0, 0.3, 1.2, 6, 86_400, .greatestFiniteMagnitude]
        for activity in activities {
            for time in times {
                let pose = PikoPetMotion.pose(
                    activity: activity, loudness: .infinity, elapsed: time,
                    patElapsed: time, touchX: .nan, touchY: .infinity
                )
                let values = [
                    pose.elevation, pose.bodyScale, pose.headTilt, pose.yaw, pose.pitch,
                    pose.leftEarAngle, pose.rightEarAngle, pose.eyeOpenness, pose.mouthOpenness
                ]
                let allFinite = values.allSatisfy { $0.isFinite }
                #expect(allFinite)
                #expect((-0.03...0.15).contains(pose.elevation))
                #expect((0.95...1.05).contains(pose.bodyScale))
                #expect((-0.4...0.4).contains(pose.headTilt))
                #expect((-1.2...1.2).contains(pose.leftEarAngle))
                #expect((-1.2...1.2).contains(pose.rightEarAngle))
                #expect((0...1).contains(pose.eyeOpenness))
                #expect((0...1).contains(pose.mouthOpenness))
            }
        }
    }

    @Test func activitiesDriveDifferentPartsOfThePose() {
        let idle = PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: 0.4)
        let listening = PikoPetMotion.pose(activity: .listening, loudness: 1, elapsed: 0.4)
        let thinking = PikoPetMotion.pose(activity: .thinking, loudness: 0, elapsed: 0.4)
        let speaking = PikoPetMotion.pose(activity: .speaking, loudness: 1, elapsed: 0.4)
        let happy = PikoPetMotion.pose(activity: .happy, loudness: 0, elapsed: 0.4)
        #expect(abs(listening.leftEarAngle) < abs(idle.leftEarAngle))
        #expect(thinking.headTilt > idle.headTilt)
        #expect(speaking.mouthOpenness > idle.mouthOpenness)
        #expect(happy.elevation > idle.elevation)
        #expect(listening != PikoPetMotion.pose(activity: .listening, loudness: 0, elapsed: 0.4))
    }

    @Test func patIsBriefAndDoesNotAcceptInvalidOrFutureTimes() {
        let idle = PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: 0.4)
        let patted = PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: 0.4, patElapsed: 0)
        #expect(patted.elevation > idle.elevation)
        #expect(patted.eyeOpenness < idle.eyeOpenness)
        for age in [Double.nan, .infinity, -.infinity, -1, 1.6, 100] {
            #expect(PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: 0.4, patElapsed: age) == idle)
        }
    }

    @Test func happyReturnsToQuietRatherThanLoopingCelebration() {
        for time in [2.0, 6, 60, 86_400] {
            #expect(PikoPetMotion.pose(activity: .happy, loudness: 0, elapsed: time)
                == PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: time))
        }
    }

    @Test func reduceMotionFreezesIdleAndRemovesCelebrationTravel() {
        let still = PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: 0, reduceMotion: true)
        for time in [0.2, 0.6, 5.7, 100] {
            #expect(PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: time, reduceMotion: true) == still)
            let happy = PikoPetMotion.pose(activity: .happy, loudness: 0, elapsed: time, reduceMotion: true)
            #expect(happy.elevation == still.elevation)
            #expect(happy.bodyScale == still.bodyScale)
        }
        #expect(PikoPetMotion.pose(activity: .listening, loudness: 1, elapsed: 1, reduceMotion: true)
            != PikoPetMotion.pose(activity: .listening, loudness: 0, elapsed: 1, reduceMotion: true))
    }

    @Test func touchChangesGazeButCannotTurnTheRabbitAway() {
        let left = PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: 0, touchX: -1, touchY: -1)
        let right = PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: 0, touchX: 1, touchY: 1)
        #expect(left.yaw < right.yaw)
        #expect(left.pitch < right.pitch)
        #expect(abs(left.yaw) <= 0.3 && abs(right.pitch) <= 0.2)
        #expect(right == PikoPetMotion.pose(activity: .idle, loudness: 0, elapsed: 0, touchX: 100, touchY: 100))
    }

    @Test func invalidElapsedTimeIsTheInitialPoseAndExtremeTimeIsBounded() {
        for activity in activities {
            let initial = PikoPetMotion.pose(activity: activity, loudness: 0.5, elapsed: 0)
            for time in [Double.nan, .infinity, -.infinity, -1] {
                #expect(PikoPetMotion.pose(activity: activity, loudness: 0.5, elapsed: time) == initial)
            }
            #expect(PikoPetMotion.pose(activity: activity, loudness: 0.5, elapsed: .greatestFiniteMagnitude)
                == PikoPetMotion.pose(activity: activity, loudness: 0.5, elapsed: 86_400))
        }
    }
}
