// Real Foundation Models integration checks. Run only when Apple Intelligence is
// available on the test device — either an iOS 27 device with AI on, or, on Xcode 27's
// iOS 27 Simulator when the runtime advertises the model. Skipped silently on hosts
// without a usable model (macOS SPM `swift test`, older Simulators, AI-off devices).
// This closes the Phase 6 CLNP-01 and CLNP-02 device-only rows *when* the platform
// makes it possible; on hosts where it cannot, `.serialized` and `SkipCondition` keep
// the suite from falsely failing.

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

@Suite("Foundation Models integration (device-condition-gated)")
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

    @Test("rewrite runs against the real SystemLanguageModel when available")
    func realRewriteRunsWhenModelAvailable() async throws {
        guard #available(iOS 27.0, *), FoundationModelsProbe.isAvailable else {
            print("[FM] SystemLanguageModel unavailable on this host. Skipping.")
            return
        }
        // Real inference, no mock. Use SystemBrain's own default inference path.
        let brain = SystemBrain(budget: .milliseconds(2_000))
        let out = try await brain.rewrite(
            "um hello there",
            profile: .message,
            lexicon: [],
            examples: []
        )
        #expect(!out.isEmpty)
        #expect(!out.lowercased().hasPrefix("um "))
    }

    @Test("CLNP-02 60-word input completes within 2000ms budget when model available")
    func realSixtyWordCleanupWithinExtendedBudget() async throws {
        guard #available(iOS 27.0, *), FoundationModelsProbe.isAvailable else {
            print("[FM] SystemLanguageModel unavailable on this host. Skipping.")
            return
        }
        let brain = SystemBrain(budget: .milliseconds(2_000))
        let start = ContinuousClock().now
        let out = try await brain.rewrite(
            Self.sixtyWordInput,
            profile: .message,
            lexicon: [],
            examples: []
        )
        let elapsed = ContinuousClock().now - start
        let ms = Int(elapsed.components.seconds * 1_000
                   + elapsed.components.attoseconds / 1_000_000_000_000_000)
        print("[FM] CLNP-02 60-word rewrite: \(ms)ms. Output length: \(out.count) chars.")
        #expect(ms <= 2_000, "60-word rewrite must complete within extended 2000ms budget")
        #expect(!out.isEmpty)
    }
}
#endif
