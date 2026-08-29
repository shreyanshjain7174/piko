# Phase 3: Armed Session - Research

**Researched:** 2026-08-29
**Domain:** AVAudioSession/AVAudioEngine lifecycle, iOS audio interruption recovery, App Intents as
the real mechanism behind Back Tap/Action Button, cross-process state modeling, Swift 6.2 strict
concurrency
**Confidence:** HIGH (AVAudioSession interruption mechanism, App Intents/Back Tap/Action Button
integration point, existing PikoKit/PikoBridge fit), MEDIUM (the `openAppWhenRun` foregrounding
requirement for C2 compliance — reasoned from sourced CONSTRAINTS.md, not yet device-verified),
LOW (exact AVAudioSession category/option constants to use — flagged for implementation-time
`apple-docs` MCP lookup, not guessed here)

## Summary

This phase's goal is **narrower than "build PikoAudio from scratch" and wider than "just wire up
AVAudioSession"**. Three things are true simultaneously:

1. **The `ArmedSession` protocol already exists and already matches the roadmap's plan hints
   exactly** `[VERIFIED: read Sources/PikoAudio/ArmedSession.swift this session]` — `arm()`,
   `disarm()`, `startCapture()`, `stopCapture()`, `phase: AsyncStream<SessionPhase>`, plus a
   `TODO(spike 2)` comment that already names every interruption type SESS-04 lists. No new
   protocol is needed; this phase writes the first real implementation.
2. **SESS-02 and SESS-03 are not audio-engine problems — they are App Intents problems, and they
   carry a real, sourced legal-activation gap.** Back Tap and the Action Button do not have a
   direct third-party API. Both route through the same mechanism: a user configures Settings to
   run a Shortcut (which can invoke an app's `AppIntent`) on that trigger. Apple's own
   documentation confirms this for the Action Button explicitly (`[CITED:
   developer.apple.com/documentation/appintents/hardware-interactions, fetched this session]` —
   "This button is configurable in Settings, so people can assign any App Shortcuts you create").
   Back Tap works the same way via Settings → Accessibility → Touch → Back Tap, which lists any
   Shortcut the user has created `[ASSUMED — consistent with public Apple documentation and this
   project's own CONSTRAINTS.md/ROADMAP.md framing, but the specific support-article page did not
   load this session; verify the exact picker behavior on device before treating as settled]`.
   **The non-obvious part:** `docs/CONSTRAINTS.md` C2 states only CallKit, LiveCommunicationKit
   and PushToTalk may activate a recording session from the background — App Intents are not on
   that exception list, and a Bluetooth/hardware trigger "buys no exception" per the same row.
   This means an `AppIntent` invoked from Back Tap or the Action Button almost certainly cannot
   call `AVAudioSession.setActive(true)` while `openAppWhenRun` is `false` (the default) — the
   intent must set `openAppWhenRun = true`, which briefly, visibly foregrounds Piko before
   `perform()` runs, satisfying C2 the same way tapping the app icon does. This is the single
   most consequential finding in this research and is flagged `[ASSUMED — grounded in sourced
   CONSTRAINTS.md C2/C5, not yet device-verified; treat as this phase's first spike, not a given]`.
3. **The five SESS-04 interruption sources collapse into three real API surfaces, not five
   independent code paths.** Phone-call interruption and "another app taking the session" are the
   *same* notification (`AVAudioSession.interruptionNotification`, type `.began`) — iOS does not
   tell you which caused it. Route change is a second, separate notification. Low power mode is a
   third, unrelated mechanism (`ProcessInfo`). Process kill is not a notification at all — nothing
   can intercept `SIGKILL`; "recovery" is entirely a next-launch/next-read affordance that **Phase
   1 already built** (`SessionState.isLive(now:tolerance:)`, already tested). This phase's real
   job for process kill is narrower than it sounds: make sure `arm()` writes state/heartbeat
   correctly and make sure something (this phase's UI, or App/Piko generally) checks `isLive()` on
   next foreground and shows the re-arm affordance — most of the hard part is already done.

**Primary recommendation:** Build a concrete `SessionCoordinator` (implementing `ArmedSession`)
**inside `PikoAudio`**, constructed with two protocol-typed dependencies injected at the
composition root (`App/Piko`): `any SessionChannel` (from `PikoKit` — no `PikoBridge` import
needed inside `PikoAudio` itself, preserving the module graph in `docs/ARCHITECTURE.md`) and a new
small `InterruptionSource` protocol (also `PikoAudio`-local) that translates real
`AVAudioSession`/`ProcessInfo` notifications into a closed enum of events. Tests construct the
coordinator with `MockSessionChannel` and `MockInterruptionSource` — fully deterministic, no
device, no App Group container, no real audio hardware, closing exactly the environment
limitation Phase 2 hit. See Architecture Patterns below for the concrete shape.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SESS-01 | User can arm a session from the container app | Foreground button call to `arm()` — the only unconditionally legal path (C2); no new mechanism needed, just the concrete `AVAudioEngine`/`AVAudioSession` implementation |
| SESS-02 | User can arm a session via Back Tap | Requires an `AppIntent` the user binds to Back Tap via Settings → Accessibility → Touch; **not** a raw Back Tap API. Likely requires `openAppWhenRun = true` per the C2 finding above — needs a device spike, not just code |
| SESS-03 | User can arm a session via the Action Button | Same mechanism as SESS-02 — an `AppIntent`/App Shortcut the user assigns to the Action Button via Settings, confirmed by Apple's own "Hardware interactions" doc. Same `openAppWhenRun` requirement applies |
| SESS-04 | Recovers from call/route-change/other-app/low-power/kill, re-arm prompt within 1s | Three real API surfaces (`interruptionNotification`, `routeChangeNotification`, `ProcessInfo` low-power), plus the pre-existing `isLive()` staleness check for process kill. Testable via an injectable `InterruptionSource` — see Testability section |
| SESS-05 | Survives 45 minutes of ordinary phone use | Manual-only. `docs/SPIKES.md` Spike 2 already exists for this exact scenario, currently "not run". No automated test should claim to cover this — flagged explicitly below |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Microphone/audio session ownership | PikoAudio (container app process only) | — | C1/C4 — only the container app process may touch audio; the keyboard extension never does |
| Arm/disarm/capture state machine | PikoAudio (`SessionCoordinator`) | PikoKit (`SessionPhase`/`SessionState` shape) | The FSM logic and its transitions are PikoAudio's job; the shared vocabulary those transitions produce is PikoKit's, per the existing Phase 1/2 pattern |
| Publishing state cross-process | App/Piko composition root (wires `SessionCoordinator` to a real `DarwinChannel`) | PikoBridge (transport, already built) | Keeps `PikoAudio`'s `Package.swift` dependency on `PikoKit` only (protocol-typed injection) — matches `docs/ARCHITECTURE.md`'s module graph, where `PikoAudio` and `PikoBridge` are siblings, not dependents |
| Back Tap / Action Button trigger surface | App/Piko target (`AppIntent` + `AppShortcutsProvider`) | System (Settings, Shortcuts app) | No PikoAudio-owned code is involved in "being triggerable" — the intent is UI/system-integration glue that calls into `arm()` |
| Interruption detection (call, route, other-app, low-power) | PikoAudio (`InterruptionSource` abstraction) | — | Same reasoning as the FSM itself — this is exactly the seam that needs to be mockable for SESS-04's testability requirement |
| Process-kill recovery detection | PikoKit (`SessionState.isLive`, already built in Phase 1) | App/Piko UI (reads it on next launch/foreground) | Nothing can recover a killed process; the "recovery" is a read-time staleness check that already exists and is already tested |
| 45-minute soak validation | Human, on physical device | `docs/SPIKES.md` Spike 2 | Explicitly out of scope for CI per the phase's own Success Criteria #3 ("in manual testing") |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `AVFAudio` (`AVAudioSession`, `AVAudioEngine`) | ships with the OS, iOS 26 target | Owns the microphone, category/route/interruption management | The only sanctioned mechanism for foreground-activated, background-continuing audio (C2/C3); no alternative exists for this product shape |
| `AppIntents` | ships with the OS, iOS 16+ (this project targets iOS 26) | Exposes "arm a session" to Back Tap, Action Button, Siri, Shortcuts | Confirmed as the actual mechanism behind both Back Tap and Action Button `[CITED: developer.apple.com/documentation/appintents/hardware-interactions]` — there is no other public entry point for a third-party app into either trigger |
| Foundation `ProcessInfo` (`isLowPowerModeEnabled`, power-state-change notification) | ships with the OS | Low power mode detection | Standard, stable API for this signal; has existed since iOS 9 |
| Swift Testing | ships with Xcode 26 / Swift 6.2 | Unit tests for the FSM, `PikoAudioTests` (new target) | Matches the pattern `PikoKitTests`/`PikoBridgeTests` already established |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `Combine` or plain `NotificationCenter` async sequences | ships with the OS | Bridging `NotificationCenter` posts into the `InterruptionSource`'s `AsyncStream` | Either works; `NotificationCenter.default.notifications(named:)` (an `AsyncSequence`, iOS 15+) is the more modern, Concurrency-native choice and avoids a Combine dependency for a single-purpose bridge |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| A dedicated `AppIntent` calling `arm()` for Back Tap/Action Button | A Shortcuts "Open App" action alone (no custom intent) | Simply opening the app via Back Tap/Action Button is a real, zero-code fallback that trivially satisfies C2 (a real foreground launch) but gives up any chance of "arm without touching the screen" — worth naming to the user as option 1 of "what would this look like if the obvious approach were forbidden", per the working agreement, since it may be the pragmatic v0.1 answer if the `openAppWhenRun` spike below fails |
| `AVAudioSession` category `.playAndRecord` with Bluetooth options | Plain `.record` category | `.playAndRecord` is very likely correct for supporting AirPods route changes mid-session (Spike 2's own scenario list), but the exact category/option constants (`.allowBluetoothHFP` vs. the older, now-partially-deprecated `.allowBluetooth`) should be confirmed via `apple-docs` MCP at implementation time — not guessed here, per this project's own working agreement item #2. Flagged as `[LOW confidence]`, not asserted as fact |
| `NotificationCenter.default.publisher` (Combine) | `NotificationCenter.default.notifications(named:)` (async sequence, iOS 15+) | The async-sequence form fits this project's `async`/`await`-first style guide (`CLAUDE.md` "Style" section) better than introducing Combine for one bridge type |

## Package Legitimacy Audit

Not applicable — every dependency this phase needs (`AVFAudio`, `AppIntents`, `Foundation`) ships
with the OS. Zero external packages are added.

## Architecture Patterns

### System Architecture Diagram

```
                         APP/PIKO (composition root — the only place these three meet)
                         ────────────────────────────────────────────────────────────
  Back Tap / Action Button                    SESS-01: in-app "Arm" button tap
  (Settings → Shortcuts)                                    │
        │                                                    ▼
        ▼                                        SessionCoordinator.arm() ── throws PikoError.notForeground
  ArmSessionIntent: AppIntent                               │                   if called off the main/foreground path
   openAppWhenRun = true  ◀── C2: no background-audio            (implements ArmedSession, lives in PikoAudio)
   (briefly foregrounds Piko,                                     │
    same as an icon tap — this                    ┌──────────────┼───────────────────┐
    is what makes SESS-02/03 legal)                ▼              ▼                    ▼
        │                                  AVAudioSession   InterruptionSource    heartbeat Task
        └──────────────► arm() ────────►   .setActive(true)  observes:              (every ~2s
                                            category:          .interruptionNotification  while armed)
                                            .playAndRecord      .routeChangeNotification
                                                                ProcessInfo power-state
                                                                    │
                                                    each event ──► SessionCoordinator's
                                                                   internal state machine
                                                                       │
                                                          phase → .idle (never crashes)
                                                                       │
                                                                       ▼
                                              writeState(SessionState(phase:.idle, heartbeat:.now, ...))
                                                          via injected `any SessionChannel`
                                                     (a real DarwinChannel, only at this composition point)
                                                                       │
                                                                       ▼
                                    KEYBOARD (Phase 2, already built): isLive()==false ⟶ "tap to arm"
                                    APP/PIKO UI (this phase, small addition): show a re-arm banner
                                                                       │
                                    PROCESS KILL — no notification exists. Recovery is entirely:
                                    next launch/foreground reads SessionState.heartbeat, finds it
                                    stale (Phase 1's isLive(), already tested), shows the same
                                    re-arm affordance. Nothing to "catch" — nothing is running.
```

A reader can trace: every legal path into `arm()` funnels through the same foreground-privileged
call; every interruption funnels through the same state machine; every recovery funnels through
the same `isLive()`-driven re-arm affordance already established in Phase 1/2 — this phase adds
exactly one new concept (`InterruptionSource`), not five.

### Recommended Project Structure
```
Sources/PikoAudio/
├── ArmedSession.swift          # existing protocol — no changes needed
├── SessionCoordinator.swift    # NEW — concrete ArmedSession, owns AVAudioEngine/AVAudioSession
├── InterruptionSource.swift    # NEW — protocol + AVAudioSessionInterruptionSource (real) impl
└── HeartbeatTimer.swift        # NEW (or inlined) — periodic SessionState refresh while armed

Tests/PikoAudioTests/           # NEW test target
├── MockSessionChannel.swift        # conforms to PikoKit.SessionChannel, in-memory
├── MockInterruptionSource.swift    # conforms to InterruptionSource, test-driven AsyncStream
├── SessionCoordinatorArmingTests.swift      # SESS-01 state transitions
└── SessionCoordinatorInterruptionTests.swift # SESS-04, one test per interruption type

App/Piko/
└── ArmSessionIntent.swift      # NEW — AppIntent, openAppWhenRun = true, calls session.arm()
```

### Pattern 1: Protocol-injected dependencies keep `PikoAudio`'s compile graph unchanged
**What:** `SessionCoordinator`'s initializer takes `channel: any SessionChannel` (a `PikoKit`
type) rather than `PikoAudio` importing `PikoBridge` directly. `Package.swift`'s
`PikoAudio` target dependency list stays `["PikoKit"]` — no change needed.
**When to use:** Any time a module needs to *use* a cross-module capability but the module
graph (`docs/ARCHITECTURE.md`) says it shouldn't *depend on* the concrete implementer.
**Example:**
```swift
// Sources/PikoAudio/SessionCoordinator.swift
public final class SessionCoordinator: ArmedSession, @unchecked Sendable {
    private let channel: any SessionChannel          // PikoKit protocol, not PikoBridge
    private let interruptions: any InterruptionSource
    // ...
    public init(channel: any SessionChannel, interruptions: any InterruptionSource) {
        self.channel = channel
        self.interruptions = interruptions
    }
}
```
```swift
// App/Piko composition root — the only place PikoBridge and PikoAudio meet
let channel = DarwinChannel()!                       // import PikoBridge lives here only
let coordinator = SessionCoordinator(
    channel: channel,
    interruptions: AVAudioSessionInterruptionSource())
```
`[ASSUMED — this is a design recommendation, not code that exists yet; consistent with the
precedent Phase 2's research set for `KeyboardViewController` already being the app-layer
composition point for `SessionChannel`]`

### Pattern 2: `InterruptionSource` — the testable seam for SESS-04
**What:** A small protocol that turns real, hard-to-mock system notifications into a plain,
injectable event stream.
**When to use:** Exactly this phase's testability requirement — "recovers... within 1 second" is
not a wall-clock UI test, it is a deterministic state-machine assertion given a synthetic event.
```swift
// Sources/PikoAudio/InterruptionSource.swift
public enum InterruptionEvent: Sendable, Equatable {
    case began                                  // call OR another app — indistinguishable at the API level
    case ended(shouldResume: Bool)
    case routeChanged
    case lowPowerModeChanged(enabled: Bool)
}

public protocol InterruptionSource: Sendable {
    var events: AsyncStream<InterruptionEvent> { get }
}

// Production implementation — real AVAudioSession/ProcessInfo notifications
public final class AVAudioSessionInterruptionSource: InterruptionSource, @unchecked Sendable {
    public var events: AsyncStream<InterruptionEvent> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let task = Task {
                for await note in center.notifications(named: AVAudioSession.interruptionNotification) {
                    guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { continue }
                    switch type {
                    case .began: continuation.yield(.began)
                    case .ended:
                        let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                            .contains(.shouldResume)
                        continuation.yield(.ended(shouldResume: shouldResume))
                    @unknown default: continue
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// Test double — no NotificationCenter, no AVAudioSession, no device
public final class MockInterruptionSource: InterruptionSource, Sendable {
    private let continuation: AsyncStream<InterruptionEvent>.Continuation
    public let events: AsyncStream<InterruptionEvent>
    public init() {
        (events, continuation) = AsyncStream.makeStream()
    }
    public func send(_ event: InterruptionEvent) { continuation.yield(event) }
}
```
```swift
// Tests/PikoAudioTests/SessionCoordinatorInterruptionTests.swift
@Test("a began-interruption drops phase to idle without crashing")
func interruptionDropsToIdle() async throws {
    let interruptions = MockInterruptionSource()
    let coordinator = SessionCoordinator(channel: MockSessionChannel(), interruptions: interruptions)
    try await coordinator.arm()
    interruptions.send(.began)
    // Assert via coordinator.phase (AsyncStream) that .idle is yielded — no sleep(), no timeout math.
}
```
**Why this satisfies "within 1 second" honestly:** there is no artificial delay anywhere in this
chain — the production code has no debounce, no timer, no polling. A test that asserts the phase
transition happened *at all*, deterministically, on the first stream element, is a stronger proof
of "near-instant" than any stopwatch-based UI test could be. The literal wall-clock "1 second"
figure remains a device-measured, manually-recorded number for `docs/SPIKES.md` Spike 2 — exactly
the same reasoning Phase 2's research already applied to BRDG-02's 120ms figure.

### Pattern 3: `openAppWhenRun = true` for the arming intent (the C2-driven decision)
**What:** `ArmSessionIntent.openAppWhenRun` must be `true`, not the default `false`.
```swift
// App/Piko/ArmSessionIntent.swift
struct ArmSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Arm Piko"
    static var openAppWhenRun: Bool = true   // required — see CONSTRAINTS C2, no background-audio exception for App Intents
    func perform() async throws -> some IntentResult {
        try await AppComposition.shared.session.arm()
        return .result()
    }
}
```
**When to use:** Any `AppIntent` in this project whose `perform()` needs to call
`AVAudioSession.setActive(true)`. Do not set this to `false` "to make it feel more magical" without
first running the spike below — a background-run intent calling `setActive(true)` will very likely
throw or silently fail per C2, which this project's own constraints doc sources to Apple DTS
guidance that explicitly excludes hardware/Bluetooth-adjacent triggers from any exception.
**Recommended first spike for this phase (not yet in `docs/SPIKES.md`):** confirm on a physical
device whether `openAppWhenRun = true` is in fact required, or whether App Intents have since
gained a narrower "user-initiated, brief foreground grant" exception not documented in
CONSTRAINTS.md's current C2 row. If the current C2 wording is confirmed correct, this spike also
answers the product question of whether Back Tap/Action Button arming is "instant and invisible"
or "a fast flash of the app" — a real UX decision, not just an implementation detail.

### Anti-Patterns to Avoid
- **Do not put a `SessionCoordinator`-equivalent type directly in `App/Piko` app-target code.**
  App-target code is not part of any SPM test target (`swift test` cannot reach it), which would
  make the entire interruption-recovery state machine — this phase's core testable claim — exempt
  from automated testing. Keep the FSM in `PikoAudio` (an SPM module); only the two-line
  composition ("construct these two concrete types, hand them to the coordinator") belongs in
  `App/Piko`.
- **Do not try to distinguish "phone call" from "another app took the session" in code.** Per
  Apple's own documented `AVAudioSessionInterruptionTypeKey`/`.began` mechanism, this information
  is not exposed. Writing a heuristic to guess (e.g. inspecting `CXCallObserver`) is out of scope
  and unnecessary — SESS-04 only requires that *either* source produces the same, correct
  recovery behavior, not that the app can label which one occurred.
- **Do not add `PikoBridge` as a `PikoAudio` package dependency "for convenience."** See Pattern 1
  — the protocol-injection approach avoids this while losing nothing.
- **Do not build a fake "45-minute test" that fast-forwards a clock or mocks battery/thermal
  state to claim SESS-05 coverage.** The requirement is explicitly a manual scenario per
  `docs/SPIKES.md` Spike 2 and the phase's own Success Criteria #3 ("in manual testing"). An
  automated test with a scaled-down duration proves nothing about real background-audio survival
  under real OS memory/thermal pressure — see `docs/WORKING-AGREEMENT.md` item 4.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| "Is a previous session still alive" check | A new staleness heuristic inside `PikoAudio` | `SessionState.isLive(now:tolerance:)` (already built and tested in Phase 1) | Exactly the same rule the keyboard already uses; duplicating it risks the two sides disagreeing on the tolerance window |
| Cross-process state publishing | A second, `PikoAudio`-owned notification/file mechanism | The existing `SessionChannel`/`DarwinChannel` from Phase 2 | Already built, already tested for BRDG-01 through BRDG-04; this phase is a *consumer* of the bridge, not a second implementation of it |
| Distinguishing interruption causes | A `CXCallObserver`-based heuristic to detect "was this a phone call" | Nothing — treat `.began` uniformly | Not exposed by the API `docs/CONSTRAINTS.md`-style sourced fact; building a heuristic adds real complexity for zero requirement benefit (SESS-04 doesn't ask the app to label the cause, only to recover) |
| Foreground-arming trigger surface | A custom Bluetooth/accessibility hook for Back Tap | `AppIntents` + `AppShortcutsProvider`, bound via Settings | There is no other public entry point; Apple's own docs list Shortcuts/Settings assignment as *the* mechanism |

**Key insight:** Every hand-roll risk in this phase is a temptation to build something *around*
an API limitation that is actually a hard OS wall (C1/C2/C7-adjacent) rather than a missing
library. The correct response to each is "recover cleanly," not "find a workaround" — consistent
with this project's own stated architecture philosophy.

## Realistic Wave 0 State

- **`ArmedSession` protocol already exists, unchanged, in `Sources/PikoAudio/ArmedSession.swift`.**
  No `PikoKit` or protocol-shape work needed here — this phase writes the first real conformer.
- **`SessionPhase` (`idle`/`armed`/`capturing`/`tidying`) has no fifth "interrupted/needs re-arm"
  case.** Recommendation: **do not add one.** An interruption should simply drive `phase` back to
  `.idle` and stop heartbeat refresh — the keyboard's existing (`isLive()`-driven) "tap to arm"
  affordance from Phase 2 already *is* the re-arm prompt for that consumer, with zero new
  `SessionPhase` cases needed and zero forward-obligation to Phase 4/7's existing phase-switch
  code. This is the opposite conclusion from Phase 2's `sessionEpoch` addition — there, the shape
  needed to grow; here, the existing shape already covers the requirement. If the planner wants a
  more specific *reason* surfaced in the container app's own UI (e.g. "call ended" vs. "device
  restarted" vs. "low power mode"), that is better modeled as a new, additive, non-breaking field
  on `SessionState` (an optional `lastInterruption: InterruptionReason?` enum, mirroring how
  `CaptureDraft.sessionEpoch` was added additively in Phase 2) — not a breaking change to
  `SessionPhase` itself. Flagging as **the one open design question this research could not fully
  close** — see Open Questions.
- **`Sources/PikoAudio/` has exactly one file today (`ArmedSession.swift`) and zero tests.** A new
  `PikoAudioTests` target must be added to `Package.swift`'s `targets:` array, matching the
  pattern `PikoBridgeTests` already established in Phase 2.
- **`Package.swift`'s `platforms:` array declares both `.iOS(.v26)` and `.macOS(.v15)` for the
  whole package** `[VERIFIED: read Package.swift this session]`. SwiftPM has no per-target
  platform list — every target must compile on every declared platform. `AVAudioSession` does not
  exist on macOS (it is an iOS/tvOS/watchOS-only type within `AVFAudio`); the moment
  `SessionCoordinator.swift` imports it unconditionally, `swift build` will **fail on macOS**,
  breaking the exact "compiles for macOS too" guarantee Phase 1's research established for
  `PikoKit` (which does not apply the same way to `PikoAudio` — `PikoAudio` was always expected to
  hold platform code, per `docs/SPEC.md`'s "Owns the microphone" framing). **This phase's Wave 0
  must wrap all `AVAudioSession`/`AVAudioEngine` code in `#if os(iOS)`** (or `#if
  canImport(AVFAudio) && os(iOS)`), with a macOS-side stub or `#if os(iOS)`-guarded target content
  so `swift build` continues to succeed on both declared platforms — this is a genuine, concrete,
  previously-undocumented build risk, not a hypothetical one.
- **No `App/Piko` source file references `AppIntents` today** `[VERIFIED: grep across `App/`
  this session found no `AppIntent` conformances]`. `ArmSessionIntent` is entirely new work,
  and per the module graph, its natural home is `App/Piko` (the container app target), not a new
  SPM module — App Intents' `perform()` needs access to the live, composed `SessionCoordinator`
  instance, which only exists at the app layer.
- **`ProcessInfo` low-power-mode observation has no existing code anywhere in the repo**
  `[VERIFIED: grep across `Sources/` this session, zero matches for `isLowPowerModeEnabled` or
  `ProcessInfoPowerStateDidChange`]` — this phase is the first to need it.
- **`docs/SPIKES.md` Spike 2 ("armed session survival") already exists, already enumerates
  exactly the SESS-04/SESS-05 manual scenario list this phase needs, and currently reads "not
  run."** No new spike file is needed; Spike 2 is the existing home for this phase's manual
  acceptance record. A second, narrower spike (the `openAppWhenRun` C2 question above) is
  recommended as new content for this file, since it doesn't fit Spike 2's existing shape.

## Testability Approach (per requirement)

### SESS-01 (arm from container app)
Fully automatable. `SessionCoordinator.arm()` called from a synchronous/foreground test context
should transition `phase` to `.armed` (or throw `PikoError.notForeground` if the test simulates a
non-foreground call — the protocol's own doc comment already commits to this contract). No device
needed for the state-machine assertion; the *actual* AVAudioSession activation succeeding is a
device-only concern (Simulator's audio session behavior is not representative of device hardware
per `docs/WORKING-AGREEMENT.md` item 4).

### SESS-02 / SESS-03 (Back Tap / Action Button)
**Largely out of automated-test scope**, and honestly so:
- The `AppIntent`'s `perform()` body (call `arm()`) is a two-line function; there is close to
  nothing to unit test beyond "does it call `arm()`" (trivially true by inspection or a thin
  test with a mock `SessionCoordinator`).
- Whether Back Tap/Action Button *actually* invoke the intent, whether `openAppWhenRun = true`
  actually satisfies C2 on-device, and whether the resulting brief foreground flash is acceptable
  UX are all **manual, on-device, Settings-configuration-dependent checks** — there is no
  Simulator equivalent for Back Tap (it requires the physical accelerometer double-tap gesture)
  and no CI harness for "user configured a Shortcut in Settings." Recommend recording this as a
  new manual checklist item in `docs/SPIKES.md`, not inventing an automated proxy.

### SESS-04 (interruption recovery, "within 1 second")
Automatable as a deterministic state-machine assertion — see Pattern 2 above. One `@Test` per
interruption type (`began`/`ended`/`routeChanged`/`lowPowerModeChanged`), each using
`MockInterruptionSource` to push a synthetic event and asserting the `phase` stream yields `.idle`
(or the appropriate resume behavior for `.ended(shouldResume: true)`) with no crash and no thrown
error escaping the coordinator. The literal "1 second" wall-clock figure is **not** something
`swift test` can certify — it becomes a device-measured entry in `docs/SPIKES.md` Spike 2,
following the identical precedent Phase 2's research set for BRDG-02's 120ms figure. Process kill
specifically needs no new interruption-source code at all: it is proven by a Phase-1-style test
that constructs a `SessionState` with a stale `heartbeat` and asserts `isLive() == false` — already
partially covered by the existing `staleSession` test in `PikoKitTests`; this phase's job is to
make sure App/Piko's launch/foreground path actually calls `isLive()` and reacts to it (a small,
testable, app-layer or `PikoAudio`-layer decision function, not a `SessionCoordinator` concern).

### SESS-05 (45-minute soak)
**No automated test.** This is stated as "manual testing" in the phase's own ROADMAP.md Success
Criteria #3 and matches `docs/SPIKES.md` Spike 2 exactly. Do not build a scaled-down or mocked
substitute and present it as coverage — a 45-second version of this test proves nothing about
memory pressure, thermal throttling, or real background-audio survival under real OS scheduling,
per `docs/WORKING-AGREEMENT.md` item 4's explicit "Simulator/scaled result is not a device result"
principle. The correct artifact from this phase's plan is: Spike 2 gets run, on a physical device,
and its result is recorded — this belongs to `/gsd:verify-work`'s manual checklist, not to
`swift test`.

## Common Pitfalls

### Pitfall 1: Assuming Back Tap/Action Button have a direct third-party API
**What goes wrong:** Time spent searching for a "Back Tap SDK" or "Action Button delegate" that
does not exist; the real integration point (App Intents + Settings-configured Shortcuts) is easy
to miss because it's indirect.
**Why it happens:** The requirement names ("via Back Tap", "via the Action Button") read like they
name an API, when they actually name a *system settings surface* whose only extensibility point is
App Intents.
**How to avoid:** Build one `AppIntent`; the rest is user configuration in Settings, not app code.
**Warning signs:** Any code attempting to register for a `UIAccessibility`-style Back Tap
notification, or a private/undocumented Action Button delegate — neither exists for third-party
apps.

### Pitfall 2: Treating App-Intent-triggered arming as exempt from C2
**What goes wrong:** Setting `openAppWhenRun = false` (the default) and calling
`AVAudioSession.setActive(true)` from `perform()`, which the app's own sourced constraints doc
says has no exception for hardware/Bluetooth-style triggers, risking a silent failure or thrown
error discovered only on-device, late in the phase.
**Why it happens:** It's easy to assume "the user explicitly triggered this" is itself enough of
an exception, since that reasoning *does* apply to `Activity.request()` (C5's documented
exception list explicitly includes "an intent the user fired from a widget, Shortcut or Siri").
C2's exception list is narrower and does not include App Intents.
**How to avoid:** Default to `openAppWhenRun = true` for `ArmSessionIntent`; treat "can this be
`false`" as a spike question, not a starting assumption.
**Warning signs:** `PikoError.notForeground` thrown (or an `AVAudioSession` activation error)
specifically when the intent is invoked via Back Tap/Action Button but not when invoked from the
in-app button.

### Pitfall 3: `AVAudioSession`/`AVAudioEngine` breaking the macOS build target
**What goes wrong:** `swift build` (the check Phase 1's research established as a real,
compiler-enforced guarantee) starts failing on macOS the moment `PikoAudio` unconditionally
imports `AVFAudio` types that don't exist there.
**Why it happens:** `Package.swift`'s `platforms:` array is package-wide, not per-target; nothing
stops a target from importing a platform-specific symbol until the build actually runs for that
platform.
**How to avoid:** `#if os(iOS)` around every `AVAudioSession`/`AVAudioEngine` reference in
`PikoAudio`, verified by actually running `swift build` for the macOS platform as part of this
phase's own verification step (not just iOS).
**Warning signs:** A `swift build` that only ever targets iOS (or is run via Xcode, which only
builds for the scheme's platform) would not catch this — the macOS check must be run explicitly,
the same way Phase 1's plan did.

### Pitfall 4: Building a heuristic to distinguish interruption causes
**What goes wrong:** Time spent trying to tell a phone call apart from "another app took the
session" (e.g. via `CXCallObserver`), when the requirement doesn't ask for that distinction — it
asks for *both* to recover correctly.
**Why it happens:** SESS-04 lists them as separate bullet points, which reads like they need
separate handling.
**How to avoid:** One `.began` case, one recovery path. Test both *scenarios* (a simulated call,
a simulated other-app takeover) against the *same* code path, not two code paths.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `AVFAudio` framework | Real audio session/engine | ✓ (ships with iOS SDK) | iOS 26 SDK | — |
| `AppIntents` framework | SESS-02/SESS-03 | ✓ (ships with iOS SDK) | iOS 26 SDK | — |
| Physical iPhone with a real double-tap sensor + (for Action Button) an iPhone 15 Pro or later | Manual verification of SESS-02/SESS-03 | Not confirmed this session — no device inventory available to this research pass | — | If no Action-Button-equipped hardware is available, SESS-03's manual on-device check cannot run this phase; flag as a blocking gap for the plan's verification step, not something to skip silently |
| Physical device generally (any interruption/route-change/low-power/kill scenario) | SESS-04, SESS-05 manual checks | Not confirmed this session | — | Simulator can exercise the `MockInterruptionSource`-driven unit tests fully; it cannot exercise any of the manual, device-only scenarios per `docs/WORKING-AGREEMENT.md` |

**Missing dependencies with no fallback:** Whether an Action-Button-equipped device (iPhone 15 Pro
or later) is available to this project is unknown from this research pass — the plan's
verification step should confirm this explicitly rather than assume it, since SESS-03's manual
check cannot be satisfied on older hardware or Simulator.

**Missing dependencies with fallback:** None beyond the above — everything else this phase needs
(frameworks, toolchain) already ships with the existing Xcode 26.0.1 install confirmed working in
Phase 1's research.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (bundled with Swift 6.2 toolchain) |
| Config file | none yet — new `PikoAudioTests` target must be added to `Package.swift` |
| Quick run command | `swift test --filter PikoAudioTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SESS-01 | `arm()` transitions phase idle→armed in the foreground; throws `notForeground` otherwise | unit | `swift test --filter PikoAudioTests` | ❌ — Wave 0 |
| SESS-02 | `ArmSessionIntent.perform()` calls `arm()` | unit (trivial) + manual (Back Tap binding) | `swift test --filter PikoAudioTests` (unit slice only) | ❌ — Wave 0 (unit); manual check has no file |
| SESS-03 | Same as SESS-02, Action Button trigger | unit (trivial, shared with SESS-02) + manual | same as above | ❌ — Wave 0 (unit); manual check has no file |
| SESS-04 | Each interruption type drives phase→idle without throwing/crashing | unit | `swift test --filter PikoAudioTests` | ❌ — Wave 0 |
| SESS-04 (process kill sub-case) | Stale `SessionState.heartbeat` ⟹ `isLive() == false` | unit | `swift test --filter PikoKitTests` | ✅ already exists (`staleSession`, Phase 1) |
| SESS-05 | 45-minute soak | manual only | none — `docs/SPIKES.md` Spike 2 | N/A by design |

### Sampling Rate
- **Per task commit:** `swift test --filter PikoAudioTests` (plus `swift test --filter
  PikoKitTests` if `SessionState` gains a new field)
- **Per wave merge:** `swift build && swift build --sdk macosx && swift test` (the macOS build is
  explicitly called out here — see Pitfall 3 — because it is the only mechanism that catches
  platform-leakage before a device build attempt would)
- **Phase gate:** Full `swift test` green, plus the manual Spike 2 record in `docs/SPIKES.md`
  before `/gsd:verify-work` treats SESS-04/SESS-05 as satisfied

### Wave 0 Gaps
- [ ] Add `.testTarget(name: "PikoAudioTests", dependencies: ["PikoAudio", "PikoKit"])` to
      `Package.swift`
- [ ] Write `MockSessionChannel` (conforms to `PikoKit.SessionChannel`, in-memory, no App Group
      container dependency — avoids the exact environment limitation `PikoBridgeTests` hit)
- [ ] Write `MockInterruptionSource` (conforms to the new `InterruptionSource` protocol)
- [ ] Confirm `swift build --sdk macosx` (or equivalent macOS target build) still succeeds once
      `PikoAudio` gains real `AVFAudio` imports — this is the phase's own responsibility to prove,
      not an assumption

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No auth surface — this is a device-local audio/session lifecycle concern |
| V3 Session Management | Marginal | `SessionState`/`SessionPhase` here is an app-lifecycle concept, not a security session; no token or credential involved |
| V4 Access Control | No | Nothing gates access to a protected resource in this phase |
| V5 Input Validation | Marginal | `AVAudioSession` notification `userInfo` dictionaries are OS-supplied, not user/network input, but should still be defensively unwrapped (`guard let`, not force-unwrap) per `CLAUDE.md`'s "No force unwraps outside tests" rule |
| V6 Cryptography | No | Nothing is encrypted or signed in this phase |

### Known Threat Patterns for this phase's stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Force-unwrapping an unexpected/missing `userInfo` key on a malformed or future-OS-version notification payload, crashing the app instead of degrading gracefully | Denial of Service (self-inflicted, not adversarial) | `guard let` + `@unknown default` on every enum switch over `AVAudioSession.InterruptionType`/`RouteChangeReason`, exactly as shown in Pattern 2's code example. This is a real risk given C4/C1-adjacent crash-with-no-log concerns already documented for this project |
| A killed/relaunched process reading a torn/corrupted `SessionState` JSON file (app killed mid-write) | Denial of Service | Already mitigated by Phase 2's atomic write (`.atomic` option) plus `Codable` decode already being a `throws`/optional-returning API in `DarwinChannel.read` — no new work needed here, just don't regress it |

## Sources

### Primary (HIGH confidence)
- This repository: `Sources/PikoAudio/ArmedSession.swift`, `Sources/PikoKit/Contracts.swift`,
  `Sources/PikoKit/Protocols.swift`, `Sources/PikoBridge/DarwinChannel.swift`, `Package.swift`,
  `App/project.yml`, `docs/SPEC.md`, `docs/ARCHITECTURE.md`, `docs/CONSTRAINTS.md`,
  `docs/SPIKES.md`, `docs/WORKING-AGREEMENT.md`, `CLAUDE.md`, `.planning/phases/piko-01-*`,
  `.planning/phases/piko-02-*` — all read directly this session
- Apple — [`AVAudioSession.interruptionNotification`](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification)
  — fetched this session; confirms userInfo keys (`AVAudioSessionInterruptionTypeKey`,
  `AVAudioSessionInterruptionOptionKey`), `.began`/`.ended` semantics, main-thread delivery
- Apple — [`AVAudioSession.routeChangeNotification`](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangenotification)
  — fetched this session; confirms it is a distinct notification from interruption, delivered on
  a secondary thread, with its own reason/previous-route userInfo keys
- Apple — [App Intents overview](https://developer.apple.com/documentation/appintents) — fetched
  this session; confirms Shortcuts/Siri/Action-Button integration is App Intents' documented
  purpose
- Apple — [App Intents: Hardware interactions](https://developer.apple.com/documentation/appintents/hardware-interactions)
  — fetched this session; **directly confirms** "On supported iPhone models, people can run
  custom actions quickly using the Action button. This button is configurable in Settings, so
  people can assign any App Shortcuts you create" — the single strongest citation in this
  research
- This project's own `docs/CONSTRAINTS.md` C2/C5 rows — sourced (per that document) from Apple
  Developer Forums threads on background recording-session activation and Live Activity
  foreground requirements; used here as the basis for the `openAppWhenRun` recommendation

### Secondary (MEDIUM confidence)
- `swift-ios-skills` plugin skill `app-intents` (`SKILL.md`, read this session) — confirms the
  `AppIntent`/`AppShortcutsProvider`/system-surface table matches the Apple-docs findings above;
  used as a cross-check, not a primary source
- `swift-ios-skills` plugin skill `background-processing` (`SKILL.md`, read this session) —
  confirms `BGTaskScheduler`/`BGContinuedProcessingTask` are unrelated to this phase's background
  audio continuation mechanism (that's the `audio` `UIBackgroundMode`, already declared in
  `App/project.yml`), preventing a possible scope-confusion between C10 and C3

### Tertiary (LOW confidence)
- Back Tap's exact Settings picker behavior (whether it lists custom Shortcuts identically to the
  Action Button's picker) — the specific Apple support-article page did not load successfully
  this session; the claim is presented as `[ASSUMED]` based on public knowledge and this project's
  own `ROADMAP.md`/`REQUIREMENTS.md` framing (IDNT-01's "already partially in v1" phrasing implies
  the maintainers already believe this works the same way), not independently re-fetched and
  confirmed this pass
- Exact `AVAudioSession.Category`/`CategoryOptions` constants to use (`.playAndRecord`,
  `.allowBluetoothHFP` vs. `.allowBluetooth`) — not verified via `apple-docs` MCP or a fetched
  page this session; flagged for implementation-time lookup per this project's own working
  agreement, not asserted as fact here

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `AppIntent`s invoked via Back Tap/Action Button do not get a C2 background-audio-activation exception, so `openAppWhenRun` must be `true` | Architecture Patterns, Pattern 3; Common Pitfalls, Pitfall 2 | High if wrong in the "too cautious" direction (a real exception exists but this research recommends foregrounding anyway) — costs a needless UX compromise, not a functional bug. High if wrong in the other direction (no exception exists at all, even with `openAppWhenRun: true`) — SESS-02/SESS-03 could be entirely infeasible as literally worded, forcing a scope conversation before planning proceeds. **This should be the first thing the plan verifies, ideally via a tiny device spike, before any other Wave 0 work in this phase** |
| A2 | Back Tap's Settings picker surfaces custom App Shortcuts the same way the Action Button's does | Summary, point 2 | Medium — if Back Tap's picker is more restricted than assumed, SESS-02 specifically (not SESS-03) could need a different mechanism or be infeasible; does not affect SESS-01/03/04/05 |
| A3 | `.playAndRecord` with Bluetooth-supporting options is the correct `AVAudioSession` category for this product (vs. plain `.record`) | Alternatives Considered | Low — this is an implementation detail correctable via `apple-docs` MCP lookup at build time with no architectural consequence; flagged so the planner doesn't treat it as settled |

**If this table is empty:** N/A — see above; two of three assumptions carry real, plan-relevant
risk and should be resolved early in this phase, not discovered late.

## Open Questions

1. **Does `SessionState` need a new field for "why was the session interrupted," or is
   phase-reverts-to-idle sufficient?**
   - What we know: The keyboard's existing `isLive()`-driven "tap to arm" UI already satisfies a
     literal reading of "re-arm prompt" for that consumer, with zero `PikoKit` changes.
   - What's unclear: Whether the *container app's own* foreground UI needs a more specific reason
     ("call ended" vs. "low power mode") to satisfy the spirit of "surfaces a re-arm prompt," or
     whether a generic "session ended — tap to arm" message is acceptable for v0.1.
   - Recommendation: Default to no new field (simplest, most consistent with the "don't blur
     module boundaries" ethos already established) unless the planner/user specifically wants a
     richer re-arm message; if so, add an additive `lastInterruption: InterruptionReason?` to
     `SessionState`, mirroring the precedent Phase 2 set for `sessionEpoch`.

2. **Is Phase 3 responsible for building the actual re-arm-prompt UI in `App/Piko`, or only the
   correct state transition a later phase's UI reacts to?**
   - What we know: ROADMAP.md's Phase 3 Success Criteria #2 says interruptions "end in either
     silent recovery or a re-arm prompt" — a user-visible outcome, not just internal state. No
     later phase in ROADMAP.md is explicitly assigned "build the container app's session-status
     UI."
   - What's unclear: Whether this phase's plan should include a minimal SwiftUI banner/alert (a
     small, bounded addition) or whether that's implicitly Phase 7's job (Live Activity, which
     already needs to render armed/listening/tidying state and could plausibly render "needs
     re-arm" too).
   - Recommendation: Scope a *minimal* re-arm affordance into this phase (even a single `Text`
     view bound to `phase == .idle` while the container app is foregrounded) so the phase's own
     stated success criterion is honestly met without waiting on Phase 7, but keep it deliberately
     small — this is not the phase to build final UI polish.

## Metadata

**Confidence breakdown:**
- Standard stack (AVAudioSession/AVAudioEngine, App Intents, ProcessInfo): HIGH — every mechanism
  is either fetched from current Apple documentation this session or cross-checked against the
  `swift-ios-skills` plugin's App Intents skill
- Back Tap/Action Button as the real integration point: HIGH for Action Button (directly cited
  Apple documentation), MEDIUM for Back Tap specifically (consistent secondary evidence, not a
  freshly fetched primary source this session)
- The `openAppWhenRun`/C2 interaction: MEDIUM — a sound inference from this project's own sourced
  constraints doc, not yet confirmed by a fetched, dated Apple document addressing App Intents
  and background audio activation specifically; recommended as this phase's first spike
- Interruption-recovery testability approach: HIGH — grounded in the same reasoning pattern
  (mockable protocol seam, deterministic assertion, defer the literal timing number to a device
  spike) that Phase 2's research already applied successfully to BRDG-02
- SESS-05 manual-only scope: HIGH — stated explicitly in both ROADMAP.md's own Success Criteria
  and `docs/SPIKES.md` Spike 2; not a judgment call this research introduced

**Research date:** 2026-08-29
**Valid until:** ~30 days for the App Intents/Action Button mechanism claims (fast-moving area of
iOS, per this project's own working agreement warning about iOS 26/27 API drift); effectively
indefinite for the AVAudioSession interruption/route-change notification mechanism (stable since
iOS 6–10, unlikely to change); re-verify the `openAppWhenRun` spike result before this research is
treated as settled for planning purposes.
