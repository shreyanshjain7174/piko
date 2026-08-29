import SwiftUI

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

    var body: some View {
        // TODO: history list, skin picker.
        VStack(spacing: 16) {
            Text("Piko")
            Text("Session: \(phaseText)")
            Button("Arm") {
                Task {
                    do {
                        try await AppComposition.shared.session.arm()
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
            for await phase in AppComposition.shared.session.phase {
                phaseText = phase.rawValue
            }
        }
    }
}
