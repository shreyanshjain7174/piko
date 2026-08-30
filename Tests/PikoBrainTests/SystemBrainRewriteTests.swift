import Foundation
import Testing
import PikoKit
@testable import PikoBrain

@Suite
struct SystemBrainRewriteTests {

    @Test func rewriteReturnsTrimmedInjectedInference() async throws {
        let brain = SystemBrain(inference: { _, _ in "  cleaned text  " })
        let out = try await brain.rewrite(
            "um hello",
            profile: .message,
            lexicon: [],
            examples: []
        )
        #expect(out == "cleaned text")
    }

    @Test func inferenceReceivesUnmodifiedInstructionsAndPrompt() async throws {
        final class Box: @unchecked Sendable {
            var instructions: String?
            var prompt: String?
        }
        let box = Box()
        let text = "hey can we push it"
        let brain = SystemBrain(inference: { instructions, prompt in
            box.instructions = instructions
            box.prompt = prompt
            return "ok"
        })
        _ = try await brain.rewrite(text, profile: .message, lexicon: [], examples: [])
        #expect(box.instructions == SystemBrain.instructions(.message, []))
        #expect(box.prompt == SystemBrain.prompt(text, []))
    }

    @Test func slowInferenceThrowsBrainBudgetExceeded() async {
        let brain = SystemBrain(
            budget: .milliseconds(200),
            inference: { _, _ in
                try await Task.sleep(for: .seconds(5))
                return ""
            }
        )
        do {
            _ = try await brain.rewrite("hello", profile: .message, lexicon: [], examples: [])
            Issue.record("expected PikoError.brainBudgetExceeded")
        } catch PikoError.brainBudgetExceeded(let milliseconds) {
            #expect(milliseconds == 200)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func brainUnavailablePropagatesUnchanged() async {
        let brain = SystemBrain(inference: { _, _ in
            throw PikoError.brainUnavailable("no model")
        })
        do {
            _ = try await brain.rewrite("hello", profile: .message, lexicon: [], examples: [])
            Issue.record("expected PikoError.brainUnavailable")
        } catch PikoError.brainUnavailable(let reason) {
            #expect(reason == "no model")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
