# Phase 5: On-Device Transcription - Research

**Researched:** 2024-08-29
**Domain:** On-Device Speech Recognition (iOS 26+ SpeechAnalyzer/SpeechTranscriber)
**Confidence:** HIGH

## Summary

Phase 5 implements the `PikoTranscribe` module: a `Transcriber` protocol backed by Apple's iOS 26+ Speech framework (`SpeechAnalyzer` + `SpeechTranscriber`) that converts audio buffers into streaming hypotheses fast enough that dictation feels instant.

**CRITICAL SCOPE SURPRISE:** The audio-buffer-to-AVAudioEngine wiring does NOT exist in the current codebase. Phase 3 VERIFICATION.md explicitly states: *"There is no AVAudioEngine, no tap installed, no PCM buffer ever produced."* The existing `SessionCoordinator.startCapture()` only flips `currentPhase = .capturing` — it performs no actual audio capture. Phase 5 **must add both**:
1. AVAudioEngine tap implementation in `PikoAudio` (extend `SessionCoordinator` to emit real `AVAudioPCMBuffer`s)
2. `SpeechTranscriberEngine` implementation in `PikoTranscribe`

This doubles the architectural surface area versus what the phase name suggests.

**Primary recommendation:** Extend `ArmedSession` protocol with `var buffers: AsyncStream<AVAudioPCMBuffer>`, implement AVAudioEngine tap in `SessionCoordinator`, then wire `SpeechTranscriberEngine` to consume those buffers via `AnalyzerInputConverter`.

---

## ⚠️ SCOPE SURPRISE — Audio Tap Missing

### Evidence

| Source | Quote |
|--------|-------|
| [Phase 3 VERIFICATION.md](../piko-03-armed-session/03-VERIFICATION.md) | "There is no AVAudioEngine, no tap installed, no PCM buffer ever produced" |
| [Phase 4 04-01-SUMMARY.md](../piko-04-keyboard-extension/04-01-SUMMARY.md) | "CAPT-01/CAPT-02 algorithm proven with synthetic drafts, not live speech" |
| `SessionCoordinator.swift` L84-89 | `func startCapture() { currentPhase = .capturing }` — no engine, no tap |
| `ArmedSession.swift` | Protocol missing `buffers: AsyncStream<AVAudioPCMBuffer>` property |
| `docs/SPEC.md` | `protocol Transcriber { func stream(_ buffers: AsyncStream<AVAudioPCMBuffer>) ... }` — expects buffer stream |

### Impact

Phase 5 must deliver TWO subsystems:
1. **Audio Capture** (PikoAudio): AVAudioEngine + installTap → buffer stream
2. **Transcription** (PikoTranscribe): SpeechAnalyzer/SpeechTranscriber → hypothesis stream

Both are required for CAPT-03/CAPT-04 acceptance criteria.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Audio buffer capture | PikoAudio (SessionCoordinator) | — | AVAudioEngine tap runs on audio-render thread, must be in dedicated audio module |
| Speech-to-text conversion | PikoTranscribe (SpeechTranscriberEngine) | — | iOS Speech framework, model isolation |
| stablePrefix calculation | PikoTranscribe (SpeechTranscriberEngine) | — | Coupled to transcription result semantics |
| Hypothesis → CaptureDraft mapping | PikoTranscribe | — | Output contract owned by transcription |
| Draft delivery to keyboard | PikoKit (SessionChannel) | — | Already implemented in Phase 4 |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Speech (SpeechAnalyzer) | iOS 26+ | Orchestrate speech analysis | Apple's new unified speech API, replaces SFSpeechRecognizer |
| Speech (SpeechTranscriber) | iOS 26+ | Speech-to-text module | On-device, low-latency, supports volatile results |
| AVFAudio (AVAudioEngine) | iOS 8+ | Audio capture | Standard iOS audio pipeline, required for buffer production |
| AVFAudio (AVAudioPCMBuffer) | iOS 8+ | Buffer format | Expected by AnalyzerInputConverter |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Speech (AnalyzerInputConverter) | iOS 26+ | Buffer format conversion | Convert AVAudioPCMBuffer to AnalyzerInput |
| Speech (AssetInventory) | iOS 26+ | Model download management | Ensure transcription models available on-device |
| Speech (CaptureInputSequenceProvider) | iOS 26+ | Simplified audio capture | Alternative to manual AVAudioEngine tap |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| SpeechTranscriber | DictationTranscriber | Compatible with older devices, but uses server, higher latency |
| SpeechTranscriber | SFSpeechRecognizer (legacy) | iOS 10+, but deprecated path, less optimized on iOS 26+ |
| Manual AVAudioEngine tap | CaptureInputSequenceProvider | Simpler setup, but less control over buffer format/timing |

**Installation:** Built-in iOS frameworks — no external dependencies.

---

## Package Legitimacy Audit

> **Not applicable** — Phase 5 uses only Apple system frameworks (Speech, AVFAudio). No external packages installed.

---

## Architecture Patterns

### System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Keyboard Extension Process                         │
└─────────────────────────────────────────────────────────────────────────────┘
          │ CaptureDraft
          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ SessionChannel                                                               │
│   draftUpdated signal ──────────────────────────────────────────────────────│
└─────────────────────────────────────────────────────────────────────────────┘
          ▲
          │ CaptureDraft
┌─────────────────────────────────────────────────────────────────────────────┐
│                               Host App Process                               │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ SessionCoordinator (PikoAudio)                                         │ │
│  │                                                                        │ │
│  │   AVAudioEngine ──┬──> installTap(onBus:) ──> AVAudioPCMBuffer stream │ │
│  │                   │                                                    │ │
│  │   AVAudioSession ─┴──> .record category, voiceChat mode               │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                    │                                                         │
│                    │ AsyncStream<AVAudioPCMBuffer>                          │
│                    ▼                                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ SpeechTranscriberEngine (PikoTranscribe)                               │ │
│  │                                                                        │ │
│  │   AnalyzerInputConverter                                               │ │
│  │         │                                                              │ │
│  │         ▼ AnalyzerInput                                                │ │
│  │   SpeechAnalyzer ──> SpeechTranscriber.results                        │ │
│  │                            │                                           │ │
│  │                            ▼ SpeechTranscriber.Result                  │ │
│  │   stablePrefix calculation (isFinal + LocalAgreement-n)               │ │
│  │                            │                                           │ │
│  │                            ▼ Hypothesis → CaptureDraft                 │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                    │                                                         │
│                    │ AsyncStream<CaptureDraft>                              │
│                    ▼                                                         │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ LoopCoordinator (orchestrates capture lifecycle)                       │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure

```
Sources/
├── PikoAudio/
│   ├── ArmedSession.swift          # Protocol (add: var buffers)
│   ├── SessionCoordinator.swift    # Implementation (add: AVAudioEngine tap)
│   └── InterruptionSource.swift    # Existing — unchanged
├── PikoTranscribe/
│   ├── Transcriber.swift           # Protocol definition
│   ├── SpeechTranscriberEngine.swift # SpeechAnalyzer implementation
│   ├── MockTranscriber.swift       # Deterministic test double
│   └── StablePrefixCalculator.swift # LocalAgreement-n logic (if needed)
└── PikoKit/
    └── Contracts.swift             # CaptureDraft, Hypothesis (existing)
```

### Pattern 1: AsyncStream Bridge for AVAudioEngine Tap

**What:** `AVAudioEngine.inputNode.installTap` produces buffers on the audio-render thread. Bridge to AsyncStream via continuation.

**When to use:** Connecting callback-based audio APIs to async/await consumers.

**Example:**
```swift
// Source: Apple AVAudioEngine documentation, adapted for AsyncStream
extension SessionCoordinator {
    var buffers: AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let format = audioEngine.inputNode.outputFormat(forBus: 0)
            audioEngine.inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format
            ) { buffer, time in
                continuation.yield(buffer)
            }
            continuation.onTermination = { _ in
                self.audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
    }
}
```

### Pattern 2: SpeechAnalyzer + SpeechTranscriber Setup

**What:** Initialize SpeechAnalyzer with SpeechTranscriber module, check/download assets, supply audio via AnalyzerInputConverter.

**When to use:** iOS 26+ on-device speech recognition.

**Example:**
```swift
// Source: https://developer.apple.com/documentation/speech/speechanalyzer
import Speech

// Step 1: Create transcriber module with volatile results enabled
guard let locale = SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
    throw TranscriptionError.unsupportedLocale
}
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults, .fastResults],
    attributeOptions: []
)

// Step 2: Check/install assets
if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()
}

// Step 3: Create input stream
let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

// Step 4: Create analyzer and converter
let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
let analyzer = SpeechAnalyzer(modules: [transcriber])
let converter = AnalyzerInputConverter(analyzerFormat: audioFormat!)

// Step 5: Feed buffers (in separate task)
Task {
    for await buffer in bufferStream {
        let inputs = try converter.convert(buffer, at: nil)
        for input in inputs { inputBuilder.yield(input) }
    }
    inputBuilder.finish()
}

// Step 6: Iterate results
for try await result in transcriber.results {
    let text = String(result.text.characters)
    let isFinal = result.isFinal
    // Map to Hypothesis/CaptureDraft...
}

// Step 7: Finalize
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

### Pattern 3: stablePrefix from isFinal + Time Ranges

**What:** `SpeechTranscriber.Result` provides `isFinal: Bool` and `range: CMTimeRange`. Use to compute stablePrefix.

**When to use:** Mapping Apple's result model to `CaptureDraft.stablePrefix`.

**Approach:**
1. When `isFinal == true`, the entire result is stable → `stablePrefix = text.count`
2. When `isFinal == false`, the result is volatile → either `stablePrefix = 0` (conservative) or track position of last final result
3. Sentence punctuation (`.`, `?`, `!`) at end → short-circuit to `stablePrefix = text.count` per SPEC.md

**Verify:** Test whether Apple's `volatileRange` / `isFinal` granularity is sufficient. If not, implement LocalAgreement-n on top.

### Anti-Patterns to Avoid

- **AVAudioEngine without try/catch:** Engine operations can throw; always wrap in do/catch
- **Blocking on audio thread:** The tap closure runs on the audio-render thread; never block or do heavy work there
- **Forgetting removeTap:** Leaks audio resources; always remove tap on termination
- **Ignoring asset availability:** SpeechTranscriber may need model download; always check AssetInventory first
- **Assuming synchronous startup:** `prepareToAnalyze(in:)` improves responsiveness but is async; call early

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Audio format conversion | Manual sample-rate conversion | AnalyzerInputConverter | Handles all format conversions correctly |
| Speech recognition | CoreML audio model | SpeechTranscriber | Optimized for iOS, handles wake words, model updates |
| Streaming audio capture | Manual AudioUnit tap | AVAudioEngine.inputNode.installTap | Thread-safe, integrates with AVAudioSession |
| Model download | Manual HTTP download | AssetInventory.assetInstallationRequest | Handles disk space, network, versioning |

**Key insight:** iOS 26+ Speech framework is comprehensive — no external ASR needed for the MVP.

---

## Common Pitfalls

### Pitfall 1: Buffer Format Mismatch

**What goes wrong:** AVAudioEngine outputs 48kHz stereo; SpeechAnalyzer expects different format.
**Why it happens:** Default tap format matches hardware, not speech model requirements.
**How to avoid:** Use `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` to get correct format, then either configure tap to that format or let AnalyzerInputConverter handle conversion.
**Warning signs:** Silent failures, empty transcription results.

### Pitfall 2: Tap Not Removed on Deallocation

**What goes wrong:** Audio continues capturing after session ends, draining battery.
**Why it happens:** AsyncStream continuation outlives coordinator.
**How to avoid:** Set `continuation.onTermination` handler; call `removeTap(onBus:)` explicitly in `stopCapture()`.
**Warning signs:** Memory growth, background audio activity.

### Pitfall 3: Blocking Audio Render Thread

**What goes wrong:** Audio dropouts, glitches, stuttering transcription.
**Why it happens:** Heavy work in tap closure.
**How to avoid:** Only yield to continuation in tap closure; do all processing asynchronously.
**Warning signs:** `kAudioQueueErr_InvalidRunState` errors, audible clicks.

### Pitfall 4: Missing Preheat

**What goes wrong:** First transcription takes 1-2 seconds to start.
**Why it happens:** SpeechAnalyzer loads models lazily.
**How to avoid:** Call `analyzer.prepareToAnalyze(in:)` during arm phase, before capture starts.
**Warning signs:** First-word latency exceeds 400ms requirement.

### Pitfall 5: Asset Not Downloaded

**What goes wrong:** Transcription fails silently or falls back to server.
**Why it happens:** On-device models require explicit download.
**How to avoid:** Check `AssetInventory.assetInstallationRequest(supporting:)` at app launch or arm time; download before capture.
**Warning signs:** Network traffic during transcription, higher latency.

---

## Code Examples

### AVAudioEngine Tap Setup

```swift
// Source: AVAudioEngine documentation + AsyncStream patterns
func setupAudioCapture() throws -> AsyncStream<AVAudioPCMBuffer> {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    
    return AsyncStream { continuation in
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { buffer, _ in
            continuation.yield(buffer)
        }
        
        continuation.onTermination = { @Sendable _ in
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        
        do {
            try engine.start()
        } catch {
            continuation.finish()
        }
    }
}
```

### Result to CaptureDraft Mapping

```swift
// Map SpeechTranscriber.Result to CaptureDraft
func mapToCaptureDraft(
    result: SpeechTranscriber.Result,
    sessionEpoch: UInt64,
    sequence: Int,
    startedAt: Date
) -> CaptureDraft {
    let text = String(result.text.characters)
    
    // stablePrefix logic:
    // - If isFinal, entire text is stable
    // - If ends with sentence punctuation, treat as stable
    // - Otherwise, 0 (conservative) or track previous final position
    let stablePrefix: Int
    if result.isFinal {
        stablePrefix = text.count
    } else if text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") {
        stablePrefix = text.count  // Punctuation short-circuit per SPEC.md
    } else {
        stablePrefix = 0  // Conservative: all volatile until final
    }
    
    return CaptureDraft(
        sessionEpoch: sessionEpoch,
        sequence: sequence,
        text: text,
        stablePrefix: stablePrefix,
        startedAt: startedAt
    )
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SFSpeechRecognizer + SFSpeechAudioBufferRecognitionRequest | SpeechAnalyzer + SpeechTranscriber | iOS 26 (2025) | Unified API, better latency control, explicit volatile results |
| Server-based recognition (requiresOnDeviceRecognition = false) | On-device by default | iOS 26 (2025) | Lower latency, privacy, offline capability |
| Result.isFinal binary flag | volatileRange + isFinal | iOS 26 (2025) | Finer-grained stability tracking |

**Deprecated/outdated:**
- `SFSpeechRecognizer`: Still works but less optimized on iOS 26+; prefer SpeechAnalyzer
- `recognitionTask(with:resultHandler:)`: Callback-based; prefer async results stream

---

## Open Questions

1. **LocalAgreement-n necessity**
   - What we know: SpeechTranscriber has `isFinal` + `volatileRange` for stability
   - What's unclear: Whether granularity is sufficient for smooth UI, or if N-agreement buffer needed
   - Recommendation: Start with direct `isFinal` mapping; add LocalAgreement only if thrash observed in testing

2. **Buffer size vs latency tradeoff**
   - What we know: Smaller buffers = lower latency, more CPU overhead
   - What's unclear: Optimal buffer size for 400ms first-word target
   - Recommendation: Start with 1024 samples (~21ms at 48kHz); tune empirically

3. **CaptureInputSequenceProvider vs manual tap**
   - What we know: Apple provides CaptureInputSequenceProvider for simpler setup
   - What's unclear: Whether it provides sufficient control for our latency needs
   - Recommendation: Start with manual tap for control; evaluate simplification later

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Swift Testing (existing in project) |
| Config file | Package.swift targets |
| Quick run command | `swift test --filter PikoTranscribeTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CAPT-03 | First words visible within 400ms | integration | Manual timing measurement | ❌ Wave 0 |
| CAPT-04 | No visible thrash across 30s monologue | integration | Visual inspection + diff count | ❌ Wave 0 |
| — | Transcriber protocol conformance | unit | `swift test --filter SpeechTranscriberEngineTests` | ❌ Wave 0 |
| — | MockTranscriber deterministic output | unit | `swift test --filter MockTranscriberTests` | ❌ Wave 0 |
| — | stablePrefix calculation | unit | `swift test --filter StablePrefixTests` | ❌ Wave 0 |
| — | AVAudioEngine buffer stream | integration | Simulator mic test | ❌ Wave 0 |

### Wave 0 Gaps

- [ ] `Tests/PikoTranscribeTests/SpeechTranscriberEngineTests.swift` — protocol conformance
- [ ] `Tests/PikoTranscribeTests/MockTranscriberTests.swift` — deterministic scenarios
- [ ] `Tests/PikoAudioTests/SessionCoordinatorBufferTests.swift` — buffer stream verification

---

## Security Domain

> Security is minimal for this phase — audio data stays on-device, no network transmission.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V2 Authentication | No | — |
| V3 Session Management | No | — |
| V4 Access Control | No | — |
| V5 Input Validation | No | Audio is system-provided |
| V6 Cryptography | No | — |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Microphone permission bypass | Information Disclosure | System enforces; keyboard extension limited to audio-only |
| Model extraction | Information Disclosure | Apple models not extractable; on-device only |

---

## Sources

### Primary (HIGH confidence)
- [Apple SpeechAnalyzer documentation](https://developer.apple.com/documentation/speech/speechanalyzer) — API patterns, lifecycle, buffer handling
- [Apple SpeechTranscriber documentation](https://developer.apple.com/documentation/speech/speechtranscriber) — Reporting options, Result structure, isFinal semantics
- [Apple SpeechTranscriber.ReportingOption](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption) — volatileResults, fastResults options

### Secondary (MEDIUM confidence)
- `docs/SPEC.md` — PikoTranscribe protocol definition, stablePrefix requirements
- `docs/SPIKES.md` — Spike 3 pass criteria (400ms, no thrash)
- Phase 3/4 summaries — Confirmed audio tap does not exist

### Tertiary (LOW confidence)
- LocalAgreement-n paper (arXiv:2307.14743) — Cited in SPEC.md but not directly verified [ASSUMED: algorithm applies to SpeechTranscriber]

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Apple documentation verified
- Architecture: HIGH — Codebase analysis confirms missing pieces
- Pitfalls: MEDIUM — Based on general AVAudioEngine/Speech patterns
- stablePrefix mapping: MEDIUM — isFinal exists; LocalAgreement-n may or may not be needed

**Research date:** 2024-08-29
**Valid until:** 2025-03-01 (iOS 26 APIs stable post-release)
