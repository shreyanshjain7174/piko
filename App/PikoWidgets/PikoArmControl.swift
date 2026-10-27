import AppIntents
import SwiftUI
import WidgetKit

/// One press from Control Center or the Lock Screen opens Piko already listening.
struct PikoArmControl: ControlWidget {
    static let kind = "dev.shreyansh.Piko.arm"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartDictationIntent()) {
                Label("Talk to Piko", systemImage: "bubble.left.and.text.bubble.right.fill")
            }
        }
        .displayName("Talk to Piko")
        .description("Open Piko already listening. It files what you say on this iPhone.")
    }
}
