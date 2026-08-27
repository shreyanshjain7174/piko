# Architecture

## The armed session

C1, C2 and C3 together allow exactly one shape. The container app owns the microphone. The
keyboard extension owns the text field. They talk over an App Group and Darwin notifications.

```
FOREGROUND, ONCE PER SESSION
  user opens Piko (Back Tap / Action Button / app icon)
    └─ AVAudioSession.setActive(true)         ← legal only here (C2)
    └─ Activity.request(...)                  ← legal only here (C5)
    └─ app backgrounds, audio background mode keeps the process alive (C3)

EVERY DICTATION, FROM ANY APP
  keyboard: mic tapped
    └─ Darwin notify "piko.capture.start"     ← ~ms, no launch, no visible switch
  app (background):
    └─ engine already running, start buffering
    └─ SpeechTranscriber streams volatile results
    └─ writes partials to App Group           ← file or UserDefaults, see PikoBridge
  keyboard:
    └─ reads partials, insertText / deleteBackward to keep the field in sync
  keyboard: stop tapped → Darwin notify "piko.capture.stop"
  app:
    └─ final transcript → Router → Rewriter (on-device model)
    └─ writes final to App Group, notifies "piko.result.ready"
  keyboard:
    └─ replaces the streamed draft with the final text
  app:
    └─ Activity.update(...) throughout (background updates are fine once started)
```

## Process boundaries

| Process | May do | Must never do |
|---|---|---|
| Container app | Audio, ASR, model inference, index, Live Activity, network tools | Assume it is alive — always check and re-arm |
| Keyboard extension | Draw keys, read App Group, `insertText`, fire notifications | Hold audio, load a model, open a database, exceed ~60 MB (C4) |
| Widget extension | Render Live Activity, run the stop `AppIntent` | Long work — hand back to the app |

## Two latency paths

Dictation and agent work share a brain but not a budget.

- **Fast path** — transcript in, cleaned text out. Target under 600 ms after speech ends.
  Runs the rewriter only. No planning, no tool calls, no retrieval unless the lexicon is small.
- **Slow path** — the utterance was a command. 2–5 s is acceptable because the user asked for
  something to happen, not for text to appear.

A cheap classifier picks the path *before* the model is loaded with a big prompt. Regex and
keyword prefilter first, then a tiny routing model only when the prefilter is unsure. Never let
the planner sit inside the dictation path.

## Module graph

```
PikoKit        (types, protocols, no dependencies)
  ├── PikoBridge      → PikoKit
  ├── PikoAudio       → PikoKit
  ├── PikoTranscribe  → PikoKit
  ├── PikoMemory      → PikoKit
  ├── PikoBrain       → PikoKit, PikoMemory
  └── PikoUI          → PikoKit

App/Piko          → all of the above
App/PikoKeyboard  → PikoKit, PikoBridge, PikoUI   (nothing heavier — enforced in CI)
App/PikoWidgets   → PikoKit, PikoUI
```

The keyboard's dependency list is a build-time expression of C4. If someone adds PikoBrain to
that target, the build should fail before the device does.

## Data contracts

All cross-process state lives in the App Group container, defined once in `PikoKit`:

- `SessionState` — armed / capturing / idle, plus a heartbeat the keyboard uses to decide
  whether to show "tap to arm" instead of a mic button.
- `CaptureDraft` — the streaming partial: text, a stable prefix length, a sequence number.
- `CaptureResult` — final text, the route taken, timings, and the raw transcript kept for
  edit-pair learning.

Sequence numbers matter. The keyboard must ignore a partial older than what it has already
inserted, or the field will thrash.
