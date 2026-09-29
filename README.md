# Piko

An on-device voice companion for iPhone. Hold a button, talk, and cleaned-up text lands in
whatever app you were already in. Nothing leaves the device.

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

Pre-code. The five spikes in `docs/SPIKES.md` gate everything else — run them before
building features. Any one of them failing changes the product, not just the plan.

## Requirements

- macOS 15+, Xcode 27.0 or later (ships the built-in MCP server used by the agent setup)
- iOS 26 minimum deployment target
- A physical iPhone. The Simulator does not reproduce keyboard-extension memory limits,
  background audio behaviour, or Live Activity throttling. Do not trust green Simulator runs.

## Quick start

```bash
./scripts/setup.sh          # installs agent tooling, checks Xcode version
make project                # generates App/Piko.xcodeproj via XcodeGen
make open                   # opens it
```

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
