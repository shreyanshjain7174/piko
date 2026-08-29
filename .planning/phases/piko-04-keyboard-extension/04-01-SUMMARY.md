---
phase: piko-04-keyboard-extension
plan: 01
subsystem: keyboard
tags: [keyboard-extension, swiftui, uikit, sessionchannel, darwinchannel, swift-testing]

requires:
  - "PikoKit SessionState/Signal/SessionPhase + isLive()"
  - "PikoBridge DarwinChannel (post Signal, read/write SessionState)"
  - "Phase 3 armed session (idle/armed/capturing/tidying)"
provides:
  - "KeyboardView SwiftUI shell: arm banner, 4 profile chips, MicButton, globe, height 240"
  - "MicButton phase-aware SF Symbols; disabled when state is nil/idle/tidying"
  - "KeyboardViewController hosts KeyboardView via UIHostingController; DarwinChannel observe + mic posts"
  - "PikoKeyboardTests: MockSessionChannel + 4 mic-button signal-rule tests"
affects: [piko-04-keyboard-extension (Plan 04-02)]

tech-stack:
  added: []
  patterns:
    - "Keyboard is a remote control: posts .captureStart/.captureStop only; never opens the mic (CONSTRAINTS.md C1)"
    - "UIHostingController embedding of SwiftUI KeyboardView inside UIInputViewController"
    - "Phase-gated mic: armed → captureStart; capturing → captureStop; nil/stale/idle/tidying → no post"
    - "PikoKeyboardTests live in the SPM package (PikoKit-only) so signal rules run without the extension target"

key-files:
  created:
    - Tests/PikoKeyboardTests/MockSessionChannel.swift
    - Tests/PikoKeyboardTests/KeyboardViewModelTests.swift
    - App/PikoKeyboard/MicButton.swift
    - App/PikoKeyboard/KeyboardView.swift
  modified:
    - Package.swift
    - App/PikoKeyboard/KeyboardViewController.swift

key-decisions:
  - "KeyboardViewModel lives in PikoKeyboardTests (Task 1), not the extension target — Task 2 is UI-only; KeyboardViewController implements the same phase rules inline"
  - "Used xcodebuild -scheme Piko-Package (not per-module schemes) because package-module schemes have no test action"
  - "Simulator destination: iPhone 17 iOS 26.0 (UDID 6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4), not the plan's iPhone 16 Pro iOS 18.6 UDID"
  - "CAPT-01 is listed in this plan's frontmatter but is streaming insertion (Plan 04-02) — not marked complete here"
  - "Full Access missing still shows 'Open Piko to arm', not a Settings prompt — keyboard cannot open Settings from the extension"

patterns-established:
  - "Extension UI lives under App/PikoKeyboard/; signal-rule tests live under Tests/PikoKeyboardTests/ depending only on PikoKit"
  - "When UIView? coalescing (inputView ?? view) still types as UIView?, bind `let canvas: UIView = inputView ?? view` before adding the host view"

requirements-completed: ["BRDG-01"]
requirements-not-completed: ["CAPT-01"]

duration: ~10min
completed: 2026-08-29
---

# Phase piko-04 Plan 01: Keyboard UI Shell + Mic Remote Control Summary

**Keyboard extension UI shell with a phase-aware mic button that posts `.captureStart` / `.captureStop` over `SessionChannel` — remote control for an already-armed container session (BRDG-01), not transcription or host-field insertion (CAPT-01).**

## Performance

- **Duration:** ~10 min (executor clock `2026-08-29T10:17:17Z` → `2026-08-29T10:26:39Z`)
- **Tasks:** 4/4 completed
- **Files modified:** 6 (4 created, 2 modified)

## Accomplishments

- `PikoKeyboardTests` added to `Package.swift`; `MockSessionChannel` (NSLock, in-memory `SessionChannel`) plus 4 `@Test`s: armed → `.captureStart`, capturing → `.captureStop`, nil → no post, stale (`isLive() == false`) → no post.
- `MicButton` reflects phase with SF Symbols and is disabled for nil / idle / tidying.
- `KeyboardView` is the SwiftUI root: arm banner ("Open Piko to arm" when not live), 4 profile chips, `MicButton`, globe; keyboard height 240.
- `KeyboardViewController` embeds `KeyboardView` via `UIHostingController`, constructs `DarwinChannel`, observes `stateChanged` / `draftUpdated` / `resultReady`, and posts capture signals only when the session is live. Full Access check present.
- macOS `swift build` green. iOS Simulator `Piko-Package` tests **30/30 pass** (includes 4/4 `PikoKeyboardTests`). Main `Piko` scheme **BUILD SUCCEEDED** with the keyboard target embedded.

## Task Commits

Each task was committed atomically:

1. **Task 1: PikoKeyboardTests + mic-button signal rules** - `f52cdce` (test)
2. **Task 2: KeyboardView + MicButton SwiftUI shell** - `d5877c0` (feat)
3. **Task 3: Host KeyboardView and post capture signals** - `a2fb495` (feat)
4. **Task 4: Verify** - no extra code commit (verify-only; empty files)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## Files Created/Modified

- `Package.swift` - Added `PikoKeyboardTests` test target (`dependencies: ["PikoKit"]`)
- `Tests/PikoKeyboardTests/MockSessionChannel.swift` - In-memory `SessionChannel` double (`NSLock`-protected, postedSignals)
- `Tests/PikoKeyboardTests/KeyboardViewModelTests.swift` - `KeyboardViewModel` + 4 `@Test` functions for mic signal rules
- `App/PikoKeyboard/MicButton.swift` - Phase-aware mic control
- `App/PikoKeyboard/KeyboardView.swift` - SwiftUI keyboard shell (banner, chips, mic, globe)
- `App/PikoKeyboard/KeyboardViewController.swift` - `UIInputViewController` + `UIHostingController` + DarwinChannel observe/post

## Decisions Made

- `KeyboardViewModel` stays in the test target (plan Task 1 inline test helper; Task 2 UI-only). Production path is `KeyboardViewController.micButtonTapped` with the same phase gates.
- `@Published` + `rootView` reassignment used to refresh hosted SwiftUI from UIKit observation (not a separate `ObservableObject` in the extension target).
- Test invocation: `xcodebuild test -scheme Piko-Package` from package root. Per-module schemes have no test action; plan's `xcodebuild -scheme Piko` is the app scheme (used for **build**, not package tests).
- Simulator: iPhone 17, iOS 26.0, UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4` (engineering judgment vs plan's iPhone 16 Pro / iOS 18.6 / `B79D226E…`).
- Did **not** mark CAPT-01 complete. This plan does not stream partial transcript into the host field.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `inputView ?? view` still typed as `UIView?`**
- **Found during:** Task 3
- **Issue:** Optional canvas blocked adding the hosting view; build failed.
- **Fix:** `let canvas: UIView = inputView ?? view` then attach the host view.
- **Files modified:** `App/PikoKeyboard/KeyboardViewController.swift`
- **Commit:** `a2fb495`

### Judgment / not Rule 1–3

- Simulator device: iPhone 17 iOS 26 instead of plan's iPhone 16 Pro iOS 18.6.
- Package tests via `Piko-Package` scheme; app embed via `Piko` scheme after `xcodegen generate`.
- Full Access failure still shows "Open Piko to arm" (not "Enable Full Access in Settings").
- Untracked xcodegen plists/entitlements (`App/*/Info.plist`, `App/*/Piko*.entitlements`) left uncommitted.

**Total deviations:** 1 auto-fixed (Rule 1). **Impact on plan:** Build unblocked; behavior matches intended UIKit embed.

## Issues Encountered

- macOS `swift test` (full suite, no filter): **17 passed / 2 failed / 19 total**. Failures are pre-existing `PikoBridgeTests` (`ReconnectionSurvivalTests`, `RoundTripLatencyTests`) — App Group container missing in unsigned SPM/macOS. **PikoKeyboardTests 4/4 pass** on macOS.
- iOS Simulator `Piko-Package`: **TEST SUCCEEDED**. Breakdown:
  - PikoAudioTests: 11/11
  - PikoBridgeTests: 6/6 (App Group works under signed Simulator)
  - PikoKeyboardTests: 4/4
  - PikoKitTests: 9/9
  - **Total: 30 passed, 0 failed**
- XCTest "All tests" suites printed `Executed 0 tests` (Swift Testing only) — ignored; counts above are Swift Testing runs.
- C4 ~60MB keyboard memory ceiling **not measured** this session (no Instruments / footprint capture).
- Device UI (enable keyboard, Full Access, tap mic against a live armed session) **not performed**.

## User Setup Required

None for code. Manual device/Simulator UI still required to prove the extension appears as a keyboard and drives a live session:

1. Settings → Keyboards → enable Piko, Full Access.
2. Arm in the Piko app, switch to a text field, tap mic.

## iOS Simulator/Device Test Run

**Attempted.** iPhone 17 (iOS 26.0) UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`.

| Command | Result |
|---------|--------|
| `swift build` (macOS) | succeeded |
| `swift test` (macOS) | 17 pass / 2 fail (pre-existing PikoBridge App Group); PikoKeyboardTests 4/4 pass |
| `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` | **TEST SUCCEEDED** — 30/30 Swift Testing tests |
| `xcodegen generate` + `xcodebuild -project App/Piko.xcodeproj -scheme Piko -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4' build` | **BUILD SUCCEEDED** |
| Physical device / keyboard UI tap | **not attempted** |

Do not treat BRDG-01 as device-proven. Signal rules are unit-tested; live Darwin round-trip from the extension UI is unverified.

## Next Phase Readiness

- Plan 04-02 can implement `stablePrefix` streaming insertion against this shell (`draftUpdated` already observed).
- Mic remote-control path is in `KeyboardViewController`; do not duplicate `KeyboardViewModel` into the extension unless a later plan extracts it.
- No blockers for Plan 04-02 besides remaining manual keyboard-enable UI.

## Known Stubs

- Profile chips in `KeyboardView` are placeholders (4 chips, no profile switching wired). Intentional UI shell; not required for this plan's mic remote-control goal.
- No host-field text insertion (CAPT-01 / CAPT-02) — Plan 04-02.

## Threat Flags

None beyond existing Darwin/App Group surface already in Phase 2. This plan posts already-defined `Signal` values; no new endpoints, auth paths, or schema.

## Self-Check: PASSED

- FOUND: Tests/PikoKeyboardTests/MockSessionChannel.swift
- FOUND: Tests/PikoKeyboardTests/KeyboardViewModelTests.swift
- FOUND: App/PikoKeyboard/MicButton.swift
- FOUND: App/PikoKeyboard/KeyboardView.swift
- FOUND: App/PikoKeyboard/KeyboardViewController.swift
- FOUND: .planning/phases/piko-04-keyboard-extension/04-01-SUMMARY.md
- FOUND: f52cdce
- FOUND: d5877c0
- FOUND: a2fb495

`gsd-sdk query state.advance-plan` / `state.record-metric` failed (`Cannot parse Current Plan or Total Plans in Phase from STATE.md`; metric argv rejected). STATE.md / ROADMAP.md patched by hand. CAPT-01 not marked complete.

---
*Phase: piko-04-keyboard-extension*
*Completed: 2026-08-29*
