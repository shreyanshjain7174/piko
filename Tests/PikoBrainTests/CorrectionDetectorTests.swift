import Testing
@testable import PikoBrain

@Suite struct CorrectionDetectorTests {

    @Test func removesTrailingDeleteThatCommand() {
        let result = CorrectionDetector.process("send the deck. delete that")
        #expect(result.text == "")
        #expect(result.corrections.contains { $0.kind == .deletion })
    }

    @Test func deleteThatRemovesOnlyLastSentence() {
        let result = CorrectionDetector.process("call mom. send the deck. scratch that")
        #expect(result.text == "call mom.")
    }

    @Test func stripsFillerWords() {
        let result = CorrectionDetector.process("um so like can you send me the deck")
        #expect(!result.text.lowercased().contains("um"))
        #expect(result.corrections.contains { $0.kind == .fillerRemoval })
    }

    @Test func appliesFormattingCommands() {
        let result = CorrectionDetector.process("hello new line how are you period")
        #expect(result.text.contains("\n"))
        #expect(result.text.hasSuffix("."))
    }

    @Test func selfCorrectionPrefixReplacesPriorClause() {
        let result = CorrectionDetector.process("call John actually call Sarah")
        #expect(result.text.contains("Sarah"))
    }

    @Test func passthroughWhenNoCorrectionSignals() {
        let result = CorrectionDetector.process("send the deck when you get a chance")
        #expect(result.text == "send the deck when you get a chance")
        #expect(result.corrections.isEmpty)
    }

    @Test func collapsesDoubleSpacesLeftByRemovals() {
        let result = CorrectionDetector.process("send  the   deck")
        #expect(!result.text.contains("  "))
    }
}
