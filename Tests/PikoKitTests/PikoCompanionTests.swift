import Foundation
import Testing
import PikoKit

@Suite("Piko companion preferences")
@MainActor
struct PikoCompanionTests {
    @Test("Cold starts do not infer a preference from one or two dismissals")
    func conservativeLearning() {
        var pattern = PikoAttentionPattern()
        #expect(pattern.permitsRoutineUpdate)
        pattern.record(.dismissed)
        pattern.record(.dismissed)
        #expect(pattern.permitsRoutineUpdate)
        pattern.record(.dismissed)
        #expect(!pattern.permitsRoutineUpdate)
    }

    @Test("Routine attention stops at the three-quarter dismissal boundary")
    func dismissalBoundary() {
        #expect(!PikoAttentionPattern(recent: [.dismissed, .dismissed, .dismissed, .engaged]).permitsRoutineUpdate)
        #expect(PikoAttentionPattern(recent: [.dismissed, .dismissed, .engaged]).permitsRoutineUpdate)
    }

    @Test("Recent engagement displaces old habits without unbounded history")
    func boundedRecency() {
        var pattern = PikoAttentionPattern()
        for _ in 0..<24 { pattern.record(.dismissed) }
        #expect(pattern.recent.count == 8)
        #expect(!pattern.permitsRoutineUpdate)
        for _ in 0..<8 { pattern.record(.engaged) }
        #expect(pattern.recent == Array(repeating: .engaged, count: 8))
        #expect(pattern.permitsRoutineUpdate)
    }

    @Test("Greeting and completion habits stay independent")
    func independentCategories() {
        var preferences = PikoCompanionPreferences()
        for _ in 0..<3 { preferences.record(.dismissed, for: .greeting) }
        #expect(!preferences.shouldPresentRoutine(.greeting))
        #expect(preferences.shouldPresentRoutine(.completion))
    }

    @Test("Explicit quiet overrides learned engagement")
    func quietOverride() {
        var preferences = PikoCompanionPreferences()
        for _ in 0..<8 { preferences.record(.engaged, for: .completion) }
        preferences.quietMode = true
        #expect(!preferences.shouldPresentRoutine(.greeting))
        #expect(!preferences.shouldPresentRoutine(.completion))
    }

    @Test("Resetting learning retains the user's personality and quiet choice")
    func resetLearning() {
        var preferences = PikoCompanionPreferences(personality: .direct, quietMode: true)
        preferences.record(.dismissed, for: .greeting)
        preferences.record(.engaged, for: .completion)
        preferences.resetLearning()
        #expect(preferences.personality == .direct)
        #expect(preferences.quietMode)
        #expect(preferences.greetings.recent.isEmpty)
        #expect(preferences.completions.recent.isEmpty)
    }

    @Test("Preferences and actual feedback survive a new store instance")
    func persistence() throws {
        let suite = "PikoCompanionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try PikoCompanionStore(defaults: defaults)
        #expect(store.preferences == PikoCompanionPreferences())
        var preferences = store.preferences
        preferences.personality = .calm
        preferences.quietMode = true
        preferences.record(.dismissed, for: .greeting)
        preferences.record(.engaged, for: .completion)
        try store.save(preferences)
        #expect(try PikoCompanionStore(defaults: defaults).preferences == preferences)
    }

    @Test("Malformed stored preferences throw without deleting their data")
    func corruptDataIsVisible() {
        let suite = "PikoCompanionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("not a preferences document".utf8)
        defaults.set(bytes, forKey: PikoCompanionStore.preferencesKey)
        #expect(throws: (any Error).self) { try PikoCompanionStore(defaults: defaults) }
        #expect(defaults.data(forKey: PikoCompanionStore.preferencesKey) == bytes)
    }

    @Test("A stored non-data value is not mistaken for first use")
    func incorrectStoredType() {
        let suite = "PikoCompanionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unexpected", forKey: PikoCompanionStore.preferencesKey)
        #expect(throws: (any Error).self) { try PikoCompanionStore(defaults: defaults) }
        #expect(defaults.string(forKey: PikoCompanionStore.preferencesKey) == "unexpected")
    }

    @Test("A future preference version is rejected without a reset")
    func futureVersion() {
        let suite = "PikoCompanionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data(#"{"version":99}"#.utf8)
        defaults.set(bytes, forKey: PikoCompanionStore.preferencesKey)
        #expect(throws: PikoCompanionStorageError.unsupportedVersion(99)) {
            try PikoCompanionStore(defaults: defaults)
        }
        #expect(defaults.data(forKey: PikoCompanionStore.preferencesKey) == bytes)
    }

    @Test("Decoding valid feedback still bounds the retained window")
    func decodedWindowIsBounded() throws {
        let bytes = Data(#"{"recent":["dismissed","dismissed","dismissed","engaged","engaged","engaged","engaged","engaged","engaged","engaged"]}"#.utf8)
        let pattern = try JSONDecoder().decode(PikoAttentionPattern.self, from: bytes)
        #expect(pattern.recent.count == 8)
        #expect(pattern.recent.first == .dismissed)
        #expect(pattern.permitsRoutineUpdate)
    }

    @Test("All personalities offer distinct short greetings")
    func personalities() {
        let greetings = PikoPersonality.allCases.map(\.greeting)
        #expect(greetings.count == 3)
        #expect(Set(greetings).count == 3)
        #expect(greetings.allSatisfy { !$0.isEmpty && $0.count < 90 })
    }

    @Test("An old speech cancellation cannot finish the next utterance")
    func speechCancellationIdentity() {
        let oldUtterance = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let newUtterance = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var playback = PikoSpeechLifecycle()
        playback.begin(oldUtterance)
        playback.cancel()
        playback.begin(newUtterance)
        let oldFinished = playback.finish(oldUtterance)
        #expect(!oldFinished)
        #expect(playback.isSpeaking)
        let currentFinished = playback.finish(newUtterance)
        #expect(currentFinished)
        #expect(!playback.isSpeaking)
    }

    @Test("Repeated speech completion and cancellation are harmless")
    func speechCompletionOnce() {
        let utterance = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        var playback = PikoSpeechLifecycle()
        playback.begin(utterance)
        let firstCompletion = playback.finish(utterance)
        let repeatedCompletion = playback.finish(utterance)
        #expect(firstCompletion)
        #expect(!repeatedCompletion)
        playback.cancel()
        #expect(!playback.isSpeaking)
    }
}
