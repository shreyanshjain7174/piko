import SwiftUI
import WidgetKit

/// Missing entry point per 07-RESEARCH.md Pitfall 3 — without it the extension has no load
/// point and will not register on the Simulator or device.
@main
struct PikoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PikoLiveActivityWidget()
    }
}
