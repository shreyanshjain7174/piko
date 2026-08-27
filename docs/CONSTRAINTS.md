# Constraints

Load-bearing facts about what iOS permits. Every design decision downstream traces to one of
these. Re-verify each on a physical device before it becomes load-bearing in code — this list
was assembled from documentation and developer-forum evidence, not from our own device runs.

| # | Constraint | Status | Consequence |
|---|---|---|---|
| C1 | A keyboard extension cannot open the microphone | **Blocked** | Runtime refuses: `was NOT allowed to start recording because it is an extension and doesn't have entitlements to record audio`. Apple's keyboard docs have said "no access to the device microphone, so dictation input is not possible" since iOS 8. Full Access does not unlock it. |
| C2 | Nothing may *start* a recording session from the background | **Blocked** | Apple DTS: only CallKit, LiveCommunicationKit and PushToTalk may activate a recording session in the background, and those are for communication apps. A Bluetooth button buys no exception. |
| C3 | A session activated in the foreground *continues* in the background | **Allowed** | With the `audio` background mode. This asymmetry is the entire product. |
| C4 | Keyboard extension memory ceiling ≈ 60 MB | **Hard** | Exceed it and jetsam kills the keyboard with no crash log. No model, no audio buffers, no index in that process. |
| C5 | `Activity.request()` requires the foreground | **Conditional** | Background start throws `ActivityAuthorizationError.visibility` / "Target is not foreground". Exceptions: an intent the user fired from a widget, Shortcut or Siri, and APNs push-to-start. |
| C6 | Live Activity lifetime: 8 h active + 4 h stale | **Fixed** | Longer than a working day. Start it at arm time. |
| C7 | A keyboard cannot learn which app hosts it | **Blocked** | No host bundle ID. Per-app tone must come from field traits plus an explicit user choice. |
| C8 | Secure and numeric fields exclude third-party keyboards | **Fixed** | Password, phone, decimal and email-address fields fall back to the system keyboard. Do not promise "every field". |
| C9 | No cross-app actuation | **Blocked** | Siri is the only orchestrator of other apps' App Intents. There is no public API for one app to run another's intents. "Do" mode means system frameworks plus our own network tools, nothing more. |
| C10 | No persistent background agent | **Fixed** | `BGTaskScheduler` grants opportunistic minutes per day, not a daemon. Piko acts when invoked. |

## What each constraint forces

- C1 + C2 + C3 → the **armed session** architecture. See `ARCHITECTURE.md`.
- C4 → all inference lives in the container app. The keyboard is a remote control and a text sink.
- C5 + C6 → the Live Activity starts at arm time, in the foreground, and lives all day.
- C7 → profile chips in the keyboard accessory row, not host-app detection.
- C9 + C10 → "companion for all tasks" means our own tools, not driving other apps.

## Sources

- Apple Developer Forums — [Recording audio in keyboard extension](https://developer.apple.com/forums/thread/742601)
- Apple Developer Forums — [Error 561145187, recording from a keyboard extension](https://developer.apple.com/forums/thread/775077)
- Apple Developer Forums — [Can I trigger AudioRecordingIntent from a Bluetooth device](https://developer.apple.com/forums/thread/816408)
- Apple Developer Forums — [Can't create a Live Activity from background](https://developer.apple.com/forums/thread/818467)
- Apple — [App Extension Programming Guide: Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
- [The three hard constraints of an iOS keyboard extension](https://dev.to/tbds_2dadf2b626f315902eae/the-three-hard-constraints-of-an-ios-keyboard-extension-46af)
- 9to5Mac — [Wispr Flow's iPhone keyboard](https://9to5mac.com/2025/06/30/wispr-flow-is-an-ai-that-transcribes-what-you-say-right-from-the-iphone-keyboard/) (the "Flow Session" bounce — prior art for C3)
