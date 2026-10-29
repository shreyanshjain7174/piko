import Testing
@testable import PikoTranscribe

@Suite struct SpeechTranscriptTests {
    @Test func revisingOnePhraseDoesNotDuplicateIt() {
        var transcript = SpeechTranscript()
        transcript.update("Send the", at: 0, isFinal: false)
        transcript.update("Send the deck.", at: 0, isFinal: true)
        transcript.update("Tomorrow", at: 2, isFinal: false)
        transcript.update("Tomorrow morning.", at: 2, isFinal: true)
        #expect(transcript.text == "Send the deck. Tomorrow morning.")
        #expect(transcript.finalText == transcript.text)
    }

    @Test func volatileTailRemainsVisibleUntilFinalized() {
        var transcript = SpeechTranscript()
        transcript.update("Hello.", at: 0, isFinal: true)
        transcript.update("Call Aarav", at: 1, isFinal: false)
        #expect(transcript.text == "Hello. Call Aarav")
        #expect(transcript.finalText == "Hello.")
        #expect(transcript.stablePrefix == "Hello.".count)
        #expect(!transcript.isFinal)
        transcript.update("Call Aarav.", at: 1, isFinal: true)
        #expect(transcript.finalText == "Hello. Call Aarav.")
        #expect(transcript.isFinal)
    }

    @Test func punctuationDoesNotFalselyFinalizeAPhrase() {
        var transcript = SpeechTranscript()
        transcript.update("Can you send it?", at: 0, isFinal: false)
        #expect(transcript.stablePrefix == 0)
        #expect(transcript.finalText.isEmpty)
        transcript.update("Can you send it tomorrow?", at: 0, isFinal: true)
        #expect(transcript.finalText == "Can you send it tomorrow?")
    }

    @Test func duplicateFinalDoesNotAppendOrUnfreezeText() {
        var transcript = SpeechTranscript()
        transcript.update("Hello.", at: 0, isFinal: true)
        transcript.update("Hello.", at: 0, isFinal: true)
        transcript.update("Hello", at: 0, isFinal: false)
        #expect(transcript.text == "Hello.")
        #expect(transcript.isFinal)
    }
}

@Suite struct SpeechTranscriptVolatileTailTests {
    @Test func finalWithShiftedStartReplacesVolatileTail() {
        var transcript = SpeechTranscript()
        transcript.update("is it using a local", at: 0.52, isFinal: false)
        transcript.update("Is it using a local model on the phone?", at: 0.48, isFinal: true)
        #expect(transcript.text == "Is it using a local model on the phone?")
        #expect(transcript.isFinal)
    }

    @Test func volatileTailIsReplacedWholesale() {
        var transcript = SpeechTranscript()
        transcript.update("Hello.", at: 0, isFinal: true)
        transcript.update("the second", at: 1.10, isFinal: false)
        transcript.update("the second is it's not", at: 1.05, isFinal: false)
        #expect(transcript.text == "Hello. the second is it's not")
        transcript.update("The second is, it's not transcribing well.", at: 1.0, isFinal: true)
        #expect(transcript.text == "Hello. The second is, it's not transcribing well.")
        #expect(transcript.finalText == transcript.text)
        #expect(transcript.isFinal)
    }
}
