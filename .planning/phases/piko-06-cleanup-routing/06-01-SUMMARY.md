---
phase: piko-06-cleanup-routing
plan: 01
subsystem: brain
tags: [foundation-models, rewrite-budget, system-brain, language-model-session, hard-deadline]

requires:
  - "Phase 5 Plan 03 CaptureCoordinator ships finalText with TODO(phase 6)"
  - "PikoKit Brain + PikoError + SystemBrain.instructions/prompt faithfulness text"
provides:
  - "PikoError.brainBudgetExceeded(milliseconds:) distinct from brainUnavailable"
  - "withRewriteBudget hard-deadline race via withCheckedThrowingContinuation + unstructured Tasks"
  - "iOS-only FoundationModelsInference (LanguageModelSession.respond greedy)"
  - "SystemBrain.rewrite wired to injectable inference under 600ms budget"
  - "PikoBrainTests: 8 tests (budget race + rewrite contract)"
affects: [piko-06-cleanup-routing (Plan 06-02)]

tech-stack:
  added: []
  patterns:
    - "Hard deadline: one-shot continuation resume; cancel loser; do not await TaskGroup children"
    - "Injectable SystemBrain.Inference so Simulator/macOS never need Apple Intelligence"
    - "FoundationModels file is #if os(iOS) entire-file; macOS swift build skips it"

key-files:
  created:
    - Sources/PikoBrain/RewriteBudget.swift
    - Sources/PikoBrain/FoundationModelsInference.swift
    - Tests/PikoBrainTests/RewriteBudgetTests.swift
    - Tests/PikoBrainTests/SystemBrainRewriteTests.swift
  modified:
    - Sources/PikoKit/Protocols.swift
    - Sources/PikoBrain/SystemBrain.swift
    - Package.swift

key-decisions:
  - "Budget race is unstructured Tasks + withCheckedThrowingContinuation, not withThrowingTaskGroup"
  - "RewriteBudgetRaceState is file-scope; Swift cannot nest a class inside a generic function"
  - "CLNP-01/CLNP-02 not marked complete: no physical Apple Intelligence quality or 600ms device proof"

patterns-established:
  - "Production inference creates a fresh local LanguageModelSession per rewrite; callers must not reuse it after timeout"
  - "Availability switch includes @unknown default because UnavailableReason is not frozen"
  - "guardrailViolation/refusal map to brainUnavailable so the caller can ship raw transcript"

requirements-completed: []
requirements-not-completed: ["CLNP-01", "CLNP-02"]

duration: ~38min
completed: 2026-08-29
---

# Phase piko-06 Plan 01: SystemBrain rewrite + 600ms budget Summary

**`SystemBrain.rewrite` runs injectable or iOS Foundation Models inference under a hard 600ms deadline that throws `PikoError.brainBudgetExceeded` without awaiting a cancellation-ignoring loser; Simulator/macOS prove the skip and budget paths, not live cleanup quality.**

## Performance

- **Duration:** ~38 min wall (`2026-08-29T18:43:03Z` → `2026-08-29T19:21:00Z`; Tasks 1–2 committed before compaction; Task 3 Simulator + this SUMMARY after)
- **Tasks:** 3/3 completed
- **Files modified:** 7 (4 created, 3 modified)

## Accomplishments

- `PikoError.brainBudgetExceeded(milliseconds:)` sits beside `brainUnavailable`.
- `withRewriteBudget` races operation vs timer via `withCheckedThrowingContinuation` and two unstructured `Task`s. Winner resumes once; loser is cancelled and never awaited.
- `FoundationModelsInference.swift` is `#if os(iOS)` entire file: `SystemLanguageModel.default` availability, `LanguageModelSession(instructions:)`, `respond(to:options:)` with `GenerationOptions(sampling: .greedy)`, no max tokens, no `prewarm`.
- `SystemBrain` takes `budget` + optional `Inference`; default on iOS 26 is Foundation Models, else `brainUnavailable`. `route` / `instructions` / `prompt` / `MockBrain` unchanged.
- `PikoBrainTests` target: 8 tests, all pass on macOS and iOS Simulator.

## Task Commits

Each task was committed atomically:

1. **Task 1: brainBudgetExceeded + withRewriteBudget** - `b16cf29` (feat)
2. **Task 2: SystemBrain.rewrite injectable inference** - `46f4893` (feat)
3. **Task 3: full suite verify** - no extra source commit (verification only)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## TDD Gate Compliance

Plan frontmatter is `type: execute`, not `type: tdd`. Tasks 1–2 have `tdd="true"`. Implementation and tests landed in the same feat commits (no separate RED `test(...)` commit). Tests drive injectable inference and the budget helper — they do not drive a live `LanguageModelSession`.

## Files Created/Modified

- `Sources/PikoKit/Protocols.swift` - `brainBudgetExceeded(milliseconds:)`
- `Sources/PikoBrain/RewriteBudget.swift` - hard-deadline race + file-scope `RewriteBudgetRaceState`
- `Sources/PikoBrain/FoundationModelsInference.swift` - iOS-only FM call site
- `Sources/PikoBrain/SystemBrain.swift` - rewrite wraps inference in `withRewriteBudget`
- `Tests/PikoBrainTests/RewriteBudgetTests.swift` - 4 budget tests
- `Tests/PikoBrainTests/SystemBrainRewriteTests.swift` - 4 rewrite contract tests
- `Package.swift` - `PikoBrainTests` target (PikoBrain not added to PikoCaptureCore)

## Decisions Made

- Hard continuation race, not TaskGroup: group exit awaits children; `cancelAll()` is cooperative only.
- File-scope race state class: nested class inside generic `withRewriteBudget` does not compile.
- SDK names matched iOS 26: `Availability.unavailable(UnavailableReason)`, `exceededContextWindowSize`, `appleIntelligenceNotEnabled`, `prewarm(promptPrefix: Prompt?)` (unused).
- Did **not** mark CLNP-01 / CLNP-02 complete. Rewrite exists and is bounded in unit tests; fillers-removed quality and 60-word 600ms on oldest device need Spike 5 on physical Apple Intelligence hardware.

## Foundation Models API path

**Used:** iOS 26 `FoundationModels` (`SystemLanguageModel` + `LanguageModelSession`). Compiled on iPhone 17 Simulator. Not executed for real generation: Simulator takes unavailable / injected path.

| Plan name | SDK reality |
|-----------|-------------|
| `SystemLanguageModel.default` | **exists** |
| `Availability.available` / `.unavailable(UnavailableReason)` | **exists**; reason is not `@frozen` — `@unknown default` required |
| `LanguageModelSession(instructions:)` + `respond(to:options:)` | **exists** |
| `GenerationOptions(sampling: .greedy)` | **exists** |
| `prewarm(promptPrefix: Prompt?)` | **exists**; not called |
| `GenerationError.exceededContextWindowSize` | **exists**; mapped to `brainUnavailable` |

macOS `swift build` skips the FM file (`#if os(iOS)`). iOS Simulator `xcodebuild` compiled `FoundationModelsInference.swift`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Nested class in generic function**
- **Found during:** Task 1 compile
- **Issue:** Plan nested `final class RaceState` inside `withRewriteBudget`. Swift rejects nesting a class in a generic function.
- **Fix:** Private file-scope `RewriteBudgetRaceState<T: Sendable>` with lock-guarded one-shot resume.
- **Files modified:** `Sources/PikoBrain/RewriteBudget.swift`
- **Commit:** `b16cf29`

### Judgment / not Rule 1–3

- Untracked xcodegen `App/*/Info.plist` and entitlements left uncommitted.
- CLNP-01/CLNP-02 left pending (same honesty as Phase 5 CAPT-03/04).
- macOS unsigned SPM still cannot create App Group container; those two PikoBridge tests fail on `swift test` and pass on Simulator.

**Total deviations:** 1 auto-fixed. **Impact on plan:** Budget helper compiles and tests pass. No live FM quality proof.

## Issues Encountered

- macOS `swift build`: **succeeded**.
- macOS `swift test`: **41 passed / 2 failed / 43 total**. Failures are pre-existing `PikoBridgeTests` App Group (`ReconnectionSurvivalTests`, Darwin round-trip) in unsigned SPM. PikoBrainTests: **8/8**.
- iOS Simulator `Piko-Package` (`id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`): **TEST SUCCEEDED**.
  - PikoAudioTests: **15/15**
  - PikoBrainTests: **8/8**
  - PikoBridgeTests: **6/6** (App Group works on signed Simulator)
  - PikoKeyboardTests: **12/12**
  - PikoKitTests: **9/9**
  - PikoTranscribeTests: **10/10**
  - **Total: 60 passed, 0 failed**
- Physical-device Foundation Models quality and 600ms latency: **not measured**. Simulator has no Apple Intelligence. CLAUDE.md: Simulator does not count for those.

## User Setup Required

None for code. Device proof still needs a physical iPhone with Apple Intelligence enabled (Spike 5). Plan 06-02 wires rewrite into `CaptureCoordinator.stopCapture`.

## iOS Simulator/Device Test Run

**Attempted.** iPhone 17 (iOS 26.0) UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`.

| Command | Result |
|---------|--------|
| `swift build` (macOS) | succeeded |
| `swift test --filter PikoBrainTests` | **8/8 passed** |
| `swift test` (macOS) | 41 pass / 2 fail (pre-existing PikoBridge App Group) |
| `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` | **TEST SUCCEEDED** — 60/60 Swift Testing tests |
| Physical device / live Foundation Models rewrite | **not attempted** |

Do not treat CLNP-01/CLNP-02 as device-proven. Budget is unit-tested with sleep/injected closures; live `LanguageModelSession` is compiled but unused on Simulator.

## Next Phase Readiness

- Plan 06-02 can call `SystemBrain.rewrite` from `CaptureCoordinator.stopCapture` and `try?` skip on `brainUnavailable` / `brainBudgetExceeded`.
- On Simulator, default inference is unavailable — that is the CLNP-02 skip path, not cleanup quality.
- Injected inference remains the deterministic path for coordinator tests.

## Known Stubs

None in files this plan created or modified. `CaptureCoordinator` still ships `finalText` with the Phase 6 TODO — owned by 06-02.

## Threat Flags

None beyond the plan `<threat_model>`. No new network endpoints. Inference stays on-device; no package installs.

## Self-Check: PASSED

- `Sources/PikoBrain/RewriteBudget.swift` FOUND
- `Sources/PikoBrain/FoundationModelsInference.swift` FOUND
- `Sources/PikoBrain/SystemBrain.swift` FOUND
- `Tests/PikoBrainTests/RewriteBudgetTests.swift` FOUND
- `Tests/PikoBrainTests/SystemBrainRewriteTests.swift` FOUND
- commit `b16cf29` FOUND
- commit `46f4893` FOUND
---
*Phase: piko-06-cleanup-routing*
*Completed: 2026-08-29*
