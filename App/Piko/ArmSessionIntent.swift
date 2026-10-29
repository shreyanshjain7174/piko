import AppIntents
import Foundation

/// The single arming entry point for Back Tap, the Action Button and the Control Center /
/// Lock Screen control. `openAppWhenRun = true` satisfies CONSTRAINTS.md C2 the same way a
/// manual icon tap does — see decision checkpoint in 03-03-PLAN.md and Spike 6 in docs/SPIKES.md.
/// Compiled into the widget extension so the control can reference it; the system runs
/// `perform()` in the app process, which is the only target that defines `PIKO_APP`.
struct ArmSessionIntent: AppIntent {
    // `let`, not `var` — Swift 6 strict concurrency rejects nonisolated mutable static state;
    // AppIntent's requirements are get-only, so `let` satisfies them without a compile error.
    static let title: LocalizedStringResource = "Arm Piko"
    static let description = IntentDescription("Get Piko ready so the Piko keyboard mic can dictate.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        #if PIKO_APP
        try await AppComposition.shared.get().armSession()
        #endif
        return .result()
    }
}
