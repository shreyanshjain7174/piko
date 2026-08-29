import SwiftUI
import PikoKit

@main
struct PikoApp: App {
    var body: some Scene {
        WindowGroup { ArmView() }
    }
}

/// The only screen in v0.1. Its whole job is to be on screen long enough to legally open the
/// microphone and start the Live Activity — then get out of the way.
struct ArmView: View {
    @State private var phaseText: String = "idle"
    @State private var armError: String?
    @State private var hasArmedThisLaunch = false
    @State private var staleAtLaunch = false

    private var showReArmBanner: Bool {
        (hasArmedThisLaunch && phaseText == "idle") || staleAtLaunch
    }

    var body: some View {
        // TODO: history list, skin picker.
        VStack(spacing: 16) {
            Text("Piko")
            Text("Session: \(phaseText)")
            if showReArmBanner {
                Text("Session ended — tap Arm to re-arm")
            }
            Button("Arm") {
                Task {
                    do {
                        try await AppComposition.shared.session.arm()
                        hasArmedThisLaunch = true
                        staleAtLaunch = false
                        armError = nil
                    } catch {
                        armError = "\(error)"
                    }
                }
            }
            if let armError {
                Text(armError)
            }
        }
        .task {
            // Process-kill sub-case: reuse Phase 1's existing staleness rule, no new heuristic.
            if let state = AppComposition.shared.channel.readState(), !state.isLive() {
                staleAtLaunch = true
            }
        }
        .task {
            for await phase in AppComposition.shared.session.phase {
                phaseText = phase.rawValue
            }
        }
    }
}
