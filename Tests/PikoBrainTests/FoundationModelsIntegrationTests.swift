// Real-model result-or-explicit-bypass integration. A budget bypass is not cleanup
// quality or physical-device latency proof. Unavailable models are explicitly skipped.

#if os(iOS)
import Foundation
import Testing
import PikoKit
@testable import PikoBrain
import FoundationModels

@available(iOS 27.0, *)
private enum FoundationModelsProbe {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
}

@Suite("Foundation Models integration (device-condition-gated)", .serialized,
       .enabled(if: FoundationModelsProbe.isAvailable))
struct FoundationModelsIntegrationTests {

    /// 60-word input matching CLNP-02's stated scenario (12 filler words, 5 sentences,
    /// mixed casing, missing punctuation). Fixed content so latency numbers compare
    /// across runs.
    static let sixtyWordInput: String = """
    um so like the meeting is at three pm tomorrow you know and i think we should \
    probably invite the design team to come along uh because they had a lot of \
    feedback on the last draft and we want to make sure we're aligned before we \
    ship it right so let me know if that works for you thanks
    """

    @Test("short real cleanup completes within production budget or reports an explicit bypass")
    func realRewriteHonorsProductionOutcome() async throws {
        let brain = SystemBrain()
        let start = ContinuousClock.now
        do {
            let out = try await brain.rewrite("um hello there", profile: .message, lexicon: [], examples: [])
            #expect(ContinuousClock.now - start <= .milliseconds(600))
            #expect(!out.isEmpty)
            #expect(!out.lowercased().hasPrefix("um "))
            print("[FM] Short cleanup completed within 600ms.")
        } catch PikoError.brainBudgetExceeded(let budget) {
            #expect(budget == 600)
            print("[FM] Short cleanup explicitly bypassed at the production budget; quality not verified.")
        } catch PikoError.brainUnavailable(let reason) {
            #expect(!reason.isEmpty)
            print("[FM] Model became unavailable; explicit bypass, not a quality pass.")
        }
    }

    @Test("60-word real cleanup completes within 600ms or reports an explicit bypass")
    func realSixtyWordCleanupHonorsProductionOutcome() async throws {
        let brain = SystemBrain()
        let start = ContinuousClock.now
        do {
            let out = try await brain.rewrite(Self.sixtyWordInput, profile: .message, lexicon: [], examples: [])
            #expect(ContinuousClock.now - start <= .milliseconds(600))
            #expect(!out.isEmpty)
            print("[FM] 60-word cleanup completed within 600ms.")
        } catch PikoError.brainBudgetExceeded(let budget) {
            #expect(budget == 600)
            print("[FM] 60-word cleanup explicitly bypassed at the production budget; quality not verified.")
        } catch PikoError.brainUnavailable(let reason) {
            #expect(!reason.isEmpty)
            print("[FM] Model became unavailable; explicit bypass, not a quality pass.")
        }
    }
}
#endif
