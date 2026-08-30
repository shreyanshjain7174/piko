# Phase 7 Verification — Live Activity

Written directly (not by gsd-verifier subagent, which returned no output twice — logged in
session, not repeated here). All evidence below is from independently re-run commands and
direct source reads, not from trusting plan/summary descriptions.

## Success Criteria

### 1. A Live Activity starts at arm time and shows armed / listening / tidying state — DONE

- `App/Piko/LiveActivityController.swift` — `start(skin:)` calls
  `Activity<PikoAttributes>.request(attributes:content:pushType:)` (real call, not unused
  plumbing), adopting an existing Activity first if one is already running (process-relaunch
  case). `AppComposition.armSession()` calls `session.arm()` then `liveActivityController.start()`
  in the same foreground call path — both `ArmSessionIntent.perform()` and `ArmView`'s Arm button
  route through `armSession()`, confirmed via `git diff`.
- `.update(phase:)` is driven by `AppComposition`'s `for await phase in session.phase` loop —
  fires on every phase emission (armed/capturing handled directly; idle triggers `end()` instead
  of a zombie update, via `LiveActivityContent.shouldEndActivity`).
- `.tidying` is never emitted by `SessionCoordinator`/`SessionPhase` itself (confirmed by
  plan-checker's grep during planning). `CaptureCoordinator.onTidyingChange` fires `true` at the
  start of `stopCapture()` and `false` once `resultReady` posts; wired to
  `liveActivityController.setTidying(_:)`. `LiveActivityContent.effectivePhase` composes this with
  the real phase — a genuine `.idle` always wins over a stale tidying flag (tested, see below).
- Word count: `AppComposition`'s signal loop reads `.draftUpdated` and calls
  `liveActivityController.updateWords(from: draft.text)` → `LiveActivityContent.wordCount`.
- `levels` is an explicit 8-zero placeholder (`LiveActivityContent.placeholderLevels()`) —
  correct per phase scope, real waveform visualization was never a stated success criterion.

### 2. The stop button in the Live Activity ends the session reliably — DONE (logic), PARTIALLY DONE (end-to-end)

- `App/PikoWidgets/StopSessionIntent.swift`: `LiveActivityIntent` (not plain `AppIntent` —
  correct per research, this is Apple's documented mechanism for intents that fire without
  foregrounding the app) posts `Signal.stopRequested` through a real `DarwinChannel()!`, not a
  stub.
- `CaptureCoordinator.handleSignal(.stopRequested)`: checks `transcriptionTask != nil` (its own
  synchronous liveness flag) rather than the heartbeat-refreshed `channel.readState()?.phase`,
  closing the stale-read race the plan-checker caught during planning. Calls `stopCapture()` only
  if a capture is genuinely in flight, then **always** calls `session.disarm()` regardless —
  confirmed by two passing tests below.
- Widget UI: `PikoLiveActivityWidget.swift` renders a real `Button(intent: StopSessionIntent())`
  in both the Lock Screen view and the Dynamic Island's expanded region.
- **What is NOT verified**: whether tapping this button on a real Lock Screen/Dynamic Island
  actually reaches the intent and produces a visible, reliable stop, and whether the Live
  Activity's real update cadence/background delivery holds up over a real session — Simulator
  Live Activity behavior is explicitly excluded from counting per `docs/WORKING-AGREEMENT.md`.
  Same category of gap as Phase 3's Back Tap/Action Button/45-min soak — requires a physical
  device.

## Independent re-verification performed

1. `swift build` — clean, 0 errors.
2. `swift test` (macOS host) — 65 tests, 2 failures, both the same pre-existing
   App-Group-in-unsigned-SPM-environment limitation present since Phase 2 (confirmed identical
   failure text to prior phases' runs). No new regressions.
3. `cd App && xcodegen generate && xcodebuild -project Piko.xcodeproj -scheme Piko -destination
   'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4' build` — **BUILD SUCCEEDED**.
   `Piko.app` embeds `PikoWidgets.appex` and `PikoKeyboard.appex` cleanly (`ValidateEmbeddedBinary`
   passed for both, no bundle-ID-nesting or CFBundleDisplayName errors — confirmed
   `App/project.yml`'s `PikoWidgets` target has `PRODUCT_BUNDLE_IDENTIFIER:
   dev.piko.Piko.PikoWidgets` and `CFBundleDisplayName: Piko`, the exact pattern that broke
   Simulator installs twice before for `PikoKeyboard`).
4. `xcodebuild test -scheme Piko-Package -destination 'platform=iOS
   Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` (full suite, no filter) — **exit 0, all
   tests passed** (115 ✔/✘ marker lines, zero ✘). Confirmed by name that the new tests actually
   ran and passed: `stopRequestedStopsCaptureThenDisarms`,
   `stopRequestedWhenArmedOnlySkipsStopCaptureButStillDisarms`,
   `stopCaptureFiresTidyingChangeAroundRewriteWindow`, and all 8
   `LiveActivityContentTests` (word counting, `shouldEndActivity`, `effectivePhase` — including
   the specific case that a real `.idle` beats a stale tidying override).

### Real bug found and fixed during this verification pass (environmental, not a code defect)

An earlier, unrelated experiment this session (installing BlackHole for a real-audio spike test,
since reverted and deleted) left the booted Simulator's CoreAudio HAL in a broken state — any
`AVAudioEngine.connect(inputNode, ...)` call crashed with an uncaught `Input HW format is invalid`
exception, killing the xctest process outright, even after the Mac's system audio devices were
restored to normal. This surfaced as 4 of 5 `CaptureIntegrationTests` "silently" not reporting
pass/fail (process died mid-suite). Fixed with `xcrun simctl shutdown` + `boot` on the Simulator
device (not a full Mac reboot) — full suite re-run clean afterward, exit 0. Documented in
`/memories/ios-simulator-audio-lessons.md` so this isn't rediscovered blind next time. Not a
regression introduced by Phase 7's actual code — confirmed by the same crash class occurring in
the pre-existing `SessionCoordinator.startCapture()` path too, unrelated to any Phase 7 file.

## Verdict

**Overall: PARTIALLY DONE**, same shape as every prior phase's device-dependent gaps.

- Everything expressible and testable on Simulator/macOS is DONE: Activity lifecycle plumbing,
  phase→state mapping including the `.tidying` synthesis, stop-signal race safety, widget/Dynamic
  Island view wiring, bundle configuration, all covered by passing tests.
- Genuine on-device Live Activity behavior (cadence, background delivery, real Lock
  Screen/Dynamic Island stop-button tap) is unverified — requires a physical device, consistent
  with Phase 3's Back Tap/Action Button/45-min soak gaps still open in that phase's own
  VERIFICATION.md.
