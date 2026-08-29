---
phase: piko-06-cleanup-routing
plan: 03
subsystem: contracts/keyboard
tags: [profile, agent, keyboard-picker, session-state, stylehint]

requires:
  - "Phase 1 Profile enum Codable + styleHint interpolated by SystemBrain.instructions"
  - "Keyboard accessory row exists (Phase 4) with placeholder profile chips"
provides:
  - "Profile.agent case with machine-parseable styleHint; Codable raw value agent"
  - "ProfileSelectionController mutates only SessionState.profile through SessionChannel"
  - "KeyboardView chips generated from Profile.allCases (five profiles including agent)"
  - "SessionCoordinator arm/heartbeat/disarm preserve profile and skin"
  - "docs/SPEC.md marks .agent as shipped after picker, not enum-only"
affects: [piko-06-cleanup-routing (Plan 06-02 rewrite still owns cleanup quality)]

tech-stack:
  added: []
  patterns:
    - "Profile is String Codable; persist raw value agent, never ordinal"
    - "Picker source of truth is Profile.allCases; controller exposes pickerProfiles for tests"
    - "SessionCoordinator writeChannelState reads existing profile/skin before phase/heartbeat writes"

key-files:
  created:
    - App/PikoKeyboard/ProfileSelectionController.swift
    - Tests/PikoKeyboardTests/ProfileSelectionTests.swift
  modified:
    - Sources/PikoKit/Contracts.swift
    - Tests/PikoKitTests/ContractTests.swift
    - App/PikoKeyboard/KeyboardView.swift
    - App/PikoKeyboard/KeyboardViewController.swift
    - Sources/PikoAudio/SessionCoordinator.swift
    - Tests/PikoAudioTests/SessionCoordinatorArmingTests.swift
    - docs/SPEC.md

key-decisions:
  - "Do not mark CLNP-01 complete: agent styleHint quality needs physical Apple Intelligence; Simulator does not count"
  - "SPEC .agent is shipped only after picker + persistence, not after the enum case alone"
  - "App scheme lives on App/Piko.xcodeproj; plan's xcodebuild -scheme Piko from package root is the wrong project"

patterns-established:
  - "Profile selection is a SessionChannel write of existing state; no-op when readState is nil"
  - "xcodegen-generated Info.plist and entitlements stay untracked"

requirements-completed: []
requirements-not-completed: ["CLNP-01"]

duration: ~10min
completed: 2026-08-29
---

# Phase piko-06 Plan 03: Profile.agent picker + persistence Summary

**Fifth `Profile` case `.agent` persists as Codable raw value `agent`, is selectable from a keyboard chip row generated from `Profile.allCases`, and survives SessionCoordinator arm/heartbeat/disarm instead of resetting to `.message`; SPEC marks it shipped only after that picker, not the enum in isolation.**

## Performance

- **Duration:** ~10 min wall (`2026-08-29T18:56:57Z` → `2026-08-29T19:06:41Z` machine UTC; Task 1 committed before compaction; Task 2 commit + Task 3 Simulator + this SUMMARY after)
- **Tasks:** 3/3 completed
- **Files modified:** 9 (2 created, 7 modified)

## Accomplishments

- `Profile` is `case message, email, note, code, agent`. `.code` remains human-commit text; `.agent` is machine-parseable. `styleHint` for agent is the imperative no-filler string from the plan.
- Codable round-trip uses `"agent"`, not an ordinal. `SessionState` with `.agent` round-trips. `SystemBrain.instructions` interpolates `profile.styleHint` unchanged — no PikoBrain edit.
- `ProfileSelectionController` reads channel state, mutates only `profile`, writes back; no-op if no state.
- `KeyboardView` horizontal chips: `ForEach(Profile.allCases, id: \.rawValue)`; selected chip accent; accessibility label + selected trait.
- `SessionCoordinator.writeChannelState` preserves existing profile and skin (defaults `.message` / `.cute` only when no prior state).
- `docs/SPEC.md` Phase 6 `.agent` paragraph is **Shipped**, not Planned, after the picker landed.

## Task Commits

Each task was committed atomically:

1. **Task 1: Profile.agent case and contract coverage** - `3e62b9f` (feat)
2. **Task 2: five-profile picker persist through session writes** - `da7b54a` (feat)
3. **Task 3: full suite verify** - no extra source commit (verification only)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## TDD Gate Compliance

Plan frontmatter is `type: execute`, not `type: tdd`. Tasks 1–2 have `tdd="true"`. Tests and implementation landed in the same feat commits (no separate RED `test(...)` commit), matching 06-01. Task 1 RED was observed (3 failing PikoKit tests) then GREEN (13/13) before the feat commit.

## Files Created/Modified

- `Sources/PikoKit/Contracts.swift` — `.agent` case + machine-reader `styleHint`
- `Tests/PikoKitTests/ContractTests.swift` — allCases count 5, JSON `"agent"`, SessionState round-trip, every styleHint non-empty
- `App/PikoKeyboard/ProfileSelectionController.swift` — testable profile mutation
- `App/PikoKeyboard/KeyboardView.swift` — chips from `Profile.allCases`
- `App/PikoKeyboard/KeyboardViewController.swift` — `selectedProfile` binding → `selectProfile`
- `Sources/PikoAudio/SessionCoordinator.swift` — preserve profile/skin on arm, heartbeat, disarm
- `Tests/PikoKeyboardTests/ProfileSelectionTests.swift` — select agent preserves other fields; no-op without state; picker == allCases
- `Tests/PikoAudioTests/SessionCoordinatorArmingTests.swift` — arm/heartbeat preserve `.agent` + skin
- `docs/SPEC.md` — `.agent` shipped after picker

## Decisions Made

- SPEC stays Planned until picker + persistence exist (CONSTRAINTS C7 / plan C7). Enum-only would have been incomplete.
- Did **not** mark CLNP-01 complete. Picker and interpolation exist; fillers-removed cleanup quality and agent-hint quality on device need physical Apple Intelligence. Simulator does not count (CLAUDE.md rule 5).
- App build used `xcodegen generate` + `xcodebuild -project App/Piko.xcodeproj -scheme Piko` because the workspace has no scheme named `Piko`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] App scheme is not on the package workspace**
- **Found during:** Task 2 verify
- **Issue:** Plan command `xcodebuild build -scheme Piko` from package root fails: workspace named piko has no scheme named Piko.
- **Fix:** `cd App && xcodegen generate`, then `xcodebuild build -project App/Piko.xcodeproj -scheme Piko` same Simulator destination. **BUILD SUCCEEDED**.
- **Files modified:** none in git (xcodegen Info.plist/entitlements left untracked)
- **Commit:** n/a (build-only)

### Judgment / not Rule 1–3

- Combined TDD: no separate RED `test(...)` commit (same as 06-01).
- Untracked xcodegen `App/*/Info.plist` and entitlements left uncommitted.
- CLNP-01 left pending (agent styleHint quality + cleanup quality not device-proven).
- macOS unsigned SPM still cannot create App Group container; those two PikoBridge tests fail on `swift test` and pass on Simulator.

**Total deviations:** 1 auto-fixed (build invocation). **Impact on plan:** Keyboard UI compiled; no scope creep.

## Issues Encountered

- macOS `swift build`: **succeeded**.
- macOS `swift test`: **48 passed / 2 failed / 50 total**. Failures are pre-existing `PikoBridgeTests` App Group (`ReconnectionSurvivalTests` with `Profile.code`, Darwin round-trip) in unsigned SPM — not a 06-03 regression. New ProfileSelectionTests ran and passed on macOS.
- iOS Simulator `Piko-Package` (`id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`): **TEST SUCCEEDED**.
  - PikoAudioTests: **17/17**
  - PikoBrainTests: **8/8**
  - PikoBridgeTests: **6/6**
  - PikoKeyboardTests: **15/15**
  - PikoKitTests: **13/13**
  - PikoTranscribeTests: **10/10**
  - **Total: 69 passed, 0 failed**
- Physical-device agent rewrite quality: **not measured**. Simulator has no Apple Intelligence.

Delta vs 06-01 Simulator 60/60: +4 PikoKit (agent contracts), +3 PikoKeyboard (picker), +2 PikoAudio (preserve agent) = +9 → 69.

## User Setup Required

None for code. Device proof still needs a physical iPhone with Apple Intelligence enabled. Do not treat CLNP-01 as done.

## iOS Simulator/Device Test Run

**Attempted.** iPhone 17 (iOS 26.0) UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`.

| Command | Result |
|---------|--------|
| `swift build` (macOS) | succeeded |
| `swift test` (macOS) | 48 pass / 2 fail (pre-existing PikoBridge App Group) |
| `xcodebuild test -scheme Piko-Package` focused PikoKeyboardTests + PikoAudioTests | **TEST SUCCEEDED** — 15 + 17 |
| `xcodegen generate` + `xcodebuild build -project App/Piko.xcodeproj -scheme Piko` same destination | **BUILD SUCCEEDED** |
| `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` | **TEST SUCCEEDED** — 69/69 Swift Testing tests |
| Physical device / live agent styleHint quality | **not attempted** |

## Next Phase Readiness

- 06-02 (wave 2) can still wire rewrite into `CaptureCoordinator.stopCapture`. `.agent` is a persisted profile the rewrite path already interpolates via `styleHint`.
- Keyboard does not link PikoBrain (CLAUDE.md rule 1) — unchanged.
- CLNP-01 remains open until physical Apple Intelligence proof.

## Known Stubs

None in files this plan created or modified. Picker is wired to `ProfileSelectionController` / `SessionChannel`, not mock-only.

## Threat Flags

None beyond the plan `<threat_model>`. No new network endpoints. Profile selection is a local App Group `SessionState` write. No package installs.

## Self-Check: PASSED

- `Sources/PikoKit/Contracts.swift` FOUND
- `Tests/PikoKitTests/ContractTests.swift` FOUND
- `App/PikoKeyboard/ProfileSelectionController.swift` FOUND
- `App/PikoKeyboard/KeyboardView.swift` FOUND
- `App/PikoKeyboard/KeyboardViewController.swift` FOUND
- `Sources/PikoAudio/SessionCoordinator.swift` FOUND
- `Tests/PikoKeyboardTests/ProfileSelectionTests.swift` FOUND
- `Tests/PikoAudioTests/SessionCoordinatorArmingTests.swift` FOUND
- `docs/SPEC.md` FOUND
- commit `3e62b9f` FOUND
- commit `da7b54a` FOUND
---
*Phase: piko-06-cleanup-routing*
*Completed: 2026-08-29*
