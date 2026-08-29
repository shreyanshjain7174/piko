# Model strategy

Three tiers. Ship tier 1, make tier 2 an opt-in download, keep tier 3 honest about what it costs.

## Tier 1 — what ships in v0.1

**Apple Foundation Models, on-device.** 8,192-token context (`model.contextSize` from iOS 26.4),
free, no download, no RAM budget of our own, vision in iOS 27, rebuilt tool-calling. It is not
the best model available — it is the only one that costs nothing to ship and nothing to run.

Escalation for long rewrites: Private Cloud Compute, 32k context with real reasoning levels,
free below 2M first-time downloads. **Off by default.** It leaves the device, which contradicts
the product's only defensible claim, so it must be an explicit per-profile opt-in and must
appear in the UI while it is on.

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

## PikoTranscribe: ASR model strategy

Same two-tier shape as `Brain`, applied to `Transcriber` (see `SPEC.md`). Tier 1 ships; tier 2 is
an opt-in swap, never a silent fallback the user can't see.

### Tier 1 — Apple SpeechAnalyzer / SpeechTranscriber (ships in v0.1)

Free, on-device, zero download, zero RAM budget of our own. `SpeechTranscriber.results` is an
`AsyncSequence` of phrase results; `ReportingOption`/`ResultAttributeOption` control whether
interim (volatile) results are delivered alongside finals — this is what `Hypothesis.stablePrefix`
in `SPEC.md` is built on. This is the only ASR tier this project has a plan to actually ship.

### Tier 2 — open-weight local ASR (research only, not yet planned as a phase)

The `Transcriber` protocol makes this a config choice, not a rewrite, same as `Brain`. Candidates,
same shape as Handy's stack (github.com/cjpais/Handy — Rust/Tauri desktop app, whisper.cpp GGML +
Parakeet via CPU-optimized inference, Silero VAD; **desktop only, not iOS** — its exact runtime
doesn't port, but the model choices are still relevant):

| Model | Why it's a candidate | Caveat |
|---|---|---|
| WhisperKit (argmaxinc) | Swift-native, Core ML-converted Whisper, built for Apple Silicon/Neural Engine | Still Whisper-family latency characteristics, not built for streaming |
| Moonshine (Jeffries et al. 2024, arXiv:2410.15608) | Encoder-decoder + RoPE, no zero-padding — 5x less compute than Whisper tiny-en at equal WER on short segments. Explicitly designed for live transcription/voice commands. | Newer, smaller ecosystem than Whisper; verify iOS/Core ML conversion path before committing |
| MLX-Whisper | Runs on MLX Swift, same framework already planned for `LocalBrain` — one runtime instead of two if both tiers ship | Still Whisper-family, same streaming caveat as WhisperKit |

**Why this stays tier 2, not a replacement:** Apple's framework is already on-device, already
free, and already ships the volatile/final split the app's algorithm needs (see below). An
open-weight model only earns its download size and RAM budget if it beats SpeechAnalyzer on
devices/locales Apple doesn't cover, or on latency for this app's specific streaming pattern —
that's a benchmark to run against a real device, not an assumption to build on.

### The streaming self-correction algorithm (informs Phase 5's `Transcriber` implementation)

The literal mechanism behind "words get corrected as more context arrives" is well-studied, not
novel — apply the existing technique rather than inventing one:

- **LocalAgreement-n policy** (Macháček, Dabre, Bojar 2023, "Turning Whisper into Real-Time
  Transcription System", arXiv:2307.14743 — Whisper-Streaming): commit a prefix once N consecutive
  re-decodes agree on it; hold the tail as volatile. Self-adaptive latency. Reported 3.3s latency
  on unsegmented long-form speech in their benchmark — **not** "ultra-low"; that number is Whisper's
  own decode cost on long context, not a floor for every model.
- **Punctuation as a stronger commit signal than n-gram agreement**: a sentence-final punctuation
  mark (`.`, `?`, `!`) is a natural re-segmentation point — once one is emitted, the ASR is
  unlikely to revise anything before it, so it can raise `stablePrefix` immediately rather than
  waiting for N more re-decodes to agree. This is a refinement on top of LocalAgreement, not a
  replacement for it: use LocalAgreement for the general case, and let punctuation short-circuit
  the wait when it fires.
- Apple's `SpeechTranscriber` may already deliver something close to this natively via its
  reporting/attribute options — verify exactly what "volatile" vs "final" means for SpeechAnalyzer
  before reimplementing LocalAgreement on top of it; only build the custom policy if Apple's own
  volatile-result boundary doesn't already give `stablePrefix` for free.


