import AppIntents
import Foundation
import PikoKit
import PikoBridge

/// C5-documented exception path: a LiveActivityIntent runs without foregrounding the app,
/// unlike ArmSessionIntent's openAppWhenRun = true.
struct StopSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop"

    func perform() async throws -> some IntentResult {
        DarwinChannel()!.post(.stopRequested)
        return .result()
    }
}
