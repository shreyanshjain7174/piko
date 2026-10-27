---
gsd_state_version: 1.0
milestone: v0.2
milestone_name: milestone
status: in_progress
stopped_at: Real Whisper-to-Safari field delivery verified. Full physical Whisper baseline retained; Apple pairing and final phone acceptance await unlock.
last_updated: "2026-10-21T05:45:53Z"
last_activity: 2026-10-21
progress:
  total_phases: 8
  completed_phases: 8
  total_plans: 21
  completed_plans: 21
  percent: 100
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-08-27)

**Core value:** Dictation that starts instantly from wherever you are and inserts clean text into
whatever field you're already in, entirely on-device.
**Current focus:** Finish the approved iOS 27+ offline dictation beta for 1-10 testers.
Compare Apple speech with native Swift/Core ML Whisper large-v3-turbo on the user's iPhone 17.
Original code phases are complete; beta acceptance is not. Preserve the existing milestone
identifier rather than relabeling historical v0.1/v0.2 work.

## Current Position

Phase: 8 of 8 complete (code)
Plan: all phases' plans complete
Historical Phase 8 completion: Real SQLiteMemory (SQLite3+FTS5) records every session;
searchable via HistoryView. Real PikoFace SVG-to-SwiftUI port, four skins selectable via chip
buttons in ArmView. Fixed two real bugs found during live verification: SessionCoordinator.phase
broadcast to multiple simultaneous subscribers (was single-continuation, raced when Phase 8 added
a second real consumer); .searchable List moved off ArmView onto its own HistoryView after it was
found intercepting taps meant for Arm/skin controls. Simulator Piko-Package 140/140. macOS swift
test 83/85 (2 pre-existing unsigned SPM App Group). No device-only gap this phase. CLNP-01/CLNP-02
(Phase 6), CAPT-03/CAPT-04, Phase 3 VERIFICATION.md PARTIALLY DONE, and Phase 7's real on-device
Live Activity cadence/stop-button tap all still pending physical device access.
Branch: feature/free-tier-device-verify
Last activity: 2026-10-21 (real decoder evaluation and physical startup regression fixes)

Progress: [██████████] 100%

The progress figure above describes the original code plans, not beta readiness. The approved
beta plan adds capture/lifecycle regression proof, an on-device Apple/Whisper comparison,
explicit engine selection, and physical acceptance before any TestFlight publication. The
user separately approves the measured engine and release; no publication is authorized yet.
English including Indian English is in scope; Hindi/code-switching, Rust, diarisation, cloud
fallback, and macOS distribution are not. Save text locally and discard ordinary capture audio.

## Beta Execution Evidence

The approved implementation is in the working tree; no commit, archive upload, or TestFlight
invitation was made. Original implementation history and milestone IDs remain intact.

### Implemented

- iOS 27/Xcode 27 floor, iPhone-only targeting, coordinated host/extension versions, and
  YAML-generated project signing for confirmed team `C7524YZPLL`. The unavailable
  `dev.piko.Piko` identifier was replaced with the existing user-specific `dev.shreyansh`
  prefix. App ID is `dev.shreyansh.Piko`; App Group remains `group.dev.piko.shared`.
- Foreground speech permission/explicit English readiness and consented language-pack setup,
  typed recognition/startup errors instead of silent stream completion or App Group crashes.
- Foreground-armed audio input stays running for the session; idle audio is dropped by a
  locked relay. Only explicit captures forward buffers. Simulator uses synthetic PCM, not
  hardware fallback. Disarming releases input; normal keyboard capture-stop stays armed.
- Range-keyed phrase assembly, real end-of-input finalization, capture-scoped cancellation,
  monotonic epochs across restarts, and stale-work guards during re-arm/cleanup.
- Host document identity/context guards prevent final replacement or reversion over a
  different field or manually changed host text. Regression failures were reproduced before
  fixes, including identical suffixes and preserving recovery for a genuinely newer capture.
- History and shared transcript storage excluded from OS backups; ordinary audio remains
  transient. Existing local history/skin UI reused, with explicit readiness/privacy text.
- Live Activity unchanged-word updates deduplicated and request failures logged. Stop intent
  moved into `App/SharedIntents` for both host and widget membership, as required for
  `LiveActivityIntent` execution in the app process. Actual physical stop/cadence is still open.
- Native WhisperKit 1.1.1 challenger behind Debug-only launch arguments; only its WhisperKit
  library product is linked through the container's transcription target. No Rust, TTS,
  diarisation, cloud inference, or product engine settings page.
- Compressed large-v3-turbo Core ML model and separate tokenizer pinned by revision, exact
  inventory, sizes and source-pinned SHA-256 hashes. All 22 assets downloaded and verified.
  Assets stage only into Debug builds. A mock cannot pass real-model readiness diagnostics.
- Fail-closed device smoke/preflight tooling, paired WER scorer with exact integer gates,
  silence/incomplete-corpus checks, and 1024px opaque icon rendered from existing Piko vectors.
  Read-only attached icon snapshots were not edited or upscaled.

### Verified

| Surface | Evidence | Limit |
|---------|----------|-------|
| iOS Simulator deterministic package lane | 185 passed, 0 failed; `beta-final-verified-tests.xcresult` | Explicitly excludes the two real Foundation Models tests; not device speech proof |
| Repository macOS CI command | `make test` passed, 144 logical tests | Hosted GitHub CI was not run |
| Benchmark tools | 13 Python standard-library tests passed | Unit fixtures are not a recorded accent corpus |
| Native model assets | 22 exact files verified against source-pinned hashes | Storage size is not runtime RSS |
| Real Whisper readiness on Simulator | `PIKO_BENCHMARK_READY: WhisperTranscriberEngine; microphone not opened` | Model loading only; not decoding accuracy or physical offline evidence |
| App configurations | Debug Simulator, Release Simulator, signed physical Debug builds passed | No signed release archive or Store validation |
| Physical installation | Current developer app, both extensions and staged model installed on iPhone 17, iOS 27.0.1 | Device auto-locked during runtime launch attempts |
| Signing | Embedded profile confirms team `C7524YZPLL`, app ID and required App Group; profile expires 2027-10-20 | Not a TestFlight publication |
| Shared stop membership | Host binary contains `Piko.StopSessionIntent` | Actual button tap remains a physical gate |
| Computer-use UI | Startup, microphone prompt, mock start/finish, exact copied text, saved History, privacy text and End session verified | Mock recognition and cleanup only |
| Icon | 1024x1024 PNG, no alpha, original vector rendering | External beta review still pending |

The two real Foundation Models Simulator tests were explicitly rerun separately and both
still failed with `brainBudgetExceeded(milliseconds: 2000)` in `beta-fm-integration-tests.xcresult`.
Their failure is not hidden by the deterministic lane. Production's 600ms budget was not
increased; the tested raw-transcript fallback remains. Cleanup quality/latency on the physical
device is not closed.

### Blocked / Next Gate

No paired consented English/Indian-English corpus has been recorded or scored. Physical
runtime attempts were blocked by the phone lock; do not bypass it. Need an unlocked iPhone,
the Piko keyboard enabled with Full Access, explicit local benchmark-recording consent, and
the fixed utterances before the real background-container-to-keyboard comparison.

Do not choose an engine yet. Require <=10% normalized WER, no silence hallucinations/data
loss/wrong-field edits, and existing timing/lifecycle gates; Whisper additionally needs >=20%
relative WER improvement. The user confirms the measured winner. Physical latency, 20 app
switches, 45-minute soak, interruptions/re-arm, keyboard/container memory, Back Tap/Action
Button, offline behavior, and Live Activity controls remain open.

Winner-specific hardening/removing the losing SDK, export compliance/license notices,
release-archive validation, explicit release authorization and external TestFlight review
follow that gate. No beta-ready claim is justified yet.

Detailed logs/result bundles/models/screenshots are in
`/Users/sunny/.copilot/session-state/cfe8dec5-91b9-4d8e-b352-4f2b9a426a4f/files/`.
Argon 4 performed the read-only audit and Opus 5.5 reviewed the plan. Implementation-worker
sessions lacked filesystem tools; the parent implemented and verified changes directly.

## Evaluation Follow-up - 2026-10-21

User requested Sarvam API/test-suite research and stronger accuracy/latency validation.
Official docs distinguish Saaras hosted STT/realtime partials from Voice Agents simulated
conversation tests with AI-judged behaviors. Neither replaces native-iPhone input/insertion
or device latency evidence. No Sarvam API call, paid test, credential lookup, MCP installation,
or private-audio upload occurred; Piko's runtime remains local.

Implemented/verified updates:

- Actual Debug-only WAV replay and sequential manifest runs through `AudioTranscriber`;
  reports identify the actual engine, physical/Simulator platform, locale, OS version and
  audio SHA-256. File-start-to-first-hypothesis is labelled separately from keyboard latency.
- Frozen local regression corpus: 30 licensed public CMU ARCTIC Indian-English recordings
  (four source speaker groups), three reproducible 20dB-noise variants, and two digital
  silence cases. Synthetic English-India speech is a separate plumbing smoke fixture.
  No private microphone recording was made. Public legacy data may overlap training data
  and does not replace real beta-user speech or broad accent validation.
- Paired scoring now rejects different audio hashes, mocks, mixed platforms/locales,
  duplicate/missing fixtures and incomplete results. It reports WER, substitutions,
  deletions/insertions, per-utterance errors, p50/p95/p99 and missing measurements.
  Silence insertions count toward corpus WER and also fail the hallucination gate.
  All 16 Python tooling tests pass.
- Real Foundation Models host diagnostic returned a response in 2.58s despite prewarming.
  The original two >2000ms integration failures remain historical evidence. Tests now verify
  the *existing* production requirement: cleanup within 600ms or explicit bypass with
  unchanged raw text, including a real-model coordinator test. No production budget was
  relaxed and a bypass is not recorded as a cleanup-quality pass.
- Complete iOS Simulator suite: **196 passed, 0 failed, 0 skipped**, including real model
  outcome tests without exclusion (`evaluation-method-full-tests.xcresult`). Real-model
  tests explicitly reported budget bypass. macOS `make test`: **146 logical tests passed**.
- Simulator file replay actually decoded the synthetic sentence through Whisper, rather
  than only loading a model. Timing is slow on Simulator and is not phone latency proof.
- Real external-keyboard testing exposed a nil `documentIdentifier` bridge trap before UIKit
  host attachment. Added nil-safe Objective-C getter, live proxy provider, context priming
  and bounded attachment wait with regression tests. Mock-backed Safari field insertion
  was verified. Real-decoder streaming/final insertion remains open: successful shared-file
  finalization did not yet prove visible host-field delivery.
- Keyboard now polls durable draft/result payloads while an explicitly initiated capture
  owns the field, recovering missed Darwin notifications. Baseline epoch/result guards
  reject pre-capture payloads and capture context is discarded when the keyboard disappears.
  This final recovery change compiles; final end-to-end rerun was blocked by Simulator install.
- Physical startup exposed that the App Group root cannot always receive the backup-exclusion
  attribute. Shared data now lives in an owned, excluded `PikoShared` subdirectory; known
  root payloads migrate, unrelated files remain untouched, and both channel/intent stores
  use the same location. A regression test passes. Failed payload writes no longer post
  success-shaped delivery notifications.

Actual phone results, not acceptance:

- With the storage fix, iPhone 17 ran Whisper on seven public recordings before auto-lock
  stalled the foreground-only file batch. The partial raw result file was copied locally.
  It contains 3 word errors over 66 reference words (4.55%); this tiny incomplete subset,
  without Apple pairing or silence results, cannot satisfy the engine gate.
- First two file-start hypothesis times were 1998ms and 1882ms; post-input finalization was
  1018ms and 1934ms. These are not speech-onset-to-keyboard times, and are not a latency pass.
  Initial model preparation was 80538ms. Keep cold/warm costs separate.
- The developer batch now temporarily disables the app's idle timer while running visibly
  in foreground and restores the previous setting. This does not unlock a phone or change
  system security settings. Latest signed iPhone and Release Simulator source builds pass.
  The phone currently contains an earlier replay build; the latest evaluation changes need
  reinstall while unlocked.
- Simulator installation later stalled even after one non-destructive reboot; installer logs
  include `Could not resolve UID for user "mobile"`. Stalled install commands were stopped,
  data was not erased, and no success was inferred. The remaining real-host insertion
  check needs a working install/runtime or the unlocked physical device.

Next gate: complete the same frozen corpus on both real engines, then real keyboard latency,
background memory/soak/offline/stop evidence and user engine approval. Beta release and
TestFlight publication remain blocked; no shipping engine has been selected.

Final recovery attempt: the iPhone was still locked and the user was unavailable to unlock it.
A separately created disposable iOS 27 Simulator also stalled in Launch Services migration,
so this was not only an existing-app installation problem. Its bounded command was stopped,
only the disposable device was deleted, and the original Simulator/data were restored.
Final signed-iPhone and Release-Simulator builds pass; no remaining runtime failure was
relabelled as successful. No helper servers or console-stream commands were left running.

## Direct-Field Acceptance and Phone Follow-up

**Product clarification:** replace the Siri-composer workflow, not Apple's system-owned
Type to Siri or keyboard Dictation controls. Select the Piko keyboard and tap its own large
microphone; text should appear in the currently focused supported field. Onboarding, mic
accessibility guidance and the specification now explicitly distinguish those controls.

**Actual direct-field acceptance passed on Simulator**, using the real Whisper decoder and a
synthetic local audio fixture, not MockTranscriber:

- Armed Piko, opened an ordinary Safari textarea, selected Piko through the globe menu,
  tapped Piko's microphone, observed partial and full insertion, then tapped Piko Stop.
- Exact final field content: `Please send the report at 4 tomorrow. My words stay on this phone.`
- Safari reported 66 inserted characters. Text remained after Stop, keyboard returned to
  armed, and no Siri composer appeared. Screenshots: `piko-safari-streaming.png` and
  `piko-safari-acceptance.png` in the session `files/` directory.
- Opus reviewed the lifecycle gates; Argon separately verified wrong-field safety and ran
  the actual UI flow. A small tested delivery-state value now retains capture ownership
  across hide/show, rejects old payloads and never mutates a hidden field. The text
  controller and document/context guards remain intact; idle/result ordering preserves
  late results and the revert offer.
- Current full Simulator suite: **203 passed, 0 failed, 0 skipped**
  (`direct-field-verified-tests.xcresult`). macOS `make test`: **149 logical tests passed**.
  Python tooling: **16 tests passed**. Real Foundation Models still explicitly bypasses
  cleanup at the unchanged production budget; quality acceptance is not implied.

Further physical evidence and fixes:

- The complete original Whisper baseline finished **35/35** frozen public fixtures on the
  iPhone 17: **17 word errors / 302 reference words = 5.63% WER**, with **one silence
  hallucination** (`"you"` on a digital-silence fixture). The original baseline therefore
  fails the no-hallucination gate despite passing the aggregate WER threshold.
- File-start-to-first-hypothesis p50/p95 was **1889/2711ms**; post-input finalization p50/p95
  **1455/1865ms**. These are not speech-onset-to-keyboard timings and are not a latency pass.
- The adapter now uses the pinned SDK's EnergyVAD before decoding non-speech; two focused
  regressions reject digital silence and accept audible input. **This changed adapter still
  needs a fresh physical corpus run**; do not rewrite the original measurement as a pass.
- A real phone crash report traced a Swift executor trap to the audio input tap inheriting
  MainActor isolation, not the Whisper decoder. A nonisolated Sendable tap factory and an
  off-main render-callback regression fix this; the regression and signed build pass.
- Apple's official SpeechAnalyzer sample confirmed local module/asset setup without the
  legacy `SFSpeechRecognizer.requestAuthorization` gate. That legacy gate and its unused
  usage-description prompt were removed; microphone permission remains mandatory for arming.
- Repeated model-bundled installations were the practical installer bottleneck. Verified
  benchmark weights are now also supported in explicit private app storage. The same model
  was cached once, and a **12MB signed app installed successfully** without reinstalling
  630MB of weights. The equivalent small Simulator install also succeeded, unblocking UI proof.
- Full same-audio Apple pairing, live phone keyboard latency, background/memory/soak/shortcut
  acceptance and engine approval remain open. The latest small developer app is installed
  on the iPhone; it remains locked, so no launch or lock bypass was attempted.

No cloud integration, private-audio upload, release archive publication or TestFlight
invitation occurred. No shipping engine was selected. Temporary UI servers/console streams
were stopped after the acceptance run.

## Local Verification - 2026-10-20

User requested local Simulator testing only, with computer-use UI verification. No physical-device
testing, TestFlight upload, certificate creation/export, or notarization was performed.
The `/gsd` skill was unavailable in this session; results are recorded here directly.

**Environment:** revision `ad86a61`, Xcode 27.0 (27A266a), iPhone 18 Pro Simulator,
iOS 27.0 (24A434). Team `C7524YZPLL` confirmed by the user; paid membership was not independently
verified. Keychain inspection found one Apple Development identity, no Developer ID Application
identity. Piko remains an iOS app; macOS DMG distribution is a separate product/build.

| Check | Result | Evidence / limits |
|-------|--------|-------------------|
| VS Code test runner | 188 passed, 0 failed | Runner did not report its execution platform; not physical-device evidence |
| Simulator app build | Passed | `xcodebuild -project App/Piko.xcodeproj -scheme Piko -destination 'platform=iOS Simulator,id=42B691DF-0CFE-47AA-85FD-B60DE6530D96' build`; local ad-hoc signing, including both extensions |
| Selected core Simulator tests | 114 passed, 0 failed | PikoKitTests, PikoMemoryTests, PikoUITests, PikoBridgeTests, PikoKeyboardTests, PikoBrainTests; explicitly excluded FoundationModelsIntegrationTests |
| Selected transcription/content Simulator tests | 19 passed, 0 failed | StablePrefixTests, MockTranscriberTests, LiveActivityContentTests, SkinSelectionTests |
| Full package Simulator integration attempt | Failed / incomplete | 14 audio tests threw `microphoneDenied`; TCC could not construct a microphone identity for `com.apple.xctest`. Two real Foundation Models tests threw `brainBudgetExceeded(milliseconds: 2000)`. Run then stalled and was stopped; no full-suite pass claimed |
| Computer-use UI smoke checks | Passed, mock pipeline only | Granted microphone permission through the real prompt; started/finished dictation; observed raw mock draft and cleaned mock result; opened saved History and detail; verified copied text exactly via Simulator pasteboard |
| Settings / setup UI | Passed | Keyboard setup sheet opened/dismissed; all four appearance options listed; changed Cute to Cool, verified selection, restored Cute; ended voice session and verified stop control disappeared |

Initial launch without signing exited during App Group initialization. Rebuilding with normal
Simulator ad-hoc signing restored launch; this was a verification setup issue, not a product fix.
The app uses MockTranscriber and MockBrain on Simulator, so successful UI dictation is not proof
of real speech recognition or Foundation Models cleanup.

Detailed build/test logs, two passing `.xcresult` bundles, and UI screenshots are retained under
`/Users/sunny/.copilot/session-state/cfe8dec5-91b9-4d8e-b352-4f2b9a426a4f/files/`.
Passing result bundles: `piko-simulator-core-tests.xcresult` and
`piko-simulator-transcribe-tests.xcresult`.

**Next verification work:** repair or provide an appropriate microphone-capable test host before
rerunning audio/capture integration tests; investigate the two Foundation Models timeouts without
relaxing the 600ms product requirement. Physical iPhone gates remain open: bridge latency and
app-switch survival, Back Tap/Action Button, interruption recovery, 45-minute soak, real speech
latency/stability, cleanup quality/latency on the oldest supported device, keyboard memory, and
Live Activity cadence/stop intent. No acceptance checkbox was closed by this Simulator pass.

## Performance Metrics

**Velocity:**

- Total plans completed: 13
- Average duration: n/a
- Total execution time: n/a

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 4 P01 | 1 | 10min | 10min |

**Recent Trend:**

- Last 5 plans: n/a
- Trend: n/a

| Phase 4 P01 | 10min | 4 tasks | 6 files |
| Phase 4 P02 | 16min | 4 tasks | 5 files |
| Phase 5 P01 | 28min | 3 tasks | 6 files |
| Phase 5 P02 | 8min | 3 tasks | 5 files |
| Phase 5 P03 | 12min | 3 tasks | 5 files |
| Phase 06 P01 | 38min | 3 tasks | 7 files |
| Phase 06 P03 | 10min | 3 tasks | 9 files |
| Phase 06 P02 | 7min | 3 tasks | 7 files |

## Accumulated Context

### Decisions

Full log lives in PROJECT.md Key Decisions table.

- Bootstrap: GSD phases follow module boundaries from `docs/SPEC.md`, not feature slices.
- Bootstrap: v0.2/v0.3 tracked as future milestones in ROADMAP.md, not phased yet — too early to
  plan concretely.

- [Phase 2]: sessionEpoch + isNewer(than:) closes the session-restart sequence-drop bug; DarwinChannel deinit removes its Darwin notify observer; PikoBridgeTests hit the anticipated App-Group-container environment limitation (writes silently no-op without the App Group entitlement in unsigned SPM tests) for BRDG-02/03, recorded per plan's escape valve
- [Phase 4 P01]: Keyboard is remote control only (C1) — posts captureStart/Stop; never opens mic. KeyboardViewModel stays in tests. Simulator iPhone 17 iOS 26 + Piko-Package scheme. CAPT-01 deferred to 04-02.
- [Phase 4 P02]: alreadyStable = min(draft.stablePrefix, insertedChars); epoch wipe to 0. PikoKeyboardCore SPM slice for tests. @MainActor TextProxy. CAPT-01/02 algorithm-complete, not speech-proven.
- [Phase 5 P01]: ArmedSession.buffers + AVAudioEngine tap with local continuation capture. Simulator skips engine.start and pumps silent PCM. FIFO AudioSessionTestGate. CAPT-03/04 not complete.
- [Phase 5 P02]: SpeechAnalyzer + SpeechTranscriber via AnalyzerInput (AnalyzerInputConverter absent). Option B configure. Phrase accumulation. CAPT-03/04 not complete.
- [Phase 5 P03]: CaptureCoordinator wires buffers to Transcriber via SpeechTranscriberEngine.configure cast; Simulator MockTranscriber; PikoCaptureCore for tests. CAPT-03/04 not complete.
- [Phase 6]: Budget race is unstructured Tasks plus withCheckedThrowingContinuation, not withThrowingTaskGroup
- [Phase 6]: RewriteBudgetRaceState is file-scope; Swift cannot nest a class inside a generic function
- [Phase 6]: CLNP-01/CLNP-02 not marked complete: no physical Apple Intelligence quality or 600ms device proof
- [Phase 6]: SPEC .agent is shipped only after picker plus persistence, not after the enum case alone
- [Phase 6]: Do not mark CLNP-01 complete after 06-03: agent styleHint quality needs physical Apple Intelligence; Simulator does not count
- [Phase 6]: CLNP-03 complete via RoutePrefilterTests inference call counter remaining zero
- [Phase 6]: Do not mark CLNP-01/CLNP-02 complete after 06-02: Simulator exercises graceful skip, not live rewrite quality or 600ms on device
- [Phase 6]: Do not publish SessionPhase.tidying from CaptureCoordinator.stopCapture; SessionCoordinator owns phase

### Pending Todos

None yet.

### Blockers/Concerns

- `docs/CONSTRAINTS.md` is sourced from Apple docs/forums, not this project's own device testing.
  Re-verify C1–C10 on physical hardware as each phase touches them (per working agreement).

- No physical device verification has occurred yet for any of the timing acceptance criteria
  (120ms bridge round-trip, 400ms first-word latency, 600ms cleanup budget) — these are targets
  from SPEC.md, not measured numbers.

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-10-20T19:45:25Z
Stopped at: Verified beta foundation; physical corpus and engine-approval gate pending
Resume file: None

## One-Press Activation (2026-10-21)

- User rejected "open Piko → Start session" as normal use. iOS still forbids keyboard mic
  access (C1) and background recording start (C2), so one brief foreground arm remains.
- `ArmSessionIntent` is now also compiled into PikoWidgets (perform body gated by the
  app-only `PIKO_APP` condition; system runs it in the app process). New `PikoArmControl`
  (`ControlWidgetButton`) exposes **Arm Piko** for Control Center, the Lock Screen and the
  Action Button. Keyboard cold-state, mic hint and onboarding copy now point there instead
  of Home → Start session.
- Evidence: signed iPhone Debug build passed; both app and widget `Metadata.appintents`
  contain `ArmSessionIntent`; installed on iPhone 17. Simulator suite **203 passed, 0 failed**
  (`arm-control-tests.xcresult`); macOS `make test` passed.
- Physical control press, cold-start-to-armed time and return-to-field flow remain unverified.
- Apple same-audio corpus attempt reached 2/35, then the phone auto-locked
  (`passcodeRequired: true`) and fixture 3 failed. Benchmark failure logs now print the
  specific `PikoError` case. Apple corpus and VAD-fixed Whisper re-run still pending unlock.

## Live Dictation Quality and Stop-Insertion Root Causes (2026-10-21)

User report from the phone: poor comprehension, duplicated text, nothing inserted on Stop,
forced return to the app, and Dynamic Island word counts/"Tidying" instead of a listening cue.

Root causes (compared against Apple's official SpeechAnalyzer sample):

1. `SpeechTranscriberEngine` created a new `AVAudioConverter` for every microphone buffer.
   Resampler state and priming reset at each buffer edge. A red test showed lost frames and
   sample discontinuities on 1s of chunked 48kHz audio. Fix: `StreamingAudioConverter` reuses
   one converter per capture with `primeMethod = .none`, as Apple's `BufferConverter` does.
2. `SpeechTranscript` keyed phrases by range start. A volatile phrase whose start differed
   from its final was never removed, which duplicated text and kept `isFinal` false.
   `runRecognition` then set `.transcriptionFailed`; `stopCapture` reported it, disarmed the
   session and wrote no result. Fix: Apple's model — finals append once, each volatile result
   replaces the whole tail. Two red tests now pass.
3. Dynamic Island now shows an animated waveform (`symbolEffect` variable colour, repeating)
   with "Ready / Listening… / Typing…" instead of word counts and "Tidying…".

Evidence: Simulator package suite **206 passed, 0 failed** (`asr-fix-tests.xcresult`); macOS
`make test` passed; signed iPhone build installed. Production engine remains Apple on-device
`SpeechTranscriber` (en-IN); Whisper is developer-benchmark only.
Unverified: live phone dictation quality after the fix, Live Activity animation on device,
and stop-to-field insertion on the phone (phone locked).

## Keyboard Auto-Listen (2026-10-21)

- User requirement: opening a text field with Piko armed should already be listening.
- `KeyboardViewController.viewDidAppear` now posts `captureStart` when the session is live and
  armed, Full Access is on, and `KeyboardPreferences.autoListen` (App Group key
  `PikoAutoListenOnKeyboard`, default on) is enabled. A pending result is landed first.
  `viewDidDisappear` posts `captureStop` for this keyboard's capture, so the mic never keeps
  listening without a visible field. Home has a "Listen when the Piko keyboard opens" toggle.
- iOS still requires one foreground arm (C1/C2); one press via the Arm Piko control.
- Evidence: Simulator package suite **207 passed, 0 failed** (`autolisten-tests.xcresult`);
  macOS `make test` passed; signed iPhone build installed. Physical auto-listen unverified.

## Lazy Session Release (2026-10-21)

- User MVP direction: Piko should be live only around dictation, not always on.
- `SessionCoordinator` now releases an armed-but-unused session after `idleTimeout`
  (default 300s): mic off, Live Activity ends (existing `.idle` handling). Capture cancels the
  timer; `finishTidying` restarts it. Two Simulator tests cover release and restart.
- Grounding: Apple forum thread 815725 / AudioRecordingIntent docs — recording cannot start
  from the background and needs a Live Activity. Wispr Flow's iPhone keyboard uses the same
  pattern (keyboard "Start" opens the Flow app, user swipes back).
- Evidence: Simulator package suite 206 passed, 0 failed on iPhone 17 sim (3 real Foundation
  Models tests absent on that runtime), including both idle tests; macOS `make test` passed;
  signed iPhone build installed. Physical behaviour unverified.

## Auto-Listen Simulator Check and Follow-up Fixes (2026-10-21)

- Simulator UI run (separate harness, Whisper fixture replay and mock engine): auto-listen started
  without a mic tap, text streamed into Safari, text stayed after Stop, no Siri UI.
- Defect found: hiding and reshowing the keyboard left the first capture's partial and fused
  the next capture: `Please send the report atPlease send the report at 4 tomorrow. ...`.
  Root cause: the new appear path applied results before the host proxy attached; the field
  check failed and permanently invalidated the capture. Fix: `applyDraft`/`applyResult` skip
  until `hostIsReady` (the 250ms loop retries); appear logic runs after host attachment.
- New captures that start right after a word now insert a separating space (two tests).
- Simulator Apple engine reported `On-device speech is unavailable for en-IN` (Simulator only).
- Evidence: Simulator package suite 211 passed, 0 failed (`sep-tests.xcresult`); macOS
  `make test` passed; signed iPhone build installed.

## Keyboard Hide/Reshow and Streaming Duplication Fixes (2026-10-21)

Evidence-driven via DEBUG instrumentation and a temporary Simulator UI harness (deleted):

1. iOS creates a new keyboard view controller when switching keyboards and back
   (`viewDidLoad` ran twice in one PikoKeyboard process). Delivery/insertion state lived on the
   old controller, so a capture that ended while hidden never landed its tidied result.
   Fix: `KeyboardProcessState` holds delivery and insertion per keyboard process, routed to the
   on-screen controller; stale controllers no longer mutate it.
2. Drafts typed during the hide transition never reached the page (keyboard counted 30 typed
   characters, field had 27), so the final commit was correctly refused. Fix: stop delivery and
   post `captureStop` in `viewWillDisappear`.
3. Streaming retyped the whole unstable tail on every draft (e.g. 5 deletes for
   "um so" -> "um so lik"). The host dropped rapid deleteBackward bursts, doubling text
   (`um so um so lik`) and invalidating the capture. Fix: rewrite only characters that changed
   (common prefix); growing drafts now need zero deletes. Two streaming tests updated to
   the minimal edit counts; final-text assertions unchanged.

Simulator UI result (mock engine, two back-to-back runs): auto-listen on keyboard show, first
capture's partial replaced by its tidied result after hide/reshow, separating space, no
blocked/rejected/doubled insertions, no Siri UI. Screenshots/logs: `autolisten4-*`.
Tests: Simulator package suite 212 passed, 0 failed (`final-tests.xcresult`); macOS
`make test` passed; signed iPhone build installed. Physical phone run still pending unlock.

## Pivot: Press-to-Talk Assistant MVP (2026-10-21)

User approved (founder-ceo-advisor review): personal intelligence, free on-device first,
premium cloud only after 10-tester validation. Decision journal and kill criterion in
`PROJECT.md`. Built this slice:

- `PikoKit/Assistant.swift`: `DumpItem`, `Organizer` (cloud-ready seam), `ItemStore`, `DumpLog`.
- `RuleOrganizer` (free basic): sentence/cue splitting, `NSDataDetector` dates; `RecallQuery`.
- `ModelOrganizer` (free smart): Foundation Models `@Generable` filing via
  `respond(to:generating:)` (API checked in the iOS 27 SDK interface), faithfulness guard,
  dates only from spoken words, rule fallback; recall answers only from provided history.
- `SQLiteMemory`/`EphemeralMemory` store notes/journal (`items` table).
- App: Home "Talk to Piko" with a review card (Save/Discard) and recall answers; `ReminderWriter`
  (EventKit, on Save only); Filed tab; Settings weekly count; keyboard moved to Settings as
  optional. `StartDictationIntent` is now "Talk to Piko" in App Shortcuts and the Control
  Center/Lock Screen control. Keyboard captures (`lastCaptureFromKeyboard`) are never filed.
- Evidence: Simulator package suite **228 passed, 0 failed** (`assistant-tests.xcresult`);
  macOS `make test` passed; signed iPhone build installed (phone locked, unverified).
- Open: on-device Foundation Models filing quality/latency on the iPhone; Action Button
  activation; recall quality on real history.

## On-Device Tool Harness (2026-10-21)

- Contracts (`PikoKit/Assistant.swift`): `ToolCall {tool,text,when}`, `ToolDescriptor`,
  `ToolRisk` (read/local/external), `PikoTool`, `Planner`, `ToolName`.
- `PikoBrain/ToolHarness.swift`: `ToolHarness` (registered tools only, 5-step cap, external
  tools need approval, failures reported), `SpokenDate`, `OrganizerPlanner` (free rules),
  `ModelPlanner` (Foundation Models `@Generable` plan, grounding guard, rule fallback).
- App tools (`AssistantTools.swift`): reminders, calendar (write-only), notes, journal,
  check-in notifications, Shortcuts runner, memory search. Home card now proposes a plan;
  "Do it" approves it and shows per-step outcomes.
- Evidence: 7 new tests; Simulator package suite **235 passed, 0 failed**
  (`harness-tests.xcresult`); macOS `make test` passed; signed iPhone build installed.
- Open: SLM (Qwen3.5-2B via MLX) vs Apple FM eval on the iPhone; Shortcuts/Calendar/check-in
  on device.
- Simulator UI run 1: the planner chose `memory.search: Deck` for an ordinary request. Fix:
  planners receive only action tools (`ToolHarness.actionDescriptors`); read tools stay on the
  recall path (1 new test; suite **236 passed, 0 failed**). Run 2: plan
  `reminder.create: Send the deck` → "Do it" → `Reminder added: Send the deck`, confirmed in
  Reminders and deleted. Screenshots `harness2-*`.

## On-Device Planner Evidence (2026-10-21, iPhone 17, iOS 27.0.1)

DEBUG `-PikoPlanProbe` (no mic, no tools run). Foundation Models `availability=available`.
After step-text tidying (`StepText`, `SpokenDate.removing`):
- "put dentist on my calendar Friday at 4 pm, remind me to buy oat milk, and nudge me at 9 pm
  to journal" → calendar Dentist @ Fri 4 PM; reminder Buy oat milk; check-in "Time to
  journal" @ 9 PM — 4035 ms (first call, model warm-up).
- "remind me to call mom tomorrow at 6 and book a cab for the airport on Sunday morning" →
  reminder Call mom @ 6 PM tomorrow; calendar Book a cab for the airport @ Sun 9 AM — 1755 ms.
- "run my gym shortcut" → shortcut Gym — 1370 ms.
- Earlier probe: brain-dump → note "A cute planner app with stickers" + journal "I felt really
  anxious about the interview today" (1745 ms).
User report "live transcript but nothing more": code-confirmed gaps fixed — results finishing
while Piko is backgrounded are now picked up on return; empty captures say "I didn't catch
that". Keyboard captures are still never planned (by design; open product question).
Suite: 238 passed, 0 failed (`fix3-tests.xcresult`); macOS `make test` passed; installed.

## Voice Orchestrator, Date Fix, Edge-Case Eval, Quiet Live Activity (2026-10-21)

User report from the phone: Live Activity Stop did nothing; Live Activity too visible; calendar
event landed at 12–1 for "4 pm"; no clash check; push-to-talk not interactive.

- **Noon bug root cause (verified):** `NSDataDetector` resolves a date-only phrase ("Friday")
  to 12:00, misses "at four", reads "4 o'clock" as 04:00 and keeps past times today.
  `SpokenTime.swift` now parses times itself, borrows a time spoken next to a day, rolls past
  times forward, honours self-corrections, and marks day-only as `timeKnown = false`.
- **Orchestrator (`Conversation`):** deterministic state machine — asks for a missing time,
  checks calendar clashes (`CalendarContext`, EventKit full access), reads the plan back,
  understands yes / no / "make it 5"; local-only plans (notes, journal) just save. The model is
  only used for planning new requests.
- **Voice turn:** spoken replies (`AVSpeechSynthesizer`, en-IN), automatic end of turn after a
  1.6 s pause (no "I'm done" tap), follow-up listening after questions; card buttons still work.
- **Plan repair (`PlanRepair`):** clause ownership for dates, self-correction merge, idea →
  note, dropped feelings kept as journal (absorbing split notes), filler-only requests ignored,
  duplicate steps removed.
- **Eval:** `scripts/planner-eval.json` (30 spoken edge cases). Apple Foundation Models
  (Simulator, same corpus): 20/25 → **30/30**, p50 969 ms, p95 1771 ms. Free rule tier: 12/30
  (fallback only). On-phone run blocked by auto-lock.
- **Live Activity:** shown only while a foreground turn is active, ended when the turn ends,
  `.immediate` dismissal, 10-minute stale date. Stop now calls the app directly
  (`StopSessionIntent` → `AppComposition.stopFromLiveActivity`) instead of a Darwin round trip.
- Tests: Simulator package suite **263 passed, 0 failed** (`repair-tests.xcresult`); macOS
  `make test` passed; signed iPhone build installed. Physical voice loop, Stop and clash prompt
  unverified (phone locked).
