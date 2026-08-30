---
phase: piko-08-history-skins
plan: 03
subsystem: PikoUI
tags: [swiftui, path, canvas, skins, rendering]

requires: ["08-01"]
provides:
  - "PikoFace real SVG-derived Path/Canvas rendering for all 4 skins x 4 phases"
  - "PikoPalette (per-skin hex color table), PikoEyeState, PikoMouthState"
  - "Skin.palette, Skin.showsEyes, SessionPhase.faceState"
affects: ["piko-08-history-skins (Plan 08-05, first container-app call site)"]

tech-stack:
  added: []
  patterns:
    - "GeometryReader + Canvas with a manual scale transform to preserve the SVG's 140x148 viewBox coordinate space, instead of per-shape SwiftUI Shape views"
    - "Static let Path constants translated 1:1 from SVG path/circle/ellipse/rect primitives, computed once per type rather than per-render"

key-files:
  created: []
  modified:
    - Sources/PikoUI/PikoFace.swift
    - Tests/PikoUITests/PikoFaceTests.swift

key-decisions:
  - "Used SwiftUI Canvas (not a stack of Shape views) — every primitive is static vector data with no interactivity, and Canvas keeps the view hierarchy flat and cheap for the keyboard extension's ~60 MB ceiling"
  - "No general-purpose hex-color parsing utility introduced — palette values are inline Color(red:green:blue:) computed from the plan's hex table, matching the one-file-need guidance in the plan"
  - ".armed phase composes eyes-wide + m-idle, a new but visually-consistent combination built only from the SVG's existing primitives per the plan's mapping table (not a literal 1:1 port of web's 4 interaction states)"

requirements-completed: [SKIN-01]
requirements-not-completed: []

duration: ~25min
completed: 2026-08-30
---

# Phase piko-08 Plan 03: Real PikoFace SVG-to-SwiftUI Path port Summary

**Replaced `PikoFace`'s placeholder `Circle`+glyph with a real `Canvas`-based Path port of `web/index.html`'s SVG character — body, blush, three eye states, three mouth states, and all four skins' accessories (antenna / shades / cape+mask / bow+sparkles), driven by exact per-skin hex colors and a phase→face-state mapping table.**

## Performance

- **Duration:** ~25 min
- **Tasks:** 2/2 completed
- **Files modified:** 2

## Accomplishments

- **Task 1:** `PikoPalette` struct + `Skin.palette` extension return the exact 4-skin/5-color hex
  table from the plan (`Color(red:green:blue:)` computed from hex bytes, no new hex-parsing
  utility). `PikoEyeState`/`PikoMouthState` enums + `SessionPhase.faceState` return the four
  documented (eye, mouth) pairs. `Skin.showsEyes` returns `false` only for `.cool`. Three `@Test`
  functions added to `PikoFaceTests.swift` (folded the original init-wiring test in alongside them
  rather than duplicating it).
- **Task 2:** `PikoFace.body` now uses `GeometryReader` + `Canvas`, applying a manual scale
  transform (`min(width/140, height/148)`) so every `Path` is authored directly in the SVG's own
  `0...140 × 0...148` viewBox coordinates — no per-shape `Shape` views, no image/PDF asset, no new
  SPM dependency. All ~25 SVG primitives (cubic/quadratic Bezier paths, circles, ellipses, one
  rounded rect, two relative-lineto sparkle stars) translated 1:1 into `static let Path` constants,
  drawn in the SVG's own document order (hero cape → antenna/bow → body → blush → hero mask → eyes
  → cool shades → mouth → sparkle tips). `skin.showsEyes` gates both the eye group and the blush
  ellipses per the plan's explicit cool-skin suppression rule; the mouth group is never gated and
  still varies by phase for `.cool`. The existing `.animation(.spring(duration: 0.35), value: phase)`
  modifier stays on the outer view.
- `swift build`: clean, `Build complete!`, no new dependency added to `Package.swift`.
- `swift test --filter PikoUITests`: 4 tests, 4 passed (0 failures).

## Task Commits

1. **Task 1 + Task 2 (landed together):** `8e83c73` (feat) — palette/mapping data and the real
   Canvas-based Path rendering were verified and committed as one unit since both tasks touch the
   same two files and Task 1's data has no independent runtime effect until Task 2 reads it.

## Deviations from Plan

### Concurrent build interference (not a deviation from this plan's own code, documented for the record)

- **Found during:** Task 2 verification (`swift build` / `swift test --filter PikoUITests`)
- **Issue:** The sibling Wave 2 plan (08-02) was mid-edit on `Sources/PikoMemory/SQLiteMemory.swift`
  in this same working tree (no isolated worktree per plan) at the moment of my first verification
  pass. `swift build` failed with an actor-isolation error in `SQLiteMemory.swift`, and
  `swift test --filter PikoUITests` failed to link because SPM builds one shared test bundle across
  all test targets in a package. Neither failure originated in `PikoFace.swift` or
  `PikoFaceTests.swift`.
- **Fix:** None applied by this plan — out of scope per the deviation rules' scope boundary (only
  fix issues directly caused by this task's own files). `swift build --target PikoUI` was used as
  an interim isolated check (passed clean both times). Re-ran the full `swift build` and
  `swift test --filter PikoUITests` a few minutes later, after 08-02's concurrent edit resolved
  itself — both passed clean with zero PikoFace-related issues at any point.
- **Files modified:** None (no PikoMemory files touched by this plan).
- **Commit:** N/A (not this plan's change).

### Auto-fixed Issues

None — Task 1 and Task 2 executed exactly as written, no bugs, missing functionality, or blocking
issues encountered in `PikoFace.swift` or `PikoFaceTests.swift` themselves.

## Self-Check: PASSED

- `Sources/PikoUI/PikoFace.swift` — FOUND
- Commit `8e83c73` — FOUND in `git log --oneline --all`
