import Testing
@testable import PikoTranscribe
import PikoKit

@Suite struct MockTranscriberTests {

    @Test func progressiveScriptBuildsExpectedSequence() async {
        let script = MockTranscriber.Script.progressive("Hello world", chunkSize: 3, sessionEpoch: 1)
        // "Hel" → "Hello " → "Hello wor" → "Hello world"
        #expect(script.drafts.count >= 3)
        #expect(script.drafts.last?.text == "Hello world")
        #expect(script.drafts.last?.stablePrefix == 11) // final gets full stable
    }

    @Test func hypothesesStreamCompletesAfterScript() async {
        let mock = MockTranscriber()
        let script = MockTranscriber.Script(drafts: [
            CaptureDraft(sessionEpoch: 1, sequence: 1, text: "Hi", stablePrefix: 0),
            CaptureDraft(sessionEpoch: 1, sequence: 2, text: "Hi there", stablePrefix: 8),
        ], delayBetween: .milliseconds(10))

        await mock.setScript(script)

        var received: [CaptureDraft] = []
        for await draft in mock.hypotheses() {
            received.append(draft)
        }

        #expect(received.count == 2)
        #expect(received[0].text == "Hi")
        #expect(received[1].text == "Hi there")
    }

    @Test func finishReturnsLastDraftText() async {
        let mock = MockTranscriber()
        let script = MockTranscriber.Script(drafts: [
            CaptureDraft(sessionEpoch: 1, sequence: 1, text: "Final text.", stablePrefix: 11),
        ], delayBetween: .milliseconds(1))

        await mock.setScript(script)

        // Consume hypotheses
        for await _ in mock.hypotheses() {}

        let result = await mock.finish()
        #expect(result == "Final text.")
    }

    @Test func defaultScriptRefreshesWithoutReplacingAnExplicitFixture() async {
        let mock = MockTranscriber()
        await mock.setDefaultScript(.progressive("First", sessionEpoch: 1))
        await mock.setDefaultScript(.progressive("Second", sessionEpoch: 2))

        #expect(await mock.finish() == "Second")

        await mock.setScript(.progressive("Fixture", sessionEpoch: 3))
        await mock.setDefaultScript(.progressive("Ignored", sessionEpoch: 4))

        #expect(await mock.finish() == "Fixture")
    }
}
