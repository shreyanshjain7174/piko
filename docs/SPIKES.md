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
