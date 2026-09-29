import Testing
import Foundation
import PikoKit

@Suite("Mood engine — the notch pet's feelings")
struct PikoMoodTests {

    @Test("active dictation engages the pet")
    func capturingMoods() {
        #expect(MoodEngine.mood(phase: .capturing, words: 3, armedSeconds: 10, hour: 14) == .fresh)
        #expect(MoodEngine.mood(phase: .capturing, words: 15, armedSeconds: 30, hour: 14) == .happy)
        #expect(MoodEngine.mood(phase: .tidying, words: 20, armedSeconds: 90, hour: 22) == .happy)
    }

    @Test("an armed hour with barely a word is a nap, not a failure")
    func sleepyAfterLongArming() {
        #expect(MoodEngine.mood(phase: .armed, words: 0, armedSeconds: 46 * 60, hour: 14) == .sleepy)
        #expect(MoodEngine.mood(phase: .armed, words: 30, armedSeconds: 46 * 60, hour: 14) == .sleepy)
    }

    @Test("morning sessions start fresh, productive ones end happy")
    func freshAndHappy() {
        #expect(MoodEngine.mood(phase: .armed, words: 0, armedSeconds: 60, hour: 7) == .fresh)
        #expect(MoodEngine.mood(phase: .armed, words: 45, armedSeconds: 20 * 60, hour: 15) == .happy)
    }

    @Test("the resting default is calm")
    func calmDefault() {
        #expect(MoodEngine.mood(phase: .armed, words: 2, armedSeconds: 5 * 60, hour: 15) == .calm)
        #expect(MoodEngine.mood(phase: .idle, words: 0, armedSeconds: 60, hour: 23) == .calm)
    }

    @Test("a long-armed session is sleepy even in the morning")
    func sleepyWinsOverMorning() {
        #expect(MoodEngine.mood(phase: .armed, words: 0, armedSeconds: 50 * 60, hour: 7) == .sleepy)
    }
}
