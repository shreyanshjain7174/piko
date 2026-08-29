---
phase: piko-03-armed-session
plan: 03
subsystem: app-intents
tags: [appintents, back-tap, action-button, swift6-concurrency, xcodegen]

requires: ["03-01"]
provides:
  - "ArmSessionIntent: the sole AppIntent entry point Back Tap and the Action Button can reach"
  - "PikoShortcuts: AppShortcutsProvider registering ArmSessionIntent for Siri/Spotlight/Shortcuts/Settings pickers"
  - "docs/SPIKES.md Spike 6: device-verification checklist for the openAppWhenRun mechanism (not yet run)"
affects: ["piko-03-armed-session (Phase 4+ should not treat SESS-02/SESS-03 as settled until Spike 6 is run on a physical device)"]

tech-stack:
  added: []
  patterns:
    - "AppIntent static protocol requirements (title, openAppWhenRun) declared as `static let`, not `static var` — Swift 6 strict concurrency rejects nonisolated mutable static state; both requirements are get-only, so `let` satisfies them with no behavior change"
    - "AppIntent.perform() as a pure two-line pass-through to the app's single arm() implementation — no second arming code path, no FSM logic in App/Piko"

key-files:
  created:
    - App/Piko/ArmSessionIntent.swift
    - App/Piko/PikoShortcuts.swift
  modified:
    - docs/SPIKES.md

key-decisions:
  - "checkpoint:decision (openAppWhenRun strategy) resolved to 'foreground-intent' — custom ArmSessionIntent with openAppWhenRun = true. No human was available in this autonomous run; applied the plan's own explicitly stated recommended option, since 03-RESEARCH.md's Assumptions Log (A1) identifies it as the only option with a sourced, HIGH-confidence path to CONSTRAINTS.md C2 compliance (foregrounding the app before perform() runs, same as a manual icon tap). The other two options (plain-shortcut, background-intent) were not applicable: plain-shortcut gives up the single-gesture arm flow SESS-02/SESS-03 ask for, and background-intent directly contradicts C2's sourced exception list. This decision is provisional pending the device-verification checkpoint below and should be revisited if Spike 6's eventual on-device result contradicts the MEDIUM-confidence assumption it rests on."
  - "checkpoint:human-verify (physical-device Back Tap/Action Button binding) was explicitly SKIPPED, not fabricated. No physical iPhone was available in this session, and per 03-RESEARCH.md's Environment Availability table there is no Simulator or CI equivalent for either trigger. docs/SPIKES.md's new Spike 6 entry records this honestly as 'not run this session' rather than inventing a pass."
  - "Rule 1 auto-fix: 'static var openAppWhenRun'/'static var title' as written in the plan fail to compile under this project's SWIFT_STRICT_CONCURRENCY: complete setting (nonisolated mutable global static state). Changed both to 'static let' per the compiler's own suggested fix — AppIntent's protocol requirements are get-only, so this is a pure compile-fix with no behavior change. Documented here since it diverges from the plan's literal 'static var openAppWhenRun: Bool = true' text, though the effective behavior (openAppWhenRun is true) is unchanged."

requirements-completed: []

duration: ~25min
completed: 2026-08-29
---

# Phase piko-03 Plan 03: ArmSessionIntent + PikoShortcuts Summary

**Custom `AppIntent` (`ArmSessionIntent`, `openAppWhenRun = true`) and its `AppShortcutsProvider`
registration (`PikoShortcuts`) exist and compile clean, giving Back Tap and the Action Button
their only reachable entry point into `arm()`. Physical-device verification of the actual
Back Tap / Action Button binding is explicitly NOT done — that requires a human with a real
iPhone and is recorded as an open gap, not fabricated.**

## What Is Code-Complete (done in this session)

- **Decision checkpoint** (openAppWhenRun strategy): resolved to the plan's recommended
  `foreground-intent` option. See `key-decisions` above for full rationale — applied
  autonomously per the user's explicit instruction, since no human was available to confirm.
- **Task 1** — `App/Piko/ArmSessionIntent.swift`: `struct ArmSessionIntent: AppIntent` with
  `static let title = "Arm Piko"`, `static let openAppWhenRun = true`, and a `perform()` whose
  entire body is `try await AppComposition.shared.session.arm(); return .result()` — the exact
  same `arm()` the in-app Arm button calls, no second code path.
- **Task 1** — `App/Piko/PikoShortcuts.swift`: `struct PikoShortcuts: AppShortcutsProvider`
  exposing one `AppShortcut(intent: ArmSessionIntent(), phrases: [...], shortTitle: "Arm Piko",
  systemImageName: "mic.fill")` — the registration Settings' Back Tap and Action Button pickers
  read from.
- **Task 2** — `docs/SPIKES.md` gained a new Spike 6 entry (Back Tap / Action Button arming via
  App Intents) with an honest, non-fabricated Result: not run this session, no device available.
  Spikes 1-5 are unmodified.
- **Verification run:**
  - `swift build` — exits 0 (App/Piko is an Xcode-target directory, not part of the SPM
    `Package.swift` graph, so this was expected to be a no-op for these two files; confirmed
    unaffected).
  - Best-effort secondary check per the plan's own acceptance criteria: `xcodegen generate` in
    `App/`, then `xcodebuild -project Piko.xcodeproj -scheme Piko -destination
    'generic/platform=iOS Simulator' build` — **initially FAILED** (Rule 1 bug, see
    `key-decisions`), fixed by changing `static var` to `static let` on both `title` and
    `openAppWhenRun`, then **BUILD SUCCEEDED**.
  - `grep -c "Spike 6" docs/SPIKES.md` → `1` (Task 2's automated verify, passed).
  - Full-project `swift test`: 15 tests, 13 passed, 2 pre-existing failures
    (`RoundTripLatencyTests`, `ReconnectionSurvivalTests`) — both are the known,
    already-documented environment limitations (unsigned SPM test environment cannot create/read
    the App Group container), unrelated to this plan's changes and explicitly excluded from scope
    per this session's instructions. No regression introduced.

## What Is NOT Done — Requires a Human With a Physical iPhone

- **The `checkpoint:human-verify` task (device verification) was SKIPPED, not performed, not
  faked.** No physical device was available to this autonomous session, and per
  `03-RESEARCH.md`'s Environment Availability table there is no Simulator or CI substitute for
  either Back Tap or the Action Button.
- **SESS-02 and SESS-03 are NOT marked complete.** Only the code/registration work
  (`ArmSessionIntent`, `PikoShortcuts`) is done. The requirement that Back Tap and the Action
  Button actually invoke `arm()` on a real device — and that `openAppWhenRun = true` is in fact
  sufficient and necessary, per `03-RESEARCH.md` Assumptions Log A1 (MEDIUM confidence) — remains
  unverified.
- A human must: build+install Piko on a physical iPhone (`DEVELOPMENT_TEAM` in
  `App/project.yml` is currently blank and must be filled in first), bind "Arm Piko" to Back Tap
  (Settings -> Accessibility -> Touch -> Back Tap) and, on an iPhone 15 Pro+, the Action Button
  (Settings -> Action Button -> Shortcut), trigger both, and update `docs/SPIKES.md`'s Spike 6
  **Result:** line with the actual outcome (pass / fail-with-reason / device-unavailable).
- If that on-device result contradicts the `openAppWhenRun = true` assumption (e.g. `arm()`
  throws `PikoError.notForeground`, or Back Tap/Action Button don't foreground the app as
  expected), the architectural decision recorded above must be revisited before Phase 4+ treats
  SESS-02/SESS-03 as settled — this is an explicit, tracked open gap, not a silent one.

## Task Commits

Each task was committed atomically:

1. **Task 1: ArmSessionIntent + PikoShortcuts (+ decision checkpoint recorded)** - `01157d5` (feat)
2. **Task 2: Spike 6 device-verification entry in docs/SPIKES.md** - `cce4ec7` (docs)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## Self-Check: PASSED

- FOUND: App/Piko/ArmSessionIntent.swift
- FOUND: App/Piko/PikoShortcuts.swift
- FOUND: docs/SPIKES.md (Spike 6 entry present, Spikes 1-5 unmodified)
- FOUND commit 01157d5
- FOUND commit cce4ec7
