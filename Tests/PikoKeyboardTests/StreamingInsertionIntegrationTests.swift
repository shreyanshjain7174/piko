import Foundation
import PikoKit
@testable import PikoKeyboardCore
import Testing

@MainActor
@Suite("Streaming insertion integration")
struct StreamingInsertionIntegrationTests {

    @Test func streamingDictationScenario() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)
        let startedAt = Date.now

        // Draft 1: "Hel" (nothing stable yet)
        controller.apply(CaptureDraft(
            sessionEpoch: 1, sequence: 1, text: "Hel", stablePrefix: 0, startedAt: startedAt))
        #expect(mock.insertedText == ["Hel"])
        #expect(mock.deleteCount == 0)
        #expect(controller.insertedChars == 3)

        // Draft 2: "Hello" (still nothing stable — transcriber not confident)
        controller.apply(CaptureDraft(
            sessionEpoch: 1, sequence: 2, text: "Hello", stablePrefix: 0, startedAt: startedAt))
        #expect(mock.deleteCount == 3)
        #expect(mock.insertedText.last == "Hello")
        #expect(controller.insertedChars == 5)

        // Draft 3: "Hello wor" with stablePrefix=6 ("Hello " is now stable)
        mock.deleteCount = 0
        mock.insertedText = []
        controller.apply(CaptureDraft(
            sessionEpoch: 1, sequence: 3, text: "Hello wor", stablePrefix: 6, startedAt: startedAt))
        #expect(mock.deleteCount == 0)
        #expect(mock.insertedText == [" wor"])
        #expect(controller.insertedChars == 9)

        // Draft 4: growing stable ("Hello world h", freeze through "Hello world ")
        mock.deleteCount = 0
        mock.insertedText = []
        controller.apply(CaptureDraft(
            sessionEpoch: 1, sequence: 4, text: "Hello world h", stablePrefix: 12, startedAt: startedAt))
        #expect(mock.deleteCount == 0)
        #expect(mock.insertedText == ["ld h"])
        #expect(controller.insertedChars == 13)

        // Draft 5: final draft before result — last unstable char rewritten, then the rest
        mock.deleteCount = 0
        mock.insertedText = []
        controller.apply(CaptureDraft(
            sessionEpoch: 1, sequence: 5,
            text: "Hello world how are you",
            stablePrefix: 12,
            startedAt: startedAt))
        #expect(mock.deleteCount == 1)
        #expect(mock.insertedText == ["how are you"])
        #expect(controller.insertedChars == 23)

        // CaptureResult with Brain rewrite of the streamed raw
        mock.deleteCount = 0
        mock.insertedText = []
        controller.commit(CaptureResult(
            raw: "Hello world how are you",
            shipped: "Hello world, how are you?"))
        #expect(mock.deleteCount == 23)
        #expect(mock.insertedText == ["Hello world, how are you?"])
        #expect(controller.insertedChars == 0)
        #expect(controller.lastApplied == nil)
    }
}
