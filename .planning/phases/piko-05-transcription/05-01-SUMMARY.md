---
phase: piko-05-transcription
plan: 01
subsystem: audio
tags: [avaudioengine, pcm-buffers, asyncstream, session-coordinator, swift-testing, simulator]

requires:
  - "Phase 3 ArmedSession + SessionCoordinator arm/disarm/startCapture/stopCapture"
  - "PikoAudioTests AudioSessionTestGate / MockSessionChannel"
provides:
  - "ArmedSession.buffers: AsyncStream<AVAudioPCMBuffer>"
  - "SessionCoordinator AVAudioEngine input tap yielding PCM while capturing"
  - "stopCapture removes tap and stops yields; disarm finishes the stream"
  - "SessionCoordinatorBufferTests: idle / capture / stop / disarm-mid-capture"
affects: [piko-05-transcription (Plan 05-02)]

tech-stack:
  added: []
  patterns:
    - "Tap closure captures AsyncStream continuation into a local let before installTap (not self.buffersContinuation)"
    - "Recreate AVAudioEngine after setActive; fallback format when hardware reports 0 Hz"
    - "Simulator: skip engine.start (HAL hang); Task.detached silence pump yields silent PCM so 05-02 has a live stream"
    - "AudioSessionTestGate FIFO mutex serializes process-wide AVAudioSession across Swift Testing suites"

key-files:
  created:
    - Tests/PikoAudioTests/SessionCoordinatorBufferTests.swift
  modified:
    - Sources/PikoAudio/ArmedSession.swift
    - Sources/PikoAudio/SessionCoordinator.swift
    - Tests/PikoAudioTests/MockSessionChannel.swift
    - Tests/PikoAudioTests/SessionCoordinatorArmingTests.swift
    - Tests/PikoAudioTests/SessionCoordinatorInterruptionTests.swift

key-decisions:
  - "AVAudioPCMBuffer @unchecked Sendable so ArmedSession.buffers can satisfy Sendable protocol (compiler: buffer not Sendable)"
  - "Do not call AVAudioApplication.requestRecordPermission in startCapture — xctest TCC identity fails (kTCCErrorDomain Code=2)"
  - "Simulator silence pump is a correctness path for CI, not a substitute for device mic I/O"
  - "CAPT-03/CAPT-04 not marked complete: this plan delivers PCM, not 400ms first-word or 30s thrash"

patterns-established:
  - "installTap callback must not hop to @MainActor self; capture continuation locally"
  - "Swift Testing .serialized is per-suite only; process-wide audio needs a FIFO gate that stays busy for the whole body"

requirements-completed: []
requirements-not-completed: ["CAPT-03", "CAPT-04"]

duration: ~28min
completed: 2026-08-29
---

# Phase piko-05 Plan 01: AVAudioEngine Tap + PCM Buffer Stream Summary

**SessionCoordinator now owns a real AVAudioEngine input tap and exposes `ArmedSession.buffers` as `AsyncStream<AVAudioPCMBuffer>` that yields while capturing, idles while armed, and stops after `stopCapture()`.**

## Performance

- **Duration:** ~28 min (executor clock `2026-08-29T16:42:46Z` → `2026-08-29T17:10:45Z`)
- **Tasks:** 3/3 completed
- **Files modified:** 6 (1 created, 5 modified)

## Accomplishments

- `ArmedSession` gained `var buffers: AsyncStream<AVAudioPCMBuffer>`. `AVAudioPCMBuffer` is marked `@unchecked Sendable` so the protocol stays `Sendable`.
- `SessionCoordinator` recreates the engine after `setActive`, installs `inputNode.installTap` with a **local** continuation capture, connects input → mixer at `outputVolume = 0.001`.
- `stopCapture()` cancels the silence pump, removes the tap, stops the engine, returns phase `.armed` — does **not** finish the stream. `disarm()` finishes the stream.
- Simulator: `engine.start()` skipped (HAL ~2.5s hang / silent tap). `Task.detached` silence pump yields 1024-frame empty PCM every 20ms so Plan 05-02 still has a live iterator.
- `SessionCoordinatorBufferTests` (4 tests, `.serialized`, gated): idle until capture, yields during capture, drain-then-timeout after stop, disarm mid-capture.
- Full iOS Simulator `Piko-Package`: **TEST SUCCEEDED** (42 Swift Testing tests). Isolated `PikoAudioTests`: **15/15**.

## Task Commits

Each task was committed atomically:

1. **Task 1: ArmedSession.buffers + AVAudioEngine tap** - `e7ce10a` (feat); follow-up `72a4a9e` (fix silence pump)
2. **Task 2: Buffer lifecycle tests** - `f7b7b22` (test); follow-up `3e9294a` (serialize + drain leftover PCM)
3. **Task 3: Full PikoAudioTests green under parallel suites** - `ead9c11` (fix Simulator pump-first + FIFO gate)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## Files Created/Modified

- `Sources/PikoAudio/ArmedSession.swift` - `buffers` on protocol; `@unchecked Sendable` on `AVAudioPCMBuffer`
- `Sources/PikoAudio/SessionCoordinator.swift` - engine tap, local continuation, Simulator silence pump, tapInstalled flag
- `Tests/PikoAudioTests/SessionCoordinatorBufferTests.swift` - 4 lifecycle tests + BufferIteratorBox race
- `Tests/PikoAudioTests/MockSessionChannel.swift` - FIFO `AudioSessionTestGate`
- `Tests/PikoAudioTests/SessionCoordinatorArmingTests.swift` - `.serialized` + gate on session-touching tests
- `Tests/PikoAudioTests/SessionCoordinatorInterruptionTests.swift` - `.serialized` + gate

## Decisions Made

- Local `let continuation = buffersContinuation` before `installTap` — plan-mandated; tap runs off MainActor.
- No `requestRecordPermission` in `startCapture` (xctest TCC cannot construct kTCCService identity).
- Simulator PCM is **silent synthetic buffers**, not microphone samples. Device tap path still calls `engine.start()` and only pumps if hardware format is 0 Hz.
- Did **not** mark CAPT-03 / CAPT-04 complete. Those are first-word latency and 30s monologue thrash; this plan only supplies PCM.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] AVAudioPCMBuffer not Sendable**
- **Found during:** Task 1 compile
- **Issue:** `ArmedSession` is `Sendable`; isolated `buffers` could not satisfy the protocol.
- **Fix:** `extension AVAudioPCMBuffer: @unchecked Sendable {}` (retroactive conformance warning remains).
- **Files modified:** `Sources/PikoAudio/ArmedSession.swift`
- **Commit:** `e7ce10a`

**2. [Rule 1 - Bug] Tap never fired on Simulator**
- **Found during:** Task 2 / Task 3
- **Issue:** 0 Hz input format, mixer volume 0 culls render, engine created before `setActive`, `engine.start()` hangs ~2.5s / HAL timeout, parallel suites fight `AVAudioSession`.
- **Fix:** Recreate engine after activate; fallback 48 kHz format; mixer volume 0.001; skip `engine.start()` on Simulator; detached silence pump yields first buffer immediately; FIFO test gate.
- **Files modified:** `Sources/PikoAudio/SessionCoordinator.swift`, `Tests/PikoAudioTests/MockSessionChannel.swift`
- **Commits:** `72a4a9e`, `ead9c11`

**3. [Rule 2 - Critical] Tests racing AVAudioSession across suites**
- **Found during:** Task 3 (`captureProducesBuffers` timed out under full PikoAudioTests)
- **Issue:** `.serialized` is per-suite; actor `run { await body() }` hopped off isolation and let a second test enter.
- **Fix:** Gate keeps `busy` until body returns/throws; wrap session-touching tests.
- **Files modified:** `Tests/PikoAudioTests/MockSessionChannel.swift` and coordinator test files
- **Commits:** `3e9294a`, `ead9c11`

**4. [Rule 1 - Bug] requestRecordPermission in xctest**
- **Found during:** Task 3
- **Issue:** TCC `Unable to construct an identity to kTCCService` → `sessionInterrupted`.
- **Fix:** Removed permission request from `startCapture`.
- **Files modified:** `Sources/PikoAudio/SessionCoordinator.swift`
- **Commit:** `72a4a9e`

### Judgment / not Rule 1–3

- Silence pump is **not** in the original PLAN.md (hardware-tap-only). Required for Simulator CI and 05-02 wiring; device still uses real tap after `engine.start()`.
- Untracked xcodegen `App/*/Info.plist` and entitlements left uncommitted.

**Total deviations:** 4 auto-fixed. **Impact on plan:** CAPT PCM stream exists; Simulator yields silent frames, not mic samples.

## Issues Encountered

- macOS `swift build`: succeeded (warning: retroactive Sendable on `AVAudioPCMBuffer`).
- macOS `swift test`: **25 passed / 2 failed / 27 total**. Failures are pre-existing `PikoBridgeTests` App Group (`ReconnectionSurvivalTests`, Darwin round-trip) in unsigned SPM. `#if os(iOS)` PikoAudioTests skipped on macOS.
- iOS Simulator `Piko-Package` (`id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`): **TEST SUCCEEDED**.
  - PikoAudioTests: **15/15**
  - PikoBridgeTests: **6/6**
  - PikoKeyboardTests: **12/12**
  - PikoKitTests: **9/9**
  - **Total: 42 passed, 0 failed**
- Physical-device mic tap, first-word latency, background audio, and memory: **not measured**. Simulator results do not count for those (CLAUDE.md).

## User Setup Required

None for code. Device proof still needs a physical iPhone with mic permission and an armed session.

## iOS Simulator/Device Test Run

**Attempted.** iPhone 17 (iOS 26.0) UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`.

| Command | Result |
|---------|--------|
| `swift build` (macOS) | succeeded |
| `swift test` (macOS) | 25 pass / 2 fail (pre-existing PikoBridge App Group); PikoAudioTests skipped (`#if os(iOS)`) |
| `xcodebuild test -scheme Piko-Package -only-testing:PikoAudioTests` | **TEST SUCCEEDED** — 15/15 |
| `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` | **TEST SUCCEEDED** — 42/42 Swift Testing tests |
| Physical device / real microphone tap | **not attempted** |

Do not treat CAPT-03/CAPT-04 as device-proven. Buffer lifecycle is unit-tested; live SpeechAnalyzer consumption is Plan 05-02.

## Next Phase Readiness

- Plan 05-02 can subscribe to `ArmedSession.buffers` and feed SpeechTranscriber.
- On Simulator, buffers are silent PCM (non-zero `frameLength`, zeros in samples). Transcriber tests must not require audible speech from this stream.
- Device path still starts the engine; if hardware format is live, no silence pump.

## Known Stubs

- Simulator silence pump yields empty 1024-frame buffers (zeros). Intentional CI path; not a UI stub. Device tap is the production source when `engine.start()` succeeds.
- No SpeechAnalyzer / hypothesis stream — Plan 05-02.

## Threat Flags

None. No new network endpoints, auth paths, or schema. Mic capture stays on-device via existing `AVAudioSession` `.playAndRecord`. Permission prompt is not invoked from tests; production TCC still required on device.

## Self-Check: PASSED

- FOUND: Sources/PikoAudio/ArmedSession.swift
- FOUND: Sources/PikoAudio/SessionCoordinator.swift
- FOUND: Tests/PikoAudioTests/SessionCoordinatorBufferTests.swift
- FOUND: .planning/phases/piko-05-transcription/05-01-SUMMARY.md
- FOUND: e7ce10a
- FOUND: f7b7b22
- FOUND: 72a4a9e
- FOUND: 3e9294a
- FOUND: ead9c11
