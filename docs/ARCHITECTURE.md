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
  ├── PikoMind        → PikoKit
  ├── PikoMemory      → PikoKit, PikoMind
  ├── PikoBrain       → PikoKit, PikoMemory
  └── PikoUI          → PikoKit

App/Piko          → all of the above
App/PikoKeyboard  → PikoKit, PikoBridge, PikoUI   (nothing heavier — enforced in CI)
App/PikoWidgets   → PikoKit, PikoUI
```

The keyboard's dependency list is a build-time expression of C4. If someone adds PikoBrain to
that target, the build should fail before the device does. CI also checks the transitive Swift
package closure of the keyboard products; PikoMind must never reach the keyboard.

### App-only memory storage

`PikoMemory.SQLiteMemory(path:)` remains the `Memory`/`ItemStore` entry point. It delegates to
the `PikoMind.SQLiteStore` actor at the same app-container `history.sqlite` URL. There is no
second database, new package dependency, or change to `EphemeralMemory`.

Schema version 2 uses SQLite `user_version`. Opening an unversioned file adds `turns`, `facts`,
`entities` and `embeddings`, retaining `results`, `results_fts`, `items` and `edits` in place.
The migration holds an immediate transaction through backfill, FTS rebuild and version update.
Failure rolls everything back and throws from initialization; newer versions are rejected.
Reopening version 2 does not backfill again or allocate LSNs. The initial version-1 foundation
also upgrades in place, retaining active committed LSNs and existing foundation columns/data.

`turns` stores `lsn`, `session`, `role`, `text` and `ts`. Each capture UUID is its deterministic
synthetic session: raw text becomes a user turn and shipped text an assistant turn, both with
the exact original timestamp. Unversioned captures backfill in rowid order, user then assistant.
Subsequent captures append both turns atomically via a trigger. The original `id`/`createdAt`
columns remain for compatibility; `id` links both turns to history deletion.

Normal writes append rather than update or replace turns. Explicit history deletion atomically
removes the result, FTS entry and both transcript-bearing turns. Direct turn deletion is allowed
for future forgetting/expiry; no maintenance API is introduced here. AUTOINCREMENT preserves
the committed LSN high-water mark even after all turn rows are deleted.

Facts store unique keys and values, LSN, source-turn provenance, confidence and `lastUsed`;
an optional entity ID links facts to entities. Source/entity foreign keys become null when their
referenced row is deleted, so retaining facts cannot prevent raw-turn expiry. Entities include
JSON-text aliases and an optional contact ID. Embeddings retain SQLite rowid-addressable vector
blobs with dimensions, model/owner identity and a Float16/int8 encoding tag. These are storage
shapes only, with no extraction, inference, recall, photo, maintenance or settings API yet.
The nonthrowing compatibility operations retain best-effort behavior and print storage errors.

## Data contracts

All cross-process state lives in the App Group container, defined once in `PikoKit`:

- `SessionState` — armed / capturing / idle, plus a heartbeat the keyboard uses to decide
  whether to show "tap to arm" instead of a mic button.
- `CaptureDraft` — the streaming partial: text, a stable prefix length, a sequence number.
- `CaptureResult` — final text, the route taken, timings, and the raw transcript kept for
  edit-pair learning.

Sequence numbers matter. The keyboard must ignore a partial older than what it has already
inserted, or the field will thrash.
