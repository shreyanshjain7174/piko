---
phase: piko-06-cleanup-routing
plan: 02
subsystem: capture/brain
tags: [brain-wiring, graceful-skip, prefilter-route, brainMS, capture-coordinator]

requires:
  - "Plan 06-01 SystemBrain.rewrite + injectable Inference + withRewriteBudget"
  - "Plan 06-03 Profile.agent persisted on SessionState via picker"
provides:
  - "SystemBrain.prefilterRoute pure function; route() never touches inference"
  - "CaptureCoordinator stopCapture routes then rewrites then writeResult"
  - "try? rewrite ships raw transcript on every Brain failure"
  - "CaptureResult.profile from channel SessionState; timings.brainMS measured"
  - "RoutePrefilterTests call-count proof of CLNP-03"
  - "CaptureCoordinatorBrainTests: 6 coordinator cleanup/skip tests"
affects: [piko-07-live-activity, spike-5-device-proof]

tech-stack:
  added: []
  patterns:
    - "CaptureCoordinator depends on Brain protocol, not SystemBrain"
    - "AppComposition injects SystemBrain() on Simulator and device; no MockBrain swap"
    - "try? around rewrite is the entire CLNP-02 skip; no user-visible Brain error"

key-files:
  created:
    - Tests/PikoBrainTests/RoutePrefilterTests.swift
    - Tests/PikoTranscribeTests/CaptureCoordinatorBrainTests.swift
  modified:
    - Sources/PikoBrain/SystemBrain.swift
    - App/Piko/CaptureCoordinator.swift
    - App/Piko/AppComposition.swift
    - Package.swift
    - Tests/PikoTranscribeTests/CaptureIntegrationTests.swift

key-decisions:
  - "CLNP-03 marked complete: RoutePrefilterTests counts inference calls at zero"
  - "CLNP-01/CLNP-02 not marked complete: Simulator only exercises graceful skip, not live rewrite quality or 600ms on device"
  - "Do not publish SessionPhase.tidying from stopCapture; SessionCoordinator owns phase"

patterns-established:
  - "PikoCaptureCore and PikoTranscribeTests both depend on PikoBrain"
  - "Coordinator tests reuse MockSessionChannel and MockTranscriber; Brain stubs stay in-file"

requirements-completed: ["CLNP-03"]
requirements-not-completed: ["CLNP-01", "CLNP-02"]

duration: ~7min
completed: 2026-08-29
---

# Phase piko-06 Plan 02: CaptureCoordinator Brain wiring Summary

**`CaptureCoordinator.stopCapture` now routes with a model-free prefilter, rewrites under the 06-01 budget via `try?`, and writes `CaptureResult` with channel profile plus measured `brainMS`; Simulator proves skip and routing, not live Foundation Models cleanup quality.**

## Performance

- **Duration:** ~7 min wall (`2026-08-29T19:09:31Z` → `2026-08-29T19:16:00Z`)
- **Tasks:** 3/3 completed
- **Files modified:** 7 (2 created, 5 modified)

## Accomplishments

- `SystemBrain.prefilterRoute` is a pure prefix match. `route(_:)` lowercases, trims, and never touches `budget` or `inference`.
- `RoutePrefilterTests` injects a call counter: a dozen-plus write/command/recall phrases leave `count == 0`. Recall still beats overlapping `"remind me"`.
- `CaptureCoordinator` takes `brain: any Brain`. After `transcriber.finish()` it reads profile from the channel (fallback `.message`), routes, times rewrite, ships `try?` result or raw text, records `brainMS`.
- `AppComposition` injects `SystemBrain()` on Simulator and device. No `#if targetEnvironment(simulator)` MockBrain swap — Simulator is the CLNP-02 skip path.
- `TODO(phase 6)` is gone because the work behind it is done.

## Task Commits

Each task was committed atomically:

1. **Task 1: Prove routing never reaches the rewrite model** - `08ae16a` (feat)
2. **Task 2: Wire Brain into CaptureCoordinator with graceful skip and brainMS** - `b5be43c` (feat)
3. **Task 3: full suite verify** - no extra source commit (verification only)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## TDD Gate Compliance

Plan frontmatter is `type: execute`, not `type: tdd`. Tasks 1–2 have `tdd="true"`. Tests and implementation landed in the same feat commits (no separate RED `test(...)` commit), matching 06-01 and 06-03.

## Files Created/Modified

- `Sources/PikoBrain/SystemBrain.swift` — `prefilterRoute`; `route` does not call inference
- `Tests/PikoBrainTests/RoutePrefilterTests.swift` — 4 tests; CLNP-03 call-count proof
- `Package.swift` — `PikoBrain` on `PikoCaptureCore` and `PikoTranscribeTests`
- `App/Piko/CaptureCoordinator.swift` — Brain between finish and writeResult
- `App/Piko/AppComposition.swift` — `import PikoBrain`; `brain: SystemBrain()`
- `Tests/PikoTranscribeTests/CaptureIntegrationTests.swift` — both coordinators get `MockBrain()`
- `Tests/PikoTranscribeTests/CaptureCoordinatorBrainTests.swift` — 6 iOS-only coordinator tests

## Decisions Made

- Mark **CLNP-03 complete**. VALIDATION.md says the injected-inference counter is sufficient. `routeNeverInvokesInference` is that proof.
- Do **not** mark CLNP-01 or CLNP-02 complete. Coordinator stubs prove cleaned vs raw vs skip. Real `SystemBrain()` on Simulator has no Apple Intelligence, so every live rewrite takes the skip branch. Fillers-removed quality and 60-word 600ms on the oldest device still need Spike 5 on physical hardware. Simulator does not count (CLAUDE.md rule 5).
- Do **not** publish `SessionPhase.tidying` from `stopCapture`. `SessionCoordinator` owns phase on a ~2 s heartbeat; a 600 ms tidying write would race it. `PikoFace` / `MicButton` already render `.tidying` and still never see it. Needs a phase-ownership API later.
- Rewrite regardless of `route`. v0.1 has no command/recall handler; `route` is recorded for v0.2.

## Deviations from Plan

### Auto-fixed Issues

None.

### Judgment / not Rule 1–3

- Combined TDD: no separate RED `test(...)` commit (same as 06-01 / 06-03).
- Untracked xcodegen `App/*/Info.plist` and entitlements left uncommitted.
- Plan success-criteria count was stale: "50 pre-existing + 8 from 06-01 + 10 from this plan". After 06-03 the baseline was **69**, not 58. Actual Simulator total is **79** (69 + 4 routing + 6 coordinator).
- Plan verify used `xcodebuild build -scheme Piko` from package root. Same as 06-03: that scheme lives on `App/Piko.xcodeproj`. Used `xcodegen generate` then `xcodebuild -project App/Piko.xcodeproj -scheme Piko`.
- CLNP-01/CLNP-02 left pending despite plan frontmatter listing them. Honest vs GSD auto-complete.
- macOS unsigned SPM still cannot create App Group container; those two PikoBridge tests fail on `swift test` and pass on Simulator.

**Total deviations:** 0 auto-fixed. **Impact on plan:** Wiring matches the plan. Device quality still unverified.

## Issues Encountered

- macOS `swift build`: **succeeded**.
- macOS `swift test`: **52 passed / 2 failed / 54 total**. Failures are pre-existing `PikoBridgeTests` App Group (`ReconnectionSurvivalTests`, Darwin round-trip) in unsigned SPM. RoutePrefilterTests: **4/4**. CaptureCoordinatorBrainTests did not run (`#if os(iOS)`).
- iOS Simulator `Piko-Package` (`id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`): **TEST SUCCEEDED**.
  - PikoAudioTests: **17/17**
  - PikoBrainTests: **12/12** (8 from 06-01 + 4 RoutePrefilter)
  - PikoBridgeTests: **6/6**
  - PikoKeyboardTests: **15/15**
  - PikoKitTests: **13/13**
  - PikoTranscribeTests: **16/16** (10 prior + 6 coordinator Brain)
  - **Total: 79 passed, 0 failed**
- `xcodegen generate` + `xcodebuild -project App/Piko.xcodeproj -scheme Piko` same destination: **BUILD SUCCEEDED**.
- Physical-device Foundation Models rewrite quality and 600ms: **not measured**. Simulator has no Apple Intelligence. Every real `SystemBrain()` Simulator path is the skip branch.

Delta vs 06-03 Simulator 69/69: +4 PikoBrain (RoutePrefilter) +6 PikoTranscribe (coordinator Brain) = +10 → 79.

## User Setup Required

None for code. Device proof still needs a physical iPhone with Apple Intelligence enabled (Spike 5). Do not treat CLNP-01/CLNP-02 as done.

## iOS Simulator/Device Test Run

**Attempted.** iPhone 17 (iOS 26.0) UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`.

| Command | Result |
|---------|--------|
| `swift build` (macOS) | succeeded |
| `swift test --filter RoutePrefilterTests` | **4/4 passed** |
| `swift test` (macOS) | 52 pass / 2 fail (pre-existing PikoBridge App Group) |
| `xcodebuild test -scheme Piko-Package` focused PikoTranscribeTests | **TEST SUCCEEDED** — 16/16 |
| `xcodebuild test -scheme Piko-Package` full suite same destination | **TEST SUCCEEDED** — 79/79 Swift Testing tests |
| `xcodegen generate` + `xcodebuild build -project App/Piko.xcodeproj -scheme Piko` same destination | **BUILD SUCCEEDED** |
| Physical device / live Foundation Models rewrite | **not attempted** |

Do not treat CLNP-01 as device-proven. Do not treat CLNP-02's 600ms bound as device-proven. CLNP-02's graceful-skip half is proven on Simulator via coordinator stubs and via real `SystemBrain()` unavailability. CLNP-03 is proven by the inference call counter.

## Next Phase Readiness

- Write path has a Brain. Phase 7 can still add Live Activity; tidying phase is still never published.
- Keyboard does not link PikoBrain (CLAUDE.md rule 1) — unchanged.
- Spike 5 on physical Apple Intelligence is the remaining CLNP-01/CLNP-02 gate.

## Known Stubs

None that block this plan's goal. In-file Brain stubs (`CleanBrain`, `SlowBrain`, `UnavailableBrain`, `RoutingBrain`, `DelayedCleanBrain`) are test doubles, not production. Production `AppComposition` uses `SystemBrain()`. Empty `lexicon: []` and `examples: []` on the coordinator rewrite call are intentional v0.1 (Memory is Phase 8).

Deliberate deferral, not a stub: `SessionPhase.tidying` is never written during cleanup.

## Threat Flags

None beyond the plan `<threat_model>`. No new network endpoints. `try?` around rewrite is T-06-05. Routing stays pure prefix match (T-06-06). No package installs.

## Self-Check: PASSED

- `Tests/PikoBrainTests/RoutePrefilterTests.swift` FOUND
- `Tests/PikoTranscribeTests/CaptureCoordinatorBrainTests.swift` FOUND
- `App/Piko/CaptureCoordinator.swift` FOUND
- `App/Piko/AppComposition.swift` FOUND
- commit `08ae16a` FOUND
- commit `b5be43c` FOUND
---
*Phase: piko-06-cleanup-routing*
*Completed: 2026-08-29*
