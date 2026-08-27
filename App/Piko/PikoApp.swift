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
    var body: some View {
        // TODO: arm button, session state, history list, skin picker.
        Text("Piko")
    }
}
