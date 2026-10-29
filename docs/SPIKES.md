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

---

## Spike 7 — fluid Lop rig: Rive vs SwiftUI Canvas

The island can only show held frames, so Lop's fluid, pet-like motion lives in the app. Two
ways to build it: the Rive runtime with an animator-made `.riv` state machine, or a rig drawn in
SwiftUI (`TimelineView` + `Canvas`) and driven by our own spring physics.

Branch `spike/lop-rig` (PR #7). Debug-only lab screen: launch with `-PikoLopLab YES`.

**Built:**
- `Sources/PikoUI/LopPhysics.swift`: springs and timers (ears with follow-through, breathing,
  blinks, glances, nose twitch, startle), driven by `LopInputs` (listening, loudness, patting,
  where to look, mood). A pure value type with a seeded RNG, covered by 7 Swift Testing tests.
- `Sources/PikoUI/LopRigView.swift`: draws the sketch-canvas geometry every frame, as either
  the soft app render or the flat island look. Stroking Lop pats it.
- `Sources/PikoUI/LopFrameView.swift`: holds one deterministic `LopPose` using that same
  painter, without simulation, timers or gestures. `LopFrameView(pose: .rest, style: .flat,
  ink: .black)` uses cream fur and thin ink outlines; `.soft` keeps the shaded app finish.
  `LopPose` presets are `rest`, `blink`, `earTwitch`, `glanceLeft`, `glanceRight`, `nose`,
  `flop`, `earsUp(level:)`, `thump`, `tilt`, `swivelLeft`, `swivelRight`, `binky1`, `binky2`.
  Ear levels are normalized to 0...1 and clamped (NaN means quiet).
  Module tests rasterize both styles at 22/26/48/58pt with `ImageRenderer`, checking visible
  cream/ink, transparency, custom ink, distinct poses and repeatability. These are macOS
  module-render checks, not physical-device Live Activity evidence; that proof is still needed.
  Production app/widget callers are unchanged.
- `App/Piko/LopLab.swift`: every rig input on one screen, in both looks.
- During the spike the lab also ran RiveRuntime 6.28.1 next to the Canvas rig, playing a sample
  file (`mascot.riv`, MIT, from rive-app/rive-ios), because a Lop `.riv` needs the Rive editor.
  Once the numbers below were recorded, the Rive package, the sample file and the Rive panel were
  removed, so nothing Rive ships.

**Measured.** Release build, `generic/platform=iOS`, unsigned, Xcode 27:

| | Piko.app on disk | Piko.app zipped (-9) |
|---|---|---|
| Without Rive (Canvas rig included) | 9,208 KB | 3,170 KB |
| With RiveRuntime embedded | 14,268 KB | 5,227 KB |
| **Rive cost** | **+5,060 KB (+55%)** | **+2,057 KB (+65%)** |

- RiveRuntime ships as a dynamic framework (arm64 binary 5,142,592 bytes). It can't go in the
  keyboard or widget targets at all, because the keyboard has a ~60 MB ceiling and links PikoUI.
- Canvas rig cost: `LopRigView.o` + `LopPhysics.o` add up to about 36 KB of `__TEXT` + `__DATA`
  before dead-stripping.
- A Rive character file is small. The sample mascot is 27,909 bytes.
- **Network:** RiveRuntime links `NSURLSession`, and every `RiveViewModel` / `RiveFile`
  initialiser defaults to `loadCdn: true`, which fetches CDN-hosted assets from
  `public.rive.app`. Shipping it would mean passing `loadCdn: false` on every call and adding a
  CI check for it, or "nothing leaves the device" breaks quietly.

**Seen in the Simulator only** (iPhone 17, iOS 27): both panels render. Canvas Lop breathes,
blinks, raises its ears when listening and droops when sleepy. Frame cost, battery and dyld
launch cost were **not measured**, because Simulator numbers don't count. That needs an
Instruments run on a device.

**Comparison:**

| | SwiftUI Canvas rig | Rive |
|---|---|---|
| Download size | ~0 | +2.0 MB compressed |
| Keyboard / widget use | yes (PikoUI) | no |
| Network surface | none | CDN loader on by default |
| Who changes the motion | an engineer, in Swift | an animator, in the Rive editor |
| Blending, bones, mesh deform | hand-written | built in |
| Testable in `swift test` | yes (physics is a value type) | state machine is opaque |
| Fur / soft render | gradients + blurred shadow; real fur edge needs a Metal shader | depends on the file |

**Result:** keep the SwiftUI Canvas rig for v0.1. It costs almost nothing, works everywhere
PikoUI does, adds no network surface, and its behaviour is unit-tested. Rive only becomes worth
+2 MB once a dedicated animator is producing many blended clips. If that happens, gate it to
the app target and enforce `loadCdn: false`. **Decision (2026-10-28): Canvas rig adopted; Rive
removed from the branch.**

**Still open:** frame cost on a real iPhone (Instruments, Core Animation FPS + CPU); a Metal
`distortionEffect` for the fuzzy fur edge; driving the rig from the real `AudioLevelMonitor`
level instead of the lab slider.
