# Phase 4: Keyboard Extension & Streaming Insertion - Research

**Researched:** 2026-08-29
**Domain:** iOS Keyboard Extension, Cross-Process IPC, Streaming Text Insertion
**Confidence:** HIGH

## Summary

Phase 4 implements the keyboard extension's role as a **remote control** and **text sink** for the armed session. The extension cannot capture audio (CONSTRAINT C1) or run inference (CONSTRAINT C4), so it delegates both to the container app via the SessionChannel established in Phase 2.

The core challenge is **streaming text insertion without flicker**. When partial transcripts arrive every 100-300ms, naïve replacement would make text jump visibly. The `stablePrefix` field in `CaptureDraft` marks how many leading characters are "frozen" — the keyboard only deletes and rewrites characters after that index, producing smooth text flow.

**Primary recommendation:** Use `UITextDocumentProxy.setMarkedText(_:selectedRange:)` for the unstable tail during streaming, then commit with `insertText(_:)` when `CaptureResult` arrives. Track insertion state locally in the extension to diff correctly.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Microphone capture | Container App | — | C1 blocks extension mic access |
| Speech recognition | Container App | — | C4 memory ceiling prohibits models |
| Session lifecycle (arm/disarm) | Container App | Keyboard (trigger) | Keyboard sends signal, app owns AVAudioSession |
| Streaming draft delivery | Container App (write) | Keyboard (read) | App writes to App Group, keyboard polls/observes |
| Text insertion | Keyboard | — | Only the keyboard has UITextDocumentProxy access |
| UI (mic button, waveform) | Keyboard | PikoUI | PikoUI provides shared components |
| Profile selection | Keyboard | — | C7 prevents host-app detection; user picks profile |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| UIKit | iOS 26 | `UIInputViewController`, `UITextDocumentProxy` | Apple's keyboard extension API [CITED: developer.apple.com/documentation/uikit/uiinputviewcontroller] |
| PikoKit | local | `CaptureDraft`, `SessionState`, `Signal` | Project's cross-process contracts |
| PikoBridge | local | `DarwinChannel` | Darwin notification + App Group IPC |
| PikoUI | local | Shared button styles, colors | Keyboard can import PikoUI per project.yml |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| SwiftUI | iOS 26 | Declarative keyboard layout | For `inputView` composition via `UIHostingController` |
| Combine | iOS 26 | Signal debouncing | If draft updates arrive faster than useful |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| setMarkedText | deleteBackward loop | marked text is cleaner for in-flight composition; delete loop risks race with host app |
| Local sequence tracking | Just sessionEpoch check | sequence gives finer ordering within a session |

**Installation:**
```bash
# No external packages — all dependencies are local Swift packages
swift build
```

## Package Legitimacy Audit

> No external packages. All dependencies are local Swift packages within the Piko monorepo.

| Package | Registry | Age | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|-----|-----------|-------------|-----------|-------------|
| PikoKit | local | — | — | /Users/sunny/Projects/piko | N/A | Approved |
| PikoBridge | local | — | — | /Users/sunny/Projects/piko | N/A | Approved |
| PikoUI | local | — | — | /Users/sunny/Projects/piko | N/A | Approved |

## Architecture Patterns

### System Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              HOST APP (any app)                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        Text Field                                    │   │
│  └──────────────────────────────▲───────────────────────────────────────┘   │
│                                 │ UITextDocumentProxy                       │
│                                 │  - insertText(_:)                         │
│                                 │  - setMarkedText(_:selectedRange:)        │
│                                 │  - deleteBackward()                       │
└─────────────────────────────────┼───────────────────────────────────────────┘

┌─────────────────────────────────┼───────────────────────────────────────────┐
│  KEYBOARD EXTENSION PROCESS     │                                           │
│                                 │                                           │
│  ┌──────────────────────────────┴───────────────────────────────────────┐   │
│  │            KeyboardViewController : UIInputViewController             │   │
│  │                                                                       │   │
│  │   ┌─────────────────────┐       ┌────────────────────────────────┐   │   │
│  │   │  Mic Button         │──────▶│ post(.captureStart)            │   │   │
│  │   │  (tap to capture)   │       │ post(.captureStop)             │   │   │
│  │   └─────────────────────┘       └────────────────────────────────┘   │   │
│  │                                                                       │   │
│  │   ┌─────────────────────────────────────────────────────────────┐   │   │
│  │   │  TextInsertionController                                     │   │   │
│  │   │    - lastAppliedDraft: CaptureDraft?                         │   │   │
│  │   │    - insertedCount: Int (chars we put in the field)          │   │   │
│  │   │    - applyDraft(_:) → diff against lastApplied               │   │   │
│  │   │    - applyResult(_:) → commit final text                     │   │   │
│  │   └─────────────────────────────────────────────────────────────┘   │   │
│  └───────────────────────────────────────────────────────────────────────┘   │
│                                 │                                           │
│               DarwinChannel     │                                           │
│              ┌──────────────────┴─────────────────┐                         │
│              │  signals: AsyncStream<Signal>      │                         │
│              │  readState() → SessionState?       │                         │
│              │  readDraft() → CaptureDraft?       │                         │
│              │  readResult() → CaptureResult?     │                         │
│              │  post(_ signal: Signal)            │                         │
│              └──────────────────┬─────────────────┘                         │
└─────────────────────────────────┼───────────────────────────────────────────┘
                                  │
            Darwin Notifications  │  App Group Files
            (doorbell only)       │  (payload)
                                  │
┌─────────────────────────────────┼───────────────────────────────────────────┐
│  CONTAINER APP PROCESS          │                                           │
│              ┌──────────────────┴─────────────────┐                         │
│              │  DarwinChannel                     │                         │
│              │  writeState(_:), writeDraft(_:)    │                         │
│              │  writeResult(_:)                   │                         │
│              └──────────────────┬─────────────────┘                         │
│                                 │                                           │
│              ┌──────────────────┴─────────────────┐                         │
│              │  SessionCoordinator                │                         │
│              │  arm(), disarm()                   │                         │
│              │  startCapture(), stopCapture()     │                         │
│              │  heartbeat every 2s                │                         │
│              └────────────────────────────────────┘                         │
│                                 │                                           │
│              ┌──────────────────┴─────────────────┐                         │
│              │  Transcriber (future phase)        │                         │
│              │  → CaptureDraft with stablePrefix  │                         │
│              └────────────────────────────────────┘                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure
```
App/PikoKeyboard/
├── KeyboardViewController.swift    # UIInputViewController subclass
├── TextInsertionController.swift   # Owns draft diffing and text proxy calls
├── KeyboardView.swift              # SwiftUI root view (mic button, profile chips)
├── MicButton.swift                 # Tap to arm/capture, long-press for profile
├── WaveformView.swift              # Visual feedback during capture
├── Info.plist                      # RequestsOpenAccess: true
└── PikoKeyboard.entitlements       # App Group
```

### Pattern 1: stablePrefix-Based Streaming Insertion

**What:** Rewrite only the unstable tail of the transcript, preserving committed text.

**When to use:** Every time a new `CaptureDraft` arrives from the container app.

**Example:**
```swift
// Source: docs/SPEC.md, verified against UITextDocumentProxy docs
final class TextInsertionController {
    private let proxy: UITextDocumentProxy
    private var lastApplied: CaptureDraft?
    private var insertedChars = 0  // how many chars we've put in the field

    func apply(_ draft: CaptureDraft) {
        guard draft.isNewer(than: lastApplied) else { return }
        
        let oldStable = lastApplied?.stablePrefix ?? 0
        let newStable = draft.stablePrefix
        let newText = draft.text
        
        // Case 1: First draft of session or new session epoch
        if lastApplied == nil || draft.sessionEpoch != lastApplied?.sessionEpoch {
            // Start fresh — use marked text for the whole thing
            proxy.setMarkedText(newText, selectedRange: NSRange(location: newStable, length: newText.count - newStable))
            insertedChars = newText.count
        } else {
            // Case 2: Continuing same session
            let oldText = lastApplied?.text ?? ""
            let charsToDelete = insertedChars - newStable
            
            // Delete unstable chars we previously inserted
            if charsToDelete > 0 {
                for _ in 0..<charsToDelete {
                    proxy.deleteBackward()
                }
            }
            
            // Insert new chars from stablePrefix onward
            let tail = String(newText.dropFirst(newStable))
            if !tail.isEmpty {
                // Mark the truly unstable portion (beyond what transcriber is confident about)
                let markedStart = max(0, newStable - oldStable)
                proxy.setMarkedText(tail, selectedRange: NSRange(location: markedStart, length: tail.count - markedStart))
            }
            
            insertedChars = newText.count
        }
        
        lastApplied = draft
    }

    func commit(_ result: CaptureResult) {
        // Replace whatever we have with the final text
        proxy.unmarkText()
        // The final shipped text is authoritative
        // Clear everything we inserted and put in result.shipped
        clearInserted()
        proxy.insertText(result.shipped)
        insertedChars = result.shipped.count
        lastApplied = nil
    }

    private func clearInserted() {
        for _ in 0..<insertedChars {
            proxy.deleteBackward()
        }
        insertedChars = 0
    }
}
```

### Pattern 2: Signal-Driven Session Control

**What:** Keyboard sends signals to arm/disarm; listens for state updates.

**When to use:** Mic button tap, session state observation.

**Example:**
```swift
// Source: existing KeyboardViewController.swift pattern
final class KeyboardViewController: UIInputViewController {
    private var channel: DarwinChannel?
    private var sessionState: SessionState?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        channel = DarwinChannel()
        Task { await observeSession() }
    }
    
    private func observeSession() async {
        guard let channel else { return }
        for await signal in channel.signals {
            switch signal {
            case .stateChanged:
                sessionState = channel.readState()
                updateUI()
            case .draftUpdated:
                if let draft = channel.readDraft() {
                    textController.apply(draft)
                }
            case .resultReady:
                if let result = channel.readResult() {
                    textController.commit(result)
                }
            default:
                break
            }
        }
    }
    
    // User taps mic button
    func micButtonTapped() {
        guard let state = sessionState, state.isLive() else {
            // App not armed — show "open Piko app" prompt
            return
        }
        
        switch state.phase {
        case .armed:
            channel?.post(.captureStart)
        case .capturing:
            channel?.post(.captureStop)
        default:
            break
        }
    }
}
```

### Pattern 3: SwiftUI Keyboard Layout

**What:** Build the keyboard UI in SwiftUI, embed via UIHostingController.

**When to use:** Creating the inputView for the keyboard.

**Example:**
```swift
// Source: Apple UIInputViewController documentation
final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let rootView = KeyboardView(
            onMicTap: { [weak self] in self?.micButtonTapped() },
            onProfileSelect: { [weak self] profile in self?.selectProfile(profile) },
            onGlobePress: { [weak self] in self?.advanceToNextInputMode() }
        )
        
        let hosting = UIHostingController(rootView: rootView)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        inputView?.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: inputView!.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: inputView!.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: inputView!.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: inputView!.bottomAnchor)
        ])
        
        hostingController = hosting
    }
}

struct KeyboardView: View {
    let onMicTap: () -> Void
    let onProfileSelect: (Profile) -> Void
    let onGlobePress: () -> Void
    
    @State private var sessionPhase: SessionPhase = .idle
    
    var body: some View {
        VStack(spacing: 8) {
            // Profile chips row
            HStack {
                ForEach(Profile.allCases, id: \.self) { profile in
                    ProfileChip(profile: profile, onSelect: { onProfileSelect(profile) })
                }
                Spacer()
                GlobeButton(action: onGlobePress)
            }
            .padding(.horizontal)
            
            // Main mic button
            MicButton(phase: sessionPhase, action: onMicTap)
                .frame(height: 80)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}
```

### Anti-Patterns to Avoid
- **Batching deleteBackward calls:** Each call is a separate text change event. Do not loop 50 times — batch by calculating the exact count and using adjustTextPosition where possible.
- **Ignoring sessionEpoch:** A new session's sequence=0 draft must override an old session's sequence=999 draft. Always compare sessionEpoch first (already implemented in `CaptureDraft.isNewer`).
- **Polling instead of observing:** The keyboard receives Darwin notifications via `signals` stream. Don't add a Timer to poll the files — observe the stream.
- **Putting inference in the extension:** The 60MB jetsam limit is real and silent. No Whisper, no Core ML, no LLM.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Cross-process IPC | Custom XPC service | DarwinChannel (already built) | Darwin notifications + App Group files is the standard for keyboard ↔ app communication |
| Text diffing | Character-by-character diff | stablePrefix comparison | stablePrefix is computed by the transcriber; the keyboard just trusts it |
| Keyboard globe button | Custom input switcher | `advanceToNextInputMode()` | System API handles this correctly [CITED: developer.apple.com/documentation/uikit/uiinputviewcontroller/advancetonextinputmode()] |
| Audio click feedback | AVAudioPlayer | `UIDevice.current.playInputClick()` | Requires UIInputViewAudioFeedback conformance [CITED: developer.apple.com/documentation/uikit/uiinputviewaudiofeedback] |

**Key insight:** The keyboard extension's only jobs are (1) show UI, (2) relay button presses to the app, (3) insert text that arrives from the app. Everything else is either impossible (mic, inference) or already handled (IPC via DarwinChannel).

## Common Pitfalls

### Pitfall 1: Text Thrash on Rapid Draft Updates
**What goes wrong:** Each draft triggers a full delete/reinsert cycle, causing visible flicker.
**Why it happens:** Ignoring stablePrefix and always replacing the entire text.
**How to avoid:** Only rewrite characters after stablePrefix. Use setMarkedText for in-flight composition.
**Warning signs:** User sees text "jump" or flicker during dictation.

### Pitfall 2: Full Access Not Granted
**What goes wrong:** Keyboard can read App Group files but not write; signals work but state updates fail silently.
**Why it happens:** User hasn't enabled "Allow Full Access" in Settings → Keyboards → Piko.
**How to avoid:** Check `hasFullAccess` on viewDidLoad; show onboarding prompt if false.
**Warning signs:** Mic button taps do nothing; `channel?.post(...)` has no effect on app.

### Pitfall 3: Session Epoch Rollover
**What goes wrong:** A stale draft from a previous session overrides a new session's drafts.
**Why it happens:** Comparing only `sequence` without checking `sessionEpoch`.
**How to avoid:** Already handled — `CaptureDraft.isNewer(than:)` compares epoch first.
**Warning signs:** Keyboard shows old text after the user started a new capture.

### Pitfall 4: Memory Pressure Jetsam
**What goes wrong:** Keyboard is killed silently mid-operation with no crash log.
**Why it happens:** Extension exceeds ~60MB memory limit (CONSTRAINT C4).
**How to avoid:** Never hold audio buffers, model weights, or large data structures. Profile with Instruments under memory pressure.
**Warning signs:** Keyboard disappears unexpectedly; cannot reproduce crash in debugger.

### Pitfall 5: Secure Text Fields
**What goes wrong:** Keyboard doesn't appear in password or credit card fields.
**Why it happens:** iOS excludes third-party keyboards from secure text input types (CONSTRAINT C8).
**How to avoid:** This is expected behavior — document it, don't fight it.
**Warning signs:** User reports "Piko doesn't work in my bank app."

### Pitfall 6: Heartbeat Staleness
**What goes wrong:** Keyboard shows "tap mic" but the app has already deactivated the session.
**Why it happens:** App backgrounded or killed without disarming; heartbeat goes stale.
**How to avoid:** Check `SessionState.isLive(tolerance: 5)` before showing active state UI.
**Warning signs:** User taps mic, nothing happens, app shows `.idle`.

## Code Examples

Verified patterns from official sources:

### Insert Text via UITextDocumentProxy
```swift
// Source: developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards
textDocumentProxy.insertText("Hello world.")
```

### Delete Backward
```swift
// Source: developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards
textDocumentProxy.deleteBackward()
```

### Marked Text for In-Progress Composition
```swift
// Source: developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards
let text = "speaking..."
let range = NSRange(location: 0, length: text.count)  // entire text is "unstable"
textDocumentProxy.setMarkedText(text, selectedRange: range)

// Later, commit the final text:
textDocumentProxy.unmarkText()
textDocumentProxy.insertText("final transcription")
```

### Check Full Access
```swift
// Source: developer.apple.com/documentation/uikit/uiinputviewcontroller/hasfullaccess
if hasFullAccess {
    // Can write to App Group, full functionality
} else {
    // Show prompt to enable Full Access in Settings
}
```

### Globe Button (Switch Keyboards)
```swift
// Source: developer.apple.com/documentation/uikit/uiinputviewcontroller/advancetonextinputmode()
@objc func globeButtonTapped() {
    advanceToNextInputMode()
}
```

### Context Before/After Insertion Point
```swift
// Source: developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards
let precedingText = textDocumentProxy.documentContextBeforeInput ?? ""
let followingText = textDocumentProxy.documentContextAfterInput ?? ""
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Request each property separately | Check hasFullAccess once | iOS 11 | Simpler permission flow |
| UITextInput delegate | UITextInputDelegate on UIInputViewController | iOS 8+ | Automatic conformance |
| Manual keyboard height | inputView intrinsicContentSize | iOS 8+ | System handles SafeArea |

**Deprecated/outdated:**
- `UITextInputMode` dictionary lookups: use `documentInputMode` property instead
- Explicit keyboard height constraints: let system handle via intrinsicContentSize

## Open Questions

1. **Marked text visual styling**
   - What we know: setMarkedText uses a system-provided underline style
   - What's unclear: Can we customize the marked text appearance? Piko's brand may want a different visual treatment
   - Recommendation: Accept system default for v0.1; investigate in a future polish phase

2. **Deletion performance on long transcripts**
   - What we know: deleteBackward is per-character
   - What's unclear: At 1000+ characters, is a batch clear faster via select-all + delete?
   - Recommendation: Start with the simple loop; profile if users report lag

3. **Cancellation UX**
   - What we know: User can tap mic to stop capture
   - What's unclear: What if the user dismisses the keyboard mid-capture? Does the app receive a signal?
   - Recommendation: App should timeout if no captureStop arrives and heartbeat stops

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode 26.3+ | Build | ✓ (user responsibility) | — | — |
| iOS 26 Simulator | Testing | ✓ | — | Physical device |
| Physical device | Full integration test | User has | — | Simulator for unit tests |

**Missing dependencies with no fallback:** None — all dependencies are local Swift packages.

## Validation Architecture

> Required per workflow.nyquist_validation: true

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (iOS 26+) |
| Config file | Package.swift testTarget |
| Quick run command | `swift test --filter PikoKeyboardTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BRDG-01 | Keyboard mic tap triggers captureStart signal | unit | `swift test --filter testMicButtonTriggersSignal` | ❌ Wave 0 |
| CAPT-01 | Draft applies only when newer | unit | `swift test --filter testDraftOrderingByEpochAndSequence` | ❌ Wave 0 |
| CAPT-02 | stablePrefix prevents thrash | unit | `swift test --filter testStablePrefixDiffing` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --filter <relevant_test>`
- **Per wave merge:** `swift test`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `Tests/PikoKeyboardTests/TextInsertionControllerTests.swift` — covers CAPT-01, CAPT-02
- [ ] `Tests/PikoKeyboardTests/KeyboardViewControllerTests.swift` — covers BRDG-01
- [ ] Mock `UITextDocumentProxy` for testing text insertion logic

## Security Domain

> Required per security_enforcement: true

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | N/A — keyboard has no auth |
| V3 Session Management | no | N/A — no user sessions in extension |
| V4 Access Control | yes (limited) | App Group entitlement + Full Access |
| V5 Input Validation | yes | Draft/Result JSON decoding via Codable |
| V6 Cryptography | no | No secrets in keyboard |

### Known Threat Patterns for Keyboard Extensions

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malicious app spoofing SessionState | Spoofing | sessionEpoch prevents replay; heartbeat validates liveness |
| Race condition on draft file | Tampering | Atomic writes in DarwinChannel; isNewer() ordering |
| Keystroke logging by keyboard | Information Disclosure | Piko does NOT log keystrokes; only inserts from app |

**Piko-specific note:** Unlike general third-party keyboards, Piko does NOT capture user keystrokes from the host app. It only inserts text received from the container app. The privacy model is: audio stays on device, transcription stays on device, inserted text is visible to the user.

## Sources

### Primary (HIGH confidence)
- [CITED: developer.apple.com/documentation/uikit/uiinputviewcontroller] — UIInputViewController class reference
- [CITED: developer.apple.com/documentation/uikit/uitextdocumentproxy] — UITextDocumentProxy protocol reference
- [CITED: developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards] — Text insertion patterns
- [CITED: developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard] — Full Access requirements

### Secondary (MEDIUM confidence)
- [CITED: docs/SPEC.md] — Project specification for stablePrefix contract
- [CITED: docs/CONSTRAINTS.md] — iOS platform constraints C1-C10

### Tertiary (LOW confidence)
- None — all claims verified against official docs or project specs

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Apple's UIKit APIs, no external dependencies
- Architecture: HIGH — Pattern follows Apple's extension architecture + project's existing IPC
- Pitfalls: HIGH — Documented from Apple forums and project CONSTRAINTS.md

**Research date:** 2026-08-29
**Valid until:** 2027-02-28 (6 months — UIKit keyboard APIs are stable)
