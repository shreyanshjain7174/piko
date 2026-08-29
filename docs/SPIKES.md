# Spikes

Five experiments, roughly a day each. Run them in order. Stop at the first failure and rethink
the product rather than routing around it — each of these can invalidate the design.

Record results in this file as you go. A spike with no recorded number did not happen.

---

## Spike 1 — keyboard ↔ backgrounded app round-trip

Bare keyboard extension, one button. Darwin notification to the container app, which is
backgrounded with an active audio session. App writes a fixed string to the App Group. Keyboard
reads it and calls `insertText`.

**Pass:** round-trip under ~120 ms, no keyboard restart, still working after twenty app switches.

**Result:** _not run_

---

## Spike 2 — armed session survival

Arm in the foreground, then use the phone normally for 45 minutes: camera, an incoming call, a
video, low power mode, AirPods connecting and disconnecting.

**Pass:** survives app switching and mixed audio; a call interruption recovers automatically or
surfaces a re-arm prompt within one second.

**Result:** _not run_

---

## Spike 3 — streaming insertion feel

Wire SpeechTranscriber's volatile results through to `insertText`. The hard part is not accuracy,
it is churn — text that rewrites itself while you watch is worse than text that arrives late.
Find the stable-prefix threshold that feels calm.

**Before picking an algorithm, verify the actual API shape.** LocalAgreement-n (the streaming-ASR
stability policy from Macháček et al. 2023, `ufal/whisper_streaming`) assumes comparing N
consecutive whole-hypothesis re-decodes of the same window and taking their longest common
prefix. Apple's `SpeechTranscriber` instead emits range-scoped, non-monotonic results per
phrase — each phrase may arrive more than once before finalizing (per Apple's own docs), but not
necessarily N times, and not as a full re-decoded transcript. Confirm via device logging
(record every `range`/`text`/`isFinal` emission for a real 30s utterance) whether a
LocalAgreement-style commit policy applies as-is, or whether only punctuation-boundary trimming
of the text/state history (not audio-buffer trimming — `SpeechAnalyzer` owns its own decoding
window, we cannot rewind or re-chunk it) is the applicable half of the technique. Do not build
`stablePrefix`'s threshold logic against an assumed API shape — verify first.

**Pass:** first words on screen within 400 ms; no visible thrash across a 30-second monologue.

**Result:** _not run_

---

## Spike 4 — Live Activity from the background

Start the activity in the foreground at arm time, then push amplitude and state updates from the
background for ten minutes. Measure the real cadence and whether the system throttles.

**Pass:** at least one visible update per second sustained; the stop-button intent fires reliably.

**Result:** _not run_

---

## Spike 5 — on-device cleanup latency

Foundation Models cleaning a 60-word raw transcript with a style prompt and three few-shot edit
pairs. This is perceived latency — it runs after the user stops talking.

**Pass:** under 600 ms on the oldest device we intend to support, or cleanup becomes optional there.

**Result:** _not run_

---

## Spike 6 — Back Tap / Action Button arming via App Intents

Bind `ArmSessionIntent` (registered via `PikoShortcuts`) to Back Tap
(Settings -> Accessibility -> Touch -> Back Tap) and, on an iPhone 15 Pro or later, the Action
Button (Settings -> Action Button -> Shortcut). Trigger each and observe whether Piko briefly
foregrounds (expected, given `openAppWhenRun = true`) before `arm()` succeeds with no thrown
`PikoError.notForeground`, and whether the app's phase text reflects `.armed` afterward.

**Pass:** both triggers invoke `arm()` successfully with no thrown error, and the visible
foreground flash (if any) is judged acceptable UX. If no Action-Button-equipped device is
available, SESS-03 specifically is recorded as not verified rather than silently marked passed.

**Result:** Not run this session — no physical iPhone was available to this autonomous execution
pass, and Back Tap / the Action Button have no Simulator or CI equivalent (per
`03-RESEARCH.md`'s Environment Availability table). The code-level prerequisites
(`ArmSessionIntent` with `openAppWhenRun = true`, `PikoShortcuts` registering it as an
`AppShortcut`) are in place and compile clean under `swift build` and a best-effort Xcode
Simulator build, but the `openAppWhenRun = true` requirement itself remains a MEDIUM-confidence,
device-unverified assumption per `03-RESEARCH.md` Assumptions Log A1. SESS-02 and SESS-03 are
**not** closed by this session — a human with a physical iPhone (and, for SESS-03, an iPhone 15
Pro or later) must complete the steps above and update this Result before either requirement is
considered device-verified.
