# Phase 6: On-Device Cleanup & Routing - Research

**Researched:** 2025-01-20
**Domain:** Apple Foundation Models, on-device LLM inference, dictation cleanup
**Confidence:** HIGH

## Summary

Phase 6 wires `SystemBrain.rewrite()` to Apple's on-device Foundation Models framework and ensures the routing prefilter stays cheap. The codebase already contains the correct prompt design (`SystemBrain.instructions()` and `SystemBrain.prompt()`), the Brain protocol signature, and a working stub—research confirms the implementation path.

**Primary recommendation:** Implement `LanguageModelSession(instructions:)` + `respond(to:)` with a 600ms Task-based timeout; skip cleanup gracefully on unavailable/slow model; keep routing purely regex-based for v0.1.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Availability check | Container App | — | Must check before wiring session |
| Rewrite inference | Container App | — | C4 constraint: 60MB keyboard limit precludes model loading |
| Routing prefilter | PikoBrain module | — | Stateless string matching, no model |
| Hard rewrite deadline | PikoBrain module | CaptureCoordinator | Brain owns inference budget; coordinator owns raw-text fallback |

## User Constraints (from project docs)

### Locked Decisions
- **iOS 26.0+ deployment target** — project.yml confirms, enables Foundation Models
- **Brain protocol signature** — `route(_:) async -> Route`, `rewrite(_:profile:lexicon:examples:) async throws -> String`
- **60MB keyboard memory ceiling** — all inference lives in container app (C4)
- **600ms performance budget** — Spike 5 defines pass condition
- **Prefilter-first routing** — CLNP-03: regex/keyword prefilter, rewrite model never in routing path

### Claude's Discretion
- Timeout mechanism (Task deadline vs. explicit timer)
- Skip-cleanup UX (silent pass-through vs. subtle indicator)
- Warm-up strategy (prewarm on arm vs. lazy first-use)

### Deferred Ideas (OUT OF SCOPE)
- LocalBrain (open-weight tier) — v0.2+
- Command/recall routes beyond keyword matching — v0.2
- Private Cloud Compute escalation — OFF by default per MODELS.md

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CLNP-01 | Fillers removed, punctuation/casing corrected | LanguageModelSession + existing prompt in SystemBrain.swift |
| CLNP-02 | 600ms budget or skip gracefully | Task timeout pattern; availability check for skip |
| CLNP-03 | Regex/keyword prefilter first; rewrite model never in routing path | Existing `commandStarters`/`recallStarters` arrays sufficient |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Foundation Models | iOS 26.0+ | On-device LLM | Apple's built-in, zero download, privacy-preserving [VERIFIED: Apple docs] |
| SystemLanguageModel | iOS 26.0+ | Model access | `SystemLanguageModel.default` provides base model [VERIFIED: Apple docs] |
| LanguageModelSession | iOS 26.0+ | Inference | Session-based prompting with instructions [VERIFIED: Apple docs] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Swift Concurrency | Swift 6.0 | Timeout handling | `Task` with `CancellationError` for deadline enforcement |
| Observation | iOS 26.0+ | Availability monitoring | `SystemLanguageModel` conforms to `Observable` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Foundation Models | Core ML + custom model | Requires model download, training, higher complexity |
| Task timeout | DispatchWorkItem | Less ergonomic with async/await |

**Installation:**
```swift
import FoundationModels  // Already available on iOS 26+
```

**Version verification:** Framework ships with iOS 26.0+; no package install needed. [VERIFIED: Apple docs]

## Package Legitimacy Audit

> No external packages to install. Foundation Models is a first-party Apple framework.

| Package | Registry | Age | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|-----|-----------|-------------|-----------|-------------|
| FoundationModels | Apple (system) | iOS 26+ | N/A | Apple internal | N/A | Approved — first-party |

**Packages removed due to slopcheck [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Container App                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────┐         ┌─────────────────────────────────────┐   │
│  │ CaptureCoordinator│◄───────│ SpeechTranscriberEngine              │   │
│  └────────┬────────┘         │ (finalText from Phase 5)             │   │
│           │                  └─────────────────────────────────────┘   │
│           │ stopCapture()                                               │
│           ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐       │
│  │                      SystemBrain                             │       │
│  │  ┌─────────────────┐    ┌─────────────────────────────────┐ │       │
│  │  │ route(text)     │    │ rewrite(text, profile, ...)     │ │       │
│  │  │ ▼               │    │ ▼                               │ │       │
│  │  │ Regex prefilter │    │ 1. Check availability           │ │       │
│  │  │ commandStarters │    │ 2. Build LanguageModelSession   │ │       │
│  │  │ recallStarters  │    │ 3. respond(to: prompt)          │ │       │
│  │  │ → .write/.cmd   │    │ 4. Timeout after 600ms          │ │       │
│  │  └─────────────────┘    │ 5. Return cleaned text or raw   │ │       │
│  │                         └─────────────────────────────────┘ │       │
│  └─────────────────────────────────────────────────────────────┘       │
│           │                                                             │
│           ▼                                                             │
│  ┌─────────────────┐                                                    │
│  │ CaptureResult   │────►  SessionChannel  ────►  Keyboard Extension   │
│  │ raw: finalText  │       (.resultReady)                               │
│  │ shipped: cleaned│                                                    │
│  └─────────────────┘                                                    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure
```
Sources/PikoBrain/
├── SystemBrain.swift        # Already exists — add FoundationModels wiring
├── MockBrain.swift          # Already exists (inline in SystemBrain.swift)
└── BrainError.swift         # Optional: dedicated error types
```

### Pattern 1: Session-Based Inference
**What:** Create a `LanguageModelSession` with instructions, then call `respond(to:)`
**When to use:** Single-turn cleanup tasks (no multi-turn conversation)
**Example:**
```swift
// Source: https://developer.apple.com/documentation/foundationmodels/languagemodelsession
import FoundationModels

let session = LanguageModelSession(instructions: Self.instructions(profile, lexicon))
let response = try await session.respond(to: Self.prompt(text, examples))
return response.content
```

### Pattern 2: Availability Check Before Use
**What:** Check `SystemLanguageModel.default.availability` before attempting inference
**When to use:** Always, before any model operation
**Example:**
```swift
// Source: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
let model = SystemLanguageModel.default
switch model.availability {
case .available:
    // Proceed with inference
case .unavailable(.deviceNotEligible):
    // Device doesn't support Apple Intelligence
    throw PikoError.brainUnavailable("Device not eligible")
case .unavailable(.modelNotReady):
    // Model downloading or system busy
    throw PikoError.brainUnavailable("Model not ready")
case .unavailable(let other):
    throw PikoError.brainUnavailable("Unavailable: \(other)")
}
```

### Pattern 3: Task-Based Timeout
**What:** Wrap async inference in a Task with deadline enforcement
**When to use:** Meeting the 600ms budget (CLNP-02)
**Example:**
```swift
func rewriteWithTimeout(_ text: String, budget: Duration = .milliseconds(600)) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            // Actual inference
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content
        }
        group.addTask {
            try await Task.sleep(for: budget)
            throw CancellationError()
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}
```

### Anti-Patterns to Avoid
- **Model in routing path:** Never call `respond(to:)` from `route(_:)`. CLNP-03 explicitly forbids this.
- **Blocking on unavailable model:** Always check availability first; never spin waiting for `.modelNotReady`.
- **Complex conditional prompts:** Per Apple docs, avoid "if-else" prompt logic — use Swift code to customize instructions.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| On-device LLM | Custom Core ML model | `FoundationModels` | Zero download, Apple-tuned, privacy-preserving |
| Prompt templating | String concatenation soup | `Instructions` struct | Framework handles token management |
| Timeout logic | Manual timers + cancellation | `withThrowingTaskGroup` + sleep task | Structured concurrency handles cleanup |
| Availability tracking | Polling loops | `Observable` conformance | `SystemLanguageModel` is `@Observable` |

**Key insight:** Foundation Models framework handles context window management, token counting, and model loading. The app just provides instructions and prompts.

## Common Pitfalls

### Pitfall 1: Blocking UI on Model Loading
**What goes wrong:** First inference takes several seconds while model loads
**Why it happens:** On-device model requires memory allocation on first use
**How to avoid:** Call `session.prewarm(promptPrefix:)` at arm time, not at capture-stop time
**Warning signs:** First cleanup after app launch noticeably slower

### Pitfall 2: Context Window Exceeded
**What goes wrong:** `LanguageModelError.contextSizeExceeded` thrown
**Why it happens:** Instructions + prompt + examples exceed 8192 tokens
**How to avoid:** Cap examples at 3 (current code does this), keep lexicon under 40 words
**Warning signs:** Long transcripts with many edit pairs failing

### Pitfall 3: Unavailable Model Silent Failure
**What goes wrong:** App hangs or crashes when model unavailable
**Why it happens:** Not checking `.availability` before creating session
**How to avoid:** Always check `SystemLanguageModel.default.availability` first
**Warning signs:** Crashes on devices without Apple Intelligence

### Pitfall 4: Rewrite Model in Routing Path
**What goes wrong:** 200ms+ delay on every single utterance
**Why it happens:** Calling the model to decide if text is a command
**How to avoid:** Per CLNP-03: regex/keyword prefilter only for v0.1 routing
**Warning signs:** Keyboard feels sluggish even for simple messages

### Pitfall 5: Prompt Engineering for Server Models
**What goes wrong:** Model hallucinates, ignores instructions, produces verbose output
**Why it happens:** On-device model is much smaller; needs simpler, more direct prompts
**How to avoid:** Follow Apple's guidance: short, imperative, role-based, 2-15 examples max
**Warning signs:** "Think step by step" producing garbage

## Code Examples

Verified patterns from official sources:

### Basic Session Creation
```swift
// Source: https://developer.apple.com/documentation/foundationmodels/languagemodelsession
import FoundationModels

let session = LanguageModelSession(instructions: """
    You clean up dictated speech into text the speaker would have typed.
    Never add information the speaker did not say.
    Remove fillers and false starts. Add punctuation and capitalisation.
    Output only the cleaned text. No preamble, no quotes, no explanation.
    """
)
let response = try await session.respond(to: "Heard: um so like yeah we should meet tomorrow\nWanted:")
print(response.content)  // "We should meet tomorrow."
```

### Availability Switch
```swift
// Source: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
let model = SystemLanguageModel.default

switch model.availability {
case .available:
    let session = LanguageModelSession(instructions: instructions)
    // proceed
case .unavailable(.deviceNotEligible):
    // fallback: return raw text unchanged
    return text
case .unavailable(.modelNotReady):
    // retry later or skip
    return text
case .unavailable(let reason):
    print("Model unavailable: \(reason)")
    return text
}
```

### Prewarm for Latency
```swift
// Source: https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:)
let session = LanguageModelSession(instructions: instructions)
// Call at arm time, not at inference time
await session.prewarm(promptPrefix: "Heard:")
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Third-party LLM APIs | Foundation Models | iOS 26.0 (WWDC 2025) | Zero latency for API calls, privacy by default |
| Core ML custom models | SystemLanguageModel | iOS 26.0 | No model download, Apple-tuned |
| Separate availability checks | `@Observable` SystemLanguageModel | iOS 26.4 | Can bind UI directly to availability |

**Deprecated/outdated:**
- `SpeechRecognizer` for cleanup: Wrong tool — transcription, not rewriting
- Manual token counting: `SystemLanguageModel.tokenCount(for:)` handles it

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | 600ms budget achievable on oldest supported device | Performance | May need to increase budget or make cleanup optional |
| A2 | 3 few-shot examples sufficient for quality | Prompt Design | May need more examples or different approach |
| A3 | `prewarm()` significantly reduces first-inference latency | Latency | May need alternative warm-up strategy |

## Open Questions (RESOLVED)

1. **Oldest supported device performance** — RESOLVED for planning: `SystemBrain.rewrite` enforces a hard
   600 ms deadline independent of cooperative model cancellation, and `CaptureCoordinator` ships raw text on
   timeout. Full phase acceptance still requires Spike 5 on the oldest supported Apple Intelligence device;
   Simulator results must not be presented as model-quality or latency evidence.
2. **Prewarm timing** — RESOLVED: do not prewarm in Phase 6. A useful prewarm requires retaining an
   instructions-keyed session; measure cold/warm behavior in Spike 5 before adding that mutable lifecycle.
3. **Model version drift** — RESOLVED: no prompt-version subsystem in this phase. Re-run the fixed rewrite
   evaluation corpus during supported OS qualification; introduce version tracking only if measured drift
   requires it.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Foundation Models | Rewrite | iOS 26+ only | N/A | Return raw text unchanged |
| Apple Intelligence | SystemLanguageModel | Device-dependent | — | Check `.deviceNotEligible`, return raw |
| Swift 6 | Strict concurrency | ✓ | 6.0 (project.yml) | — |

**Missing dependencies with no fallback:**
- None — graceful degradation returns raw text

**Missing dependencies with fallback:**
- Foundation Models unavailable → skip cleanup, return raw transcript

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (iOS 26+) |
| Config file | Package.swift testTarget |
| Quick run command | `swift test --filter PikoBrainTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test files planned | Automated command |
|--------|----------|--------------------|-------------------|
| CLNP-01 | Rewrite contract and coordinator cleanup | `SystemBrainRewriteTests.swift`, `CaptureCoordinatorBrainTests.swift` | `swift test --filter SystemBrainRewriteTests`; Simulator coordinator tests |
| CLNP-02 | Hard deadline plus raw fallback | `RewriteBudgetTests.swift`, `CaptureCoordinatorBrainTests.swift` | `swift test --filter PikoBrainTests`; Simulator coordinator tests |
| CLNP-03 | Prefilter never invokes inference | `RoutePrefilterTests.swift` | `swift test --filter RoutePrefilterTests` |

### Sampling Rate
- **Per task:** focused command from the task's `<automated>` block
- **Per wave:** full iOS Simulator package suite
- **Phase gate:** full suite plus physical-device Spike 5 evidence from `06-VALIDATION.md`

### Wave 0 Gaps
None. Each TDD task creates its named test before implementation and runs a focused automated check.

## Security Domain

> Phase 6 does not introduce authentication, session management, or cryptography. Input validation is minimal (string processing).

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | minimal | Input is user's own transcribed speech; model handles safely |
| V6 Cryptography | no | — |

### Known Threat Patterns for Foundation Models

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Prompt injection | Tampering | Instructions are app-controlled, user input is in "Heard:" format |
| Model jailbreak | Elevation | Apple's Guardrails handle safety; we use default guardrails |
| Data exfiltration | Info Disclosure | On-device only; PCC disabled by default per MODELS.md |

## Sources

### Primary (HIGH confidence)
- [Apple Foundation Models docs](https://developer.apple.com/documentation/foundationmodels) - LanguageModelSession, SystemLanguageModel, availability
- [Prompting an on-device foundation model](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model) - prompt engineering guidance
- Project docs: SPEC.md, MODELS.md, CONSTRAINTS.md, REQUIREMENTS.md

### Secondary (MEDIUM confidence)
- SystemBrain.swift existing prompt design - already in codebase, needs device validation
- SPIKES.md Spike 5 definition - budget defined but not yet run

### Tertiary (LOW confidence)
- Prewarm latency improvement estimates [A3] - needs measurement

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Apple first-party framework, well-documented
- Architecture: HIGH - existing Brain protocol and stub match API
- Pitfalls: MEDIUM - some pitfalls need device validation (Spike 5)

**Research date:** 2025-01-20
**Valid until:** iOS 27.0 release (model version changes may affect prompt effectiveness)
