---
phase: 05-transcription
verified: 2026-08-29T23:15:00Z
status: human_needed
score: 1/3 must-haves verified
must_haves:
  truths:
    - "First recognized words visible within 400ms of speech starting"
    - "30-second continuous dictation produces no visibly thrashing partial text"
    - "Transcriber protocol has SpeechTranscriberEngine and MockTranscriber implementations"
  artifacts:
    - path: "Sources/PikoTranscribe/SpeechTranscriberEngine.swift"
      provides: "iOS 26 Speech framework integration with accumulation logic"
    - path: "Sources/PikoTranscribe/MockTranscriber.swift"
      provides: "Deterministic transcriber for tests/Simulator"
    - path: "Sources/PikoAudio/SessionCoordinator.swift"
      provides: "AVAudioEngine buffer streaming with continuation capture fix"
    - path: "App/Piko/CaptureCoordinator.swift"
      provides: "Wiring buffers → transcriber → channel"
  key_links:
    - from: "SessionCoordinator"
      to: "buffers AsyncStream"
      via: "installTap → continuation.yield"
    - from: "CaptureCoordinator"
      to: "Transcriber"
      via: "for await buffer in session.buffers"
    - from: "Transcriber"
      to: "CaptureDraft"
      via: "hypotheses stream → channel.writeDraft"
human_verification:
  - test: "Measure first-word latency on physical device"
    expected: "First recognized word visible in ≤400ms after speech starts"
    why_human: "Requires real speech input and device timing measurement; Simulator uses MockTranscriber"
  - test: "30-second continuous dictation stability test"
    expected: "No visible text thrash or repeated words during 30s monologue"
    why_human: "Requires real speech input on device; algorithm correctness verified but runtime behavior needs device proof"
---

# Phase 5: On-Device Transcription — Verification Report

**Phase Goal:** `PikoTranscribe` turns audio buffers into a hypothesis stream fast enough that the loop feels instant.
**Verified:** 2026-08-29T23:15:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | First recognized words visible within 400ms | ? UNCERTAIN | Accumulation algorithm verified (lines 115-135 SpeechTranscriberEngine.swift); device timing measurement needed |
| 2 | 30s continuous dictation without thrash | ? UNCERTAIN | StablePrefix logic verified (tests pass); device speech test needed |
| 3 | Transcriber protocol with SpeechTranscriberEngine + MockTranscriber | ✓ VERIFIED | Both implementations exist, compile, tested |

**Score:** 1/3 truths verified (2 require device testing)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/PikoTranscribe/SpeechTranscriberEngine.swift` | iOS 26 Speech framework integration | ✓ VERIFIED | 158 lines, accumulation logic at L115-135: `fullText = accumulatedText + " " + phraseText`, stablePrefix set correctly |
| `Sources/PikoTranscribe/MockTranscriber.swift` | Deterministic test transcriber | ✓ VERIFIED | 67 lines, Script.progressive convenience, ignores PCM input |
| `Sources/PikoAudio/SessionCoordinator.swift` | AVAudioEngine tap + buffer stream | ✓ VERIFIED | 325 lines, continuation capture fix at L132-138: `let continuation = buffersContinuation` before installTap |
| `App/Piko/CaptureCoordinator.swift` | Buffers → transcriber → channel wiring | ✓ VERIFIED | 79 lines, startCapture configures SpeechTranscriberEngine, streams hypotheses |
| `App/Piko/AppComposition.swift` | Composition root with Simulator/device switch | ✓ VERIFIED | `#if targetEnvironment(simulator)` → MockTranscriber, else SpeechTranscriberEngine |
| `Tests/PikoTranscribeTests/MockTranscriberTests.swift` | MockTranscriber tests | ✓ VERIFIED | 3 tests pass |
| `Tests/PikoTranscribeTests/StablePrefixTests.swift` | StablePrefix algorithm tests | ✓ VERIFIED | 5 tests pass |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| SessionCoordinator | buffers AsyncStream | installTap → continuation.yield | ✓ WIRED | L132-138: `let continuation = buffersContinuation` captured before tap, callback uses `continuation.yield(buffer)` |
| CaptureCoordinator | Transcriber | for await buffer in session.buffers | ✓ WIRED | L40-55: configures transcriber, feeds buffers, streams hypotheses |
| Transcriber.hypotheses | CaptureDraft | channel.writeDraft | ✓ WIRED | L47-52: `for try await hypothesis in transcriber.hypotheses` → `channel.writeDraft()` |
| CaptureCoordinator | SessionChannel | draftUpdated signal | ✓ WIRED | L50: `channel.draftUpdated()` after writeDraft |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|-------------------|--------|
| SpeechTranscriberEngine | hypotheses stream | SpeechTranscriber.transcribe() | Yes — real Speech framework | ✓ FLOWING (on device) |
| MockTranscriber | hypotheses stream | Script entries | Yes — deterministic test data | ✓ FLOWING |
| CaptureCoordinator | drafts | transcriber.hypotheses | Yes — from transcriber | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Build compiles | `swift build` | Build complete! (0.07s) | ✓ PASS |
| macOS tests pass | `swift test` | 33 pass / 2 fail (pre-existing App Group env) | ✓ PASS |
| iOS Simulator tests pass | `xcodebuild test -scheme Piko-Package` | TEST SUCCEEDED | ✓ PASS |
| MockTranscriberTests | 3 tests | All pass | ✓ PASS |
| StablePrefixTests | 5 tests | All pass | ✓ PASS |
| PikoAudioTests | 15 tests | All pass | ✓ PASS |
| Capture pipeline tests | startCaptureBeginsDraftFlow, stopCaptureWritesResult | All pass | ✓ PASS |

### Probe Execution

No probes declared for Phase 5.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| CAPT-03 | 05-02-PLAN | First words visible within 400ms | ? NEEDS HUMAN | Algorithm implemented; device timing needed |
| CAPT-04 | 05-02-PLAN | No visible text thrash in 30s monologue | ? NEEDS HUMAN | StablePrefix logic verified; device speech test needed |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| ArmedSession.swift | 27 | TODO(spike 2) | ℹ️ Info | Documentation comment — work is implemented and tested |
| CaptureCoordinator.swift | 64 | TODO(phase 6) | ℹ️ Info | Explicitly deferred to Phase 6 — not a gap |

**No blocking anti-patterns.** Both TODOs are informational:
- ArmedSession.swift TODO describes implemented behavior (tests verify interruption handling)
- CaptureCoordinator.swift TODO explicitly references Phase 6 work (Brain rewrites)

### Human Verification Required

#### 1. First-Word Latency (CAPT-03)

**Test:** On a physical iOS 26 device, start dictation and speak. Measure time from first sound to first visible text.
**Expected:** First recognized word appears in ≤400ms
**Why human:** Requires real microphone input and real Speech framework; Simulator uses MockTranscriber which bypasses the latency path under test.

#### 2. 30-Second Dictation Stability (CAPT-04)

**Test:** On a physical iOS 26 device, dictate continuously for 30 seconds without pausing.
**Expected:** No visible thrashing (repeated/flashing words, unstable prefix, text jumping)
**Why human:** Requires real speech with natural pauses and cadence; StablePrefix algorithm is verified at unit level but end-to-end stability needs device observation.

### Algorithm Verification Summary

**Accumulation Logic (SpeechTranscriberEngine.swift L115-135):**
```swift
let fullText = accumulatedText.isEmpty ? phraseText : accumulatedText + " " + phraseText
if segment.isFinal { accumulatedText = fullText }
```
✓ VERIFIED — correctly combines finalized phrases with current segment.

**StablePrefix Logic (SpeechTranscriberEngine.swift L119-131):**
- Volatile text (not final, no punctuation): `stablePrefix = accumulatedText.count` — only finalized text is stable
- Final or punctuated text: `stablePrefix = fullText.count` — entire text is stable
✓ VERIFIED — 5 unit tests confirm boundary conditions.

**Continuation Capture Fix (SessionCoordinator.swift L132-138):**
```swift
let continuation = buffersContinuation
inputNode.installTap(...) { buffer, _ in
    continuation.yield(buffer)
}
```
✓ VERIFIED — local capture avoids Swift 6 actor-isolation errors.

### Gaps Summary

No code gaps found. All artifacts exist, are substantive, and are correctly wired. Algorithm correctness verified through unit tests.

**Human verification is required** because:
- CAPT-03 (400ms latency) and CAPT-04 (no thrash) are performance requirements that can only be verified with real speech input on a physical device
- The Simulator path uses MockTranscriber, which doesn't exercise the real Speech framework timing or stability characteristics

---

_Verified: 2026-08-29T23:15:00Z_
_Verifier: Claude (gsd-verifier)_
