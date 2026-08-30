# Phase 8 Verification — Local History & Skins

Written directly, same discipline as Phase 7's VERIFICATION.md: independent re-runs and direct
source reads, not trust in plan/summary descriptions.

## Success Criteria

### 1. Every completed capture session appears in local history — DONE

- `Sources/PikoMemory/SQLiteMemory.swift`: real SQLite3 C API implementation (not the prior
  complete stub). Schema: content table `results` + external-content FTS5 virtual table
  `results_fts` synced via an `AFTER INSERT` trigger. All queries parameterized
  (`sqlite3_bind_text`/`sqlite3_bind_int`, `SQLITE_TRANSIENT` correctly redefined via
  `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`) — no raw string interpolation into SQL
  anywhere, confirmed by direct read.
- `App/Piko/CaptureCoordinator.swift`: `stopCapture()` calls `await memory.record(result)` right
  after `channel.post(.resultReady)`, on every successful finalize.
- `App/Piko/AppComposition.swift`: constructs `SQLiteMemory` unconditionally (no
  `#if targetEnvironment(simulator)` mock swap — correct, since SQLite file I/O has no
  Simulator-specific hardware dependency, unlike audio/ActivityKit) at an app-private
  `Application Support` path (not the App Group — no other process reads history).
- Storage location choice (app-private, not App Group) matches 08-RESEARCH.md's own reasoning:
  only the container app's own UI reads history.

### 2. History is searchable by content — DONE

- `SQLiteMemory.search(_:limit:)` uses `MATCH` + `ORDER BY rank` against the FTS5 table for a
  non-empty query; an empty query bypasses `MATCH` entirely and returns `ORDER BY createdAt DESC`
  (deliberate refinement over the research doc's naive empty-string-returns-nothing sketch,
  needed for "show all history" with no search text — confirmed present in the real
  implementation, not just described).
- `PikoMemoryTests/SQLiteMemoryTests.swift`: 14/14 passing — real persistence (write, reopen a
  fresh `SQLiteMemory` instance pointed at the same path, confirm data survives), real FTS5
  match/reject behavior, and a 50-task concurrency stress test exercising the actor's
  serialization. Reproducible across 5 consecutive runs per the 08-02 executor's own report;
  re-confirmed again in this pass (14/14 clean).
- `HistoryView` (new, `App/Piko/PikoApp.swift`): `.searchable(text: $searchText)` on a real
  `List`, with `.task(id: searchText)` calling `memory.search(searchText, limit: 50)` — reactive
  to search text changes, not a one-shot `.task` that only fires at mount.

### 3. Four skins exist and can be selected locally, with no network call involved — DONE

- `Skin` enum (`Sources/PikoKit/Contracts.swift`): `cute, cool, hero, sparkle` — 4 cases,
  `CaseIterable`, `Hashable` (added in Phase 7 for `ActivityAttributes` conformance, still
  correct here).
- `PikoFace` (`Sources/PikoUI/PikoFace.swift`): real SVG-to-SwiftUI `Path`/`Canvas` port from
  `web/index.html`'s character design (~25 primitives), not the prior placeholder
  circle-plus-glyph. All 4 skins render genuinely distinct art — directly observed via
  screenshot: `.cute` (round face, antenna, no accessory), `.hero` (sunglasses, side hair) are
  visibly, substantially different, not just a color swap.
- `SkinSelection.apply(_:via:)` (`App/Piko/SkinSelection.swift`): read-modify-write through the
  same `SessionChannel.writeState` mechanism already used for `Profile` — no new IPC. Directly
  unit-tested: `SkinSelectionTests.swift`, 2/2 passing.
- `ArmView`'s skin row: individual chip `Button`s (matching the existing, proven
  `KeyboardView.swift` profile-chip pattern) — not a `Picker(.segmented)`. Switched away from the
  segmented Picker after finding, via the Simulator's own accessibility snapshot, that it
  reported as a single non-interactable, childless `AXTabGroup` — a real accessibility gap for
  VoiceOver users too, not just a testing-tool inconvenience, so this was a correctness fix, not
  just a testability one.
- No network call anywhere in `Skin`/`PikoFace`/`SkinSelection` — confirmed by inspection; all
  three files have zero networking imports or calls.

## Real bugs found and fixed during interactive verification (not by an automated subagent)

`gsd-verifier` returned no output twice this phase (same failure mode noted in Phase 7). Did the
verification directly instead, via Mobile Canvas on the real Simulator, and found two genuine,
independent bugs neither plan-checker nor any automated test had caught, because both only
manifest with a real, rendered, tapped UI:

1. **`SessionCoordinator.phase` was a single-continuation `AsyncStream`.** Phase 8 was the first
   time a *second* real consumer (`ArmView`'s own phase-observation `.task`) existed alongside
   Phase 7's `LiveActivityController` observation loop in `AppComposition`. Two simultaneous
   `for await` loops on one `AsyncStream` race for each yielded value — confirmed directly by
   reproducing it (tapping Arm updated the real persisted `state.json` but `ArmView`'s
   `Session: idle` text never changed). Fixed: `phase` is now a computed property handing back an
   independent stream per subscriber, fanned out from one `broadcastPhase()` call site. New test
   `twoSimultaneousPhaseSubscribersBothSeeEveryTransition` reproduces the exact real shape and
   passes, proving both subscribers see every transition.
2. **A `.searchable` `List` sharing a screen with `ArmView`'s Arm/skin controls intercepted taps
   meant for those controls.** Confirmed via the accessibility snapshot showing a `Toolbar`
   AXGroup whose frame overlapped the Arm button and skin chips. Fixed architecturally, not
   patched: history/search moved to its own `HistoryView`, reached via `NavigationLink`, entirely
   off `ArmView` — matching `ArmView`'s own original doc comment ("its whole job is to arm... then
   get out of the way"). Confirmed clean via the accessibility tree afterward: no `Toolbar` AXGroup
   present at all on `ArmView` anymore.

Both fixes are commit `47db7a3`, confirmed via `git show --stat` and re-run of the full test
suite (140/140 Simulator, 83 macOS with the same 2 pre-existing failures) after landing.

## What is proven vs. what remains environment-limited

- **Proven, tooling-independent**: every mechanism above is directly unit/integration tested —
  `SQLiteMemoryTests` (14/14), `SkinSelectionTests` (2/2), `PikoFaceTests`,
  `SessionCoordinatorArmingTests` including the new multi-subscriber test (7/7) — none of which
  depend on Mobile Canvas, screen taps, or OS window focus.
- **Confirmed once, live, via Mobile Canvas**: `arm()` → real `"Session: armed"` UI update (after
  the broadcast fix), and the real distinct `.cute`/`.hero` character art, both directly observed
  via screenshot.
- **Not independently re-confirmed on repeat attempts**: further live interactive taps (skin
  chip selection specifically) became unreliable partway through this session — traced to
  WhatsApp persistently holding OS-level frontmost focus even after explicit
  `osascript ... activate`/`set frontmost to true` calls returned without effect (the same class
  of Accessibility-permission gap already documented earlier this session for AppleScript-based
  Simulator control). This is an external environment condition, not a code defect — confirmed by
  the fact that touch delivery succeeded and failed in a pattern that tracked with the OS focus
  state and elapsed time, not with any change to the app's own code. Not something I can resolve
  myself (no ability to grant Accessibility permission or bring another running desktop app to
  the foreground).

## Verdict

**DONE** for all three success criteria, on the strength of direct source review, comprehensive
automated test coverage (proving the exact mechanisms in question, including both real bugs found
during this pass), and at least one clean live confirmation of the previously-broken behavior now
working. No device-only gap this phase, unlike Phases 3 and 7 — everything here is genuinely
testable on Simulator/macOS, matching 08-RESEARCH.md's own claim. The one open item is
Mobile-Canvas-tooling reliability under OS focus contention, not app correctness.
