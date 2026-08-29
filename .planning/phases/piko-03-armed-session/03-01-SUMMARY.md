---
phase: piko-03-armed-session
plan: 01
subsystem: audio
tags: [avfaudio, avaudiosession, swift-concurrency, swift-testing, mainactor, spm]

requires: []
provides:
  - "SessionCoordinator: first real ArmedSession conformer, owning AVAudioSession, #if os(iOS)-guarded"
  - "InterruptionSource protocol + InterruptionEvent enum contract (unguarded), plus NullInterruptionSource permanent no-op conformer"
  - "PikoAudioTests test target with MockSessionChannel/MockInterruptionSource doubles and 4 SESS-01 arming-transition tests"
  - "AppComposition.shared: sole DarwinChannel + SessionCoordinator construction site"
  - "ArmView with a real, reachable Arm button and live phase text"
affects: [piko-03-armed-session (Plan 03-02, Plan 03-03)]

tech-stack:
  added: []
  patterns:
    - "Package-wide platform guard: #if os(iOS) wraps an entire source file (SessionCoordinator.swift), not individual declarations, keeping `swift build` green on macOS while PikoAudio gains real AVFAudio code"
    - "@MainActor class instead of @unchecked Sendable + NSLock for UI-driven-only state machines"
    - "Required (non-defaulted) closure parameter as a compile-time trace of a security constraint (isForeground, CONSTRAINTS.md C2)"
    - "Permanent Null Object conformer (NullInterruptionSource) as a real seam for previews/tests and a one-line composition-root swap point for a future plan"

key-files:
  created:
    - Sources/PikoAudio/InterruptionSource.swift
    - Sources/PikoAudio/SessionCoordinator.swift
    - Tests/PikoAudioTests/MockSessionChannel.swift
    - Tests/PikoAudioTests/MockInterruptionSource.swift
    - Tests/PikoAudioTests/SessionCoordinatorArmingTests.swift
    - App/Piko/AppComposition.swift
  modified:
    - Package.swift
    - App/Piko/PikoApp.swift

key-decisions:
  - "isForeground has no default value — every construction site must supply it explicitly, keeping CONSTRAINTS.md C2 visible rather than silently bypassable (per plan's explicit rationale)"
  - "SessionCoordinator is @MainActor rather than @unchecked Sendable + NSLock, since every legal caller (button tap, future AppIntent.perform()) is already UI-driven"
  - "stopCapture() returns phase to .armed, not .idle, so the session stays armed for another capture"
  - "Interruption handling collapses .began/.routeChanged/.lowPowerModeChanged(enabled: true) to a shared disarm(); .ended/.lowPowerModeChanged(enabled: false) are no-ops — re-arming is user-initiated, per 03-RESEARCH.md Open Question 1"
  - "Used .allowBluetoothHFP as instructed by the plan; NOT independently re-verified against Apple docs (no apple-docs MCP tool / network doc access available in this session) — flagged here per the plan's own [LOW confidence] caveat for a future pass to confirm before shipping to a real device"

patterns-established:
  - "Any future PikoAudio file that touches AVFAudio must wrap its entire contents in #if os(iOS) / #endif, mirroring SessionCoordinator.swift, or swift build breaks on this macOS dev machine"
  - "Test files that reference an iOS-guarded type must themselves be entirely #if os(iOS)-guarded so swift test compiles-but-no-ops (0 tests, exit 0) on macOS rather than failing to compile"

requirements-completed: ["SESS-01"]

duration: ~35min
completed: 2026-08-29
---

# Phase piko-03 Plan 01: SessionCoordinator + AppComposition Summary

**First real `ArmedSession` conformer (`SessionCoordinator`, `AVAudioSession`-backed, `#if os(iOS)`-guarded) with a reachable Arm button in the container app, proving `swift build` stays green on macOS now that `PikoAudio` contains real `AVFAudio` code.**

## Performance

- **Duration:** ~35 min
- **Tasks:** 3/3 completed
- **Files modified:** 8 (6 created, 2 modified)

## Accomplishments

- `SessionCoordinator` implements the full `ArmedSession` state machine (`idle → armed → capturing → armed → idle`) against real `AVAudioSession.setCategory`/`setActive` calls, with `arm()` gated on an injected `isForeground` closure and no force-unwraps on any `AVAudioSession` call.
- `InterruptionSource`/`InterruptionEvent`/`NullInterruptionSource` exist as a stable, unguarded contract Plan 03-02's real conformer will implement without touching this plan's files.
- `PikoAudioTests` target added to `Package.swift`; 4 `@Test` functions cover all four SESS-01 state transitions (arm success, arm-while-backgrounded throws `notForeground`, `startCapture` before `arm` throws `notArmed`, `stopCapture` returns to `.armed` not `.idle`), entirely `#if os(iOS)`-guarded.
- `AppComposition.shared` is the sole construction site of a real `DarwinChannel` + `SessionCoordinator`; `ArmView` now has a working "Arm" button, live phase text, and error display wired to it — SESS-01 has a concrete, tappable path, not just protocol conformance.
- `swift build` succeeds on this macOS dev machine after all three tasks, confirming the platform guard actually protects the package-wide build.

## Task Commits

Each task was committed atomically:

1. **Task 1: Wave 0 — InterruptionSource contract + platform-guarded SessionCoordinator** - `d1f8d5d` (feat)
2. **Task 2: MockSessionChannel + MockInterruptionSource + SESS-01 arming tests** - `0e06507` (test)
3. **Task 3: AppComposition root + reachable Arm button in ArmView** - `a4e4984` (feat)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## Files Created/Modified

- `Package.swift` - Added `PikoAudioTests` test target (`dependencies: ["PikoAudio", "PikoKit"]`)
- `Sources/PikoAudio/InterruptionSource.swift` - `InterruptionEvent` enum, `InterruptionSource` protocol, `NullInterruptionSource` permanent no-op conformer — unguarded, compiles on every platform
- `Sources/PikoAudio/SessionCoordinator.swift` - `@MainActor final class SessionCoordinator: ArmedSession`, entirely `#if os(iOS)`-guarded; owns `AVAudioSession`, heartbeat task, interruption-consuming task
- `Tests/PikoAudioTests/MockSessionChannel.swift` - In-memory `SessionChannel` double (`NSLock`-protected, mirrors `DarwinChannel`'s pattern), unguarded
- `Tests/PikoAudioTests/MockInterruptionSource.swift` - Manual-fire `InterruptionSource` double, unguarded
- `Tests/PikoAudioTests/SessionCoordinatorArmingTests.swift` - 4 `@Test @MainActor` functions covering SESS-01 transitions, entirely `#if os(iOS)`-guarded
- `App/Piko/AppComposition.swift` - `@MainActor final class AppComposition`, `static let shared`, sole `DarwinChannel()!`/`SessionCoordinator(...)` construction site
- `App/Piko/PikoApp.swift` - `ArmView` rewritten with a real Arm button, live `phaseText` from `session.phase`, and `armError` display; TODO comment narrowed to the two portions still out of scope (history list, skin picker)

## Decisions Made

- `isForeground` kept non-defaulted per plan's explicit rationale (compile-time trace of CONSTRAINTS.md C2).
- `SessionCoordinator` is `@MainActor`, not `@unchecked Sendable` + `NSLock` — matches plan's stated rationale (all legal callers are already UI/MainActor-driven).
- Kept `isForeground` typed `@escaping @MainActor @Sendable () -> Bool` exactly as specified in the user's instructions and the plan — did NOT simplify to plain `@Sendable`, since `AppComposition`'s closure calls `UIApplication.shared.applicationState`, which is `MainActor`-isolated under this project's `SWIFT_STRICT_CONCURRENCY: complete` setting.
- Interruption-consuming `Task` in `SessionCoordinator.init` uses `[weak self]` capture on the outer task and re-checks `self` per iteration to avoid a retain cycle, per the plan's guidance.
- Assertion tests for `PikoError.notForeground`/`PikoError.notArmed` use a `do`/`catch` pattern rather than `#expect(throws: <instance>)`, since `PikoError` is not `Equatable` and the plan permits "an equivalent do/catch pattern" — `PikoKit/Protocols.swift` was left unmodified per the plan's read-only instruction for that file.

## Deviations from Plan

**None (Rules 1–3) required for correctness/security/blocking issues.** One deviation-adjacent note, not a Rule 1–4 fix:

- **[Not a deviation, a caveat carried forward from the plan itself]** The plan flagged `.allowBluetoothHFP` as `[LOW confidence]` and asked to verify it against Apple docs before treating it as final. No `apple-docs` MCP tool or network access was available in this execution environment, so the constant was used exactly as the plan specified but was **not independently re-verified**. `swift build` cannot catch a renamed/deprecated-but-still-present constant at the source level if it still compiles, so this should be manually confirmed against current `AVAudioSession.CategoryOptions` documentation before this code ships to a real device or App Store build.

**Total deviations:** 0 auto-fixed. **Impact on plan:** None — plan executed exactly as written, including the concurrency-annotation guidance from the plan-checker's prior fix (`isForeground: @escaping @MainActor @Sendable () -> Bool` kept as-is).

## Issues Encountered

- `swift build` alone did not fail even before `Tests/PikoAudioTests/` existed as a populated directory in Task 1 (SPM emits a warning, not an error, for a declared test target whose directory doesn't yet exist) — Task 1's directory was created empty ahead of Task 2's files landing in it; this required no plan deviation, just running `mkdir -p Tests/PikoAudioTests` before Task 1's `swift build` verify step so the target had somewhere to look. No plan file was affected.
- `swift test` (full suite, no filter) still shows 2 pre-existing `PikoBridgeTests` failures (`RoundTripLatencyTests`, `ReconnectionSurvivalTests`) — both are documented in the test code itself as environment limitations (no real App Group container in this unsigned SPM/macOS test environment), unrelated to this plan's changes. Confirmed via `swift test --filter PikoAudioTests` (0 tests, exit 0, as expected) and `swift test` full run (`PikoKitTests` all pass; only the two pre-existing `PikoBridgeTests` failures present).

## User Setup Required

None - no external service configuration required.

## iOS Simulator/Device Test Run

Not attempted in this session — no iOS Simulator/device toolchain was invoked; verification was limited to `swift build` and `swift test --filter PikoAudioTests` on macOS, per the user's explicit instructions for this execution. `SessionCoordinatorArmingTests` compiles cleanly (0 tests run) on macOS as expected by its `#if os(iOS)` guard. An iOS Simulator/device run to actually execute the 4 arming tests is recommended before this plan's work is considered fully proven, matching this plan's own non-gating verification note.

## Next Phase Readiness

- `InterruptionSource` contract is stable and unguarded — Plan 03-02 can implement the real `AVAudioSessionInterruptionSource()` conformer against it without touching this plan's files, swapping only the single `NullInterruptionSource()` line in `App/Piko/AppComposition.swift`.
- `SessionCoordinator`'s `sessionEpoch` counter exists (bumped on every `arm()`) ready for a future `CaptureDraft.sessionEpoch` tagging consumer.
- No blockers for Plan 03-02 or Plan 03-03.

---
*Phase: piko-03-armed-session*
*Completed: 2026-08-29*
