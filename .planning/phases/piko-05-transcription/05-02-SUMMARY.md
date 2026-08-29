---
phase: piko-05-transcription
plan: 02
subsystem: transcription
tags: [speech-analyzer, speech-transcriber, capture-draft, stableprefix, mock-transcriber, ios26]

requires:
  - "Phase 5 Plan 01 ArmedSession.buffers AsyncStream PCM"
  - "PikoKit Transcriber + CaptureDraft"
provides:
  - "SpeechTranscriberEngine: SpeechAnalyzer + SpeechTranscriber → AsyncStream<CaptureDraft>"
  - "Option B configure(buffers:sessionEpoch:) without PikoKit protocol change"
  - "Phrase accumulation: CaptureDraft.text is running finalized phrases + current phrase"
  - "MockTranscriber scripted hypotheses for tests and Simulator"
  - "PikoTranscribeTests: 8 tests (stablePrefix + MockTranscriber)"
affects: [piko-05-transcription (Plan 05-03)]

tech-stack:
  added: []
  patterns:
    - "SpeechAnalyzer.start(inputSequence:) + AnalyzerInput(buffer:), not AnalyzerInputConverter"
    - "AVAudioConverter to SpeechTranscriber.bestAvailableAudioFormat before AnalyzerInput"
    - "String(result.text.characters) for AttributedString; never bestTranscription.formattedString"
    - "isFinal phrases append to accumulatedText; volatile drafts prefix accumulatedText + current phrase"

key-files:
  created:
    - Sources/PikoTranscribe/MockTranscriber.swift
    - Tests/PikoTranscribeTests/StablePrefixTests.swift
    - Tests/PikoTranscribeTests/MockTranscriberTests.swift
  modified:
    - Sources/PikoTranscribe/SpeechTranscriberEngine.swift
    - Package.swift

key-decisions:
  - "Option B configure(buffers:sessionEpoch:) — Transcriber protocol unchanged"
  - "AnalyzerInputConverter does not exist in iOS 26.0 Speech.swiftmodule; used AnalyzerInput + start(inputSequence:)"
  - "Not SFSpeechRecognizer recognition fallback — SpeechAnalyzer types compiled on iOS Simulator"
  - "CAPT-03/CAPT-04 not marked complete: no device 400ms / 30s thrash proof"

patterns-established:
  - "Per-phrase SpeechTranscriber.Result must accumulate; a draft is never the latest phrase alone"
  - "T-05-04: SpeechTranscriber.isAvailable and SFSpeechRecognizer()?.isAvailable before start"
  - "MockTranscriber.Script.progressive for deterministic CaptureDraft sequences"

requirements-completed: []
requirements-not-completed: ["CAPT-03", "CAPT-04"]

duration: ~8min
completed: 2026-08-29
---

# Phase piko-05 Plan 02: SpeechTranscriberEngine + MockTranscriber Summary

**SpeechTranscriberEngine consumes `AsyncStream<AVAudioPCMBuffer>` via Option B `configure`, runs iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (AnalyzerInput stream, not AnalyzerInputConverter), and yields accumulated `CaptureDraft` hypotheses; MockTranscriber plus 8 unit tests cover conservative stablePrefix.**

## Performance

- **Duration:** ~8 min wall after resume (executor clock `2026-08-29T17:13:40Z` → `2026-08-29T17:21:00Z`; Tasks 1–2 already committed in same session before compaction)
- **Tasks:** 3/3 completed
- **Files modified:** 5 (3 created, 2 modified)

## Accomplishments

- `SpeechTranscriberEngine` is an iOS-only actor: `configure(buffers:sessionEpoch:)`, `hypotheses()` → `runRecognition`, `finish()` returns `accumulatedText`.
- Text path: `String(result.text.characters)`. Finalized phrases append to `accumulatedText`; volatile `stablePrefix` is `accumulatedText.count` (prior finals only); punctuation `.?!` or `isFinal` uses full current string length.
- Asset install: `AssetInventory.assetInstallationRequest(forModules:)` then `downloadAndInstall()`.
- T-05-04: `SpeechTranscriber.isAvailable` + `SFSpeechRecognizer()?.isAvailable` before start; `SFSpeechRecognizer.requestAuthorization` first.
- `MockTranscriber` + `Script.progressive` for tests/Simulator (no Speech framework).
- `PikoTranscribeTests` target: 8 tests, all pass on macOS and iOS Simulator.

## Task Commits

Each task was committed atomically:

1. **Task 1: SpeechTranscriberEngine** - `6baf180` (feat)
2. **Task 2: MockTranscriber** - `5329199` (feat)
3. **Task 3: PikoTranscribeTests** - `aa74d8d` (test)

_Note: this SUMMARY.md commit is a separate, final metadata commit._

## TDD Gate Compliance

Plan frontmatter is `type: execute`, not `type: tdd`. Task 3 has `tdd="true"`. Implementation landed in Tasks 1–2 first; Task 3 tests passed on first run (GREEN without a failing RED commit). Tests encode the local `calculateStablePrefix` helper and MockTranscriber behavior — they do not drive SpeechAnalyzer.

## Files Created/Modified

- `Sources/PikoTranscribe/SpeechTranscriberEngine.swift` - SpeechAnalyzer + SpeechTranscriber engine (`#if os(iOS)`)
- `Sources/PikoTranscribe/MockTranscriber.swift` - scripted Transcriber
- `Tests/PikoTranscribeTests/StablePrefixTests.swift` - 5 stablePrefix helper tests
- `Tests/PikoTranscribeTests/MockTranscriberTests.swift` - 3 mock stream/finish tests
- `Package.swift` - `PikoTranscribeTests` target

Plan artifact listed `SpeechTranscriberEngineTests.swift`; Task 3 action specified `StablePrefixTests.swift`. Followed the task action.

## Decisions Made

- Option B `configure` so PikoKit `Transcriber` stays `hypotheses() -> AsyncStream<CaptureDraft>`.
- Phrase accumulation required: SDK results are range-scoped phrases, not the full utterance.
- Conservative volatile prefix: tests use 0 when no punctuation; engine uses `accumulatedText.count` so prior finals stay stable (05-RESEARCH + corrected Task 1).
- Did **not** mark CAPT-03 / CAPT-04 complete. Engine exists; first-word 400ms and 30s thrash need Plan 05-03 wiring + device speech.

## Speech API path

**Used:** iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (compiled against iPhoneOS26.0 Speech.swiftmodule).

| Plan name | SDK reality |
|-----------|-------------|
| `AnalyzerInputConverter` | **Does not exist** |
| Feed path | `AVAudioConverter` → `AnalyzerInput(buffer:)` → `SpeechAnalyzer.start(inputSequence:)` |
| Result text | `String(result.text.characters)` (`AttributedString`) |
| SFSpeechRecognizer | Authorization + `isAvailable` only — **not** `SFSpeechAudioBufferRecognitionRequest` recognition |

macOS `swift build` skips the engine (`#if os(iOS)`). iOS Simulator `xcodebuild` compiled `SpeechTranscriberEngine.swift`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] AnalyzerInputConverter missing from SDK**
- **Found during:** Task 1 (swiftinterface / compile)
- **Issue:** Plan and 05-RESEARCH name `AnalyzerInputConverter`. Type is absent from iOS 26.0 Speech module.
- **Fix:** Documented live-audio pattern: `AsyncStream<AnalyzerInput>`, convert PCM with `AVAudioConverter` to `bestAvailableAudioFormat`, `analyzer.start(inputSequence:)`. Did **not** fall back to SFSpeechRecognizer recognition.
- **Files modified:** `Sources/PikoTranscribe/SpeechTranscriberEngine.swift`
- **Commit:** `6baf180`

**2. [Rule 1 - Bug] AVAudioConverter / AVAudioPCMBuffer Sendable**
- **Found during:** Task 1 iOS compile
- **Issue:** Converter input block and PCM buffers are not Sendable under Swift 6.
- **Fix:** `ConverterOnce` class; `AVAudioPCMBuffer: @unchecked @retroactive Sendable` (same pattern as 05-01).
- **Files modified:** `Sources/PikoTranscribe/SpeechTranscriberEngine.swift`
- **Commit:** `6baf180`

### Judgment / not Rule 1–3

- Plan key_links still say AnalyzerInputConverter; implementation uses AnalyzerInput.
- Untracked xcodegen `App/*/Info.plist` and entitlements left uncommitted.
- CAPT-03/CAPT-04 left pending (same honesty as 05-01).

**Total deviations:** 2 auto-fixed. **Impact on plan:** Engine compiles on iOS 26 SpeechAnalyzer path. No live speech proof.

## Issues Encountered

- macOS `swift build`: **succeeded**.
- macOS `swift test`: **33 passed / 2 failed / 35 total**. Failures are pre-existing `PikoBridgeTests` App Group (`ReconnectionSurvivalTests`, Darwin round-trip) in unsigned SPM. PikoTranscribeTests: **8/8**.
- iOS Simulator `Piko-Package` (`id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`): **TEST SUCCEEDED**.
  - PikoAudioTests: **15/15**
  - PikoBridgeTests: **6/6**
  - PikoKeyboardTests: **12/12**
  - PikoKitTests: **9/9**
  - PikoTranscribeTests: **8/8**
  - **Total: 50 passed, 0 failed**
- Physical-device speech, first-word latency, background, memory: **not measured**. Simulator PCM from 05-01 is silent zeros. CLAUDE.md: Simulator does not count for those.

## User Setup Required

None for code. Device proof still needs a physical iPhone, mic permission, speech assets, and Plan 05-03 wiring into the keyboard channel.

## iOS Simulator/Device Test Run

**Attempted.** iPhone 17 (iOS 26.0) UDID `6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4`.

| Command | Result |
|---------|--------|
| `swift build` (macOS) | succeeded |
| `swift test --filter PikoTranscribeTests` | **8/8 passed** |
| `swift test` (macOS) | 33 pass / 2 fail (pre-existing PikoBridge App Group) |
| `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` | **TEST SUCCEEDED** — 50/50 Swift Testing tests |
| Physical device / audible speech through SpeechAnalyzer | **not attempted** |

Do not treat CAPT-03/CAPT-04 as device-proven. stablePrefix is unit-tested via a local helper; live analyzer output is unwired until 05-03.

## Next Phase Readiness

- Plan 05-03 can `configure` `SpeechTranscriberEngine` with `ArmedSession.buffers` and stream `hypotheses()` to the session channel.
- On Simulator, buffers are silent PCM — do not expect non-empty SpeechAnalyzer text from that stream.
- MockTranscriber is the deterministic path for keyboard insertion tests.

## Known Stubs

- `SpeechTranscriberEngine` is compiled only `#if os(iOS)`; macOS has MockTranscriber only.
- Engine `hypotheses()` finishes immediately if `configure` was not called, auth denied, or transcriber unavailable — no error surface to UI (05-03).
- Lexicon is stored (`setLexicon`) but not applied to `SpeechTranscriber` (no SDK custom-vocab wiring in this plan).
- Simulator silence pump (05-01) still yields zeros; not a UI stub.

## Threat Flags

None new beyond T-05-04 (availability check, mitigated). No new network endpoints except Speech framework asset download via `AssetInventory.downloadAndInstall()` (on-device model install, Apple API). Mic audio stays in-process. Authorization uses `SFSpeechRecognizer.requestAuthorization`.

## Self-Check: PASSED

- FOUND: Sources/PikoTranscribe/SpeechTranscriberEngine.swift
- FOUND: Sources/PikoTranscribe/MockTranscriber.swift
- FOUND: Tests/PikoTranscribeTests/StablePrefixTests.swift
- FOUND: Tests/PikoTranscribeTests/MockTranscriberTests.swift
- FOUND: Package.swift (PikoTranscribeTests)
- FOUND: .planning/phases/piko-05-transcription/05-02-SUMMARY.md
- FOUND: 6baf180
- FOUND: 5329199
- FOUND: aa74d8d
