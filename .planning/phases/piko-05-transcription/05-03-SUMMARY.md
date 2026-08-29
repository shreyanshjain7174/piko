---
phase: piko-05-transcription
plan: 03
subsystem: transcription
tags: [capture-coordinator, mock-transcriber, session-channel, wiring, pikocapturecore]

requires:
  - "Phase 5 Plan 01 ArmedSession.buffers AsyncStream PCM"
  - "Phase 5 Plan 02 SpeechTranscriberEngine.configure(buffers:sessionEpoch:) + MockTranscriber"
  - "PikoKit Transcriber + SessionChannel + CaptureDraft + CaptureResult"
provides:
  - "CaptureCoordinator: buffers → Transcriber.hypotheses → writeDraft/writeResult"
  - "AppComposition wires CaptureCoordinator; Simulator MockTranscriber, device SpeechTranscriberEngine"
  - "PikoCaptureCore SPM slice so App/Piko CaptureCoordinator is testable"
  - "CaptureIntegrationTests: MockTranscriber drafts + CaptureResult via local MockSessionChannel"
affects: [piko-06-cleanup]

tech-stack:
  added: []
  patterns:
    - "configure only via transcriber as? SpeechTranscriberEngine (Option B; MockTranscriber has no configure)"
    - "PikoCaptureCore mirrors PikoKeyboardCore: App/Piko minus app shell"
    - "PikoCaptureCoreMarker + #if os(iOS) so the SPM target compiles on macOS"

key-files:
  created:
    - App/Piko/CaptureCoordinator.swift
    - Tests/PikoTranscribeTests/CaptureIntegrationTests.swift
  modified:
    - App/Piko/AppComposition.swift
    - App/Piko/PikoApp.swift
    - Package.swift

key-decisions:
  - "Honor 05-02 API: configure(buffers:sessionEpoch:), not AnalyzerInputConverter"
  - "PikoCaptureCore SPM target required so PikoTranscribeTests can import CaptureCoordinator"
  - "CAPT-03/CAPT-04/CAPT-05 not marked complete: MockTranscriber wiring only; no device 400ms / 30s / live keyboard speech"

patterns-established:
  - "App types that tests need live in an SPM core target excluding Info.plist, entitlements, and UIKit app shell"
  - "Simulator composition uses MockTranscriber; device composition uses SpeechTranscriberEngine"

requirements-completed: []
requirements-not-completed: ["CAPT-03", "CAPT-04"]

duration: ~12min
completed: 2026-08-29
---

# Phase piko-05 Plan 03: CaptureCoordinator wiring Summary

**CaptureCoordinator connects SessionCoordinator.buffers to Transcriber hypotheses and writes CaptureDraft / CaptureResult on SessionChannel; Simulator uses MockTranscriber, device uses SpeechTranscriberEngine.configure. Proven only with MockTranscriber integration tests — not real speech.**

## Performance

- **Duration:** ~12 min wall (`2026-08-29T17:24:05Z` → `2026-08-29T17:36:02Z`)
- **Tasks:** 3/3 completed
- **Files modified:** 5 (2 created, 3 modified)

## Accomplishments

- `CaptureCoordinator` (`@MainActor`, iOS-only): `startCapture` bumps `sessionEpoch`, starts `SessionCoordinator`, configures `SpeechTranscriberEngine` when present, streams `hypotheses()` to `writeDraft` + `post(.draftUpdated)`. `stopCapture` stops session, cancels the task, `finish()`, writes `CaptureResult` + `post(.resultReady)`.
- `AppComposition` constructs coordinator; `#if targetEnvironment(simulator)` → `MockTranscriber()`, else `SpeechTranscriberEngine()`. Observes `channel.signals` and calls `handleSignal`.
- `PikoApp` ArmView shows `Recording...` when `phase == .capturing`. `Processing...` for `.tidying` is unused: `SessionCoordinator.stopCapture()` returns `.armed`, not `.tidying`.
- `PikoCaptureCore` SPM target exposes `CaptureCoordinator` to `PikoTranscribeTests` without the UIKit app shell.
- Integration tests: `startCaptureBeginsDraftFlow` (scripted drafts + `.draftUpdated`); `stopCaptureWritesResult` (`CaptureResult.raw` + `.resultReady`).

## Task Commits

Each task was committed atomically:

1. **Task 1: CaptureCoordinator** - `5eb86c0` (feat)
2. **Task 2: AppComposition + ArmView** - `c2d848a` (feat)
3. **Task 3: CaptureIntegrationTests + PikoCaptureCore** - `4b5b41e` (test)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## TDD Gate Compliance

Plan frontmatter is `type: execute`, not `type: tdd`. Task 3 has `tdd="true"`. Implementation landed in Tasks 1–2 first; Task 3 tests passed after a Foundation/`NSLock` compile fix (GREEN without a failing RED commit). Same honesty as 05-02.

## Files Created/Modified

- `App/Piko/CaptureCoordinator.swift` - orchestration + `PikoCaptureCoreMarker` + `#if os(iOS)`
- `App/Piko/AppComposition.swift` - composition root wiring
- `App/Piko/PikoApp.swift` - capturing / tidying labels
- `Tests/PikoTranscribeTests/CaptureIntegrationTests.swift` - MockTranscriber integration
- `Package.swift` - `PikoCaptureCore` + `PikoTranscribeTests` dependency

## Decisions Made

- Option B configure via `as? SpeechTranscriberEngine` so PikoKit `Transcriber` stays `hypotheses()` / `finish()` / `setLexicon`. CLAUDE.md prefers protocols; this cast is the 05-02 Option B entrypoint, not a new protocol method.
- PikoCaptureCore (Rule 3) so tests can import App/Piko types — same pattern as PikoKeyboardCore.
- Did **not** mark CAPT-03 / CAPT-04 complete. Wiring exists; first-word 400ms and 30s thrash need physical-device speech. CAPT-05 is not in REQUIREMENTS.md.

## Speech / audio path

| Piece | Reality |
|-------|---------|
| Engine feed | `SpeechTranscriberEngine.configure(buffers:sessionEpoch:)` then `hypotheses()` |
| Simulator transcriber | `MockTranscriber` — ignores PCM, yields script |
| Device transcriber | `SpeechTranscriberEngine` — compiled, **not run on a device this plan** |
| SessionCoordinator buffers | Simulator silence pump (zeros) from 05-01 |
| DarwinChannel.writeDraft | Already posts `.draftUpdated`; CaptureCoordinator posts again (duplicate doorbell possible) |
| stopCapture phase | `.armed`, not `.tidying` |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] CaptureCoordinator not importable by PikoTranscribeTests**
- **Found during:** Task 3
- **Issue:** Plan puts coordinator in App/Piko; SPM tests cannot `@testable import` the app target.
- **Fix:** `PikoCaptureCore` target (`path: App/Piko`, exclude app shell / plists). `PikoCaptureCoreMarker` + `#if os(iOS)` so macOS still compiles an empty-ish module.
- **Files modified:** `Package.swift`, `App/Piko/CaptureCoordinator.swift`
- **Commit:** `4b5b41e`

**2. [Rule 1 - Bug] NSLock / Foundation missing in CaptureIntegrationTests**
- **Found during:** Task 3 iOS compile
- **Issue:** Local `AudioSessionTestGate` uses `NSLock`; iOS test compile failed without `import Foundation`.
- **Fix:** Import Foundation; `@MainActor in` on gate bodies (same as PikoAudioTests).
- **Files modified:** `Tests/PikoTranscribeTests/CaptureIntegrationTests.swift`
- **Commit:** `4b5b41e`

### Judgment / not Rule 1–3

- Plan snippets assumed AnalyzerInputConverter; used 05-02 `configure` + engine cast.
- Duplicate `.draftUpdated` / `.resultReady` vs DarwinChannel.write* left in place (plan asked CaptureCoordinator to post; DarwinChannel already does).
- `stopCapture` does not enter `.tidying` (SessionCoordinator contract from 05-01).
- Task 3 TDD RED skipped (impl already in Tasks 1–2).
- Untracked xcodegen `App/*/Info.plist` and entitlements left uncommitted.
- App scheme lives on `App/Piko.xcodeproj`, not the workspace `Piko-Package` scheme. App build used `-project App/Piko.xcodeproj -scheme Piko`.
- CAPT-03/CAPT-04 left pending. CAPT-05 not in REQUIREMENTS.md — not marked.

**Total deviations:** 2 auto-fixed. **Impact on plan:** Pipeline wired for MockTranscriber tests. No live speech proof.

## Issues Encountered

- macOS `swift build`: **succeeded**.
- macOS `swift test`: **33 passed / 2 failed / 35 total**. Failures are pre-existing `PikoBridgeTests` App Group (`ReconnectionSurvivalTests`, Darwin round-trip) in unsigned SPM. Capture integration suite is `#if os(iOS)` so it is a no-op on macOS (suite still reports passed with no tests).
- iOS Simulator `Piko-Package` (`id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`): **TEST SUCCEEDED**.
  - PikoAudioTests: **15/15**
  - PikoBridgeTests: **6/6**
  - PikoKeyboardTests: **12/12**
  - PikoKitTests: **9/9**
  - PikoTranscribeTests: **10/10** (8 prior + 2 CaptureIntegrationTests)
  - **Total: 52 passed, 0 failed**
- iOS Simulator `xcodebuild build -project App/Piko.xcodeproj -scheme Piko` same destination: **BUILD SUCCEEDED**.
- Physical-device speech, 400ms first word, 30s thrash, keyboard host-field E2E: **not measured**. Simulator PCM is silent zeros. MockTranscriber does not exercise SpeechAnalyzer.

## User Setup Required

None for code. Device proof still needs a physical iPhone, mic permission, speech assets, and a host field with the Piko keyboard.

## iOS Simulator/Device Test Run

**Attempted.** iPhone 17 (iOS 26.0) UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`.

| Command | Result |
|---------|--------|
| `swift build` (macOS) | succeeded |
| `swift test` (macOS) | 33 pass / 2 fail (pre-existing PikoBridge App Group) |
| `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4' -only-testing:PikoTranscribeTests` | **TEST SUCCEEDED** — 10/10 |
| `xcodebuild test -scheme Piko-Package` same destination | **TEST SUCCEEDED** — 52/52 |
| `xcodebuild build -project App/Piko.xcodeproj -scheme Piko` same destination | **BUILD SUCCEEDED** |
| Physical device / audible speech through SpeechAnalyzer into keyboard | **not attempted** |

Do not treat CAPT-03/CAPT-04 as device-proven. Integration coverage is MockTranscriber → channel only.

## Next Phase Readiness

- Plan 06 can rewrite `CaptureResult.shipped` (today `shipped == raw`; TODO phase 6 in CaptureCoordinator).
- On Simulator, do not expect non-empty SpeechAnalyzer text; MockTranscriber is the deterministic path.
- Keyboard insertion path from 04-02 still consumes drafts via Darwin signals; duplicate doorbells possible but writeDraft itself is real.

## Known Stubs

- `CaptureResult.shipped` copies `raw` until Brain (phase 6).
- ArmView `Processing...` never shows after stop (phase stays `.armed`).
- Simulator MockTranscriber in AppComposition has no `setScript` — live Simulator app will not stream scripted drafts unless something else sets a script.
- `SpeechTranscriberEngine` still iOS-only; lexicon stored not applied (05-02).
- Engine `hypotheses()` can finish empty if configure/auth/assets fail — no UI error surface.

## Threat Flags

None new. No new network endpoints. Mic audio stays in-process. Keyboard still remote-control only (C1).

## Self-Check: PASSED

- FOUND: App/Piko/CaptureCoordinator.swift
- FOUND: App/Piko/AppComposition.swift
- FOUND: App/Piko/PikoApp.swift
- FOUND: Tests/PikoTranscribeTests/CaptureIntegrationTests.swift
- FOUND: Package.swift (PikoCaptureCore)
- FOUND: .planning/phases/piko-05-transcription/05-03-SUMMARY.md
- FOUND: 5eb86c0
- FOUND: c2d848a
- FOUND: 4b5b41e
