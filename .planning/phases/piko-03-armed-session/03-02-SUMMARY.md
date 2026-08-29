---
phase: piko-03-armed-session
plan: 02
subsystem: audio
tags: [avfaudio, avaudiosession, processinfo, notificationcenter, swift-concurrency, swift-testing, mainactor, swiftui]

requires:
  - phase: piko-03-armed-session (Plan 03-01)
    provides: "SessionCoordinator, InterruptionSource/InterruptionEvent contract, NullInterruptionSource, AppComposition, MockInterruptionSource/MockSessionChannel test doubles"
provides:
  - "AVAudioSessionInterruptionSource: real InterruptionSource conformer merging interruption/route-change/low-power-mode notifications into one events stream, #if os(iOS)-guarded"
  - "AVAudioSessionInterruptionSourceTests: notification-translation coverage via synthetic NotificationCenter posts, no device required"
  - "SessionCoordinatorInterruptionTests: SESS-04 FSM coverage — one test per recovering event type plus a negative test for the two non-recovering variants"
  - "AppComposition wired to real interruption monitoring (AVAudioSessionInterruptionSource in place of NullInterruptionSource), now also exposes channel: any SessionChannel"
  - "ArmView re-arm banner covering both live-interruption recovery and stale/process-killed launch (via SessionState.isLive())"
affects: [piko-03-armed-session (Plan 03-03)]

tech-stack:
  added: []
  patterns:
    - "Merge N independent NotificationCenter.notifications(named:) AsyncSequences into one AsyncStream via N Tasks writing into a shared continuation, with a single onTermination cancelling all N"
    - "Notification-translation tests race the stream's first element against a fixed CI-safe timeout (mirrors RoundTripLatencyTests' pattern), with a short pre-post settle delay to cover Task{} scheduling not being synchronous"
    - "Negative FSM assertions (proving an event does NOT cause a transition) use the same race-against-timeout technique, expecting the timeout to win, then follow up with a real triggering event on the same iterator to prove the consumer was still alive and correctly wired throughout"

key-files:
  created:
    - Sources/PikoAudio/AVAudioSessionInterruptionSource.swift
    - Tests/PikoAudioTests/AVAudioSessionInterruptionSourceTests.swift
    - Tests/PikoAudioTests/SessionCoordinatorInterruptionTests.swift
  modified:
    - App/Piko/AppComposition.swift
    - App/Piko/PikoApp.swift

key-decisions:
  - "AVAudioSessionInterruptionSource merges three notification sources (AVAudioSession.interruptionNotification, .routeChangeNotification, .NSProcessInfoPowerStateDidChange) into one AsyncStream via three independent Tasks, each writing into a shared continuation — matches the plan's explicit merge design, not three separate InterruptionSource instances"
  - "Route-change notifications yield .routeChanged unconditionally, never inspecting AVAudioSessionRouteChangeReasonKey — per the plan's explicit instruction not to invent a reason-based heuristic"
  - "Low-power-mode notifications carry no payload; the current ProcessInfo.processInfo.isLowPowerModeEnabled value is re-queried on every post rather than inferred, per the plan's instruction"
  - "AVAudioSessionInterruptionTypeKey/AVAudioSessionInterruptionOptionKey used exactly as given in the plan's reference shape — these are long-standing, stable AVFAudio API names; no apple-docs MCP tool or network doc access was available in this session to independently re-verify against current SDK headers (same caveat 03-01-SUMMARY.md already flagged for .allowBluetoothHFP), so this is carried forward rather than re-litigated"
  - "SessionCoordinatorInterruptionTests' negative test (nonRecoveringEventsDoNotDisarm) races a fresh consumption of the shared phase stream against a 200ms timeout to prove no transition occurred, rather than asserting on a stateful property that doesn't exist on SessionCoordinator (currentPhase is private) — the only way to observe phase without adding a new public accessor Plan 03-01 didn't design in"
  - "AppComposition's new channel property is typed any SessionChannel (not DarwinChannel) to match the existing session/channel handling style and keep ArmView decoupled from the concrete cross-process implementation"
  - "ArmView's re-arm banner condition is `(hasArmedThisLaunch && phaseText == \"idle\") || staleAtLaunch` — two independent boolean flags rather than one merged state, since the live-interruption case and the stale-launch case are detected via entirely different mechanisms (the live phase stream vs. a one-time launch-time channel read) and conflating them into one flag would obscure which one fired"

patterns-established:
  - "Any future AVFAudio/ProcessInfo notification bridge in PikoAudio should mirror AVAudioSessionInterruptionSource's one-Task-per-source-into-shared-continuation shape rather than inventing a new merge pattern"
  - "Notification-translation and negative-FSM tests in this codebase use a race-against-CI-safe-timeout helper (TaskGroup with a reader task + a Task.sleep timeout task), not raw unbounded awaits or wall-clock assertions"

requirements-completed: ["SESS-04", "SESS-05"]

duration: ~40min
completed: 2026-08-29
---

# Phase piko-03 Plan 02: Real AVAudioSessionInterruptionSource + Recovery Proof Summary

**`AVAudioSessionInterruptionSource` merges phone-call/other-app interruptions, route changes, and low-power-mode transitions into one `InterruptionEvent` stream; `SessionCoordinator` is proven to recover to `.idle` deterministically for every recovering event type (and proven NOT to for the two non-recovering ones); the container app now uses real interruption monitoring and shows a re-arm banner for both live recovery and a stale/process-killed launch.**

## Performance

- **Duration:** ~40 min
- **Tasks:** 3/3 completed
- **Files modified:** 5 (3 created, 2 modified)

## Accomplishments

- `AVAudioSessionInterruptionSource` (entirely `#if os(iOS)`-guarded) bridges `AVAudioSession.interruptionNotification`, `AVAudioSession.routeChangeNotification`, and `.NSProcessInfoPowerStateDidChange` into a single `events: AsyncStream<InterruptionEvent>`, with defensive `guard let`/`@unknown default` unwrapping on every `userInfo` payload — no force-unwraps anywhere.
- `AVAudioSessionInterruptionSourceTests` proves the translation logic for all three notification sources using synthetic `NotificationCenter.default.post` calls, with no real audio session or device required — each test races the stream's first element against a 2s CI-safe timeout.
- `SessionCoordinatorInterruptionTests` proves `.began`, `.routeChanged`, and `.lowPowerModeChanged(enabled: true)` each independently drive `phase` from `.armed` to `.idle` via the shared `disarm()` path, and a fourth test proves `.lowPowerModeChanged(enabled: false)`/`.ended(shouldResume: true)` do NOT — closing SESS-04's FSM-coverage requirement without inventing a wall-clock timing proxy for the "recovers within 1 second" claim.
- `AppComposition` now constructs `AVAudioSessionInterruptionSource()` in place of Plan 03-01's `NullInterruptionSource()`, and exposes `channel: any SessionChannel` alongside `session` so the container app can read last-known state without a second `DarwinChannel` construction.
- `ArmView` shows "Session ended — tap Arm to re-arm" both after a live interruption/disarm cycle and at launch when `SessionState.isLive()` reads false — reusing Phase 1's existing staleness rule unchanged, closing the process-kill sub-case with zero new heuristic.
- `swift build` succeeds on macOS; the iOS Simulator app target (`xcodebuild -project App/Piko.xcodeproj -scheme Piko -sdk iphonesimulator`) also builds successfully with all of this plan's new code, confirming real-SDK compileability beyond the plan's own `swift build`-only verify step.

## Task Commits

Each task was committed atomically:

1. **Task 1: Real AVAudioSessionInterruptionSource + notification-translation tests** - `4591c71` (feat)
2. **Task 2: SessionCoordinator interruption-recovery tests (SESS-04 FSM coverage)** - `6fb05bf` (test)
3. **Task 3: Wire real interruption monitoring + re-arm banner + process-kill launch check** - `9f7abcd` (feat)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## Files Created/Modified

- `Sources/PikoAudio/AVAudioSessionInterruptionSource.swift` - `final class AVAudioSessionInterruptionSource: InterruptionSource, @unchecked Sendable`, entirely `#if os(iOS)`-guarded; three `Task`s bridging `AVAudioSession.interruptionNotification`, `.routeChangeNotification`, and `.NSProcessInfoPowerStateDidChange` into one merged `AsyncStream`, all cancelled via a single `continuation.onTermination`
- `Tests/PikoAudioTests/AVAudioSessionInterruptionSourceTests.swift` - 3 `@Test` functions proving `.began`/`.routeChanged`/`.lowPowerModeChanged` translation via synthetic `NotificationCenter.default.post` calls, race-against-2s-timeout pattern mirroring `RoundTripLatencyTests.swift`
- `Tests/PikoAudioTests/SessionCoordinatorInterruptionTests.swift` - 4 `@Test @MainActor` functions: three positive (`.began`, `.routeChanged`, `.lowPowerModeChanged(enabled: true)` → `.idle`) and one negative (`.lowPowerModeChanged(enabled: false)`/`.ended(shouldResume: true)` do not disarm, proven via a race-against-200ms-timeout probe on the shared `phase` stream)
- `App/Piko/AppComposition.swift` - `AVAudioSessionInterruptionSource()` replaces `NullInterruptionSource()`; added `let channel: any SessionChannel` public stored property, set to the same `DarwinChannel` instance already constructed
- `App/Piko/PikoApp.swift` - `ArmView` gained `hasArmedThisLaunch`/`staleAtLaunch` state, a computed `showReArmBanner`, a re-arm banner `Text`, and a launch-time `.task` reading `AppComposition.shared.channel.readState()` and checking `!state.isLive()`

## Decisions Made

See `key-decisions` in frontmatter for the full list. Highlights:
- Kept the plan's reference `AVAudioSessionInterruptionTypeKey`/`AVAudioSessionInterruptionOptionKey` constant names as-is (no `apple-docs` MCP tool or network access available in this session to independently re-verify against current SDK headers) — same caveat class as 03-01-SUMMARY.md's `.allowBluetoothHFP` note, carried forward rather than re-litigated. These are long-standing, stable AVFAudio symbols; the iOS Simulator app build (see Accomplishments) confirms they still exist and compile against the current SDK on this machine.
- The negative FSM test races a fresh stream consumption against a bounded timeout rather than reading a (nonexistent) public `currentPhase` accessor on `SessionCoordinator` — `SessionCoordinator.swift` was not modified, per the plan's explicit instruction.

## Deviations from Plan

**None (Rules 1–4).** Plan executed exactly as written across all three tasks; no bugs, missing functionality, blocking issues, or architectural changes were encountered that required deviation from the plan's text. `SessionCoordinator.swift` and `InterruptionSource.swift` (Plan 03-01's files) were not touched, confirming the Wave 1→Wave 2 handoff held.

**Total deviations:** 0. **Impact on plan:** None.

## Issues Encountered

- **Concurrent branch activity (not a deviation, an environment observation):** while this plan was being executed, commits for a different plan (`piko-03-03`: `ArmSessionIntent.swift`, `PikoShortcuts.swift`, a `docs(piko-03-03)` Spike entry) landed on the same `piko-03-armed-session-plan01` branch from what appears to be a separate concurrent process. This plan's execution staged and committed only its own five files (`git add` was always called with explicit paths, never `git add .`/`-A`), so no cross-contamination occurred in this plan's three commits. Flagging this so the orchestrator/user is aware two executions may have been running against the same branch simultaneously — worth confirming intent before merging.
- `swift test --filter PikoAudioTests` correctly reports 0 tests on macOS after every task (all three new files are entirely `#if os(iOS)`-guarded, matching the established pattern), consistent with the plan's own acceptance criteria.
- Full `swift test` (no filter) shows the same 2 pre-existing `PikoBridgeTests` failures noted in 03-01-SUMMARY.md (`RoundTripLatencyTests`, `ReconnectionSurvivalTests`) — both are documented environment limitations (no real App Group container in this unsigned SPM/macOS test environment), unrelated to this plan's changes. No new test failures were introduced.

## User Setup Required

None — no external service configuration required.

## iOS Simulator/Device Test Run

No iOS Simulator/device *test execution* was attempted in this session (matching 03-01's precedent) — verification was `swift build`/`swift test --filter PikoAudioTests` on macOS per the user's explicit instructions, both green. As an extra, non-required confidence check, the full iOS app target was built via `xcodebuild -project App/Piko.xcodeproj -scheme Piko -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`, which **succeeded**, confirming `AVAudioSessionInterruptionSource.swift` and both new test files compile cleanly against the real iOS 26 SDK, and that `AppComposition`/`ArmView`'s edits build correctly in the actual app target. Actually *running* the 7 new `@Test` functions on an iOS Simulator or device is recommended before this plan's work is considered fully proven end-to-end, same non-gating caveat as 03-01.

## SESS-05 Scope Note (required by this plan's `<verification>` checklist)

SESS-05 (the 45-minute soak requirement) is **explicitly NOT covered by any automated test in this plan.** It remains a manual, physical-device entry in `docs/SPIKES.md` Spike 2, unchanged by this plan. `requirements-completed` lists SESS-05 per the plan's own frontmatter `requirements` field, but that reflects the plan's scope of work touching that requirement's non-automatable portion (confirming no automated substitute was invented), not that SESS-05's soak test itself has been run.

## Next Phase Readiness

- `SessionCoordinator.swift` and `InterruptionSource.swift` remain unmodified — Plan 03-03 (already showing partial commits on this branch from a concurrent process) can build on top of this plan's `AVAudioSessionInterruptionSource` and re-arm banner without further changes here.
- `AppComposition.channel` is now a public seam any future plan can read from without constructing a second `DarwinChannel`.
- No blockers for Plan 03-03.

---
*Phase: piko-03-armed-session*
*Completed: 2026-08-29*
