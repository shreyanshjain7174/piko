import Testing
@testable import PikoTranscribe
import PikoKit

/// Tests for stablePrefix calculation rules (05-RESEARCH.md spec)
@Suite struct StablePrefixTests {

    /// Helper that mimics the stablePrefix logic from SpeechTranscriberEngine
    func calculateStablePrefix(text: String, isFinal: Bool) -> Int {
        if isFinal { return text.count }
        if text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") { return text.count }
        return 0
    }

    @Test func finalResultGetsFullStablePrefix() {
        #expect(calculateStablePrefix(text: "Hello world", isFinal: true) == 11)
    }

    @Test func periodPunctuationShortCircuits() {
        #expect(calculateStablePrefix(text: "Hello.", isFinal: false) == 6)
    }

    @Test func questionMarkShortCircuits() {
        #expect(calculateStablePrefix(text: "Hello?", isFinal: false) == 6)
    }

    @Test func exclamationShortCircuits() {
        #expect(calculateStablePrefix(text: "Hello!", isFinal: false) == 6)
    }

    @Test func volatileTextWithoutPunctuationGetsZero() {
        #expect(calculateStablePrefix(text: "Hello wor", isFinal: false) == 0)
    }
}
