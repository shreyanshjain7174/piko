# Piko — MVP specification

## One sentence

Press, talk, and Piko files what you said — reminders, notes, journal — and later answers
"what did I say about…?" from your own history, privately on your iPhone.

Piko does not replace Siri or system Dictation, and iOS does not allow a background wake word:
activation is a press (Action Button, Control Center / Lock Screen control, Siri phrase
"Talk to Piko", or the app), which briefly foregrounds Piko. Dynamic Island shows listening
state with a stop button.

## MVP scope (free, on-device)

**In:**

1. "Talk to Piko" from the Action Button, Control Center / Lock Screen control, Siri/Spotlight
   or the Home screen button.
2. On-device speech recognition and a Live Activity with an animated listening state.
3. Filing: every iPhone gets rule-based filing (`RuleOrganizer`); Apple Intelligence devices
   get on-device Foundation Models filing (`ModelOrganizer`) with a faithfulness guard and
   rule fallback. Items are reviewed, then saved with one tap.
4. Reminders saved to Apple Reminders (EventKit, only on Save); notes and journal stored
   locally and shown in the Filed tab.
5. Recall: questions starting "what did I…" are answered only from local history.
6. Local history of every capture, searchable; on-device weekly brain-dump count for testers.
7. Four skins for the Piko character. Optional Piko keyboard for typing into other apps.

**Out (deliberately, for this MVP):**

- Cloud, accounts, sync, subscriptions. Premium cloud is chosen from tester demand later.
- Wake word, replacing Siri, Hindi/Hinglish.
- The Pebble accessory, iPad and Mac.
- Any model we trained ourselves.

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

**Shipped profile (Phase 6):** `.agent` rewrites for a coding agent or LLM to parse
unambiguously, not for a human reader. `.code` still shapes text a human will read in a
commit or a file. `styleHint`: "Imperative, unambiguous, no filler words or hedging. State
the concrete file/symbol/action if the speaker named one. No greeting, no pleasantries, no
restating the obvious." `SystemBrain.instructions()` interpolates `profile.styleHint`
unchanged. The keyboard accessory row (`App/PikoKeyboard`) is the picker surface
(CONSTRAINTS C7); the container app does not duplicate it.

Acceptance: cleanup of a 60-word transcript completes in under 600 ms on the oldest supported
device, or the cleanup step becomes optional on that device.

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
