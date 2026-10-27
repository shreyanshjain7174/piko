# Model strategy

Three tiers. Ship tier 1, make tier 2 an opt-in download, keep tier 3 honest about what it costs.

## Tier 1 — what ships in v0.1

**Apple Foundation Models, on-device.** The beta uses the system model only when available
on the verified device. Eligibility, user settings, language/region, and downloaded system
assets affect availability. There is no separately bundled rewrite model, but inference is
not free of memory/latency cost. The existing 600ms budget remains; on failure Piko preserves
the original transcript and explains the bypass.

There is no cloud escalation in this beta. Any future cloud feature is a separate product
decision with explicit consent, not a way to pass offline acceptance.

## Tool harness (2026-10-21)

Planners propose; `ToolHarness` (PikoBrain) decides. Every planner emits the same step shape
`ToolCall {tool, text, when}`, so Apple Foundation Models, an open SLM, or a future opt-in
cloud model are interchangeable behind `Planner`. The harness runs only registered tools, caps
plans at five steps, and runs `.external` tools (Reminders, Calendar, Shortcuts) only after
user approval. `ModelPlanner` drops unknown tools, unspoken content and unspoken dates, and
falls back to the free rule planner. Apple's built-in `Tool` calling loop (present in the
iOS 27 SDK) is not used for execution because it would bypass this approval gate.

Tools (all public iOS APIs): reminder.create (EventKit), calendar.create (EventKit
write-only), note.save / journal.save (local SQLite), checkin.schedule (UserNotifications),
shortcut.run (`shortcuts://run-shortcut`, the bridge to other apps' actions), memory.search
(local history). iOS gives third-party apps no way to see or drive other apps' UI, so
"computer use" is replaced by "app use" through these APIs and Shortcuts.

Next: an on-device eval (20 real requests) of Apple Foundation Models vs Qwen3.5-2B 4-bit via
MLX Swift on iPhone 17, scored on tool choice, argument accuracy and latency. A third-party
benchmark reports ~61 tok/s and ~1.3 GB for Qwen3.5-2B on iPhone 17 Pro (unverified by us).
Ship the SLM only if it clearly wins.

## Tier 2 — open weights, opt-in

Bring-your-own model is legitimate on iOS 27: convert to `.mlaimodel` with the Core AI tools in
Xcode 27, ship via on-demand resources, add
`com.apple.developer.kernel.increased-memory-limit`. MLX Swift is the other path and is easier
to iterate on. Inference only — there is no on-device fine-tuning yet.

Device budget, from published measurements: 8 GB iPhones handle roughly 4B at 4-bit;
6 GB devices, 2–3B. Expect 12–20 tok/s for a 3–4B at 4-bit on an iPhone 16 Pro, 20–30 tok/s at
2–3B, first token 300–500 ms. A 3B 4-bit model is ~1.7 GB of download.

### Two models, two jobs

Do not use one model for both. The router runs on every utterance; the rewriter runs once per
dictation. Their budgets differ by an order of magnitude.

| Job | Candidate | Size (4-bit) | License | Why |
|---|---|---|---|---|
| Router / classifier | Qwen3.5-0.8B | under 1 GB | Apache 2.0 | Tiny, multilingual, made for edge. Overkill is the enemy here. |
| Router / classifier | LFM2.5-1.2B-Thinking | ~1.1 GB | LFM Open | Built for reasoning-flavoured classification. Check the licence terms before shipping commercially. |
| Rewriter | Phi-4-mini (3.8B) | ~3 GB | MIT | Strongest permissive small model; MIT means no licence anxiety. Heavy for a phone. |
| Rewriter | SmolLM3-3B | ~2 GB | Apache 2.0 | Fully open training pipeline, which matters if we fine-tune and want to explain ourselves. |

Verify every size and licence against the model card at the time you pick — this table is a
starting shortlist, not a decision.

### The honest cost of tier 2

A 2 GB download, a memory entitlement, an App Review conversation, and a support burden on
devices that cannot hold it. It buys three things: devices without Apple Intelligence, our own
fine-tune, and output Apple's guardrails would refuse. Ship it when one of those is the reason
someone is not using Piko — not before.

## Tier 3 — our own fine-tune

The learning loop produces the dataset for free. Every `recordEdit(raw:shipped:final:)` is a
training pair: what the ASR heard, what we shipped, what the user actually wanted.

Path:

1. Collect pairs locally. Never upload them — the whole point is that they stay put.
2. To train, the user exports a dataset deliberately, or we train on our own dumped corpus and
   ship the adapter to everyone.
3. LoRA on the base rewriter (`mlx_lm.lora` on an Apple Silicon Mac is the cheapest loop).
4. Fuse or ship the adapter separately; adapters are small enough to update without re-downloading
   the base.
5. Evaluate against a held-out set of real transcripts with a rubric, not vibes: filler removal,
   punctuation, preserved meaning, preserved names, no hallucinated content.

**The trap:** a fine-tune that "sounds like the user" is very easy to make hallucinate content
the user never said. Weight the eval toward *faithfulness*, not style. A rewriter that invents a
sentence in someone's voice is worse than one that leaves an "um" in.

## Abstraction

Everything above sits behind `Brain` in `PikoBrain`. WWDC26's `LanguageModel` protocol lets
`SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, `CoreAILanguageModel` and
`MLXLanguageModel` swap by import. Build against the protocol from day one and tier 2 becomes a
configuration change instead of a rewrite.

## Transcriber tiers (PikoTranscribe)

Same tiered structure as `Brain` above, applied to speech-to-text instead of rewrite.

### Tier 1 — what ships in v0.1

Apple's SpeechAnalyzer/SpeechTranscriber is the existing baseline. Language assets may need
an explicit initial installation and can later be reclaimed by the system. Readiness must
be checked before capture; recognition then runs locally. Measure runtime memory and latency
on the phone rather than treating a system-managed model as zero-cost.

### Current beta comparison

Compare Apple against exactly one native Swift/Core ML Whisper challenger: WhisperKit 1.1.1
with compressed large-v3-turbo `openai_whisper-large-v3-v20240930_626MB`. The model and tokenizer
are separately revision/checksum pinned; see the developer commands in `../README.md`.
Rust, diarisation, and additional model tiers below are not part of this comparison.

Use the same consented English/Indian-English corpus and real background-app-to-keyboard
path on the user's iPhone 17. Require at most 10% normalized WER, no silence hallucinations
or data loss, and the existing latency/lifecycle gates. Whisper must additionally reduce
Apple's WER by at least 20% relative to justify its complexity; ties favor Apple. This is a
selection rule, not a measured result. Neither qualifying blocks beta distribution.

The "ultra-low-latency, self-correcting via punctuation" want is a **stable-prefix commit
policy**, not a model choice — it decides which characters of an already-streaming hypothesis are
safe to hand to the keyboard, regardless of which engine produced them. `stablePrefix` on
`CaptureDraft` (`Sources/PikoKit/Contracts.swift`) already exists for exactly this. The reference
technique is LocalAgreement-n (compare N consecutive hypothesis updates, commit their longest
common prefix) plus punctuation-boundary trimming, from Macháček, Dabre, Bojar,
["Turning Whisper into Real-Time Transcription System"](https://aclanthology.org/2023.ijcnlp-demo.3/)
(IJCNLP-AACL 2023), implemented in `github.com/ufal/whisper_streaming`.

**Not yet verified against Apple's actual API** — see `docs/SPIKES.md` Spike 3. LocalAgreement-n
assumes comparing full-hypothesis re-decodes of the same window; `SpeechTranscriber` instead
emits range-scoped, non-monotonic per-phrase results. Confirm the real revision behavior on
device before committing to a specific commit-policy shape. Whisper-style *audio*-buffer
trimming at sentence boundaries does not apply either way — `SpeechAnalyzer` owns its own
decoding window and cannot be rewound or re-chunked from outside.

A 2025 successor policy, AlignAtt (attention-guided, `github.com/ufal/SimulStreaming`), is
best-performing but requires a 10GB+ VRAM GPU — not applicable to an iPhone. SimulStreaming's
license is also unresolved (README states MIT; its release is tagged "Noncommercial version") —
do not adopt anything from it without checking that directly.

### Tier 2 — open-weight local ASR, opt-in (v0.2+, not v0.1)

Deferred, matching `Brain`'s own tier 2 timing and for the same reason: ship it when Apple's
engine is provably the blocker for someone, not before. The keyboard extension does zero
inference itself (CONSTRAINTS C1/C4) — all ASR runs in the container app, so this only ever
affects the app's own memory/size budget, never the keyboard's.

Reference architecture: [Handy](https://github.com/cjpais/Handy) (MIT, cross-platform local
dictation app, 30k+ stars) runs entirely offline via a Rust core — `transcribe-cpp`
(whisper.cpp/GGML) or [`transcribe-rs`](https://github.com/cjpais/transcribe-rs) (MIT,
multi-engine: Parakeet, Canary, Moonshine, SenseVoice, GigaAM, Whisper, via ONNX Runtime or
whisper.cpp) plus Silero VAD. If this tier is ever built, take the smallest slice — one engine,
not the full multi-engine surface. `transcribe-rs` lists a `moonshine-streaming` variant
(Useful Sensors' Moonshine, purpose-built for tiny/fast streaming edge ASR, not chunked-retry
like Whisper) as the most latency-aligned single candidate, but its iOS/Metal performance is
unverified — no published iPhone benchmark exists. Do not pick a model before benchmarking it on
device.

Bridging: Rust cross-compiles to iOS targets; Mozilla's
[UniFFI](https://mozilla.github.io/uniffi-rs/) officially generates Swift bindings for exactly
this pattern (Rust core embedded in a Swift app) and is the "memory safe" path for embedding a
C/C++-based engine like whisper.cpp without bridging its raw C API directly into Swift.

**The honest cost**, same shape as Brain's tier 2: a Rust toolchain, an FFI bridge, XCFramework
packaging, a second ASR engine to validate, and an App Review conversation about an embedded
compiled ML runtime — a multi-week commitment for a currently-unverified latency gain over Tier 1.
Ship it when that gain is measured and real, not speculative.
