# Piko — MVP specification

## One sentence

Hold a button anywhere on iOS, speak, and cleaned-up text appears in the field you were already
in, with no network involved.

## v0.1 scope

**In:**

1. Arm a session from the container app, Back Tap, or the Action Button.
2. A keyboard extension with a mic button that drives the armed session.
3. Streaming insertion of partial transcript into the host text field.
4. On-device cleanup of the final transcript — fillers, punctuation, casing.
5. A Live Activity showing armed / listening / tidying state with a working stop button.
6. Local history of every session, searchable.
7. Four skins for the Piko character, chosen locally.

**Out (deliberately):**

- Accounts, sync, subscriptions, any server at all.
- "Do" and "Recall" modes. The router ships in v0.2; v0.1 always takes the write path.
- The Pebble accessory.
- iPad and Mac.
- Any model we trained ourselves. v0.1 uses what ships with the OS.

## Modules and their contracts

### PikoKit
Types and protocols only, no platform APIs, no dependencies. Everything cross-process is
defined here so the keyboard and the app cannot drift.

Owns: `SessionState`, `CaptureDraft`, `CaptureResult`, `Route`, `Skin`, `Profile`,
`AppGroup` identifiers, notification name constants.

### PikoBridge
The only place that knows how the two processes talk.

```swift
protocol SessionChannel {
    func post(_ event: BridgeEvent)
    var events: AsyncStream<BridgeEvent> { get }
    func readDraft() -> CaptureDraft?
    func writeDraft(_ draft: CaptureDraft)
}
```

Acceptance: a round-trip from keyboard to app and back completes in under 120 ms on device,
survives twenty app switches, and never delivers a stale sequence number to the keyboard.

### PikoAudio
Owns the armed session and nothing else.

```swift
protocol ArmedSession {
    var state: AsyncStream<SessionState> { get }
    func arm() async throws        // foreground only — throws otherwise
    func disarm()
    func startCapture() throws     // legal only while armed
    func stopCapture()
    var buffers: AsyncStream<AVAudioPCMBuffer> { get }
}
```

Must handle: phone call interruption, route change (AirPods connecting mid-sentence), another
app taking the session, low power mode, and being killed outright. Every one of those is a
re-arm prompt, not a crash.

Acceptance: survives 45 minutes of ordinary phone use; every interruption either recovers
silently or surfaces a re-arm prompt within one second.

### PikoTranscribe
Speech-to-text behind a protocol so the engine can be swapped.

```swift
protocol Transcriber {
    func stream(_ buffers: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<Hypothesis>
    func finish() async -> String
}
struct Hypothesis { let text: String; let stablePrefix: Int; let isFinal: Bool }
```

`stablePrefix` is what makes streaming insertion tolerable — the keyboard only rewrites the
characters after it. Getting this threshold right is the difference between magic and thrash.

Default implementation: Apple's SpeechAnalyzer / SpeechTranscriber.
Contextual bias from the personal lexicon goes in here — verify how far SpeechTranscriber's
custom vocabulary reaches; `SFSpeechRecognitionRequest.contextualStrings` is the fallback.

`stablePrefix` policy: LocalAgreement-n (Macháček, Dabre, Bojar 2023, "Turning Whisper into
Real-Time Transcription System", arXiv:2307.14743) — commit a prefix once N re-decodes agree,
hold the tail as volatile. Sentence-final punctuation (`.`, `?`, `!`) short-circuits the wait: once
emitted, raise `stablePrefix` immediately rather than waiting for further agreement, since a
sentence boundary is a natural re-segmentation point the decoder is unlikely to revise past.
Verify first whether `SpeechTranscriber`'s own volatile/final result reporting already gives this
for free before implementing LocalAgreement on top of it — see `MODELS.md`'s PikoTranscribe
section for the full research and open-weight-model comparison (Moonshine, WhisperKit, MLX-Whisper).

Acceptance: first words visible within 400 ms of speech starting; no visible thrash across a
30-second monologue.

### PikoBrain
Routing and rewriting behind one protocol, so the model underneath is a config choice.

```swift
protocol Brain {
    func route(_ text: String) async -> Route          // .write, .command, .recall
    func rewrite(_ text: String, profile: Profile, examples: [EditPair]) async throws -> String
}
```

Implementations:
- `SystemBrain` — Apple Foundation Models. Default. Zero download, zero RAM budget, free.
- `LocalBrain` — an open-weight model via MLX Swift or Core AI. Opt-in download. See `MODELS.md`.
- `MockBrain` — deterministic, for tests and for the fast Simulator loop.

Routing must not cost the fast path. Order: regex and keyword prefilter → tiny routing model
only when the prefilter is unsure → never the rewrite model.

Acceptance: cleanup of a 60-word transcript completes in under 600 ms on the oldest supported
device, or the cleanup step becomes optional on that device.

**Planned profile addition (Phase 6, not yet in `Contracts.swift`):** an `.agent` profile —
rewrites for a coding agent or LLM to parse unambiguously, not for a human reader. Draft
instruction, matching the style of the four shipped profiles: "Imperative, unambiguous, no
filler words or hedging. State the concrete file/symbol/action if the speaker named one. No
greeting, no pleasantries, no restating the obvious." This is a new `Profile` enum case, which
is Phase 1 (`PikoKit`) contract surface — do not add it ad hoc; land it as part of Phase 6
planning so the picker UI (`App/Piko/PikoApp.swift`) and `SystemBrain` prompt table update
together, not piecemeal.

### PikoMemory
Local index and the learning loop.

```swift
protocol Memory {
    func record(_ result: CaptureResult)
    func recordEdit(raw: String, shipped: String, final: String)   // the learning signal
    func lexicon(limit: Int) -> [String]
    func nearestEdits(to text: String, limit: Int) -> [EditPair]
    func search(_ query: String, limit: Int) -> [CaptureResult]
}
```

SQLite with FTS5. Retrieval, never a growing prompt — the on-device context window is 8,192
tokens and months of sessions will not fit in it, so do not try.

Lexicon sources, in order of value: corrections the user actually made, Contacts names,
calendar titles, words that appear in their own past dictations and nowhere in the dictionary.

Acceptance: 10,000 stored sessions still search in under 50 ms; the database survives an app
kill mid-write.

### PikoUI
The Piko character as a SwiftUI view with four skins and four states, plus the shared
components used by app, keyboard and widget. The character is one view with a state enum, not
four views.

## Non-goals that are easy to drift into

- Do not build a chat interface. Piko has no conversation view in v0.1.
- Do not add a settings screen with more than one screen of options.
- Do not implement cloud fallback "just in case". It changes the product's only real claim.
