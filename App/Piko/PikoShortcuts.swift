import AppIntents

/// Registers the intents with Siri/Spotlight/Shortcuts — the mechanism Settings ->
/// Accessibility -> Touch -> Back Tap and Settings -> Action Button both read from.
/// "Arm" prepares the session; "Dictate" arms and starts listening in one step.
struct PikoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ArmSessionIntent(),
            phrases: ["Arm \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Arm Piko",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: ["Dictate with \(.applicationName)"],
            shortTitle: "Dictate",
            systemImageName: "waveform"
        )
    }
}
