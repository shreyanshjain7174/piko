---
phase: piko-08-history-skins
plan: 04
subsystem: PikoCaptureCore / App composition
tags: [memory, sqlite, wiring, capture-coordinator, app-composition]

requires: ["08-02"]
provides:
  - "CaptureCoordinator.stopCapture() records every finished CaptureResult into memory"
  - "AppComposition.memory — the app's one real SQLiteMemory instance, Application-Support-backed"
affects: ["piko-08-history-skins (Plan 08-05, ArmView history list reads AppComposition.shared.memory)"]

tech-stack:
  added: []
  patterns:
    - "memory: any Memory threaded as CaptureCoordinator's fifth constructor parameter, same shape as the existing session/channel/transcriber/brain dependencies"
    - "SQLiteMemory constructed unconditionally (no #if targetEnvironment(simulator) gate), unlike transcriber/brain mocks — it has no hardware/entitlement dependency"

key-files:
  created: []
  modified:
    - App/Piko/CaptureCoordinator.swift
    - App/Piko/AppComposition.swift
    - Package.swift
    - Tests/PikoTranscribeTests/CaptureIntegrationTests.swift
    - Tests/PikoTranscribeTests/CaptureCoordinatorBrainTests.swift

key-decisions:
  - "memory.record(result) placed exactly per 08-RESEARCH.md Pattern 4: after channel.post(.resultReady), before onTidyingChange?(false)"
  - "SQLiteMemory backed by FileManager.applicationSupportDirectory, not the group.dev.piko.shared App Group — no other process needs to read history back"
  - "All six real CaptureCoordinator(...) call sites (1 production in AppComposition.swift, 5 test call sites in CaptureIntegrationTests.swift, 1 in CaptureCoordinatorBrainTests.swift's makeCoordinator helper) updated with a trailing memory: argument — see Deviations for the count discrepancy vs. the plan's stated 4+1"

requirements-completed: [HIST-01]
requirements-not-completed: []

duration: ~20min
completed: 2026-08-30
---

# Phase piko-08 Plan 04: Wire SQLiteMemory into AppComposition and CaptureCoordinator Summary

**`CaptureCoordinator` gained a fifth `memory: any Memory` dependency and now calls `memory.record(result)` on every finished capture; `AppComposition` constructs the one real `SQLiteMemory`, backed by an app-private `Application Support/history.sqlite` file, unconditionally on Simulator and device, and exposes it as `public let memory`.**

## Performance

- **Duration:** ~20 min
- **Tasks:** 2/2 completed
- **Files modified:** 5

## Accomplishments

- **Task 1:** `CaptureCoordinator` gained `private let memory: any Memory` and a fifth
  `init(session:channel:transcriber:brain:memory:)` parameter. `stopCapture()` now calls `await
  memory.record(result)` immediately after `channel.post(.resultReady)` and before
  `onTidyingChange?(false)`, matching `08-RESEARCH.md`'s Pattern 4 exactly. `PikoTranscribeTests`
  gained a `PikoMemory` target dependency in `Package.swift`. All real
  `CaptureCoordinator(...)` construction call sites — 5 in `CaptureIntegrationTests.swift`, 1 in
  `CaptureCoordinatorBrainTests.swift`'s `makeCoordinator` helper — now pass `memory:
  EphemeralMemory()`. Added `stopCaptureRecordsResultIntoMemory()`, a new end-to-end test: a full
  arm→startCapture→(sleep)→stopCapture cycle, then `await memory.search("Final", limit:
  10).count == 1` — proves HIST-01's wiring works at the real call site, not just that it compiles.
- **Task 2:** `AppComposition` gained `import PikoMemory` and `public let memory: any Memory`.
  `private init()` now builds `history.sqlite` under
  `FileManager.default.url(for: .applicationSupportDirectory, ...)` and constructs `SQLiteMemory(path:
  dbURL)` unconditionally — no `#if targetEnvironment(simulator)` gate, unlike `transcriber`/`brain`,
  since `SQLiteMemory` has no hardware/entitlement dependency. The resulting `memory` instance is
  threaded into `CaptureCoordinator`'s new fifth argument and exposed as a public property for Plan
  08-05's `ArmView`.
- `swift build`: clean.
- `swift test` (macOS): 81/83 passed — the 2 pre-existing App-Group-container failures
  (`ReconnectionSurvivalTests`, `RoundTripLatencyTests`) are the known, expected unsigned-SPM-test
  environment limitation, unrelated to this plan.
- `xcodebuild test -scheme Piko-Package -only-testing:PikoTranscribeTests` (iOS Simulator): **28/28
  passed**, including the new `stopCaptureRecordsResultIntoMemory` test — zero regressions across
  `CaptureIntegrationTests` and `CaptureCoordinatorBrainTests`.
- `xcodegen generate` + `xcodebuild -project Piko.xcodeproj -scheme Piko build` (iOS Simulator):
  **BUILD SUCCEEDED** — confirms `AppComposition`'s wiring compiles against the real container-app
  target, not just the SPM package.

## Task Commits

1. **Task 1:** `31d88a8` (feat) — `CaptureCoordinator` memory dependency, `Package.swift`
   dependency, all six test call sites, new end-to-end test.
2. **Task 2:** `c814829` (feat) — `AppComposition` real `SQLiteMemory` construction and wiring.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - plan inaccuracy, no code impact] Call-site count in `CaptureIntegrationTests.swift`**
- **Found during:** Task 1
- **Issue:** The plan's `<interfaces>` section states "Four call sites in
  `Tests/PikoTranscribeTests/CaptureIntegrationTests.swift`" (items 2–5 of "six total"). The file
  actually contains **five** `CaptureCoordinator(...)` construction call sites (verified via grep:
  `startCaptureBeginsDraftFlow`, `stopCaptureWritesResult`, `stopRequestedStopsCaptureThenDisarms`,
  `stopRequestedWhenArmedOnlySkipsStopCaptureButStillDisarms`,
  `stopCaptureFiresTidyingChangeAroundRewriteWindow`), making the real total 1 (production) + 5 +
  1 (`CaptureCoordinatorBrainTests.swift`) = 7, not the stated 6.
- **Fix:** Updated all five real call sites in `CaptureIntegrationTests.swift` (not four), plus the
  one in `CaptureCoordinatorBrainTests.swift` and the one in `AppComposition.swift` — seven total,
  all real construction sites in the repo, confirmed via `grep -c "CaptureCoordinator(" ` across
  both test files and `AppComposition.swift` after the edit.
- **Files modified:** `Tests/PikoTranscribeTests/CaptureIntegrationTests.swift` (as already listed
  in `files_modified`).
- **Commit:** `31d88a8`

### None affecting behavior

No architectural changes, no auth gates, no bugs found in existing code. The plan's exact call
site (`memory.record(result)` between `channel.post(.resultReady)` and `onTidyingChange?(false)`)
and the `try!` Application Support path construction were implemented verbatim as specified.

## Known Stubs

None — `AppComposition.memory` is a fully real `SQLiteMemory`, not a stub; no data path in this
plan renders empty/placeholder UI (Plan 08-05 is the first consumer).

## Self-Check: PASSED

- `App/Piko/CaptureCoordinator.swift` — FOUND, contains `memory.record(result)`
- `App/Piko/AppComposition.swift` — FOUND, contains `applicationSupportDirectory`
- Commit `31d88a8` — FOUND in `git log`
- Commit `c814829` — FOUND in `git log`
