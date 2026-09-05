import SwiftUI

@main
struct PikoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup { RootView() }
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await AppComposition.shared.handlePendingCaptureRequest() }
            }
    }
}
