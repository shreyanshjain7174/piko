---
phase: piko-04-keyboard-extension
plan: 02
subsystem: keyboard
tags: [keyboard-extension, uitextdocumentproxy, capture-draft, stableprefix, swift-testing, mainactor]

requires:
  - phase: piko-04-keyboard-extension (Plan 04-01)
    provides: "KeyboardViewController DarwinChannel observe (draftUpdated/resultReady), KeyboardView shell, PikoKeyboardTests"
  - phase: piko-01-shared-contracts
    provides: "CaptureDraft.isNewer(than:), CaptureResult, sessionEpoch/sequence"
provides:
  - "TextInsertionController: stablePrefix-aware UITextDocumentProxy insert/delete, commit, reset"
  - "KeyboardViewController.applyDraft/applyResult/idle → insertionController"
  - "PikoKeyboardCore SPM target so insertion tests run without compiling the UIKit keyboard shell"
  - "TextInsertionControllerTests (7) + StreamingInsertionIntegrationTests (1)"
affects: [piko-05-on-device-transcription]

tech-stack:
  added: []
  patterns:
    - "alreadyStable = min(draft.stablePrefix, insertedChars); epoch change wipes alreadyStable to 0"
    - "PikoKeyboardCore is the testable slice of App/PikoKeyboard (exclude KeyboardView*, MicButton, plist, entitlements)"
    - "@MainActor on TextProxy / UITextDocumentProxyBox / TextInsertionController for Swift 6 Sendable"

key-files:
  created:
    - App/PikoKeyboard/TextInsertionController.swift
    - Tests/PikoKeyboardTests/TextInsertionControllerTests.swift
    - Tests/PikoKeyboardTests/StreamingInsertionIntegrationTests.swift
  modified:
    - App/PikoKeyboard/KeyboardViewController.swift
    - Package.swift

key-decisions:
  - "Task 3 correction: alreadyStable uses incoming draft.stablePrefix, not lastApplied.stablePrefix — research Pattern 1 froze the previous prefix and full-replaced whenever freeze was 0"
  - "New session epoch always alreadyStable=0 even if lastApplied.stablePrefix was non-zero — leftover high-water freeze would skip deletes"
  - "PikoKeyboardCore SPM target required: keyboard extension sources cannot be imported by package tests otherwise"
  - "UITextDocumentProxy is not Sendable; isolate protocol, box, controller, and tests on @MainActor"
  - "Simulator destination: iPhone 17 iOS 26.0 (UDID 6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4), not the plan's iPhone 16 Pro UDID"
  - "CAPT-01/CAPT-02 closed at algorithm+wiring level; live host-field / real speech still Phase 5 + device UI"

patterns-established:
  - "Streaming diffs: delete (insertedChars - alreadyStable) then insert dropFirst(alreadyStable); commit deletes all inserted then insertText(shipped)"
  - "Insertion algorithm lives in PikoKeyboardCore; UIKit shell stays excluded from SPM"

requirements-completed: ["CAPT-01", "CAPT-02"]

duration: ~16min
completed: 2026-08-29
---

# Phase piko-04 Plan 02: stablePrefix Streaming Insertion Summary

**`TextInsertionController` streams `CaptureDraft` into the host field by rewriting only characters after `stablePrefix`, then replaces the streamed draft with `CaptureResult.shipped` on commit — CAPT-01/CAPT-02 algorithm proven with synthetic drafts, not live speech.**

## Performance

- **Duration:** ~16 min (executor clock `2026-08-29T10:30:55Z` → `2026-08-29T10:47:08Z`)
- **Started:** 2026-08-29T10:30:55Z
- **Completed:** 2026-08-29T10:47:08Z
- **Tasks:** 4/4 completed
- **Files modified:** 5 (3 created, 2 modified)

## Accomplishments

- `TextInsertionController` owns `UITextDocumentProxy` insert/delete: `isNewer` gate, tail-only rewrite, epoch wipe, `commit` (delete streamed + insert shipped), `reset` (clear state, no proxy writes).
- `KeyboardViewController` constructs the controller in `viewDidLoad` / `viewWillAppear`, `applyDraft` → `apply(_:)`, `applyResult` → `commit(_:)`, idle → `reset()`. Removed `lastAppliedDraft` / insertion TODOs.
- Seven unit tests + one integration walk (`Hel` → `Hello` → `Hello wor` → `Hello world h` → final + commit).
- macOS `swift build` green. macOS `swift test` **25 pass / 2 fail / 27 total** (same pre-existing PikoBridge App Group pair). iOS Simulator `Piko-Package` **38/38**. `Piko` scheme **BUILD SUCCEEDED**.

## Task Commits

Each task was committed atomically:

1. **Task 1 RED: failing TextInsertionController tests** - `1425a84` (test)
2. **Task 1 GREEN: implement TextInsertionController stablePrefix diffing** - `6634818` (feat)
3. **Task 2: wire TextInsertionController into KeyboardViewController** - `2775765` (feat)
4. **Task 3: use incoming draft.stablePrefix for streaming diffs** - `85072e5` (fix)
5. **Task 4: Verify** - no extra code commit (verify-only)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## Files Created/Modified

- `App/PikoKeyboard/TextInsertionController.swift` - `@MainActor TextInsertionController` + `TextProxy` + `UITextDocumentProxyBox`; `apply`/`commit`/`reset`
- `Tests/PikoKeyboardTests/TextInsertionControllerTests.swift` - `MockTextDocumentProxy` + 7 `@MainActor` tests
- `Tests/PikoKeyboardTests/StreamingInsertionIntegrationTests.swift` - `streamingDictationScenario()`
- `App/PikoKeyboard/KeyboardViewController.swift` - owns `insertionController`; draft/result/idle wiring
- `Package.swift` - `PikoKeyboardCore` target from `App/PikoKeyboard` (UI files excluded); `PikoKeyboardTests` depends on `PikoKit` + `PikoKeyboardCore`

## Decisions Made

See `key-decisions` in frontmatter. Highlights:

- Task 3 applied the plan's documented correction: `alreadyStable = min(draft.stablePrefix, insertedChars)`, not `lastApplied.stablePrefix`. Research Pattern 1 treated freeze=0 as a full replace.
- Extra epoch wipe (`alreadyStable = 0` when `sessionEpoch` changes) kept so a leftover freeze cannot skip deletes on a new session.
- SPM cannot import a keyboard extension target → `PikoKeyboardCore` is the testable algorithm slice.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] PikoKeyboardCore SPM target**
- **Found during:** Task 1 RED
- **Issue:** Package tests cannot import keyboard-extension sources.
- **Fix:** `PikoKeyboardCore` target, path `App/PikoKeyboard`, exclude UI/plist/entitlements.
- **Files modified:** `Package.swift`
- **Commit:** `1425a84` / used by `6634818`

**2. [Rule 2 - Correctness] Epoch wipe of alreadyStable**
- **Found during:** Task 1 GREEN (Test 5)
- **Issue:** Research `lastApplied.stablePrefix` after epoch change could skip deletes.
- **Fix:** `alreadyStable = 0` on epoch change; still used after Task 3's `draft.stablePrefix` correction.
- **Files modified:** `App/PikoKeyboard/TextInsertionController.swift`
- **Commit:** `6634818` (kept through `85072e5`)

**3. [Rule 3 - Blocking] Swift 6 MainActor isolation**
- **Found during:** Task 2 iOS build
- **Issue:** `any UITextDocumentProxy` is not Sendable.
- **Fix:** `@MainActor` on `TextProxy`, `UITextDocumentProxyBox`, `TextInsertionController`, tests.
- **Files modified:** `App/PikoKeyboard/TextInsertionController.swift`, tests
- **Commit:** `2775765`

### Judgment / not Rule 1–3

- Simulator: iPhone 17 iOS 26 UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4` (same as 04-01), not plan's iPhone 16 Pro `B79D226E…`.
- Untracked xcodegen plists/entitlements left uncommitted (04-01 precedent).
- C4 ~60MB keyboard memory **not measured**.
- Device / Simulator keyboard UI (enable keyboard, type into a host field) **not performed**.

**Total deviations:** 3 auto-fixed (Rule 2 × 1, Rule 3 × 2). **Impact on plan:** Tests and iOS build unblocked; insertion semantics match the Task 3 correction plus epoch safety.

## Issues Encountered

- macOS `swift test` (full suite): **25 passed / 2 failed / 27 total**. Failures are pre-existing `PikoBridgeTests` (`ReconnectionSurvivalTests`, `RoundTripLatencyTests`) — App Group container missing in unsigned SPM/macOS. **PikoKeyboardTests 12/12 pass** on macOS (4 mic + 7 insertion + 1 integration).
- iOS Simulator `Piko-Package`: **TEST SUCCEEDED**. Breakdown:
  - PikoAudioTests: 11/11
  - PikoBridgeTests: 6/6 (App Group works under signed Simulator)
  - PikoKeyboardTests: 12/12
  - PikoKitTests: 9/9
  - **Total: 38 passed, 0 failed** (04-01 was 30/30; +8 insertion tests)
- XCTest "All tests" suites printed `Executed 0 tests` (Swift Testing only) — ignored; counts above are Swift Testing runs.

## User Setup Required

None for code. Manual device/Simulator UI still required to see streaming text in a real host field:

1. Settings → Keyboards → enable Piko, Full Access.
2. Arm in the Piko app, switch to a text field, tap mic.
3. Phase 5 must emit real `CaptureDraft` / `CaptureResult` — this plan only consumes them.

## iOS Simulator/Device Test Run

**Attempted.** iPhone 17 (iOS 26.0) UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`.

| Command | Result |
|---------|--------|
| `swift build` (macOS) | succeeded |
| `swift test` (macOS) | 25 pass / 2 fail (pre-existing PikoBridge App Group); PikoKeyboardTests 12/12 pass |
| `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` | **TEST SUCCEEDED** — 38/38 Swift Testing tests |
| `xcodegen generate` + `xcodebuild -project App/Piko.xcodeproj -scheme Piko -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4' build` | **BUILD SUCCEEDED** |
| Physical device / keyboard UI / live host-field insertion | **not attempted** |

Do not treat CAPT-01 as speech-proven. Insertion is unit-tested against `MockTextDocumentProxy`. Live Darwin drafts from a real transcriber are Phase 5.

## Next Phase Readiness

- Phase 5 can emit `CaptureDraft` with growing `stablePrefix`; keyboard already applies them.
- Do not duplicate insertion logic in the transcriber — keep freeze/rewrite in `TextInsertionController`.
- No code blockers for Phase 5 besides remaining manual keyboard-enable UI and C4 footprint measurement.

## Known Stubs

- Profile chips in `KeyboardView` still placeholders (04-01). Not required for CAPT-01/CAPT-02.
- No real SpeechAnalyzer drafts — intentional; this plan uses synthetic `CaptureDraft` sequences.

## Threat Flags

None. No new network endpoints, auth paths, or schema. Proxy writes stay in-process to the host text field.

## TDD Gate Compliance

RED commit `1425a84` then GREEN `6634818` present. Task 3 is a documented algorithm fix (`85072e5`), not a skipped RED.

## Self-Check: PASSED

- FOUND: App/PikoKeyboard/TextInsertionController.swift
- FOUND: Tests/PikoKeyboardTests/TextInsertionControllerTests.swift
- FOUND: Tests/PikoKeyboardTests/StreamingInsertionIntegrationTests.swift
- FOUND: App/PikoKeyboard/KeyboardViewController.swift
- FOUND: Package.swift
- FOUND: 1425a84
- FOUND: 6634818
- FOUND: 2775765
- FOUND: 85072e5

---
*Phase: piko-04-keyboard-extension*
*Completed: 2026-08-29*
