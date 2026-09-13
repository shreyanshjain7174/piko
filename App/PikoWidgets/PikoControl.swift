import AppIntents
import WidgetKit
import SwiftUI
import PikoKit
import PikoBridge

/// Control Center / Lock Screen / Action Button — the user's own hardware shortcut key.
/// C2 honored exactly like the Island's Start button: `openAppWhenRun` foregrounds the
/// app, which owns the mic session; the request is also written durably so a cold app
/// picks it up on activation.
struct StartDictationControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Dictate with Piko"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        guard let store = CaptureLaunchRequestStore(), let channel = DarwinChannel() else {
            return .result()
        }
        try? store.write(CaptureLaunchRequest())
        channel.post(.captureRequested)
        return .result()
    }
}

/// The one control, everywhere a control can live: Control Center, the Lock Screen and
/// (on iOS 18+) the Action Button.
struct PikoDictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PikoDictationControl") {
            ControlWidgetButton(action: StartDictationControlIntent()) {
                Label("Dictate", systemImage: "mic.fill")
            }
        }
        .displayName("Piko Dictation")
    }
}
