import AppIntents
import Foundation
import PikoKit
import PikoBridge

/// Shared with both targets so ActivityKit can execute this inside the app process.
struct StopSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop"

    func perform() async throws -> some IntentResult {
        #if PIKO_APP
        // Runs in the app process: stop directly instead of relying on a notification round trip.
        try await AppComposition.shared.get().stopFromLiveActivity()
        #else
        guard let channel = DarwinChannel() else { throw PikoError.sharedContainerUnavailable }
        channel.post(.stopRequested)
        #endif
        return .result()
    }
}
