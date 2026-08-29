# Phase 2: Cross-Process Bridge - Research

**Researched:** 2026-08-27
**Domain:** iOS cross-process IPC between a container app and a keyboard extension (Darwin
notifications + App Group file storage), Swift 6.2 strict concurrency, on-device latency testing
**Confidence:** HIGH (architecture/mechanism), MEDIUM (testability approach for BRDG-02/BRDG-03,
since no device timing has been captured yet)

## Summary

The phase goal is **partially already met** by existing skeleton code, but not in the "verify and
harden" sense Phase 1 was — there is a real, non-obvious correctness gap that must be designed
around before this phase can be called done.

`Sources/PikoBridge/DarwinChannel.swift` already implements the full `SessionChannel` protocol
end to end: Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) as the "doorbell"
and JSON files in the App Group container (`.atomic` writes) as the payload, exactly matching the
mechanism `docs/SPEC.md` and `docs/ARCHITECTURE.md` already prescribe
`[VERIFIED: read Sources/PikoBridge/DarwinChannel.swift this session]`. `App/PikoKeyboard/KeyboardViewController.swift`
already wires a `DarwinChannel` up and does client-side sequence filtering
(`draft.sequence > lastSequence`) `[VERIFIED: read this session]`. **PikoKit's `SessionChannel`
protocol already models this bridge exactly** — no new protocol is needed in `PikoKit`.

**The primary recommendation is not "pick an IPC mechanism"** — that decision was already made
correctly in Phase 1/skeleton — **it is: fix the sequence-number contract before it becomes a
silent bug, add a real `PikoBridgeTests` target, and build a non-manual harness for the two
timing/survival acceptance criteria.** Specifically:

1. **BRDG-04 has a real design gap today, not just a missing test.** `CaptureDraft.sequence` is a
   plain `Int` that each `Transcriber` implementation owns independently
   (`Sources/PikoTranscribe/SpeechTranscriberEngine.swift` starts its own counter at 0). The
   keyboard's `lastSequence` guard (`draft.sequence > lastSequence`) is **only safe within a
   single continuous capture session**. The moment a *new* session starts — app relaunch after
   crash, or simply the second capture of the day — the transcriber's sequence counter resets to
   0 while the keyboard extension process (which is long-lived relative to any one capture) still
   remembers a `lastSequence` from the previous session. Result: every draft of the new session is
   silently dropped as "stale" forever, because `0 > 47` is `false`. This is the opposite of the
   requirement's intent and needs a session-scoped ordering key, not a bare monotonic `Int`. See
   Common Pitfalls and Code Examples below for the recommended fix.
2. **`DarwinChannel` never removes its `CFNotificationCenterAddObserver` registrations.** There is
   no `deinit`. `observeAll()` registers an unretained `self` pointer with the Darwin notify
   center every time a `DarwinChannel` is constructed, and nothing ever calls
   `CFNotificationCenterRemoveObserver`. In the current single-long-lived-instance-per-process
   usage this is latent, not yet triggered — but it is exactly the kind of gap a Phase 2 test
   should catch before more code depends on the channel's lifecycle being safe to construct more
   than once (e.g., in tests, or if a future retry/reconnect path constructs a second channel).
3. **There is no `PikoBridgeTests` target yet** — `Package.swift` only declares `PikoKitTests`.
   Phase 2 needs a new test target added to `Package.swift`, matching the pattern Phase 1 already
   established for `PikoKitTests`.
4. **BRDG-02 (under 120 ms) and BRDG-03 (twenty app switches)** are not literally testable as
   written by any existing infrastructure, on-device or in Simulator — see the dedicated section
   below for the recommended testable reframing of each.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BRDG-01 | Keyboard extension's mic button drives the armed session through `SessionChannel` | `DarwinChannel` + `KeyboardViewController` already wire `post(.captureStart)`/`post(.captureStop)`; this phase's job is to prove the channel side works correctly, not to build the mic button UI (that's Phase 4, `CAPT-01`/`CAPT-02`'s sibling requirement) |
| BRDG-02 | Round trip under 120ms on device | Requires an instrumented timestamp round-trip harness, not a stopwatch — see "What 'under 120ms' Practically Requires" |
| BRDG-03 | Survives twenty consecutive app switches without losing state | Requires reframing as a persistence/reconnection property, testable via repeated channel-instance recreation against the same App Group container — see "Testability for 'Survives Twenty App Switches'" |
| BRDG-04 | Never delivers a stale sequence number | Requires closing the session-scoped-sequence design gap described in Summary point 1 before it is meaningfully testable |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Signal delivery (arm/start/stop/draft-updated/result-ready) | PikoBridge (Darwin notify center) | — | Only cross-process wake mechanism available to a keyboard extension; already implemented |
| Payload storage (state/draft/result) | PikoBridge (App Group JSON files) | PikoKit (type definitions) | Darwin notifications carry no payload (Apple-documented); App Group container is the only shared storage both processes can reach |
| Sequence/staleness semantics | PikoKit (`CaptureDraft`/`SessionState` shape) | PikoBridge (channel read/write ordering) | The *rule* ("what counts as stale") is a contract both processes must agree on — it belongs in the shared type, not duplicated logic in each consumer |
| Round-trip timing instrumentation | PikoBridge (timestamps in the payload) | App target (device-only harness) | The channel is the only place that sees both ends of the trip; a debug/test-only entry point in the app schedules the response |
| Reconnection safety after extension process death | PikoBridge (channel construction/read path) | — | The keyboard extension process is not the container app process — it is torn down and recreated far more aggressively; the channel must be safe to re-open cold against state written by a still-running app |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Core Foundation (`CFNotificationCenterGetDarwinNotifyCenter`) | ships with the OS | System-wide, cross-process, payload-less "something changed" signal | The only notification center that crosses process boundaries on iOS without an entitlement beyond the App Group itself; already in use `[VERIFIED: Apple docs, fetched this session]` |
| Foundation `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` + `Data.write(options: .atomic)` | ships with the OS | Shared payload storage with an atomic, torn-read-safe write | Standard mechanism for App Group data sharing; `.atomic` is what prevents the keyboard from ever reading a half-written JSON file |
| Swift Testing | ships with Xcode 26 / Swift 6.2 | Unit/integration tests for `PikoBridgeTests` (new target) | Matches the pattern already established in `PikoKitTests` (Phase 1) |

### Supporting
None new. This phase adds zero third-party dependencies — `PikoBridge` already depends on only
`PikoKit` in `Package.swift`.

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Darwin notifications + App Group JSON files (current, correct choice) | XPC (`NSXPCConnection`) | XPC requires the extension to either host a service or connect to one the app publishes; a keyboard extension cannot reliably keep a persistent XPC connection to a backgrounded app process across app suspension, and Apple's own extension guidance does not document XPC as a supported app↔keyboard-extension channel. Rejected — this is not a viable option for this pairing, not just a worse one. |
| Darwin notifications + App Group JSON files | `NSFileCoordinator`/`NSFilePresenter` for the payload instead of plain atomic writes | File coordination adds real protection against concurrent-writer races, but there is only ever one writer (the app) and one reader (the keyboard) per file in this design — `.atomic` write already prevents torn reads without the added complexity and the coordination daemon round-trip cost, which cuts directly against the 120ms budget. Correct choice already made; do not "upgrade" to `NSFileCoordinator` without a measured reason. |
| Darwin notifications + App Group JSON files | `NSUbiquitousKeyValueStore` (iCloud KV) | Introduces network dependency and eventual-consistency lag measured in seconds, not milliseconds — disqualified outright by the zero-network constraint and the 120ms budget. |
| Per-signal payload via Darwin notification's `userInfo` | N/A — not possible | Apple's own docs confirm the Darwin notify center ignores the object/userInfo parameters entirely (`[VERIFIED: developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter()`, fetched this session]`) — this rules out "just put the payload on the notification" as an option, not merely a style choice. `DarwinChannel.post` already correctly passes `nil, nil` for those parameters. |

No installation needed — everything is either OS-provided or already in `Package.swift`.

## Package Legitimacy Audit

Not applicable — this phase adds zero external packages.

## Architecture Patterns

### System Architecture Diagram

```
KEYBOARD EXTENSION PROCESS                    CONTAINER APP PROCESS (backgrounded, audio-alive)
(ephemeral — created/destroyed far            (long-lived while armed — C3 background audio mode)
 more often than the app process)

┌──────────────────────────┐                  ┌───────────────────────────────────┐
│ KeyboardViewController    │                  │ ArmedSession / Transcriber owner    │
│  mic tapped               │                  │                                     │
│    └─ channel.post(       │──Darwin notify──▶│  observes .captureStart             │
│         .captureStart)    │  (no payload,     │    └─ starts capture, streams       │
│                           │   system-wide,    │       CaptureDraft(sequence: n++)   │
│                           │   ~sub-ms wake)   │    └─ channel.writeDraft(draft)     │
│                           │                  │         └─ JSON → App Group file    │
│  observes .draftUpdated ◀─│──Darwin notify───│         └─ post(.draftUpdated)      │
│    └─ readDraft()         │                  │                                     │
│    └─ guard sequence >    │                  │                                     │
│         lastSequence      │                  │                                     │
│    └─ insertText/delete   │                  │                                     │
└──────────────────────────┘                  └───────────────────────────────────┘
              │                                                  │
              └───────────────── App Group container ────────────┘
                    (draft.json / result.json / state.json,
                     atomic writes = the only durable state;
                     both processes' in-memory state is disposable)
```

A reader can trace: the keyboard never talks to the app directly — it wakes the app (or is woken
by it) via a payload-less doorbell, then both sides independently read the one place the payload
actually lives. Because the App Group file is the only durable state, **"surviving an app switch"
is really "the file is still there and still correct" — not "the in-memory Swift objects survived"**,
since neither process's in-memory state is expected to survive a suspension in the first place.

### Recommended Project Structure
```
Sources/PikoBridge/
└── DarwinChannel.swift        # existing — no restructuring needed
Tests/
└── PikoBridgeTests/           # NEW — add to Package.swift testTarget list
    ├── SequenceOrderingTests.swift     # BRDG-04
    ├── RoundTripLatencyTests.swift     # BRDG-02 (device-only, XCTSkip on Simulator)
    └── ReconnectionSurvivalTests.swift # BRDG-03
```

### Pattern 1: Session-scoped sequence (the fix for BRDG-04)
**What:** Pair every `CaptureDraft.sequence` with a session identifier that changes once per
`arm()`, and compare the pair, not the bare integer. Two options, both compatible with the
existing `Codable`/`Sendable` shape:
- **(a) Add `sessionEpoch: Int` to `CaptureDraft`** (and/or to `SessionState`), incremented by the
  app every time a session is armed. Keyboard compares `(epoch, sequence)` lexicographically: a
  draft from a new epoch always wins regardless of its sequence value; within the same epoch, the
  existing `sequence > lastSequence` rule holds.
- **(b) Fold session identity into the sequence itself** by seeding each session's counter from a
  monotonically increasing source (e.g., `Date.now.timeIntervalSince1970` milliseconds, or a
  value persisted in `SessionState` and read back at arm time) instead of restarting at 0. Simpler
  shape (no new field), but relies on wall-clock monotonicity across process restarts, which is
  weaker than an explicit epoch counter.
**Recommendation:** (a) — explicit `sessionEpoch` field. It is auditable, does not depend on
clock behavior, and is a two-line addition to an existing `Codable` struct that both processes
already rebuild from source on every commit (no migration concern since nothing is persisted
across app versions yet — v0.1 is unshipped).
**When to use:** Any time a "keep the latest" comparison must survive the producer's own counter
resetting.
```swift
// Proposed addition to Sources/PikoKit/Contracts.swift
public struct CaptureDraft: Codable, Sendable, Equatable {
    public var sessionEpoch: Int   // NEW — bumped once per arm(), never resets mid-session
    public var sequence: Int
    public var text: String
    public var stablePrefix: Int
    public var startedAt: Date
}
```
```swift
// Proposed fix to App/PikoKeyboard/KeyboardViewController.swift
private var lastEpoch = -1
private var lastSequence = -1

private func applyDraft() {
    guard let draft = channel?.readDraft() else { return }
    let isNewer = draft.sessionEpoch > lastEpoch
        || (draft.sessionEpoch == lastEpoch && draft.sequence > lastSequence)
    guard isNewer else { return }
    lastEpoch = draft.sessionEpoch
    lastSequence = draft.sequence
    // ... insertText/deleteBackward diffing (Phase 4 scope)
}
```

### Pattern 2: Observer lifecycle safety (the fix for the `deinit` gap)
**What:** `DarwinChannel` must remove its Darwin notify center observers when it is deallocated,
mirroring the `CFNotificationCenterAddObserver` calls with `CFNotificationCenterRemoveObserver` (or
`RemoveEveryObserver` for this observer pointer) in a `deinit`.
**When to use:** Any type that registers itself as a C-callback observer with an unretained
pointer — the pointer becomes dangling the instant the instance deallocates if nothing unregisters
it first.
```swift
// Proposed addition to Sources/PikoBridge/DarwinChannel.swift
deinit {
    CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
}
```
`[ASSUMED — CFNotificationCenterRemoveEveryObserver is the standard pairing for
CFNotificationCenterAddObserver with an unretained observer pointer; verify the exact symbol name
against current Core Foundation headers before committing, since this was not independently
re-fetched from Apple docs this pass]`

### Pattern 3: Round-trip timestamp piggybacking (for BRDG-02 instrumentation)
**What:** For a *test/debug build only*, add a timestamp the keyboard stamps at post-time and the
app echoes back, so elapsed time can be computed on the keyboard side without any external clock
sync.
**When to use:** Only inside a `#if DEBUG` or a dedicated test harness type — this must never ship
in the `RequestsOpenAccess`-gated production keyboard path as an always-on field, to avoid
growing the payload or the keyboard's responsibilities for no user-facing reason.

### Anti-Patterns to Avoid
- **Do not build a custom polling loop as a Darwin-notification fallback.** If a notification is
  believed "missed," the correct recovery is: the reader polls the App Group file *once* on its
  own lifecycle events (e.g., `viewDidLoad`, becoming active) — not a timer loop. `docs/ARCHITECTURE.md`
  already frames a missed notification as degrading to "the keyboard notices on its next poll,"
  meaning an occasional catch-up read, not a persistent poll timer that would burn the keyboard's
  60MB/CPU budget (C4).
- **Do not add `NSFileCoordinator` "just in case."** See Alternatives Considered — there is no
  concurrent-writer scenario in this design that `.atomic` doesn't already solve, and coordination
  has a real latency cost that works against BRDG-02.
- **Do not test BRDG-02/BRDG-03 by literally scripting the Simulator to switch apps 20 times or
  measuring latency with `Date()` calls sprinkled through production code.** See the dedicated
  sections below.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Cross-process wake-up | A custom named-pipe or socket listener | `CFNotificationCenterGetDarwinNotifyCenter` (already used) | It is the only Apple-sanctioned, sandbox-compatible mechanism available to a keyboard extension; already correctly chosen |
| Atomic cross-process payload write | Manual temp-file-then-rename dance | `Data.write(to:options:.atomic)` (already used) | Foundation's `.atomic` option already does write-to-temp-then-rename under the hood; reimplementing it adds risk for zero benefit |
| "Is this the newest data" check | A custom timestamp-diff heuristic | An explicit, session-scoped sequence pair (Pattern 1) | Wall-clock-based staleness heuristics are exactly the kind of "seems fine in Simulator, flaky on device" bug the working agreement warns about; an explicit counter pair is deterministic and unit-testable without a clock at all |

**Key insight:** Every mechanism-level choice in this phase is already correct in the skeleton.
The actual risk is a **contract gap** (the sequence field's meaning is underspecified across
session boundaries) and a **lifecycle gap** (the observer leak), not a wrong tool choice.

## What "Round Trip Under 120ms" Practically Requires

The current design is **push-based, not polling** — a Darwin notification wakes the observing
process, which then does one file read. There is no polling loop anywhere in the current
`DarwinChannel`, which is the right baseline for a 120ms budget: polling on any reasonable
interval (even 16ms/60fps) adds up to half the interval as pure latency before the read even
starts, on top of read time, for no benefit over an immediate wake.

Confirmed from Apple's own documentation (fetched this session): Darwin notifications carry **no
payload** — object and userInfo parameters are ignored — and delivery requires the observing
process's main thread run loop to be "running in one of the common modes." This has one concrete
implication for the app side: the container app must genuinely keep its run loop pumping while
backgrounded (already required for C3's background-audio-mode survival, so this is not new work,
but it is a real dependency this phase should assert, not assume — a background app that is
merely alive-but-blocked on synchronous work would delay delivery in a way that eats directly into
the 120ms budget).

**What the 120ms is actually spent on**, in order: (1) Darwin notify post → OS dispatch → observer
callback invoked (sub-millisecond in practice, not something this phase's code controls), (2)
whichever side is now awake reads/writes the App Group JSON file (`Data(contentsOf:)` /
`.write(options: .atomic)` — dominated by JSON encode/decode size, which is tiny for `CaptureDraft`),
(3) the response notification + read on the other side, repeating (1)–(2) once more. There is no
step in this chain that inherently costs more than a few milliseconds at `CaptureDraft`'s payload
size — the risk to the 120ms budget is not the mechanism, it is **anything synchronous the app
does before it gets around to reading/writing** (e.g., if `arm()`/session-management code runs on
the same actor/queue and is busy). This phase's plan should treat "app responds promptly to the
signal, on a dedicated path, not queued behind other work" as a design requirement, not just an
implementation detail.

**Testability:** This is not measurable in a normal unit test (no cross-process boundary exists in
a single test process) and Simulator timing is explicitly called out by `docs/WORKING-AGREEMENT.md`
as not representative of device timing for exactly this kind of cross-process/background work.
Recommended approach:
1. Build a minimal, real dual-process harness: a debug-only round-trip mode where the keyboard
   posts a signal carrying (via the payload piggyback, Pattern 3) a `sentAt` timestamp, the app
   echoes it straight back through `writeDraft`/`.draftUpdated` with no other work in between, and
   the keyboard computes `Date.now.timeIntervalSince(sentAt) * 1000` on receipt.
2. Run this only on a physical device (per working agreement — Simulator numbers must be labeled
   as such, not presented as the acceptance measurement) attached to Xcode/Instruments, or logged
   to a file readable via Console.
3. Record the actual measured number in `docs/SPIKES.md` under Spike 1, which already exists for
   exactly this purpose and currently reads "not run."
4. This phase's automated test suite should assert the **mechanism** (a round trip completes and
   the correct data comes back) with a generous, CI-safe timeout (e.g., 2 seconds) — the *precise*
   120ms number is a device-measured, manually-recorded acceptance criterion for
   `/gsd:verify-work`, not something `swift test` can certify in CI.

## Testability for "Survives Twenty App Switches" (BRDG-03)

Read literally, this requirement asks for a UI-automation script that manually backgrounds and
foregrounds an app twenty times — fragile, slow, and it does not actually test the bridge in
isolation; it tests whatever else is also happening during app switches. The **actual property
under test** is: *App Group file state, once written, must still be correct and readable after
the keyboard extension process has been torn down and recreated* — because that is what "an app
switch" does to a keyboard extension's process in practice (it is not the app being backgrounded
that threatens state, it is the *extension's own* aggressive lifecycle).

**Recommended reframing:** simulate the extension's process churn directly, without driving
Springboard:
1. **Unit/integration test** (`Tests/PikoBridgeTests/ReconnectionSurvivalTests.swift`): construct
   a `DarwinChannel` representing "the app," write a `SessionState`/`CaptureDraft`. Then, in a
   loop of 20, construct and immediately discard a *second* `DarwinChannel` representing "the
   keyboard, freshly relaunched" (this is the correctness-relevant action a real app switch causes
   in the extension process), and on each iteration assert it reads back the exact state the "app"
   instance last wrote — i.e., the file survives repeated cold reader construction/teardown. This
   is directly testable, in-process, deterministic, and CI-safe.
2. **Manual device pass** (tracked in `docs/SPIKES.md`, Spike 1, which already asks for this):
   twenty *actual* app switches on a physical device, confirming the keyboard still shows live
   session state and the mic button still works after the twentieth switch — this is the literal
   acceptance criterion and should remain a recorded, human-run check, not something the plan
   claims to automate away entirely.
3. **What this does NOT need:** any XCUITest driving Springboard/app-switcher UI. That would be
   slow, flaky, and would not test anything about the bridge that the file-survival test above
   doesn't already cover more directly.

## Sequence Numbers (BRDG-04) — Structure Recommendation

See Pattern 1 above for the concrete fix. Summary of the reasoning: `CaptureDraft.sequence` today
is monotonic *within* a `Transcriber` instance's lifetime, but nothing in `PikoKit`'s type shape
prevents (or even signals) that lifetime resetting — which it will, every time a new session
starts, by design (`SpeechTranscriberEngine`'s `sequence` var starts at 0 in every fresh instance).
`SessionState.isLive(now:tolerance:)` already establishes the precedent of putting staleness logic
on the shared type rather than duplicating it per-consumer; `sessionEpoch` should follow the same
pattern. This is a `PikoKit` change (add the field), a `PikoAudio`/`PikoTranscribe` change
(increment it at `arm()`, thread it through to every draft — out of this phase's module but its
existence must be decided here since Phase 2 defines the shape both future phases build against),
and a `PikoBridge`/keyboard-side change (compare the pair, not the bare int).

## Whether Existing PikoKit Types Already Model This Bridge

**Yes — `SessionChannel` in `Sources/PikoKit/Protocols.swift` already matches this phase's needs
exactly**, and matches `docs/SPEC.md`'s `PikoBridge` contract sketch closely (SPEC.md's sketch is
slightly older/simpler — `post(_ event: BridgeEvent)` vs. the real `post(_ signal: Signal)`, and
SPEC.md omits `readState`/`writeState`/`readResult`/`writeResult` which the real protocol already
has). **No new protocol is needed.** The one type-level gap is the sequence/epoch issue described
above — that is a modification to `CaptureDraft` (and possibly `SessionState`), not a new type.

## Realistic Wave 0 Gaps

- **`Tests/PikoBridgeTests` test target does not exist.** Must be added to `Package.swift`'s
  `targets:` array (`.testTarget(name: "PikoBridgeTests", dependencies: ["PikoBridge", "PikoKit"])`)
  before any test in this phase can run.
- **`CaptureDraft.sessionEpoch` does not exist.** This is a `PikoKit` change even though the
  phase's module is `PikoBridge` — flag for the plan that this phase's Wave 0 may need to touch
  `PikoKit` (a dependency, already-"complete" module) to add one field, which is a legitimate,
  narrow exception to "Phase 1 is done" rather than scope creep, since the field is meaningless
  without the bridge that enforces it.
- **`DarwinChannel` has no `deinit`.** One-line fix, should be Wave 0 alongside the test target
  addition since a test that constructs/discards multiple channels (needed for the BRDG-03
  reconnection test above) will otherwise leak observers across test cases.
- **No existing round-trip timing harness of any kind** (no `os_signpost`, no `ContinuousClock`
  usage anywhere in the repo `[VERIFIED: grep across Sources/ this session, zero matches]`) — this
  phase is the first to need one.
- **There is no stub/mock `SessionChannel`** for host-app + extension wiring beyond the real
  `DarwinChannel` — none is needed for *this* phase's own tests (the reconnection test above uses
  two real `DarwinChannel` instances against the same App Group container, which is more faithful
  than a mock), but a `MockSessionChannel` conforming to `SessionChannel` may be worth adding here
  anyway since Phase 4 (Keyboard Extension & Streaming Insertion) will need to unit-test keyboard
  UI logic without a real App Group container in a UI-test target. Flagging as optional/discretionary
  for the planner, not a hard requirement of this phase's own success criteria.

## Common Pitfalls

### Pitfall 1: Sequence resets silently break the keyboard after the first session
**What goes wrong:** Second and all subsequent capture sessions in a single keyboard-extension
process lifetime get every draft silently dropped, because the new session's sequence counter
starts below the previous session's high-water mark.
**Why it happens:** `sequence` is scoped to a `Transcriber` instance's lifetime, but the keyboard's
`lastSequence` guard is scoped to the *extension process's* lifetime, and those two lifetimes are
unrelated.
**How to avoid:** Add `sessionEpoch` (Pattern 1) and compare the pair.
**Warning signs:** A second dictation in the same keyboard session (i.e., without dismissing and
reopening the keyboard) never displays any streamed text, even though `.draftUpdated` notifications
are firing.

### Pitfall 2: Darwin notify center observers are never removed
**What goes wrong:** `CFNotificationCenterAddObserver` registrations passed with
`Unmanaged.passUnretained(self)` outlive the `DarwinChannel` instance if nothing removes them —
a dangling-pointer crash risk the moment a second channel is constructed and the first is
deallocated (exactly what the recommended BRDG-03 reconnection test does 20 times over).
**Why it happens:** No `deinit` exists on `DarwinChannel` today.
**How to avoid:** Add the `deinit` shown in Pattern 2, before writing any test that constructs more
than one `DarwinChannel` in a process lifetime.
**Warning signs:** Crashes or flaky test failures specifically in a test that loops constructing
and discarding `DarwinChannel` instances — which is exactly the recommended BRDG-03 test shape, so
this pitfall will surface immediately if not fixed first.

### Pitfall 3: Treating Simulator round-trip numbers as the BRDG-02 acceptance measurement
**What goes wrong:** A round trip measured in Simulator (same-machine, no real background-process
scheduling pressure, different Darwin notify center implementation characteristics under the hood)
can look comfortably under 120ms while a physical device — under real memory/thermal/scheduler
pressure with the app genuinely backgrounded, not just "another window" — is not.
**Why it happens:** Simulator processes are not really backgrounded/foregrounded the way device
processes are; the OS-level scheduling and suspension behavior this bridge depends on doesn't fully
exist in Simulator.
**How to avoid:** Per `docs/WORKING-AGREEMENT.md`, always state which environment a timing number
came from; treat only a physical-device number as satisfying BRDG-02; record it in `docs/SPIKES.md`.
**Warning signs:** A plan or verification step that reports "120ms round trip, passing" without
stating "measured on device."

### Pitfall 4: Confusing "the App Group file survived" with "the extension's UI state survived"
**What goes wrong:** A plan might try to preserve `KeyboardViewController`'s in-memory
`lastSequence`/UI state itself across app switches, which is both unnecessary and impossible —
`UIInputViewController` instances are recreated by the system on their own schedule, independent
of anything this phase's code can control.
**Why it happens:** "Survives twenty app switches without losing state" reads like it's asking for
in-memory continuity.
**How to avoid:** The state that must survive is exclusively the App Group file content (durable,
already correctly designed for this) — the correct behavior on a fresh `KeyboardViewController` is
to read the current file state from scratch and pick up from there (which the current
`readDraft`/`readResult`/`readState` calls in `viewDidLoad`-driven `observe()` already do
structurally), not to have remembered anything from before.
**Warning signs:** A design that tries to persist `lastSequence` itself (e.g., in `UserDefaults`)
rather than deriving correctness purely from the App Group payload plus the epoch/sequence pair.

## Code Examples

### Darwin notification post/observe (existing, correct — reference only)
```swift
// Source: Sources/PikoBridge/DarwinChannel.swift (this repo)
public func post(_ signal: Signal) {
    CFNotificationCenterPostNotification(
        center, CFNotificationName(signal.rawValue as CFString), nil, nil, true)
}
```
Passing `nil, nil` for object/userInfo is correct and required — Apple's docs confirm these
parameters are ignored by the Darwin notify center, so passing anything else would be silently
discarded, not an error, which is why this is easy to get subtly wrong without realizing it.

### Proposed integration test shape for BRDG-03 (see Testability section for full reasoning)
```swift
// Proposed: Tests/PikoBridgeTests/ReconnectionSurvivalTests.swift
@Test("state survives repeated cold keyboard-side channel construction")
func reconnectionSurvival() throws {
    let appSide = try #require(DarwinChannel())
    let state = SessionState(phase: .armed)
    appSide.writeState(state)

    for _ in 0..<20 {
        let keyboardSide = try #require(DarwinChannel())  // simulates extension relaunch
        #expect(keyboardSide.readState() == state)
        // keyboardSide deallocates here — exercises Pattern 2's deinit fix
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| N/A | Darwin notifications + App Group JSON, already adopted | Established in the existing skeleton, predates this research | No migration — this phase hardens an already-current approach |

**Deprecated/outdated:** Nothing in this phase's scope relies on a deprecated API. Darwin
notifications and App Group containers remain Apple's current-documented mechanism for this exact
pairing as of the fetched documentation this session.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `CFNotificationCenterRemoveEveryObserver` is the correct pairing call for an observer registered via `CFNotificationCenterAddObserver` with an unretained pointer | Pattern 2 | Low-medium — wrong symbol name is a compile error, easily caught; but if the *semantics* differ from expectation (e.g., it requires the same `CFNotificationName` per call rather than removing all registrations for the observer), the fix could be incomplete. Verify against current Core Foundation headers/docs before the plan locks this in. |
| A2 | The container app's backgrounded run loop reliably stays in a "common mode" for Darwin notification delivery while held alive only by the `audio` background mode (C3) | "What 'Round Trip Under 120ms' Practically Requires" | Medium — if wrong, notification delivery to the backgrounded app could be delayed independent of anything this phase's code does, which would make BRDG-02 unachievable regardless of implementation quality. This should be the first thing measured on-device (Spike 1), before investing further in the harness. |
| A3 | XPC is not a viable alternative for this specific app↔keyboard-extension pairing | Alternatives Considered | Low — this is a well-documented limitation (extensions cannot reliably host/reach a persistent XPC service across app suspension) rather than a training-data guess, but was not independently re-verified against a current WWDC/session source this pass. |

## Open Questions

1. **Should `sessionEpoch` live on `CaptureDraft` alone, or also on `SessionState`/`CaptureResult`?**
   - What we know: The staleness problem as described directly affects `CaptureDraft` (the
     streaming partial), which is what BRDG-04 explicitly calls out.
   - What's unclear: Whether `CaptureResult` (the final transcript) has an analogous staleness
     risk — e.g., a result from a previous, since-abandoned session arriving after a new session
     has already started. `SessionState.isLive(now:tolerance:)`'s heartbeat-based staleness check
     may already cover this for `SessionState` itself.
   - Recommendation: Add `sessionEpoch` to `CaptureDraft` now (directly required by BRDG-04);
     leave `CaptureResult` to the planner's judgment — Phase 2's own success criteria don't
     explicitly require it, but it's a one-line addition if the planner wants to close the same
     class of bug there too.

2. **Does the round-trip timing harness need to ship as removable debug code, or can it be
   `#if DEBUG`-gated permanently in `PikoBridge`?**
   - What we know: The harness needs a way to piggyback a timestamp through the existing payload
     path without polluting the production `CaptureDraft`/`SessionState` shape.
   - What's unclear: Whether a separate, `PikoBridgeTests`-only type (not touching `PikoKit` at
     all) is cleaner than a `#if DEBUG` field on a shared type.
   - Recommendation: Keep the timing harness entirely inside `PikoBridgeTests` using its own
     private payload type over the same App Group mechanism, rather than adding any field to
     shared `PikoKit` types — this avoids any risk of a debug-only field leaking into a release
     build's `Codable` shape.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Swift toolchain / `swift build` / `swift test` | All automated tests in this phase | ✓ | 6.2 (confirmed in Phase 1) | — |
| Physical iOS device | BRDG-02 acceptance measurement, BRDG-03 manual device pass | Not confirmed available this session — no device was attached/queried | — | Automated tests can verify mechanism correctness (Pattern/Pitfall fixes) on Simulator/CI; the literal ms/switch-count numbers require a device pass tracked in `docs/SPIKES.md`, same gap already logged in `.planning/STATE.md`'s Blockers section |
| XcodeGen + Xcode (dual-target build proof, per Phase 1's precedent) | Confirming `PikoBridge` links into both `Piko` and `PikoKeyboard` schemes | ✓ (confirmed working in Phase 1 this repo) | XcodeGen 2.46.0, Xcode 26.0.1 | — |

**Missing dependencies with no fallback:** A physical device for the BRDG-02/BRDG-03 numeric
acceptance criteria — no fallback exists for measuring real cross-process, real-backgrounding
latency; this must be flagged to the human for a device pass, consistent with the existing
STATE.md blocker.

**Missing dependencies with fallback:** None beyond the above — all mechanism-correctness testing
(sequence ordering, reconnection survival, observer lifecycle) is fully achievable via `swift test`
without a device.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (bundled with Swift 6.2 toolchain) |
| Config file | none yet — new `PikoBridgeTests` target must be declared in `Package.swift` |
| Quick run command | `swift test --filter PikoBridgeTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BRDG-01 | Keyboard's signal post reaches the app side and vice versa | integration | `swift test --filter PikoBridgeTests` (two `DarwinChannel` instances in one test process, post from one, `#expect` the other's `signals` stream yields it) | ❌ — Wave 0 |
| BRDG-02 | Round trip completes correctly (mechanism); numeric <120ms | integration (mechanism) + manual (number) | `swift test --filter PikoBridgeTests` for mechanism, generous CI timeout; device pass recorded in `docs/SPIKES.md` Spike 1 for the number | ❌ — Wave 0 for both |
| BRDG-03 | State survives repeated cold keyboard-side channel reconnection | integration | `swift test --filter PikoBridgeTests` (`ReconnectionSurvivalTests`, 20-iteration loop per Testability section) | ❌ — Wave 0 |
| BRDG-04 | Keyboard never applies a lower `(sessionEpoch, sequence)` pair than one already applied | unit | `swift test --filter PikoBridgeTests` (`SequenceOrderingTests` — construct out-of-order and cross-epoch draft sequences, assert the comparison logic rejects stale ones) | ❌ — Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --filter PikoBridgeTests` (should stay sub-second, same as `PikoKitTests`)
- **Per wave merge:** `swift build && swift test`
- **Phase gate:** Full `swift test` green, plus a recorded device-measured number in
  `docs/SPIKES.md` Spike 1 before `/gsd:verify-work` closes BRDG-02/BRDG-03's numeric criteria

### Wave 0 Gaps
- [ ] Add `.testTarget(name: "PikoBridgeTests", dependencies: ["PikoBridge", "PikoKit"])` to `Package.swift`
- [ ] Add `sessionEpoch: Int` to `CaptureDraft` in `Sources/PikoKit/Contracts.swift` (and update
      its `init`/existing `PikoKitTests` Codable round-trip test to include the new field)
- [ ] Add `deinit` to `DarwinChannel` calling the observer-removal API (verify exact symbol against
      current Core Foundation reference first — see Assumption A1)
- [ ] Write `SequenceOrderingTests.swift`, `ReconnectionSurvivalTests.swift` per the Test Map above
- [ ] Decide (planner's call, Open Question 2) how the BRDG-02 timing harness payload is shaped
      before writing `RoundTripLatencyTests.swift`

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No auth surface — cross-process trust here is entirely OS-enforced via the App Group entitlement, not application-level auth |
| V3 Session Management | Marginal | `SessionState`/`sessionEpoch` are app-lifecycle session concepts, not auth sessions — but the staleness fix (Pattern 1) is itself a session-integrity control worth naming explicitly here |
| V4 Access Control | Yes | App Group container access is gated entirely by the `com.apple.security.application-groups` entitlement (OS-enforced sandbox boundary) — already correctly relied upon; no additional app-level access control is appropriate or possible for a same-App-Group read/write |
| V5 Input Validation | Yes | `JSONDecoder` decode of a file this phase's own two processes wrote is the only "input" surface; a malformed/truncated file (e.g., process killed mid-write, though `.atomic` write is designed to prevent this) must fail closed (`try?` returning `nil`, already the existing pattern) rather than crash the keyboard extension, since a keyboard crash is a much worse user-facing failure than a missed draft |
| V6 Cryptography | No | App Group container isolation is OS-level sandboxing, not cryptographic; nothing in this phase's payload is sensitive enough to warrant additional encryption beyond the OS's own container protection |

### Known Threat Patterns for this phase's stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Stale/replayed state applied after a new session starts (the BRDG-04 gap itself) | Tampering (data integrity, not malicious — a design bug, not an attacker) | The `sessionEpoch` fix (Pattern 1) is the mitigation; this is the primary security-relevant finding of this research, even though its root cause is a correctness bug rather than an adversarial threat |
| Dangling observer pointer after `DarwinChannel` deallocation (the observer-leak gap) | Denial of Service (crash) | The `deinit` fix (Pattern 2) |
| Malformed/truncated JSON in an App Group file (process killed mid-write) | Denial of Service | Already mitigated by `.atomic` write plus `try?`-based decode-failure-is-nil handling in `DarwinChannel.read` — no new code needed, confirmed already in place |

## Sources

### Primary (HIGH confidence)
- This repository: `Sources/PikoBridge/DarwinChannel.swift`, `Sources/PikoKit/Contracts.swift`,
  `Sources/PikoKit/Protocols.swift`, `Sources/PikoTranscribe/SpeechTranscriberEngine.swift`,
  `App/PikoKeyboard/KeyboardViewController.swift`, `Package.swift`, `docs/SPEC.md`,
  `docs/ARCHITECTURE.md`, `docs/CONSTRAINTS.md`, `docs/SPIKES.md`, `docs/WORKING-AGREEMENT.md`,
  `.planning/phases/piko-01-shared-contracts/01-RESEARCH.md` — read directly this session
- Apple — [`CFNotificationCenterGetDarwinNotifyCenter()`](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter())
  — fetched this session; confirms system-wide scope, ignored object/userInfo parameters, and the
  common-run-loop-mode delivery requirement
- Apple — [App Extension Programming Guide: Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
  — fetched this session; confirms `RequestsOpenAccess` is required for a shared container between
  keyboard and containing app, and that this is the only path to a shared container at all

### Secondary (MEDIUM confidence)
- None used beyond the primary sources above and Phase 1's own research, which this phase builds
  directly on.

### Tertiary (LOW confidence)
- `CFNotificationCenterRemoveEveryObserver` as the exact pairing symbol (Assumption A1) — not
  independently re-fetched from a current Core Foundation reference this pass; flagged rather than
  asserted as fact.

## Metadata

**Confidence breakdown:**
- Standard stack / mechanism choice: HIGH — already implemented in the repo and independently
  confirmed against fetched Apple documentation this session
- Sequence/epoch design gap: HIGH — derived directly from reading the actual current
  implementations of `CaptureDraft`, `SpeechTranscriberEngine`, and `KeyboardViewController`
  side by side; this is a logical deduction from the existing code, not a speculative concern
- BRDG-02/BRDG-03 testability reframing: MEDIUM — the reasoning is sound and grounded in the
  project's own `docs/WORKING-AGREEMENT.md` (Simulator ≠ device) and `docs/ARCHITECTURE.md`
  (poll-on-miss, not poll-loop), but no device measurement exists yet to confirm the 120ms budget
  is achievable at all under real backgrounding conditions (Assumption A2) — this is Spike 1's job,
  still unrun as of this research
- Security domain: MEDIUM — ASVS mapping is straightforward for this narrow, no-auth,
  no-network surface, but the "known threat patterns" table intentionally reframes two
  correctness bugs (sequence staleness, observer leak) as the security-relevant findings, since
  there is no meaningful adversarial surface in an App-Group-sandboxed, single-user, no-network
  IPC channel

**Research date:** 2026-08-27
**Valid until:** Re-check if Apple changes Darwin notification center semantics or App Group
container APIs in a future OS release (not anticipated within this milestone); re-check
immediately if Spike 1's device measurement contradicts Assumption A2 (backgrounded run loop
delivery timing), since that would change this phase's feasibility, not just its test approach.
