import AppIntents
import Foundation
import PikoKit
import PikoBridge

/// C5-documented exception path: a LiveActivityIntent runs without foregrounding the app.
/// The app is backgrounded while the notch is visible, so the request is written durably
/// (the app polls it) and the Darwin notification is only the fast path.
struct StopSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop"

    func perform() async throws -> some IntentResult {
        try? StopRequestStore()?.write(StopRequest())
        DarwinChannel()?.post(.stopRequested)
        return .result()
    }
}
