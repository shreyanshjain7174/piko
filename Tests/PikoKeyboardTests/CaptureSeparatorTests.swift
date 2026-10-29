import Foundation
import Testing
@testable import PikoKeyboardCore
@testable import PikoKit

@MainActor
@Suite("Consecutive captures in one field")
struct CaptureSeparatorTests {
    private func draft(_ text: String, sequence: Int, stable: Int = 0) -> CaptureDraft {
        CaptureDraft(sessionEpoch: 2, sequence: sequence, text: text, stablePrefix: stable, startedAt: .now)
    }

    @Test func newCaptureAfterWordsIsSeparatedBySpace() {
        let mock = MockTextDocumentProxy()
        mock.text = "Please send the report at 4."
        let controller = TextInsertionController(proxy: mock)
        controller.beginCapture()
        controller.apply(draft("thanks", sequence: 1))
        controller.apply(draft("thanks so", sequence: 2, stable: 6))
        #expect(mock.text == "Please send the report at 4. thanks so")
        controller.commit(CaptureResult(raw: "thanks so", shipped: "Thanks so much!"))
        #expect(mock.text == "Please send the report at 4. Thanks so much!")
        #expect(controller.revertToRaw())
        #expect(mock.text == "Please send the report at 4. thanks so")
    }

    @Test func emptyFieldAndTrailingWhitespaceGetNoExtraSpace() {
        for prefix in ["", "Hi ", "Line\n"] {
            let mock = MockTextDocumentProxy()
            mock.text = prefix
            let controller = TextInsertionController(proxy: mock)
            controller.beginCapture()
            controller.apply(draft("hello", sequence: 1))
            controller.commit(CaptureResult(raw: "hello", shipped: "Hello."))
            #expect(mock.text == prefix + "Hello.")
        }
    }
}

@MainActor
@Suite("Minimal host edits while streaming")
struct MinimalHostEditTests {
    @Test func growingVolatileDraftOnlyTypesNewCharacters() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)
        controller.beginCapture()
        for (index, text) in ["um so", "um so lik", "um so like can you"].enumerated() {
            controller.apply(CaptureDraft(sessionEpoch: 3, sequence: index + 1, text: text,
                                          stablePrefix: 0, startedAt: .now))
        }
        #expect(mock.deleteCount == 0)
        #expect(mock.insertedText == ["um so", " lik", "e can you"])
        #expect(mock.text == "um so like can you")
    }
}
