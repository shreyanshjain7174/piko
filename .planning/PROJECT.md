# Piko

## What This Is

Hold a button anywhere on iOS, speak, and cleaned-up text appears in the field you were already
in — no network involved. A container app plus a custom keyboard extension, built around the
"armed session" pattern that works around iOS's hard rule that keyboard extensions cannot open
the microphone.

## Core Value

Dictation that starts instantly from wherever you are and inserts clean text into whatever field
you're already in, entirely on-device. If arm-and-speak-and-see-clean-text stops working, nothing
else about this product matters.

## Requirements

### Validated

(None yet — nothing shipped. Module skeletons exist (`PikoKit`, `PikoBridge`, `PikoAudio`,
`PikoTranscribe`, `PikoBrain`, `PikoMemory`, `PikoUI`) but contain no working feature.)

### Active

See `.planning/REQUIREMENTS.md` for the full checklist. Summary — v0.1 ("the loop"):

- [ ] Arm a session from the container app, Back Tap, or the Action Button
- [ ] Keyboard extension with a mic button that drives the armed session
- [ ] Streaming insertion of partial transcript into the host text field
- [ ] On-device cleanup of the final transcript (fillers, punctuation, casing)
- [ ] Live Activity showing armed / listening / tidying state with a working stop button
- [ ] Local, searchable history of every session
- [ ] Four skins for the Piko character, chosen locally

### Out of Scope

- Accounts, sync, subscriptions, any server at all — zero network dependency is the point.
- "Do" and "Recall" router modes — v0.1 always takes the write path; router ships in v0.2.
- The Pebble accessory — v0.3, contingent on v0.2 usage frequency.
- iPad and Mac — different interaction model, different product.
- Any self-trained model — v0.1 uses only what ships with the OS.
- Cross-app actuation ("driving other apps") — no public API for this; Siri is the only
  orchestrator of other apps' intents (C9).
- A persistent background agent — `BGTaskScheduler` grants opportunistic minutes, not a daemon (C10).

## Context

- Platform: iOS 26+ (Swift 6.2 tools-version), Swift Package Manager workspace at
  `/Users/sunny/Projects/piko`.
- Repo state at planning time: 4 commits, spec + module skeleton only. No feature code written yet.
- Modules and their single-purpose contracts are fixed in `docs/SPEC.md` — do not blur module
  boundaries; `PikoKit` has zero platform dependencies, `PikoBridge` is the only cross-process
  channel, `PikoAudio` owns the armed session exclusively, etc.
- Ten load-bearing OS constraints are catalogued in `docs/CONSTRAINTS.md` (C1–C10) and every
  architectural choice traces to one of them. Re-verify on physical device before treating as
  settled; the doc is sourced from Apple docs/forums, not from this project's own device runs yet.
- `docs/MODELS.md`, `docs/MONETISATION.md`, `docs/SPIKES.md`, `docs/TOOLING.md`,
  `docs/WORKING-AGREEMENT.md` hold supporting detail — read them before touching the areas they cover.
- Working agreement (repo-specific, applies on top of GSD workflow): present 2-3 real options
  before non-trivial work with at least one non-obvious; verify Apple API claims against current
  docs/MCP rather than training data; distinguish Simulator results from device results explicitly;
  record spike results in `docs/SPIKES.md`; small reversible commits, never direct to `main`.

## Constraints

- **Platform**: iOS 26+ only for v0.1 — no iPad, no Mac, no Android.
- **Keyboard memory**: Keyboard extension process ceiling ≈60MB (C4) — no model, no audio
  buffers, no index may live there. All inference lives in the container app.
- **No background mic start**: Only a foreground-initiated session may continue in the
  background (C1-C3) — this asymmetry is the entire architecture.
- **No network**: v0.1–v0.2 have zero server dependency by design; this is a stated product
  differentiator, not a temporary limitation.
- **Live Activity lifetime**: 8h active + 4h stale (C6) — must be started at arm time.
- **Field exclusions**: Secure/numeric fields fall back to the system keyboard (C8) — cannot
  promise "every field."

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Armed-session architecture (foreground arm, background continue) | Only way around C1/C2 keyboard-mic and background-start blocks | — Pending (design decided, unimplemented) |
| SystemBrain (Apple Foundation Models) as default rewrite engine | Zero download, zero RAM budget, free | — Pending |
| GSD phase breakdown follows module boundaries, not feature slices | Matches the fixed module contracts in SPEC.md; keeps each phase's blast radius to one module | — Pending |

---
*Last updated: 2026-08-27 after initial GSD planning bootstrap from existing docs/*.*
