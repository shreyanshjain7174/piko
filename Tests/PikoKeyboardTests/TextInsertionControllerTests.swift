import Foundation
import PikoKit
@testable import PikoKeyboardCore
import Testing

/// Records insert/delete operations. Production talks to `UITextDocumentProxy` via `TextProxy`.
@MainActor
final class MockTextDocumentProxy: NSObject, TextProxy {
    var insertedText: [String] = []
    var deleteCount: Int = 0

    func insertText(_ text: String) { insertedText.append(text) }
    func deleteBackward() { deleteCount += 1 }
}

@MainActor
@Suite("TextInsertionController stablePrefix diffing")
struct TextInsertionControllerTests {

    private func draft(
        epoch: Int = 1,
        sequence: Int,
        text: String,
        stablePrefix: Int
    ) -> CaptureDraft {
        CaptureDraft(
            sessionEpoch: epoch,
            sequence: sequence,
            text: text,
            stablePrefix: stablePrefix,
            startedAt: .now)
    }

    private func result(raw: String, shipped: String) -> CaptureResult {
        CaptureResult(raw: raw, shipped: shipped)
    }

    @Test("first draft inserts full text")
    func firstDraftInsertsFullText() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(sequence: 1, text: "Hello", stablePrefix: 5))

        #expect(mock.insertedText == ["Hello"])
        #expect(mock.deleteCount == 0)
        #expect(controller.insertedChars == 5)
        #expect(controller.lastApplied?.text == "Hello")
    }

    @Test("second draft with extended stablePrefix only inserts the unstable tail")
    func secondDraftInsertsOnlyUnstableTail() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(sequence: 1, text: "Hello", stablePrefix: 5))
        controller.apply(draft(sequence: 2, text: "Hello wo", stablePrefix: 6))

        #expect(mock.deleteCount == 0)
        #expect(mock.insertedText == ["Hello", " wo"])
        #expect(controller.insertedChars == 8)
    }

    @Test("revised unstable tail deletes old tail and inserts the new one")
    func revisedUnstableTailDeletesAndInserts() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(sequence: 1, text: "Hello wo", stablePrefix: 6))
        mock.deleteCount = 0
        mock.insertedText = []

        controller.apply(draft(sequence: 2, text: "Hello world", stablePrefix: 6))

        #expect(mock.deleteCount == 2)
        #expect(mock.insertedText == ["world"])
        #expect(controller.insertedChars == 11)
    }

    @Test("stale draft with lower sequence in the same epoch is ignored")
    func staleDraftIsIgnored() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(sequence: 2, text: "Hello", stablePrefix: 5))
        controller.apply(draft(sequence: 1, text: "Hel", stablePrefix: 0))

        #expect(mock.insertedText == ["Hello"])
        #expect(mock.deleteCount == 0)
        #expect(controller.lastApplied?.sequence == 2)
        #expect(controller.insertedChars == 5)
    }

    @Test("new session epoch resets streamed state and applies fresh text")
    func newSessionEpochAppliesFresh() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(epoch: 1, sequence: 3, text: "Hello", stablePrefix: 5))
        mock.deleteCount = 0
        mock.insertedText = []

        controller.apply(draft(epoch: 2, sequence: 0, text: "Hi", stablePrefix: 2))

        #expect(mock.deleteCount == 5)
        #expect(mock.insertedText == ["Hi"])
        #expect(controller.insertedChars == 2)
        #expect(controller.lastApplied?.sessionEpoch == 2)
        #expect(controller.lastApplied?.sequence == 0)
    }

    @Test("commit replaces streamed text with shipped result and clears state")
    func commitReplacesStreamedTextWithShipped() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(sequence: 1, text: "Hello world", stablePrefix: 11))
        mock.deleteCount = 0
        mock.insertedText = []

        controller.commit(result(raw: "Hello world", shipped: "Hello world."))

        #expect(mock.deleteCount == 11)
        #expect(mock.insertedText == ["Hello world."])
        #expect(controller.insertedChars == 0)
        #expect(controller.lastApplied == nil)
    }

    @Test("reset clears state without inserting")
    func resetClearsStateWithoutInserting() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(sequence: 1, text: "Hello", stablePrefix: 5))
        mock.deleteCount = 0
        mock.insertedText = []

        controller.reset()

        #expect(controller.insertedChars == 0)
        #expect(controller.lastApplied == nil)
        #expect(mock.insertedText.isEmpty)
        #expect(mock.deleteCount == 0)
    }
}
