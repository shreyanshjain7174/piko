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
