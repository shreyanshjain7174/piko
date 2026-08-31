import Foundation
import Testing
import PikoKit
@testable import PikoBrain

@Suite
struct RoutePrefilterTests {

    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func routeNeverInvokesInference() async {
        let counter = CallCounter()
        let brain = SystemBrain(inference: { _, _ in
            counter.increment()
            return ""
        })

        let phrases: [(String, Route)] = [
            ("hello there how are you", .write),
            ("um I think we should ship friday", .write),
            ("please send this to the team", .write),
            ("the meeting is at three", .write),
            ("remind me to call alex", .command),
            ("set a timer for ten minutes", .command),
            ("add to the grocery list", .command),
            ("schedule lunch with sam", .command),
            ("create a reminder", .command),
            ("what did i say about pricing", .recall),
            ("when did i last talk to jamie", .recall),
            ("search for the deck", .recall),
            ("show me my notes", .recall),
            ("find where we parked", .recall),
        ]

        for (phrase, expected) in phrases {
            let route = await brain.route(phrase)
            #expect(route == expected, "phrase: \(phrase)")
        }
        #expect(counter.count == 0)
    }

    @Test func recallBeatsOverlappingCommandPrefix() async {
        let route = await SystemBrain().route("remind me what I said about pricing")
        #expect(route == .recall)
        #expect(SystemBrain.prefilterRoute("remind me what i said about pricing") == .recall)
    }

    @Test func leadingWhitespaceAndMixedCasingStillRoute() async {
        let brain = SystemBrain()
        #expect(await brain.route("  REMIND ME to pack  ") == .command)
        #expect(await brain.route("\nWhat Did I say about this\t") == .recall)
        #expect(await brain.route("  Hello World  ") == .write)
    }

    @Test func emptyOrWhitespaceRoutesToWrite() async {
        let brain = SystemBrain()
        #expect(await brain.route("") == .write)
        #expect(await brain.route("   \n\t  ") == .write)
        #expect(SystemBrain.prefilterRoute("") == .write)
    }

    // MARK: - Battle tests: real adversarial input, not just clean ASCII keyword matches.

    @Test func emojiOnlyInputRoutesToWriteNotCrash() async {
        let brain = SystemBrain()
        #expect(await brain.route("👍👍👍") == .write)
        // Prefilter is a pure hasPrefix match (documented in SystemBrain.prefilterRoute) —
        // leading emoji, like any leading noise, defeats it. Not a bug: real ASR output
        // never contains emoji, so this input shape can't occur on the real pipeline.
        #expect(await brain.route("🎉 remind me 🎉") == .write)
        #expect(await brain.route("remind me 🎉 to call back") == .command, "keyword still at the true prefix, emoji only in the tail")
    }

    @Test func nonLatinScriptInputDoesNotFalsePositiveOnEnglishKeywords() async {
        let brain = SystemBrain()
        // Arabic/Hindi/Japanese text containing no English command/recall keywords must
        // route to .write, not accidentally match a substring of a transliterated word.
        #expect(await brain.route("مرحبا كيف حالك اليوم") == .write)
        #expect(await brain.route("आज मौसम बहुत अच्छा है") == .write)
        #expect(await brain.route("今日はいい天気ですね") == .write)
    }

    @Test func veryLongInputDoesNotHangOrCrash() async {
        let brain = SystemBrain()
        let longText = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 2000)
        let route = await brain.route(longText)
        #expect(route == .write)
        #expect(await brain.route("remind me " + longText) == .command)
    }

    @Test func keywordEmbeddedInsideALongerWordDoesNotFalsePositive() async {
        let brain = SystemBrain()
        // "remind" is a command starter; "reminders" and "remindful" (not a real word, but
        // adversarially close) must not match as a whole-word/prefix false positive if the
        // prefilter is meant to match starters, not arbitrary substrings.
        #expect(await brain.route("reminders app is full") == .write, "the word 'reminders' alone, not a command sentence, should not misroute")
    }
}
