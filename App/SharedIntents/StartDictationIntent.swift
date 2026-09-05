import AppIntents
import PikoBridge
import PikoKit

/// Foregrounds the container app before microphone activation. The intent is compiled into
/// both targets, while `openAppWhenRun` makes the system execute it in the app process.
struct StartDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Open Piko and start on-device dictation.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        guard let store = CaptureLaunchRequestStore(),
              let channel = DarwinChannel() else {
            throw CaptureLaunchIntentError.appGroupUnavailable
        }

        try store.write(CaptureLaunchRequest())
        channel.post(.captureRequested)
        return .result()
    }
}

private enum CaptureLaunchIntentError: Error {
    case appGroupUnavailable
}
