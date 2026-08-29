---
phase: piko-04-keyboard-extension
verified: 2026-08-29T16:22:00Z
status: human_needed
score: 3/3 must-haves verified (algorithm level)
overrides_applied: 0
human_verification:
  - test: "Enable Piko keyboard + Full Access in Settings, then tap mic in a host text field"
    expected: "Mic button posts .captureStart when armed, .captureStop when capturing; app receives Darwin notification"
    why_human: "Real Darwin notification round-trip requires device/Simulator UI; keyboard enable flow cannot be automated"
  - test: "Stream real CaptureDraft values into the keyboard while typing is in progress"
    expected: "Text appears progressively; stable prefix never flickers; only unstable tail rewrites"
    why_human: "Requires Phase 5 PikoTranscribe emitting real drafts — algorithm verified with synthetic mocks only"
  - test: "Measure keyboard extension memory footprint with Instruments/leaks"
    expected: "<60 MB per CONSTRAINTS C4"
    why_human: "Memory profiling requires Instruments; not automated in package tests"
---

# Phase 4: Keyboard Extension & Streaming Insertion — Verification Report

**Phase Goal:** Keyboard extension posts capture signals to the armed session, and partial transcripts stream into the host text field with stablePrefix-aware rewriting.
**Verified:** 2026-08-29T16:22:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Tapping the mic button in the keyboard arms/drives the session via SessionChannel | ✓ VERIFIED | `KeyboardViewController.micButtonTapped()` posts `.captureStart` (armed) / `.captureStop` (capturing); 4 signal-rule tests pass (`KeyboardViewModelTests`) |
| 2 | Partial transcript appears in the host text field as speech is recognized | ✓ VERIFIED (algorithm) | `TextInsertionController.apply()` inserts via `UITextDocumentProxy`; 7 insertion tests + 1 integration test pass |
| 3 | Only characters after stablePrefix are rewritten on each update — the stable prefix never flickers | ✓ VERIFIED (algorithm) | `alreadyStable = min(draft.stablePrefix, insertedChars)` logic; "revised unstable tail" test proves tail-only delete/insert |

**Score:** 3/3 truths verified at algorithm level

**Caveat:** Truths #2 and #3 are verified against synthetic `CaptureDraft` sequences in unit tests. Real speech-to-text streaming requires Phase 5's `PikoTranscribe` (which does not exist yet). The insertion algorithm is proven correct; the full user flow is not.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `App/PikoKeyboard/KeyboardViewController.swift` | UIInputViewController hosting SwiftUI, observing SessionChannel | ✓ VERIFIED | 112 lines; contains `UIHostingController`, `DarwinChannel`, `insertionController?.apply/commit/reset` wiring |
| `App/PikoKeyboard/TextInsertionController.swift` | stablePrefix-aware text insertion using UITextDocumentProxy | ✓ VERIFIED | 76 lines; `apply()` implements tail-only rewrite, epoch wipe, `commit()`, `reset()` |
| `App/PikoKeyboard/KeyboardView.swift` | SwiftUI root with MicButton, profile chips, globe | ✓ VERIFIED | 58 lines; arm banner, 4 profile chips (placeholder), MicButton, globe; height 240 |
| `App/PikoKeyboard/MicButton.swift` | Phase-aware mic button | ✓ VERIFIED | 60 lines; disabled for nil/idle/tidying; SF Symbols per phase |
| `Tests/PikoKeyboardTests/KeyboardViewModelTests.swift` | Signal posting tests | ✓ VERIFIED | 4 `@Test` functions; all pass |
| `Tests/PikoKeyboardTests/TextInsertionControllerTests.swift` | stablePrefix diffing tests | ✓ VERIFIED | 7 `@Test` functions; all pass |
| `Tests/PikoKeyboardTests/StreamingInsertionIntegrationTests.swift` | End-to-end scenario | ✓ VERIFIED | 1 `@Test` (streamingDictationScenario); passes |
| `Tests/PikoKeyboardTests/MockSessionChannel.swift` | In-memory SessionChannel double | ✓ VERIFIED | Records `postedSignals`; used by KeyboardViewModelTests |
| `Package.swift` (PikoKeyboardCore target) | SPM target for testable insertion logic | ✓ VERIFIED | `PikoKeyboardCore` excludes UI files; `PikoKeyboardTests` depends on it |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| KeyboardViewController | DarwinChannel | `channel.post(.captureStart)` / `channel.post(.captureStop)` | ✓ WIRED | Lines 90-92: `case .armed: channel?.post(.captureStart)` |
| KeyboardViewController | TextInsertionController | `insertionController?.apply(draft)` / `.commit(result)` / `.reset()` | ✓ WIRED | `applyDraft()` line 102, `applyResult()` line 107, idle→reset line 73 |
| KeyboardViewController | KeyboardView | `UIHostingController(rootView: makeKeyboardView())` | ✓ WIRED | Lines 30-40; SwiftUI embedded via `addChild` / `didMove(toParent:)` |
| TextInsertionController | UITextDocumentProxy | `proxy.deleteBackward()` / `proxy.insertText()` | ✓ WIRED | `apply()` lines 53-58, `commit()` lines 62-64 |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|-------------------|--------|
| KeyboardViewController | `channel?.readDraft()` | DarwinChannel → App Group file | Yes (if app writes draft) | ⚠️ HOLLOW — real drafts require Phase 5 PikoTranscribe |
| TextInsertionController | `draft` param in `apply()` | Caller passes CaptureDraft | Tests use synthetic mocks | ✓ FLOWING (at algorithm level) |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| PikoKeyboardTests pass on macOS | `swift test 2>&1 \| grep PikoKeyboard` | 12/12 pass | ✓ PASS |
| PikoKeyboardTests pass on iOS Simulator | `xcodebuild test -scheme Piko-Package ...` | 12/12 pass (38/38 total) | ✓ PASS |
| swift build succeeds | `swift build` | Build complete! (0.09s) | ✓ PASS |

### Probe Execution

No probes declared for Phase 4.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| BRDG-01 | 04-01 | Keyboard posts capture signals to armed session | ✓ SATISFIED | 4 signal-rule tests; `micButtonTapped()` wiring |
| CAPT-01 | 04-02 | Partial transcript streams into host text field | ✓ SATISFIED (algorithm) | `TextInsertionController.apply()` + 7 tests |
| CAPT-02 | 04-02 | Only characters after stablePrefix rewritten | ✓ SATISFIED (algorithm) | `alreadyStable = min(draft.stablePrefix, insertedChars)` logic + tests |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `KeyboardView.swift` | 27-32 | Profile chips are placeholders (hardcoded labels, no profile switching) | ℹ️ Info | Intentional UI shell; documented in SUMMARY; not required for CAPT-01/CAPT-02 |

### Human Verification Required

**3 items need human testing:**

### 1. Keyboard Enable & Darwin Round-Trip

**Test:** Enable Piko keyboard + Full Access in Settings → General → Keyboards. Open any text field, switch to Piko keyboard, tap mic while app is armed.

**Expected:** Mic button enabled when app is armed; tapping posts `.captureStart` and app transitions to capturing; tapping again posts `.captureStop`.

**Why human:** Keyboard enable flow, Full Access grant, and real Darwin notification IPC cannot be automated in package tests.

### 2. Real Streaming Insertion

**Test:** While a host text field is focused and the keyboard is active, have Phase 5's `PikoTranscribe` emit `CaptureDraft` sequences with growing `stablePrefix`.

**Expected:** Text appears progressively character-by-character; stable portion never jumps or flickers; only the unstable tail rewrites.

**Why human:** No real transcriber exists yet (Phase 5). Algorithm is verified with synthetic mocks; real speech-to-text integration requires PikoTranscribe.

### 3. Memory Footprint Verification

**Test:** Profile the keyboard extension with Instruments (Allocations or Leaks) while it is active in a host app.

**Expected:** Peak memory <60 MB per CONSTRAINTS C4.

**Why human:** Memory profiling requires Instruments or `footprint` CLI; not automated in test suite.

## Gaps Summary

No blocking gaps. All must-have truths are verified at the algorithm level with passing tests. The phase goal is achieved within its scope:

- **Mic remote control:** Proven by 4 signal-rule tests and `KeyboardViewController` wiring.
- **Streaming insertion algorithm:** Proven by 7 + 1 insertion tests against `MockTextDocumentProxy`.
- **PikoKeyboardCore module:** Exists and is correctly wired in `Package.swift`.

**What remains unverified (deferred to human / Phase 5):**
- Device UI (keyboard enable, Full Access, tap in real host field)
- Real Darwin notification round-trip from extension to app
- Real speech-to-text drafts from Phase 5's PikoTranscribe
- C4 memory ceiling measurement

---

## Independent Test Verification

Tests re-run by verifier (not trusting executor self-reports):

| Command | Executor Claim | Verifier Result | Match |
|---------|----------------|-----------------|-------|
| `swift build` | succeeded | ✓ Build complete! (0.09s) | ✓ |
| `swift test` (macOS) | 25 pass / 2 fail | 25 pass / 2 fail (same pre-existing PikoBridge App Group failures) | ✓ |
| `xcodebuild test -scheme Piko-Package` (iOS Simulator) | 38/38 pass | 38/38 pass (TEST SUCCEEDED) | ✓ |
| PikoKeyboardTests count | 12 tests | 12 tests (4 mic + 7 insertion + 1 integration) | ✓ |

---

_Verified: 2026-08-29T16:22:00Z_
_Verifier: Claude (gsd-verifier)_
