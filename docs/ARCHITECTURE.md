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

Schema version 1 uses SQLite `user_version`. The only migration is shipped version 0 → final
version 1. Opening an unversioned file adds `turns`, `facts`, `entities` and `embeddings`,
retaining `results`, `results_fts`, `items` and `edits` in place.
The migration holds an immediate transaction through backfill, FTS rebuild and version update.
Failure rolls everything back and throws from initialization; unsupported/future versions and
nonfinal version-1 layouts are explicitly rejected without modification. There are no upgrade
paths for unreleased PR schemas. Reopening version 1 does not backfill again or allocate LSNs.

`turns` stores only `lsn`, `session`, `role`, `text` and `ts`. Each capture UUID is its own
deterministic synthetic session; it cannot group multiple dictations. Dictation cleanup is
the user's speech, not an assistant reply: each capture produces exactly one `user` turn with
exact `results.shipped` text and the original timestamp. Raw text remains only in legacy
results/FTS, not turns. Unversioned captures backfill in rowid order. Subsequent captures append
one turn atomically with the result and FTS insertion via a trigger.

Normal writes append rather than update or replace turns. Explicit history deletion atomically
removes the result, FTS entry and turns matching the capture's deterministic session. Direct
turn deletion is allowed for future forgetting/expiry; no maintenance API is introduced here.
AUTOINCREMENT preserves the committed LSN high-water mark even after all turn rows are deleted.

Facts store only `key TEXT NOT NULL PRIMARY KEY` (no default), `value`, `lsn`, `sourceTurn`,
`confidence`, `lastUsed` and `entityID`; there are no duplicate id/text/createdAt fields.
An optional entity ID links facts to entities. Source/entity foreign keys become null when their
referenced row is deleted, so retaining facts cannot prevent turn expiry. Entities include
JSON-text aliases and an optional contact ID; alias indexing is deferred. Embeddings retain
SQLite rowid-addressable vector blobs with dimensions, model/owner identity and a Float16/int8
encoding tag. These are storage
shapes only, with no extraction, inference, recall, photo, maintenance or settings API yet.
Owner-scoped AFTER DELETE triggers remove every embedding model for deleted turns
(`ownerKind = 'turn'`, `ownerID = CAST(old.lsn AS TEXT)`), facts (`'fact'`, `old.key`) and
entities (`'entity'`, `old.id`). Other IDs and same-ID owners of other kinds are untouched;
failure rolls back the enclosing history/turn/embedding deletion atomically.
The nonthrowing compatibility operations retain best-effort behavior and print storage errors.

### Quiet-sidekick companion

The native 3D character lives in `App/Piko/Pet`, using RealityKit's virtual `nonAR` mode.
It starts no camera or microphone session. `PikoUI` and the keyboard do not import RealityKit.
Pure finite motion in `PikoKit/PikoPetMotion.swift` maps actual listening, thinking, speaking
and completion state to the pet. Reduce Motion freezes idle motion. Home passes scroll,
scene and presentation visibility; the renderer tears down its view and update tasks when inactive.

Voice and typed requests share the existing `Conversation` and `ToolHarness`. Typed input is
recorded as user text without re-dictating or rewriting it. A typed clarification never starts
voice capture. External actions still wait for the existing confirmation. Results and errors
remain visible even when Quiet mode or learned habits suppress routine speech and celebration.
Superseded planning responses cannot run after dismissal. An already-approved action that is
finishing is not presented as cancelled.
Capture startup is separately owned and cancelled across permission, preparation, activity and
capture awaits. Stop invalidates pending arming, including a request sent from a widget.
Cancelled preparation cannot activate audio later, and stale cleanup cannot end a newer turn.
Activities being ended are not adopted by a new turn.

`PikoCompanionPreferences` stores a versioned preferences blob in app-only UserDefaults.
It contains personality, Quiet mode and the last 8 explicit engaged/dismissed events for each
of greeting and completion. There are no transcripts, screenshots, inferred emotions or
cross-app usage records in this store. The existing history SQLite file/schema is unchanged.
After at least 3 observations, a category with at least 75% dismissals stops routine nudges.
Recent engagement displaces old habits. There is no automatic promotion to unsolicited voice.
Explicit quiet settings override patterns; required approvals and real results bypass suppression.
Settings shows the retained counts and resets learning without resetting personality or history.
Corrupt or future preferences are reported and preserved until an explicit reset.

## Data contracts

All cross-process state lives in the App Group container, defined once in `PikoKit`:

- `SessionState` — armed / capturing / idle, plus a heartbeat the keyboard uses to decide
  whether to show "tap to arm" instead of a mic button.
- `CaptureDraft` — the streaming partial: text, a stable prefix length, a sequence number.
- `CaptureResult` — final text, the route taken, timings, and the raw transcript kept for
  edit-pair learning.

Sequence numbers matter. The keyboard must ignore a partial older than what it has already
inserted, or the field will thrash.
