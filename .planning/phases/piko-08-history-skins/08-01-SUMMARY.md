---
phase: piko-08-history-skins
plan: 01
subsystem: build/testing
tags: [spm, test-target, scaffolding]

requires: []
provides:
  - "PikoMemoryTests SPM test target, dependencies [PikoMemory, PikoKit]"
  - "PikoUITests SPM test target, dependencies [PikoUI, PikoKit]"
affects: [piko-08-history-skins (Plans 08-02, 08-03 extend these targets with real tests)]

tech-stack:
  added: []
  patterns:
    - "New .testTarget entries grouped immediately after PikoKitTests, not appended at the end of targets:"

key-files:
  created:
    - Tests/PikoMemoryTests/SQLiteMemoryTests.swift
    - Tests/PikoUITests/PikoFaceTests.swift
  modified:
    - Package.swift

key-decisions:
  - "Starter tests assert real behavior (EphemeralMemory conforms to Memory; PikoFace stores its init args), not vacuous #expect(true), per plan instruction"

patterns-established:
  - "Wave 1 = exclusive Package.swift edit; Wave 2 plans (08-02, 08-03) can now run genuinely parallel with zero file overlap"

requirements-completed: [HIST-01, HIST-02, SKIN-01]
requirements-not-completed: []

duration: ~5min
completed: 2026-08-30
---

# Phase piko-08 Plan 01: PikoMemoryTests + PikoUITests scaffolding Summary

**Added `PikoMemoryTests` and `PikoUITests` as real SPM test targets with one genuine (non-vacuous) passing `@Test` each, unblocking Plans 08-02 and 08-03 to run in the same wave without both touching `Package.swift`.**

## Performance

- **Duration:** ~5 min
- **Tasks:** 1/1 completed
- **Files modified:** 3 (1 modified, 2 created)

## Accomplishments

- `Package.swift` gains `.testTarget(name: "PikoMemoryTests", dependencies: ["PikoMemory", "PikoKit"])` and `.testTarget(name: "PikoUITests", dependencies: ["PikoUI", "PikoKit"])`, placed immediately after `PikoKitTests` per plan instruction — purely additive, no other line touched.
- `Tests/PikoMemoryTests/SQLiteMemoryTests.swift` — one `@Test` confirming `EphemeralMemory` (the one real `Memory`-conforming type currently in `PikoMemory`) actually conforms to `Memory`.
- `Tests/PikoUITests/PikoFaceTests.swift` — one `@Test` constructing a real `PikoFace(phase: .idle, skin: .cute)` and asserting both stored properties round-trip correctly.
- `swift build`: clean, `Build complete!`.
- `swift test --filter PikoMemoryTests`: 1 test, 1 passed.
- `swift test --filter PikoUITests`: 1 test, 1 passed.
- Full `swift test`: 67 tests, 2 pre-existing failures (both `PikoBridgeTests` App-Group-container environment limitations, documented since Phase 2 — see below). Zero new failures, zero regressions.

## Task Commits

1. **Task 1: Add PikoMemoryTests and PikoUITests targets with starter placeholder tests** - `b8c0140` (feat)

## Files Created/Modified

- `Package.swift` — two new `.testTarget` declarations
- `Tests/PikoMemoryTests/SQLiteMemoryTests.swift` — new, `targetIsWired()` proving `EphemeralMemory: Memory`
- `Tests/PikoUITests/PikoFaceTests.swift` — new, `targetIsWired()` proving `PikoFace` init + stored properties

## Deviations from Plan

None — plan executed exactly as written. `Package.swift` edit was purely additive at the exact location specified; both starter test files match the plan's action prose verbatim (including the real, non-placeholder assertions).

## Issues Encountered

- macOS `swift build`: **succeeded**, clean.
- macOS `swift test`: **65 passed / 2 failed / 67 total**. The 2 failures are the pre-existing `PikoBridgeTests` App-Group-container environment limitation (`ReconnectionSurvivalTests`, `RoundTripLatencyTests`) documented in every phase since Phase 2 (unsigned SPM/macOS test environment cannot create the App Group container). Unrelated to this plan's changes — confirmed by targeted `--filter` runs on both new targets (1/1 pass each) before running the full suite.

## Self-Check: PASSED

- FOUND: Package.swift (modified, contains PikoMemoryTests/PikoUITests entries)
- FOUND: Tests/PikoMemoryTests/SQLiteMemoryTests.swift
- FOUND: Tests/PikoUITests/PikoFaceTests.swift
- FOUND: commit b8c0140 in `git log --oneline`
