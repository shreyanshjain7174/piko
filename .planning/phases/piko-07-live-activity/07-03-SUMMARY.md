---
phase: piko-07-live-activity
plan: 03
subsystem: ui
tags: [widgetkit, activitykit, appintents, live-activity, dynamic-island]

requires:
  - phase: piko-07-live-activity (07-01)
    provides: PikoAttributes/ContentState in PikoKit, Signal.stopRequested
provides:
  - "@main WidgetBundle entry point for App/PikoWidgets"
  - "ActivityConfiguration/DynamicIsland view rendering PikoFace for LACT-01"
  - "StopSessionIntent (LiveActivityIntent) posting Signal.stopRequested for LACT-02"
  - "PikoWidgets CFBundleDisplayName fix (same pattern as PikoKeyboard)"
affects: [piko-07-live-activity (07-02, integration/manual-verify pass)]

tech-stack:
  added: []
  patterns:
    - "LiveActivityIntent (not AppIntent) for widget-fired actions that must not foreground the app"

key-files:
  created:
    - App/PikoWidgets/PikoWidgetsBundle.swift
    - App/PikoWidgets/PikoLiveActivityWidget.swift
    - App/PikoWidgets/StopSessionIntent.swift
  modified:
    - App/project.yml

key-decisions:
  - "PikoWidgetsBundle.swift needs an explicit 'import SwiftUI' alongside 'import WidgetKit', or Widget/WidgetBundle fail to resolve in that specific file (see Deviations)."

requirements-completed: [LACT-01, LACT-02]

duration: ~35min
completed: 2026-08-30
---

# Phase piko-07-live-activity Plan 03: Widget Extension — @main, Live Activity View, Stop Button Summary

**`App/PikoWidgets` now has a real `@main WidgetBundle`, a `PikoFace`-rendering `ActivityConfiguration`/`DynamicIsland`, and a `LiveActivityIntent`-based stop button wired to the existing `DarwinChannel`/`Signal.stopRequested` — all three things the target was previously missing entirely.**

## Performance

- **Duration:** ~35 min (most of it diagnosing a WidgetKit import-resolution failure)
- **Tasks:** 3/3 completed
- **Files modified:** 4 (1 modified, 3 created)

## Accomplishments
- Fixed the `CFBundleDisplayName` gap in `PikoWidgets`' `project.yml` target (same pattern that already broke Simulator installs twice for `PikoKeyboard`)
- `StopSessionIntent` is a `LiveActivityIntent` (not a plain `AppIntent`) posting `.stopRequested` via the existing, unmodified `DarwinChannel()!.post(...)` — no new IPC mechanism
- `PikoWidgetsBundle` (`@main WidgetBundle`) and `PikoLiveActivityWidget` (`ActivityConfiguration`/`DynamicIsland`) give the extension a real entry point and a Live Activity view that renders unmodified `PikoFace` on the Lock Screen and in all four Dynamic Island regions (`.expanded(.center)`, `.expanded(.bottom)`, `compactLeading`, `compactTrailing`, `minimal`)

## Task Commits

1. **Task 1: Fix PikoWidgets' CFBundleDisplayName; regenerate and verify** - `33222c7` (feat) — also folds in Task 2's `PikoBridge` dependency addition since both are the same `project.yml` hunk
2. **Task 2: StopSessionIntent — LiveActivityIntent posting Signal.stopRequested** - `3c0a823` (feat)
3. **Task 3: Widget view — @main WidgetBundle, ActivityConfiguration/DynamicIsland with PikoFace** - `66ffcf0` (feat)

_Note: Task 1 and Task 2 both touch `App/project.yml`'s `PikoWidgets` target block in adjacent lines; they were committed together under Task 1's commit rather than split with `git add -p`, since the hunks are inseparable in practice. Task 2's own file (`StopSessionIntent.swift`) still has its own commit._

## Files Created/Modified
- `App/project.yml` - `PikoWidgets` target: added `CFBundleDisplayName: Piko`; added `PikoBridge` to `dependencies.products`
- `App/PikoWidgets/StopSessionIntent.swift` - `LiveActivityIntent` calling `DarwinChannel()!.post(.stopRequested)`
- `App/PikoWidgets/PikoWidgetsBundle.swift` - `@main struct PikoWidgetsBundle: WidgetBundle`
- `App/PikoWidgets/PikoLiveActivityWidget.swift` - `ActivityConfiguration(for: PikoAttributes.self)` + `DynamicIsland` rendering `PikoFace`, stop button in Lock Screen + `.expanded(.bottom)`

## Decisions Made
- Kept `App/PikoWidgets/PikoLiveActivity.swift` (the 07-01 stub with only comments) untouched rather than deleting it or folding its content in — it's not in this plan's `files_modified`, has no conflicting declarations, and deleting it wasn't necessary for any success criterion.
- Did not build a custom waveform view for `context.state.levels` (explicitly out of scope per plan text) — Lock Screen shows `PikoFace` + word count + stop button only.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `PikoWidgetsBundle.swift` needs an explicit `import SwiftUI`**
- **Found during:** Task 3, first `xcodebuild build -scheme Piko` verification
- **Issue:** With only `import WidgetKit` (as the plan's `Pattern 4`-style example and `PikoLiveActivity.swift`'s own header comment implied was sufficient), the compiler reported `error: cannot find type 'Widget' in scope` and `error: cannot find type 'WidgetBundle' in scope` for `PikoWidgetsBundle.swift` specifically — even though `import WidgetKit` was present and `WidgetKit.framework` is confirmed present in the iOS 26.0 Simulator SDK. The sibling file `PikoLiveActivityWidget.swift`, which also references `Widget`/`WidgetConfiguration` but additionally imports `ActivityKit`/`SwiftUI`/`PikoKit`/`PikoUI`, compiled the same bare `Widget` protocol conformance with zero errors. Ruled out: stale/corrupted DerivedData (wiped `~/Library/Developer/Xcode/DerivedData/Piko-*` entirely and rebuilt from scratch — identical error), file content corruption (verified via `python3 -c "print(repr(...))"` — clean), and Signing-related issues (unrelated `-target PikoWidgets` standalone build gives a different, unrelated signing error).
- **Fix:** Added `import SwiftUI` above `import WidgetKit` in `PikoWidgetsBundle.swift`. This resolved both errors immediately; no other change was needed.
- **Files modified:** `App/PikoWidgets/PikoWidgetsBundle.swift`
- **Verification:** Full clean `xcodebuild build -scheme Piko` re-run — zero errors attributable to any `App/PikoWidgets/*` file or `App/project.yml` afterward (see Issues Encountered for the remaining, out-of-scope failure).
- **Committed in:** `66ffcf0` (part of Task 3 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1)
**Impact on plan:** Necessary for correctness — the widget extension would not have compiled at all otherwise. No scope creep; only the one import line was added.

## Issues Encountered

**`xcodebuild build -scheme Piko` currently fails — but not due to this plan's files.**

After the `import SwiftUI` fix, every file this plan created or modified (`App/PikoWidgets/PikoWidgetsBundle.swift`, `App/PikoWidgets/PikoLiveActivityWidget.swift`, `App/PikoWidgets/StopSessionIntent.swift`, `App/project.yml`) compiles with zero errors, confirmed across two independent full clean builds (`rm -rf ~/Library/Developer/Xcode/DerivedData/Piko-*` between them). The build's remaining failure is entirely in `App/Piko/LiveActivityController.swift:75` and `:88` — `error: sending 'activity' risks causing data races` — a Swift 6 strict-concurrency `Sendable` issue in Plan 07-02's code.

`git status --short` confirms `App/Piko/LiveActivityController.swift` (and `LiveActivityContent.swift`, `Tests/PikoTranscribeTests/LiveActivityContentTests.swift`) are **untracked**, i.e. Plan 07-02's own in-progress, not-yet-committed work, being executed concurrently in this same checkout by a separate agent during this session. This plan's frontmatter explicitly declares it "runs in parallel with Plan 07-02" and "does not touch `App/Piko`... at all" — per plan boundaries, `LiveActivityController.swift` was left untouched.

**This plan's own success criteria (Task 1–3 `<done>` criteria) are met.** The plan-level success criterion "`xcodebuild build -scheme Piko` succeeds on the iOS Simulator with the widget extension embedded" is **not yet met end-to-end**, but only because of Plan 07-02's incomplete, uncommitted state — re-running the same build command once Plan 07-02 lands and fixes its own `Sendable` diagnostic should succeed without any further changes to this plan's files. **Recommend re-running `xcodebuild build -scheme Piko` after Plan 07-02 completes, to get a true end-to-end BUILD SUCCEEDED confirming both plans compile together.**

## Verification Gap (carried from plan)

Per the plan's own `<verification>` section item 3: whether the widget extension actually registers on the Simulator, and whether the Dynamic Island/Lock Screen presentation renders and the stop button is tappable, needs an actual install-and-arm run — not covered by a compile-only check. **VERIFICATION.md: PARTIALLY DONE** (matching the plan's own stated Phase 3 precedent), now for two reasons: (1) the stated manual-install gap, and (2) the full-scheme build itself is currently blocked by Plan 07-02's in-flight work as described above.
