# Piko

A cute, private personal-intelligence companion for iPhone. Press the Action Button (or the
Control Center / Lock Screen control) and talk: Piko files reminders into Apple Reminders and
notes and journal entries into Piko, and answers "what did I say about…?" from your own
history. Free features run on-device; premium cloud features are planned as opt-in and paid.
The Piko keyboard remains an optional extra for typing into other apps.

- **Landing page** — `web/index.html`
- **What we're building** — `docs/SPEC.md`
- **How it works and why it has to work that way** — `docs/ARCHITECTURE.md`
- **The iOS walls, with sources** — `docs/CONSTRAINTS.md`
- **Model strategy (open weights, router, fine-tune)** — `docs/MODELS.md`
- **Prove-it-first experiments** — `docs/SPIKES.md`
- **Agent + editor setup** — `docs/TOOLING.md`
- **What's free and what isn't** — `docs/MONETISATION.md`
- **How we work here** — `docs/WORKING-AGREEMENT.md`
- **Order of work** — `docs/ROADMAP.md`

## Status

The eight original phases are code-complete, not beta-verified. Beta completion work compares
Apple speech against native Swift/Core ML Whisper on an iPhone 17, with English including
Indian English speech. Only one engine will ship after measured accuracy, latency, offline,
and background-lifecycle acceptance. See `.planning/STATE.md` for evidence and open gates.

Local Simulator checks exercise mocks; they do not prove recognition quality, background
survival, keyboard memory, or Live Activity behavior on a physical phone. Password/secure
fields, phone-pad fields, and apps that reject third-party keyboards are unsupported.
An armed session keeps the microphone active so keyboard capture can begin without reopening
Piko. Idle audio is discarded, not transcribed or saved. End the session to release the mic.

## Requirements

- Xcode 27 or later, on a compatible macOS host
- iOS 27 minimum deployment target
- A physical iPhone. The Simulator does not reproduce keyboard-extension memory limits,
  background audio behaviour, or Live Activity throttling. Do not trust green Simulator runs.

## Quick start

```bash
./scripts/setup.sh          # installs agent tooling, checks Xcode version
make project                # generates App/Piko.xcodeproj via XcodeGen
make open                   # opens it
```

Review and safely scan third-party tooling before running setup; it registers external MCP
packages. Setup is not required for `make project` or the existing local test commands.

## Developer engine comparison

The normal iPhone build still uses Apple speech pending the measured engine decision.
Simulator dictation normally uses mocks. The Whisper challenger is developer-only, with
WhisperKit pinned to 1.1.1; it is not a claim of beta quality or real-device latency.

Prepare the single compressed large-v3-turbo Core ML variant and its tokenizer explicitly:

```bash
python3 -B scripts/prepare-whisper-model.py /absolute/path/Whisper --download
python3 -B scripts/prepare-whisper-model.py /absolute/path/Whisper
make project
xcodebuild -project App/Piko.xcodeproj -scheme Piko \
  -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  PIKO_WHISPER_MODEL_DIR=/absolute/path/Whisper build
```

This downloads about 630 MB of public assets. Revisions, sizes, and all SHA-256 digests are
pinned in `scripts/whisper-model-manifest.json`. Only Debug builds stage these assets. Do not
commit weights or private benchmark recordings. The local tokenizer is validated before
loading; no automatic model download runs in the capture path.

For repeated developer installs, the same verified `Whisper` folder may instead be copied
once to the app's `Documents/Benchmarks/Whisper` directory using `devicectl device copy to`.
Build without `PIKO_WHISPER_MODEL_DIR` in a fresh DerivedData directory to avoid transferring
the 630 MB model with every app installation. The developer factory checks the bundle first,
then this explicit local cache; neither path downloads during capture. This cache is not a
new shipping engine choice or a user-facing model downloader.

Launch arguments `-PikoBenchmarkEngine whisper` select the staged challenger. Adding
`-PikoBenchmarkPrepare YES` performs model-readiness checks without opening the microphone;
the console reports `PIKO_BENCHMARK_READY` or `PIKO_BENCHMARK_FAILED`. A readiness success is
not an accuracy, offline-network, latency, memory, or background-survival result.

Use `scripts/verify-on-device.sh --preflight` for a read-only physical-device check.
`--smoke` builds, installs, and launches; it exits 2 because manual acceptance remains
unverified. Set `PIKO_DEVICE_UDID` and `PIKO_VERIFICATION_OUT` to select the phone/evidence
directory. The app identifier is `dev.shreyansh.Piko`; `dev.piko.Piko` was unavailable for
the confirmed team. Shared App Group remains `group.dev.piko.shared`.

Score consented paired recognition results with:

```bash
python3 -B scripts/score-transcriptions.py /private/path/corpus.json
python3 -B -m unittest discover -s scripts/tests
```

The JSON contains `corpus_id`, actual `locale`, `speaker_count`, and `utterances`. Each
utterance needs a unique `id`, `reference`, `apple`, and `whisper` string. Silence cases also
set `"category": "silence"` and an empty reference. At least 30 speech cases plus silence are
required. Case/punctuation normalization preserves numeric signs and decimal separators.
The scorer reports only an accuracy candidate; it never selects a shipping engine or passes
device gates. Preserve raw results for manual name/number/meaning review.

Release is gated on physical acceptance, user engine approval, removing the losing engine
and benchmark controls, export compliance and applicable dependency/model license notices.
TestFlight upload and invitations require separate explicit approval.

### Accuracy and latency evaluation

Test recognition independently of optional cleanup. Freeze the same audio bytes, references,
locale, engine/model revision, normalization and hardware for each comparison. Use multiple
speakers, Indian English accents, names/numbers, short replies, pauses, mild noise, and silence.
Public CMU ARCTIC Indian-English recordings are useful regression material, not a substitute
for beta-user dictation; training-data overlap and the limited speaking style remain caveats.
Synthetic speech is a plumbing smoke test, not human-accent accuracy evidence.

`score-transcriptions.py` reports aggregate WER `(substitutions + deletions + insertions) /
reference words`, edit counts and per-utterance errors. Separately inspect names, dates,
amounts and negation: low WER can still change a critical fact. Silence must produce no
fabricated text. Never exclude failures or difficult utterances to improve a headline score.
The same normalizer is applied to both engines; record number-format differences rather than
changing normalization for one provider. See [JiWER's metric and silence definitions](https://github.com/jitsi/jiwer).

For real-engine file replay, place WAVs in the app's `Documents/Benchmarks` directory and use
`-PikoBenchmarkEngine apple` or `whisper` with `-PikoBenchmarkFixture NAME.wav`. Reports include
the actual engine/platform, preparation, file-start-to-first-hypothesis, and post-input
finalization. A mock cannot be substituted in this lane. A manifest containing `locale` and
`files` can run sequential fixtures with `-PikoBenchmarkFixtureManifest fixtures.json`.
When using `devicectl ... process launch`, put `--` between the app bundle identifier and
these application arguments so the device tool does not interpret them as its own flags.

Reports are stored beside the input audio, one output file per engine. Compare actual replay
results without retyping transcripts:

```bash
python3 -B scripts/score-transcriptions.py /private/path/references.json \
  --apple-results /private/path/fixtures.apple.results.json \
  --whisper-results /private/path/fixtures.whisper.results.json
```

The reference list additionally supplies each `filename` and audio `sha256`; `speaker_count` must be the actual
known count, not inferred from an accent label. Pairing rejects mocks, missing/duplicate
fixtures, differing audio bytes/locales and mixed physical/Simulator results. Timing summaries use
nearest-rank p50/p95/p99 and retain missing counts rather than inventing zero measurements.
Repeat cold and warm runs separately; p95/p99 from a tiny corpus are descriptive, not a
statistical reliability guarantee.

File-start-to-first-hypothesis is **not** speech-onset-to-first-inserted-word. For the latter,
annotate speech onset, background Piko, and measure the actual keyboard edit in the host app.
Debug launch argument `-PikoBenchmarkCaptureFixture NAME.wav` replays a staged local WAV through
the existing capture/IPC/keyboard path while discarding microphone buffers. The UI labels
fixture mode. Debug timing markers contain epoch/uptime only, never transcript text. The
real microphone still stays active while armed; end the session to release it. Include
first *stable/correct* text, revision churn, finalization after Stop, failures/timeouts, and
keyboard/container memory and thermal behavior. Do not label Simulator CPU/RSS as phone data.

Optional Foundation Models tests check the documented production outcome: either faithful
cleanup within the unchanged 600ms budget or explicit bypass with raw text preserved.
A bypass passing this contract is not a cleanup-quality pass. Original extended-budget
failures stay in the recorded evidence.

### Sarvam as an optional external reference

[Saaras REST](https://docs.sarvam.ai/api-reference/speech-to-text/transcribe) is a hosted
speech-to-text API; [realtime streaming](https://docs.sarvam.ai/api/api-guides-tutorials/speech-to-text/realtime-streaming)
provides actual partial events. It can serve as an external accuracy reference using the
same licensed/public fixtures, but it is not part of Piko's offline runtime or engine gate.
Do not upload private speech, install external MCP packages, or make paid API calls without
explicit authorization. Keep keys outside the app/repository. Provider retention/privacy
terms require separate review; do not assume zero retention.

Cloud REST time includes upload, network, server inference and response. Realtime measurement
must pace audio as spoken and separate connection setup, first partial, endpointing delay
and final result. Do not compare a full-file cloud REST response directly against the local
400ms keyboard-first-word requirement. Match output modes: normalized `transcribe` and
`verbatim` differ, particularly for fillers and spoken numbers.

[Sarvam Voice Agents Tests](https://docs.sarvam.ai/voice-agents/build/tests) simulate conversations
and judge explicit expected behaviors. Their [Tests API](https://docs.sarvam.ai/voice-agents/api/tests/overview)
requires a Sarvam workspace and committed agent version; it is not a drop-in native-iOS
microphone/keyboard test suite. For a future conversational agent, repeat scenarios and
check tool arguments, task completion, interruption/barge-in, timeout/error recovery and
speech-end-to-first-audible-reply latency in addition to STT accuracy. Deterministic audio
metrics and actual phone integration tests remain necessary.

## Layout

| Path | What lives there |
|---|---|
| `Sources/PikoKit` | Shared types, protocols, IPC contracts. No platform code. |
| `Sources/PikoAudio` | The armed session — AVAudioEngine lifecycle, interruption recovery |
| `Sources/PikoTranscribe` | Speech-to-text behind a protocol; SpeechAnalyzer implementation |
| `Sources/PikoBrain` | Router + rewriter behind a protocol; Foundation Models and MLX implementations |
| `Sources/PikoMemory` | Local index, edit pairs, personal lexicon |
| `Sources/PikoBridge` | Keyboard ↔ app IPC (Darwin notifications + App Group) |
| `Sources/PikoUI` | The Piko character, skins, shared views |
| `App/Piko` | Container app target |
| `App/PikoKeyboard` | Keyboard extension target — stays dumb, stays under 60 MB |
| `App/PikoWidgets` | Live Activity / Dynamic Island + Control Center control |

## License

TBD before first public commit.
