import AppIntents

/// Registers `ArmSessionIntent` with Siri/Spotlight/Shortcuts — the mechanism Settings ->
/// Accessibility -> Touch -> Back Tap and Settings -> Action Button both read from.
struct PikoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ArmSessionIntent(),
            phrases: ["Arm \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Arm Piko",
            systemImageName: "mic.fill"
        )
    }
}
