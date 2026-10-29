import AppIntents

/// Registers Piko's intents with Siri/Spotlight/Shortcuts — the mechanism Settings ->
/// Action Button, Back Tap and Control Center read from.
struct PikoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: ["Talk to \(.applicationName)", "Tell \(.applicationName)"],
            shortTitle: "Talk to Piko",
            systemImageName: "bubble.left.and.text.bubble.right.fill"
        )
        AppShortcut(
            intent: ArmSessionIntent(),
            phrases: ["Arm \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Arm Piko keyboard",
            systemImageName: "mic.fill"
        )
    }
}
