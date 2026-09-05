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

    // MARK: - Battle tests: real adversarial Unicode, not just ASCII.
    // `insertedChars`/`dropFirst` use Swift's grapheme-cluster count, matching
    // UITextDocumentProxy.deleteBackward()'s documented one-character-per-call
    // contract — these prove that holds for multi-scalar clusters, not just guess it.

    @Test("flag emoji (2 scalars, 1 grapheme) counts and diffs as a single character")
    func flagEmojiSingleGrapheme() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(sequence: 1, text: "🇮🇳", stablePrefix: 0))
        #expect(controller.insertedChars == 1)

        controller.apply(draft(sequence: 2, text: "🇮🇳🇺🇸", stablePrefix: 1))
        #expect(mock.deleteCount == 0)
        #expect(mock.insertedText == ["🇮🇳", "🇺🇸"])
        #expect(controller.insertedChars == 2)
    }

    @Test("ZWJ family emoji (many scalars, 1 grapheme) deletes as one character on revision")
    func zwjFamilyEmojiRevisionDeletesOneCharacter() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)
        let family = "👨‍👩‍👧‍👦"

        controller.apply(draft(sequence: 1, text: family, stablePrefix: 0))
        #expect(controller.insertedChars == 1)
        mock.deleteCount = 0
        mock.insertedText = []

        // Revise the unstable tail: same stablePrefix (0), different single-grapheme text.
        controller.apply(draft(sequence: 2, text: "👍", stablePrefix: 0))
        #expect(mock.deleteCount == 1, "one grapheme cluster, regardless of scalar count, is one deleteBackward()")
        #expect(mock.insertedText == ["👍"])
        #expect(controller.insertedChars == 1)
    }

    @Test("combining diacritic (e + combining acute, 2 scalars, 1 grapheme) round-trips correctly")
    func combiningDiacriticSingleGrapheme() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)
        let combining = "cafe\u{0301}" // "café" spelled with a combining acute accent, not the precomposed é

        controller.apply(draft(sequence: 1, text: combining, stablePrefix: combining.count))
        #expect(controller.insertedChars == combining.count)
        #expect(combining.count == 4, "grapheme-cluster count treats e+combining-accent as one character")

        controller.commit(result(raw: combining, shipped: "Café."))
        #expect(mock.deleteCount == 4)
        #expect(mock.insertedText.last == "Café.")
    }

    @Test("RTL Arabic text streams and revises without corrupting insertedChars")
    func rtlArabicTextStreamsCorrectly() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)
        let partial = "مرحبا"
        let extended = "مرحبا بك"

        controller.apply(draft(sequence: 1, text: partial, stablePrefix: 0))
        #expect(controller.insertedChars == partial.count)

        controller.apply(draft(sequence: 2, text: extended, stablePrefix: partial.count))
        #expect(controller.insertedChars == extended.count)
        #expect(mock.insertedText.last == " بك")
    }

    @Test("rapid sequence of ten revisions never desyncs insertedChars from the last draft's length")
    func rapidRevisionSequenceStaysConsistent() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)
        var text = ""

        for i in 1...10 {
            text += "word\(i) "
            controller.apply(draft(sequence: i, text: text, stablePrefix: max(0, text.count - 6)))
            #expect(controller.insertedChars == text.count, "desync at revision \(i)")
        }
    }

    @Test("revertToRaw swaps the rewriter's output for what the transcriber heard")
    func revertToRawRestoresTranscript() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.apply(draft(sequence: 1, text: "um hello world", stablePrefix: 14))
        controller.commit(result(raw: "um hello world", shipped: "Hello world."))
        mock.deleteCount = 0
        mock.insertedText = []

        #expect(controller.canRevertToRaw)
        #expect(controller.revertToRaw())

        #expect(mock.deleteCount == 12)
        #expect(mock.insertedText == ["um hello world"])
        #expect(!controller.canRevertToRaw)
    }

    @Test("revertToRaw is unavailable when the rewriter changed nothing")
    func revertUnavailableWhenShippedEqualsRaw() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.commit(result(raw: "Hello world.", shipped: "Hello world."))

        #expect(!controller.canRevertToRaw)
        #expect(!controller.revertToRaw())
    }

    @Test("a second revert is a no-op rather than deleting the restored text")
    func secondRevertIsNoOp() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.commit(result(raw: "raw text", shipped: "Raw text."))
        #expect(controller.revertToRaw())
        mock.deleteCount = 0
        mock.insertedText = []

        #expect(!controller.revertToRaw())
        #expect(mock.deleteCount == 0)
        #expect(mock.insertedText.isEmpty)
    }

    @Test("a new draft withdraws the revert offer, so it can never delete live text")
    func newDraftClearsRevertOffer() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.commit(result(raw: "raw", shipped: "Raw."))
        #expect(controller.canRevertToRaw)

        controller.apply(draft(epoch: 2, sequence: 1, text: "next", stablePrefix: 4))

        #expect(!controller.canRevertToRaw)
    }

    @Test("reset clears the revert offer")
    func resetClearsRevertOffer() {
        let mock = MockTextDocumentProxy()
        let controller = TextInsertionController(proxy: mock)

        controller.commit(result(raw: "raw", shipped: "Raw."))
        controller.reset()

        #expect(!controller.canRevertToRaw)
        #expect(controller.lastCommitted == nil)
    }
}

