import AppIntents
import Foundation

/// The only entry point Back Tap and the Action Button can reach. `openAppWhenRun = true`
/// satisfies CONSTRAINTS.md C2 the same way a manual icon tap does — see decision checkpoint
/// in 03-03-PLAN.md and Spike 6 in docs/SPIKES.md.
struct ArmSessionIntent: AppIntent {
    // `let`, not `var` — Swift 6 strict concurrency rejects nonisolated mutable static state;
    // AppIntent's requirements are get-only, so `let` satisfies them without a compile error.
    static let title: LocalizedStringResource = "Arm Piko"
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await AppComposition.shared.session.arm()
        return .result()
    }
}
