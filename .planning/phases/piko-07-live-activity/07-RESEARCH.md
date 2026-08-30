# Phase 7: Live Activity - Research

**Researched:** 2026-08-30
**Domain:** ActivityKit, WidgetKit (Dynamic Island / Lock Screen), App Intents cross-process control
**Confidence:** MEDIUM-HIGH (API surface HIGH; cadence/background behavior LOW per docs/SPIKES.md Spike 4 not-run)

## Summary

Phase 7 wires the already-modeled `PikoAttributes`/`ContentState` in
`App/PikoWidgets/PikoLiveActivity.swift` to a real `Activity<PikoAttributes>` lifecycle, a
`DynamicIsland`/Lock Screen `ActivityConfiguration` view, and a stop button that reaches back into
the container app's existing cross-process signal (`Signal.captureStop`, already implemented and
tested for the keyboard's mic button). The real ActivityKit surface is
`Activity<Attributes>.request(attributes:content:pushType:)` /
`activity.update(_:alertConfiguration:)` / `activity.end(_:dismissalPolicy:)` /
`Activity<Attributes>.activities`, all verified against the `activitykit` skill (itself sourced
from developer.apple.com) plus a direct fetch of `LiveActivityIntent`'s official doc page.

**Three findings block a naive "just fill in the TODO" plan and must be decided/fixed before or
during planning, not discovered mid-task:**

1. **`PikoAttributes`/`ContentState` currently live inside the `App/PikoWidgets` app-extension
   target.** That target is not an importable module — the container app (`App/Piko`) cannot
   `import` it to call `Activity<PikoAttributes>.request(...)`. The type must move to a module
   both targets already link (`PikoKit` is the obvious, already-established home per Phase 1's
   "single source of truth for every cross-process type" charter).
2. **`SessionPhase` and `Skin` are not `Hashable`.** `ActivityAttributes` and its `ContentState`
   both require `Codable, Hashable`. `ContentState.phase: SessionPhase` and
   `PikoAttributes.skin: Skin` mean the scaffold as written will not compile the moment it's
   pulled into a real `ActivityAttributes` conformance in an actual build target. This is a
   one-line-per-type fix, not a redesign, but it must happen in `PikoKit/Contracts.swift`.
3. **There is no existing cross-process "end the whole session" signal.** `Signal` only has
   `.captureStop` (ends capture, returns to `.armed` — this is what the keyboard's stop button
   already does) and no `.disarm`/`.sessionEnd` equivalent. LACT-02 says the stop button "ends
   the session reliably," which reads as full disarm (audio session torn down, Live Activity
   ended), not "return to armed and wait." This is a real scope ambiguity between the phase
   Goal ("stop an in-progress capture") and Success Criterion 2 ("ends the session") — see Open
   Questions. Do not resolve this by guessing in code; it needs one line in CONTEXT.md.

**Primary recommendation:** Add a new, small `LiveActivityController` (owned by
`AppComposition`, not inside `SessionCoordinator`/`PikoAudio`) that observes
`session.phase: AsyncStream<SessionPhase>` and `channel` draft/state reads, and is the only place
that imports `ActivityKit`. This keeps `ActivityKit` out of `PikoAudio` (which must stay
`#if os(iOS)`-clean and buildable on macOS per `Package.swift`'s `platforms: [.iOS(.v26),
.macOS(.v15)]`) and matches `ARCHITECTURE.md`'s process table ("Widget extension: Render Live
Activity, run the stop `AppIntent` — long work, hand back to the app" — the app, not the widget,
owns the lifecycle calls).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| `Activity.request/.update/.end` lifecycle calls | Container App (App/Piko) | — | C5: request needs foreground; update/end need a live process, which only the container app maintains via `UIBackgroundModes: audio` (C3) |
| `ActivityAttributes`/`ContentState` type definition | Shared module (PikoKit) | — | Must compile in both App/Piko (calls `.request`) and App/PikoWidgets (renders `ActivityConfiguration(for:)`) — an app-extension target's own sources are not importable by the container app |
| Dynamic Island / Lock Screen `Widget` view | Widget extension (App/PikoWidgets) | — | `ActivityConfiguration` and `@main WidgetBundle` must live in the WidgetKit extension target |
| Stop button intent (`perform()`) | Widget extension process (intent struct compiles into whichever target references it) OR a small shared module | Container App (signal handling) | The struct itself must be visible to the widget's `Button(intent:)` call; its `perform()` body only needs to reach the App Group / Darwin notification, which any process holding the group entitlement can do — no dependency on `AppComposition`/UIKit |
| Cross-process stop signal | App Group (`DarwinChannel`) | — | Same mechanism the keyboard's mic button already uses (`Signal.captureStop`); do not invent a second IPC path |
| Word count / level bucket computation | Container App (`LiveActivityController` or `CaptureCoordinator`) | — | Source data (`CaptureDraft.text`) already lives in the container app process; the widget only ever receives a fully-formed `ContentState` |

## User Constraints (from ROADMAP.md / REQUIREMENTS.md — no CONTEXT.md exists yet for this phase)

### Locked Decisions
- **Requirements:** LACT-01 (Live Activity shows armed/listening/tidying state), LACT-02 (stop
  button ends the session reliably)
- **Success Criteria (ROADMAP.md):** (1) Live Activity starts at arm time and shows
  armed/listening/tidying state; (2) the stop button ends the session reliably
- **iOS 26.0+ deployment target, Swift 6.0 strict concurrency** (project.yml, Package.swift)
- **CONSTRAINTS.md C5:** `Activity.request()` requires the foreground, except for an intent the
  user fired from a widget/Shortcut/Siri, or APNs push-to-start
- **CONSTRAINTS.md C6:** Live Activity lifetime is 8h active + 4h stale — start it at arm time,
  not at capture time
- **ARCHITECTURE.md process table:** widget extension renders the Live Activity and runs the stop
  `AppIntent`; it must hand long work back to the app, not do it itself
- **Zero network / zero server (REQUIREMENTS.md "Out of Scope")** — no APNs infrastructure exists
  or should be built; push-to-update/push-to-start are architecturally unavailable here

### Claude's Discretion (no CONTEXT.md yet — flag these for `/gsd:discuss-phase` before planning)
- Where exactly `PikoAttributes` should live (PikoKit vs. a new thin SPM target) — see Pitfall 1
- Whether the stop button fully disarms or only stops capture (see Open Questions — this is the
  one item that most needs a human decision before planning, not Claude's discretion)
- `levels: [Int]` computation approach (real amplitude vs. static/simple placeholder — success
  criteria only ask for phase state and stop button, not real waveform visualization)
- Whether to wire the existing `PikoFace` placeholder into the widget view now (user asked for
  "cute animations"; the component and its `.spring` transition already exist and are unused)

### Deferred Ideas (OUT OF SCOPE)
- Push-to-update / push-to-start (no server exists; C10 already rules out a persistent backend)
- Real waveform-accurate `levels` visualization (not a stated success criterion)
- Porting the real SVG character art into `PikoFace` (tracked separately, PikoFace.swift's own TODO)
- Scheduled Live Activities / Control Center start controls (v0.2 territory — IDNT-02)

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| LACT-01 | Live Activity shows armed/listening/tidying state | `Activity.request` at arm time + `.update()` on every `SessionCoordinator.phase` emission; existing `SessionPhase` enum already has the three states plus `.idle` |
| LACT-02 | Stop button ends the session reliably | `StopCaptureIntent: LiveActivityIntent` posting the existing `Signal.captureStop` (or a new signal, pending the Open Questions decision) over the already-tested `DarwinChannel` |

## Standard Stack

### Core
| Framework | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| ActivityKit | iOS 16.1+ (this project: iOS 26+) | Live Activity lifecycle (`Activity<Attributes>`) | Apple's only API for Lock Screen/Dynamic Island live state [CITED: activitykit skill, sourced from developer.apple.com] |
| WidgetKit | iOS 14+ | `ActivityConfiguration`, `DynamicIsland`, `@main WidgetBundle` | Live Activity views are rendered through a WidgetKit extension target — no alternative rendering path exists [CITED: activitykit skill] |
| App Intents | iOS 16+ | `LiveActivityIntent` for the stop button | The only intent flavor Apple documents for actions that start/modify/end a Live Activity from outside the foregrounded app [VERIFIED: developer.apple.com/documentation/appintents/liveactivityintent, fetched this session] |
| Swift Concurrency | Swift 6.0 | Observing `SessionCoordinator.phase: AsyncStream<SessionPhase>` to drive `.update()` | Already the project's concurrency model everywhere else |

### Supporting
| Piece | Purpose | When to Use |
|-------|---------|-------------|
| `DarwinChannel` / `Signal` (already exists, `Sources/PikoBridge`) | Cross-process stop signal | Reuse unchanged — this is the exact mechanism `Tests/PikoKeyboardTests/KeyboardViewModelTests.swift` already exercises for the keyboard's own stop behavior |
| `PikoUI.PikoFace` (already exists) | Character view for the widget's Dynamic Island expanded region / Lock Screen | Reuse as-is; do not build new character art this phase |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `LiveActivityIntent` for the stop button | Plain `AppIntent` with `openAppWhenRun = true` (like `ArmSessionIntent`) | Plain `AppIntent` would foreground the app on every stop tap — bad UX for a "just stop it" action, and does not use the exception path CONSTRAINTS.md C5 explicitly documents for widget-fired intents |
| `PikoAttributes` moved into `PikoKit` | New dedicated SPM target (e.g. `PikoLiveActivityKit`) depending on `PikoKit` | A new target matches the project's existing `PikoCaptureCore`/`PikoKeyboardCore` convention for cross-target sharing, and avoids the `#if canImport(ActivityKit)` guard `PikoKit` would otherwise need (ActivityKit is unavailable on plain macOS, and `PikoKit` targets `.macOS(.v15)` for `swift test` on the dev machine) — costs one more `Package.swift` target |
| App-driven periodic `.update()` calls | APNs push-to-update | Push requires server infra Piko explicitly does not have (REQUIREMENTS.md Out of Scope); app-driven updates are viable specifically because C3's background-audio mode keeps the app process alive during capture |

**Installation:**
```swift
import ActivityKit   // App/Piko target (container app) and wherever PikoAttributes' request/update/end calls live
import WidgetKit      // App/PikoWidgets target only
import AppIntents     // Both — the intent struct's declaring module
```

**Version verification:** All three are first-party frameworks shipping with iOS 26 SDK already in
use elsewhere in this project (`AppIntents` already used by `ArmSessionIntent.swift`). No package
manager entries needed. `LiveActivityIntent` confirmed present as of the current SDK via direct
fetch of its documentation page this session (iOS 17.0+ minimum, well under this project's iOS 26
floor).

## Package Legitimacy Audit

> No external packages. ActivityKit, WidgetKit, and App Intents are first-party Apple frameworks
> already linked into this project's targets (App Intents via `ArmSessionIntent.swift`; WidgetKit
> via the existing `App/PikoWidgets` extension target in `project.yml`).

| Package | Registry | Age | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|-----|-----------|-------------|-----------|-------------|
| ActivityKit | Apple (system) | iOS 16.1+ | N/A | Apple internal | N/A | Approved — first-party |
| WidgetKit | Apple (system) | iOS 14+ | N/A | Apple internal | N/A | Approved — first-party, already a project.yml target |
| AppIntents | Apple (system) | iOS 16+ | N/A | Apple internal | N/A | Approved — first-party, already used by ArmSessionIntent |

**Packages removed due to slopcheck [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
┌──────────────────────────────── Container App (App/Piko) ─────────────────────────────────┐
│                                                                                             │
│  AppComposition (sole construction site)                                                   │
│    ├── SessionCoordinator            (unchanged — no ActivityKit import added here)         │
│    │     phase: AsyncStream<SessionPhase>  ─────────────┐                                   │
│    ├── CaptureCoordinator            (unchanged except word-count hook, see below)          │
│    │     writes CaptureDraft/CaptureResult to DarwinChannel                                 │
│    └── LiveActivityController  (NEW — the only App/Piko-side ActivityKit importer)          │
│           │                                              │                                  │
│           │  arm() succeeds (foreground) ──► Activity<PikoAttributes>.request(...)          │
│           │  session.phase yields  ─────────► activity.update(ActivityContent(...))         │
│           │  CaptureDraft arrives (capturing) ► activity.update(... words: n, levels: ...)   │
│           │  disarm() / session ends ────────► activity.end(..., dismissalPolicy: .default)  │
│           └────────────────────────────────────────────────────────────────────────────────┘
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
                                        │  App Group (shared container + Darwin notifications)
                                        ▼
┌────────────────────────── Widget Extension (App/PikoWidgets) ─────────────────────────────┐
│                                                                                             │
│  @main PikoWidgetsBundle: WidgetBundle          (NEW — no @main entry point exists yet)     │
│    └── PikoLiveActivityWidget: Widget                                                       │
│           ActivityConfiguration(for: PikoAttributes.self) { context in                      │
│               // Lock Screen: PikoFace(phase:, skin:) + word count                          │
│           } dynamicIsland: { context in                                                     │
│               DynamicIsland {                                                               │
│                   .expanded(.center)  → PikoFace(phase:, skin:)                              │
│                   .expanded(.bottom)  → Button(intent: StopCaptureIntent()) { "Stop" }       │
│               } compactLeading: { PikoFace glyph }                                           │
│                 compactTrailing: { word count / phase label }                               │
│                 minimal: { PikoFace glyph }                                                  │
│           }                                                                                  │
│                                                                                             │
│  StopCaptureIntent: LiveActivityIntent           (NEW)                                      │
│     perform() { DarwinChannel()!.post(.captureStop) }  ── reuses existing IPC, no new path   │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

Shared module (PikoKit or new PikoLiveActivityKit):
  PikoAttributes: ActivityAttributes   (MOVED here from App/PikoWidgets — see Pitfall 1)
    struct ContentState: Codable, Hashable { phase: SessionPhase; words: Int; levels: [Int] }
    var skin: Skin
  // SessionPhase and Skin both need `Hashable` added in PikoKit/Contracts.swift — see Pitfall 2
```

### Recommended Project Structure
```
Sources/PikoKit/
├── Contracts.swift          # add `Hashable` to SessionPhase, Skin
└── LiveActivityAttributes.swift   # NEW — PikoAttributes/ContentState moved here
                                    # (or: a new Sources/PikoLiveActivityKit target — see
                                    #  Alternatives Considered table for the tradeoff)

App/Piko/
└── LiveActivityController.swift   # NEW — owns Activity<PikoAttributes> lifecycle

App/PikoWidgets/
├── PikoLiveActivity.swift         # keep ContentState reference here or import from PikoKit;
│                                  # add the actual ActivityConfiguration/DynamicIsland view
├── PikoWidgetsBundle.swift        # NEW — @main WidgetBundle entry point (none exists today)
└── StopCaptureIntent.swift        # NEW — LiveActivityIntent, posts .captureStop
```

### Pattern 1: Foreground-Gated Activity Start
**What:** Call `Activity<PikoAttributes>.request(...)` only from a path already proven to run in
the foreground.
**When to use:** At arm time, inside (or immediately after) `SessionCoordinator.arm()`'s existing
`guard isForeground() else { throw PikoError.notForeground }` check — that guard already proves
the precondition C5 requires. Do not duplicate the foreground check; sequence the Activity
request after `arm()` succeeds.
```swift
// Source: activitykit skill (developer.apple.com/documentation/activitykit)
// Called from LiveActivityController, driven by session.phase's first .armed emission
// after a fresh arm() call (or by AppComposition calling it directly after `try await
// session.arm()` succeeds — either wiring point works; pick one, don't duplicate the call).
let attributes = PikoAttributes(skin: state?.skin ?? .cute)
let content = ActivityContent(
    state: PikoAttributes.ContentState(phase: .armed, words: 0, levels: Array(repeating: 0, count: 8)),
    staleDate: Date().addingTimeInterval(8 * 3600)   // C6: 8h active window
)
let activity = try Activity<PikoAttributes>.request(attributes: attributes, content: content, pushType: nil)
```
Note `pushType: nil` (not `.token`) — Piko has no APNs infrastructure and none is planned; all
updates are app-driven, which is valid because the app stays alive via `UIBackgroundModes: audio`
(C3) for the ordinary duration of a session.

### Pattern 2: Resuming After Relaunch
**What:** `Activity<Attributes>.activities` (a static property, an array of currently-running
activities of that attributes type) lets a freshly-launched app process find an activity it
started before being suspended/killed, instead of blindly calling `.request()` again (which would
create a duplicate).
**When to use:** In `AppComposition.init()` or `LiveActivityController.init()`, before deciding
whether to start a new activity — check `Activity<PikoAttributes>.activities.first` and adopt it
if present (matches an armed `SessionState` read from the App Group, same pattern
`SessionState.isLive()` already uses to decide "is this session still real").
```swift
// Source: activitykit skill
if let existing = Activity<PikoAttributes>.activities.first {
    // adopt `existing`, keep updating it, do not call .request() again
} else if let state = channel.readState(), state.isLive() {
    // SessionState says armed but the Activity was lost (e.g. it expired) — decide whether
    // to re-request; likely only on the next explicit arm(), not silently.
}
```

### Pattern 3: Stop Button via LiveActivityIntent
**What:** A `LiveActivityIntent` (not a plain `AppIntent`) run from a `Button(intent:)` inside the
`DynamicIsland`/Lock Screen view. `LiveActivityIntent` is Apple's documented protocol for intents
that "start, pause, or otherwise modify a Live Activity" from outside a foregrounded app context —
this is the C5-documented exception path ("an intent the user fired from a widget").
```swift
// Source: developer.apple.com/documentation/appintents/liveactivityintent (fetched this session)
import AppIntents
import PikoBridge   // for DarwinChannel — same module the keyboard extension already links

struct StopCaptureIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop"

    func perform() async throws -> some IntentResult {
        // Same signal the keyboard's mic button already posts when phase == .capturing.
        // If the phase 7 discuss-phase decision is "stop = full disarm", this instead needs
        // a new Signal case — see Open Questions before implementing.
        DarwinChannel()!.post(.captureStop)
        return .result()
    }
}
```
```swift
// Inside the widget's DynamicIsland expanded region or Lock Screen body
Button(intent: StopCaptureIntent()) {
    Label("Stop", systemImage: "stop.fill")
}
```

### Pattern 4: Tying `.update()` Cadence to Real Signals, Not a Timer
**What:** Drive `activity.update(...)` from events that already exist — `SessionCoordinator.phase`
emissions for phase changes, and `CaptureDraft` arrivals (already flowing through
`CaptureCoordinator`'s `transcriptionTask` loop) for word-count updates during `.capturing`. Do
not build a new polling timer; `SessionCoordinator` already has a 2-second heartbeat loop for
`SessionState` — during `.armed` (not `.capturing`), that same cadence is sufficient for the Live
Activity too, since nothing else is changing.
**When to use:** Every phase transition and every draft arrival while capturing.
```swift
// LiveActivityController, observing what AppComposition already exposes
Task { [weak self] in
    guard let self else { return }
    for await phase in session.phase {
        await self.updateActivity(phase: phase)
    }
}
```

### Anti-Patterns to Avoid
- **Importing ActivityKit into `Sources/PikoAudio`:** `SessionCoordinator` is a Swift Package
  target that also targets `.macOS(.v15)` for `swift test` on the dev machine (per
  `Package.swift`). ActivityKit is unavailable on plain macOS. Keep the Activity lifecycle in
  `App/Piko` (an iOS-only Xcode target), not in the cross-platform SPM package.
- **A new polling timer for `.update()` cadence:** the phase stream and draft stream already exist;
  wire to them.
- **Calling `.request()` more than once per armed session:** check `Activity<Attributes>.activities`
  first (Pattern 2) — a duplicate request produces two competing Live Activities.
- **Assuming `context.isStale` handling is optional:** the activitykit skill's review checklist
  explicitly requires it; C6's 4h stale window means real users will see stale content on a long
  idle-armed day.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Live Activity lifecycle | A custom notification-driven "fake Live Activity" via UNNotification | `Activity<Attributes>.request/update/end` | This is exactly what ActivityKit exists for; no substitute renders on the Lock Screen/Dynamic Island |
| Cross-process stop signal | A second IPC mechanism between the widget extension and the app | The existing `DarwinChannel`/`Signal`/App Group mechanism, unchanged | Phase 1/2 already solved this problem and tested it (`PikoBridgeTests`, `KeyboardViewModelTests`); a second mechanism is a second thing to keep in sync |
| Foreground detection for starting the Activity | A new `UIApplication.applicationState` check duplicated in `LiveActivityController` | The `isForeground` closure `SessionCoordinator` already receives and gates `arm()` on | One source of truth for "are we allowed to do the foreground-only thing" |
| Update cadence timer | `Timer`/`DispatchSourceTimer` polling loop | The existing `phase: AsyncStream<SessionPhase>` and `CaptureDraft` arrival events | Both streams already exist and already fire exactly when state actually changes |

**Key insight:** every piece Phase 7 needs except the ActivityKit calls themselves and the widget
view already exists in the codebase in some form (IPC, foreground check, phase stream, draft
stream). This phase is almost entirely wiring, not new mechanism design — except for the three
findings in the Summary, which are real gaps, not just wiring.

## Common Pitfalls

### Pitfall 1: `PikoAttributes` Unreachable From the Container App
**What goes wrong:** `App/Piko` cannot `import App/PikoWidgets` — app-extension targets are not
generally importable modules the way SPM library products are (unlike `PikoKit`, `PikoUI`, etc.,
which `project.yml` explicitly lists as `products:` both targets depend on). Writing
`Activity<PikoAttributes>.request(...)` in `App/Piko/AppComposition.swift` today would not
compile.
**Why it happens:** The scaffold was written attributes-first without yet deciding which module
owns the shared type, per its own `// TODO(spike 4)` marker.
**How to avoid:** Move `PikoAttributes`/`ContentState` into `PikoKit` (simplest — zero new
`Package.swift` targets, but needs a `#if canImport(ActivityKit)` guard since `PikoKit` also
targets macOS) or into a new small SPM target following the `PikoCaptureCore`/`PikoKeyboardCore`
convention already established in this repo (cleaner platform separation, one more target to
maintain). Both are legitimate; this needs one line in CONTEXT.md, not a silent pick.
**Warning signs:** A build error citing "cannot find type 'PikoAttributes' in scope" in any file
under `App/Piko/`.

### Pitfall 2: Missing `Hashable` Conformance
**What goes wrong:** `ActivityAttributes` requires `Self: Codable, Hashable`; its `ContentState`
requires the same. `PikoAttributes.skin: Skin` and `ContentState.phase: SessionPhase` are both
currently `enum ...: String, Codable, Sendable, CaseIterable` — no `Hashable`. Struct-level
`Hashable` synthesis fails silently at the point of use (not at the enum's own declaration) with a
"type does not conform to protocol 'Hashable'" error on `PikoAttributes`/`ContentState`
themselves.
**Why it happens:** `SessionPhase` and `Skin` were defined for `Codable` cross-process transport
(Phase 1), before Live Activity's additional `Hashable` requirement was relevant.
**How to avoid:** Add `Hashable` to both enum declarations in `Sources/PikoKit/Contracts.swift`.
Trivial for `String`-raw-value, no-associated-value enums — the compiler synthesizes it once
declared.
**Warning signs:** Build failure the moment `PikoAttributes`/`ContentState` is used in a real
`ActivityConfiguration`/`Activity.request` call, not before.

### Pitfall 3: No `@main` Entry Point in the Widget Extension
**What goes wrong:** `App/PikoWidgets` currently contains exactly three files:
`PikoLiveActivity.swift` (the attributes model), `Info.plist`, and `PikoWidgets.entitlements`.
There is no `@main struct ...: WidgetBundle` — WidgetKit extensions require exactly one. Without
it, the extension has no entry point and will not load.
**Why it happens:** Only the data model was scaffolded (per the file's own `// TODO(spike 4): the
widget itself`).
**How to avoid:** Add a `PikoWidgetsBundle.swift` with `@main struct PikoWidgetsBundle: WidgetBundle
{ var body: some Widget { PikoLiveActivityWidget() } }`.
**Warning signs:** The widget extension target builds but never appears/registers on the
Simulator/device.

### Pitfall 4: `App/PikoWidgets`'s `Info.plist` and `project.yml` Are Missing `CFBundleDisplayName`
**What goes wrong:** `App/project.yml`'s `PikoWidgets` target `info.properties` (and the
generated `App/PikoWidgets/Info.plist`) do not set `CFBundleDisplayName`, unlike `PikoKeyboard`'s
target, which explicitly sets `CFBundleDisplayName: Piko`. This exact class of bug ("nested bundle
ID under `dev.piko.Piko.*` plus missing `CFBundleDisplayName`") has already caused Simulator
install failures twice for other extensions per this project's own history.
**Why it happens:** The `PikoWidgets` target block in `project.yml` was added before this pattern
was learned from the keyboard extension's fixes.
**How to avoid:** Add `CFBundleDisplayName: Piko` (or a widget-specific display name) to
`App/project.yml`'s `PikoWidgets.info.properties`, then re-run `xcodegen generate` so
`App/PikoWidgets/Info.plist` picks it up. Verify `PRODUCT_BUNDLE_IDENTIFIER:
dev.piko.Piko.PikoWidgets` (already correctly nested, matching the working `PikoKeyboard`
pattern) is unaffected.
**Warning signs:** App fails to install on Simulator with no obviously-related error message —
matches the description of the two prior incidents.

### Pitfall 5: Update Cadence Cannot Be Proven on Simulator
**What goes wrong:** Simulator Live Activity behavior (background update delivery cadence,
throttling) is documented by this project as unreliable
(`docs/WORKING-AGREEMENT.md`: "A Simulator result is not a device result for ... Live Activity
cadence"), and Spike 4 ("at least one visible update per second sustained... measure the real
cadence and whether the system throttles") has never been run.
**Why it happens:** ActivityKit's actual background delivery throttling behavior is an OS
implementation detail not fully specified in public docs, and Simulator's WidgetKit/ActivityKit
host process differs from device.
**How to avoid:** Do not claim LACT-01/LACT-02 fully verified from Simulator observation alone.
Build the code so it is correct by construction (drive updates from real events, not a guessed
timer), then flag device cadence verification as a `VERIFICATION.md` gap — same pattern already
used for Phase 3's Back Tap/Action Button and 45-minute soak.
**Warning signs:** A plan or summary that reports "Live Activity updates smoothly" based on
Simulator testing alone.

### Pitfall 6: `ContentState` Must Stay Small
**What goes wrong:** The entire `ContentState` struct is serialized on every `.update()` call and
(if push were ever added later) every push payload. `levels: [Int]` at 8 entries plus `words: Int`
plus `phase` is already appropriately small — the risk is scope creep (e.g., adding a full
transcript string) during implementation.
**Why it happens:** It's tempting to pass more context through once the plumbing exists.
**How to avoid:** Keep `ContentState` exactly as scaffolded (`phase`, `words`, `levels`) unless a
success criterion requires more.
**Warning signs:** A diff that adds a `String` transcript field to `ContentState`.

## Code Examples

### Full ActivityConfiguration Skeleton (widget target)
```swift
// Source: activitykit skill, adapted to PikoAttributes
import ActivityKit
import WidgetKit
import SwiftUI
import PikoKit
import PikoUI

struct PikoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PikoAttributes.self) { context in
            HStack {
                PikoFace(phase: context.state.phase, skin: context.attributes.skin)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading) {
                    Text(context.state.phase.label)
                    if context.state.phase == .capturing {
                        Text("\(context.state.words) words").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(intent: StopCaptureIntent()) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
            }
            .padding()
            .opacity(context.isStale ? 0.5 : 1)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    PikoFace(phase: context.state.phase, skin: context.attributes.skin)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: StopCaptureIntent()) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            } compactLeading: {
                PikoFace(phase: context.state.phase, skin: context.attributes.skin)
                    .frame(width: 20, height: 20)
            } compactTrailing: {
                Text(context.state.phase.label).font(.caption2)
            } minimal: {
                PikoFace(phase: context.state.phase, skin: context.attributes.skin)
                    .frame(width: 16, height: 16)
            }
        }
    }
}

@main
struct PikoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PikoLiveActivityWidget()
    }
}
```

### Word Count / Levels Population (pure function, testable on macOS)
```swift
// Lives wherever LiveActivityController lives; no ActivityKit import needed for this function
// itself — keep it pure so it can be unit tested without a real Activity.
func contentState(for phase: SessionPhase, draft: CaptureDraft?) -> PikoAttributes.ContentState {
    let words = draft?.text.split(separator: " ").count ?? 0
    // Placeholder — not a stated success criterion. A flat mid-level bucket set communicates
    // "something is happening" without claiming real amplitude data.
    let levels = phase == .capturing ? Array(repeating: 5, count: 8) : Array(repeating: 0, count: 8)
    return PikoAttributes.ContentState(phase: phase, words: words, levels: levels)
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Deprecated `contentState:`-only `Activity.request` overload | `ActivityContent<State>`-based `request`/`update`/`end` | iOS 16.2+ | Project's iOS 26 floor means only the `ActivityContent` API should ever be used — no legacy overload needed |
| Plain `AppIntent` for widget-fired Live Activity actions | `LiveActivityIntent` | iOS 17.0+ | Confirmed via direct fetch this session; grants the documented foreground exception (C5) for actions that start/modify/end a Live Activity |
| Manual push-token bookkeeping for cadence | App-driven local `.update()` calls (no push) | N/A for this project | Piko has no server; push-to-update/push-to-start are architecturally out of scope, not a maturity gap |

**Deprecated/outdated:** none directly relevant — this is a from-scratch implementation against
current APIs, not a migration.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `LiveActivityIntent`'s foreground-exception behavior (launches the app process without opening/foregrounding it, per its own doc text) actually satisfies CONSTRAINTS.md C5 for the STOP case, not just the "start a Live Activity" case its doc text emphasizes | Standard Stack / Pattern 3 | If wrong, the stop button might require `openAppWhenRun = true` like `ArmSessionIntent` (visible foreground flash on every stop tap) — worth a Spike-4-style device check, not just code review |
| A2 | Reusing `Signal.captureStop` for the Live Activity stop button is correct, vs. LACT-02 actually wanting full disarm | Summary / Pitfall discussion | If wrong, plan must add a new `Signal` case (e.g. `.sessionEnd`) and wire `CaptureCoordinator`/`SessionCoordinator` to handle it — a real scope difference, not a naming nit. See Open Questions. |
| A3 | Moving `PikoAttributes` into `PikoKit` (vs. a new dedicated target) is the lower-cost option | Alternatives Considered | If `PikoKit`'s macOS target build breaks under `#if canImport(ActivityKit)` guarding in some Xcode/SPM edge case, the dedicated-target option becomes the fallback — flagged, not silently chosen |
| A4 | App-driven `.update()` calls (no push) remain reliable for the full 8-hour active window without the app process being killed by the OS during a long idle-armed period | Pitfall 5 / Architecture | This is exactly Spike 4's unresolved question — flagged as LOW confidence pending device measurement, not assumed to work |

## Open Questions

1. **Does the stop button end the capture (return to `.armed`) or the whole session (`.idle`,
   Activity ended)?**
   - What we know: Phase Goal says "stop an in-progress capture" (matches existing
     `.captureStop` semantics exactly — this is what the keyboard's stop button already does).
     Success Criterion 2 says "ends the session reliably" (reads as full disarm).
   - What's unclear: These are two different scopes with two different implementations. If it's
     "return to armed," the Live Activity keeps running afterward showing `.armed`. If it's "full
     disarm," the Live Activity should also be ended (`.end()`), and a new `Signal` case is
     needed since none currently signals "disarm" cross-process (only `.captureStart`/
     `.captureStop` exist).
   - Recommendation: Resolve in `/gsd:discuss-phase` before planning, not by guessing in code. The
     phase's own Goal text is the stronger signal ("stop an in-progress capture"), suggesting
     reuse of `.captureStop` unchanged is correct and the Success Criterion wording is loose
     paraphrase rather than a distinct requirement — but this is exactly the kind of ambiguity the
     working agreement says to surface with options, not silently pick.

2. **Does `LiveActivityIntent`'s documented foreground exception cover stopping an activity, or
   only starting one?**
   - What we know: The official doc text ("To gain permission for starting Live Activities,
     conform to this protocol... you can use a LiveActivityIntent and start the Live Activity in
     its perform() method") emphasizes the *starting* case. The protocol's stated purpose line
     ("An intent that starts, pauses, or otherwise modifies a Live Activity") is broader than the
     body text's examples.
   - What's unclear: Whether an intent that only *ends*/*modifies* an already-running activity
     (this project's stop button never starts one) needs the same conformance, or whether a plain
     `AppIntent` would work identically for that narrower case since C5's actual constraint is on
     `Activity.request()` specifically, not on posting a Darwin notification.
   - Recommendation: Use `LiveActivityIntent` regardless — it is a strict superset of what a plain
     `AppIntent` provides for this use case (per the protocol's own broader purpose statement,
     "or otherwise modifies"), costs nothing extra, and is the more conservative choice if the
     assumption in question 1 above turns out to matter. Verify actual dismiss behavior with a
     physical-device tap once implemented (see Environment Availability).

3. **Should `LiveActivityController` be a new type, or should its logic live directly in
   `AppComposition`?**
   - What we know: `AppComposition` is already described as "the one place PikoBridge and
     PikoAudio meet" and is a small, flat composition root today.
   - What's unclear: Whether adding Live Activity lifecycle logic directly to
     `AppComposition.init()`/a few methods is simpler than a new dedicated type, given the phase's
     overall size (two requirements, mostly wiring).
   - Recommendation: Claude's discretion at plan time — either is architecturally sound; a
     dedicated type is slightly more testable in isolation (mockable `Activity` boundary) but
     adds one more file for a phase this small. Not worth a CONTEXT.md decision; just decide and
     note the reasoning in the plan.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| ActivityKit framework | Activity lifecycle | iOS 26+ SDK (Simulator + device) | N/A — ships with SDK | None needed; framework always present on this deployment target |
| WidgetKit framework | Widget/DynamicIsland rendering | iOS 26+ SDK | N/A | None needed |
| Physical iPhone (Dynamic-Island-equipped, e.g. 14 Pro+, for full DI regions) | Verifying compact/expanded/minimal DI presentation and real update cadence | Not confirmed this session — no device inventory available to this research pass | — | Lock Screen presentation (all devices) can be verified on Simulator; DI-specific regions and background cadence cannot per `docs/WORKING-AGREEMENT.md` |
| `xcodegen generate` re-run after `project.yml` edit (Pitfall 4 fix) | Producing a correct `Info.plist` for `PikoWidgets` | Assumed available (used to generate the existing `.xcodeproj`) — not re-verified this session | — | None; this is a required step, not optional |

**Missing dependencies with no fallback:**
- None that block writing the code. Device cadence/DI-region verification has no Simulator
  fallback and must be recorded as a `VERIFICATION.md` gap, matching Phase 3's pattern.

**Missing dependencies with fallback:**
- Full Dynamic Island region testing → Lock Screen testing works on Simulator as a partial
  substitute for layout (not cadence).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (project convention throughout) |
| Config file | `Package.swift` testTarget list |
| Quick run command | `swift test --filter <NewTestTarget>` (see Wave 0 Gaps) |
| Full suite command | `swift test` (macOS-buildable parts); `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,...'` for `#if os(iOS)`-only code |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| LACT-01 | `contentState(for:draft:)` (or equivalent pure function) produces correct `phase`/`words`/`levels` for each `SessionPhase` | unit | `swift test --filter <NewTestTarget>` | ❌ Wave 0 |
| LACT-01 | `SessionPhase`/`Skin` gained `Hashable` without breaking existing `Codable` round-trip tests | unit (regression) | `swift test --filter PikoKitTests` | ✅ existing target, needs new assertions |
| LACT-02 | `StopCaptureIntent.perform()` posts `Signal.captureStop` (or the decided signal) via `DarwinChannel` | unit/integration | `swift test --filter <NewTestTarget>` (mirrors `KeyboardViewModelTests`' existing pattern of asserting on posted signals) | ❌ Wave 0 |
| LACT-01, LACT-02 | Actual Live Activity request/update/end lifecycle, Dynamic Island rendering, stop button tap-to-signal round trip on a real device | manual (device) | none — no Simulator/CI equivalent | N/A — flag in `VERIFICATION.md` |

### Sampling Rate
- **Per task commit:** the focused `swift test --filter` command for whatever pure logic that
  task added
- **Per wave merge:** full `swift test` (macOS-buildable parts) plus a best-effort
  `xcodebuild build -scheme Piko -sdk iphonesimulator` to catch the `App/PikoWidgets`/`App/Piko`
  compile errors that `swift test` alone cannot see (ActivityKit/WidgetKit code isn't part of the
  SPM package)
- **Phase gate:** both of the above, plus the physical-device checklist below, recorded in
  `07-VALIDATION.md`/`VERIFICATION.md` per this project's established pattern (Phase 3, Phase 6)

### Wave 0 Gaps
- [ ] A new test target (or file added to an existing macOS-buildable target, e.g. `PikoKitTests`)
      covering `contentState(for:draft:)`-equivalent pure logic and `StopCaptureIntent`'s signal
      posting — following the `PikoCaptureCore`/`PikoKeyboardCore` pattern of extracting
      UI-extension-only logic into an SPM-testable target if `StopCaptureIntent`'s file itself
      cannot compile on macOS (it likely can — `AppIntents` + `PikoBridge` have no iOS-only
      dependency, only the actual `Activity` calls do)
- [ ] `PikoKitTests` gains explicit `Hashable`/`Equatable` regression coverage for `SessionPhase`
      and `Skin` after the conformance is added, to prevent silent regression

## Security Domain

> Phase 7 introduces no authentication, new network surface, or cryptography. The stop button is
> a new externally-triggerable entry point into session state, which is the one item worth a
> STRIDE pass.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | partial | The stop signal must only be actionable by this app's own widget extension (App Group-scoped Darwin notification, already unforgeable cross-app by construction — Darwin notification names are process-wide but the payload files live in an App-Group-restricted container only this app's targets can write) |
| V4 Access Control | no | Same App Group boundary as every other cross-process signal already in this codebase |
| V5 Input Validation | no | The Live Activity displays only data this app itself produced (`CaptureDraft.text` word count, phase enum) — no untrusted external input enters through this surface |
| V6 Cryptography | no | — |

### Known Threat Patterns for This Phase

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Lock Screen content exposure — `ContentState` is visible without unlocking the device | Information Disclosure | `ContentState` already contains no transcript text, only phase/word-count/level buckets (per Pitfall 6's "keep it small" guidance) — do not add the raw or shipped transcript to it |
| A stale/duplicate `Activity<PikoAttributes>` left running after a crash, showing incorrect state indefinitely | Denial of Service (UX) | `Activity<Attributes>.activities` check at launch (Pattern 2) plus always calling `.end()` on every disarm path, matching the activitykit skill's "end in all terminal paths" checklist item |
| Malformed/replayed Darwin notification triggering `StopCaptureIntent`'s `perform()` from outside this app | Spoofing | Darwin notifications carry no payload and no sender identity by design (already true of every existing `Signal`); this is an accepted, pre-existing property of the chosen IPC mechanism, not a new risk introduced by this phase — posting `.captureStop` early/spuriously has no worse effect than a user tapping the keyboard's own stop button unexpectedly, which the existing `CaptureCoordinator.handleSignal` already handles safely (stops capture, writes a result) |

## Sources

### Primary (HIGH confidence)
- [`activitykit` skill](file:///Users/sunny/.vscode/agent-plugins/github.com/dpearson2699/swift-ios-skills/skills/activitykit/SKILL.md) — sourced from developer.apple.com per its own frontmatter; used for `Activity.request/.update/.end`, `ActivityContent`, `ActivityConfiguration`, `DynamicIsland` region API, stale-date handling, review checklist
- [developer.apple.com/documentation/appintents/liveactivityintent](https://developer.apple.com/documentation/appintents/liveactivityintent) — fetched directly this session; confirms the protocol exists, its inheritance (`SystemIntent`), and its documented purpose/foreground-exception behavior
- `app-intents` skill (`swift-ios-skills` plugin) — `AppIntent` protocol shape, `@Parameter`, `Button(intent:)` usage pattern, consistent with the project's existing `ArmSessionIntent.swift`
- Project docs: `docs/CONSTRAINTS.md` (C5, C6), `docs/ARCHITECTURE.md` (process table, module graph, latency-path diagram), `docs/SPIKES.md` (Spike 4 definition and not-run status), `docs/WORKING-AGREEMENT.md` (Simulator-vs-device honesty rule), `docs/TOOLING.md` (skill inventory)
- Direct source reading (this session): `App/PikoWidgets/PikoLiveActivity.swift`, `Sources/PikoKit/Contracts.swift`, `Sources/PikoKit/Protocols.swift`, `Sources/PikoBridge/DarwinChannel.swift`, `Sources/PikoAudio/SessionCoordinator.swift`, `App/Piko/AppComposition.swift`, `App/Piko/ArmSessionIntent.swift`, `App/Piko/CaptureCoordinator.swift`, `App/project.yml`, `App/PikoWidgets/Info.plist`, `App/PikoKeyboard/Info.plist`, `Package.swift`, `Tests/PikoKeyboardTests/KeyboardViewModelTests.swift` — confirms Pitfalls 1–4 and the `Signal`/`DarwinChannel` reuse pattern as verified facts about this codebase, not assumptions

### Secondary (MEDIUM confidence)
- Reasoning about `LiveActivityIntent` applicability to the *stop* case specifically (vs. its
  documented *start* case) — see Assumptions Log A1 and Open Question 2
- Reasoning about which module should own `PikoAttributes` — both options in Alternatives
  Considered are sound; the recommendation is a judgment call, not a verified requirement

### Tertiary (LOW confidence)
- Real-world `.update()` cadence and OS throttling behavior during a long idle-armed period
  (Assumption A4, Pitfall 5) — genuinely unknown until Spike 4 is run on a physical device; public
  documentation does not fully specify ActivityKit's background delivery throttling behavior

## Metadata

**Confidence breakdown:**
- ActivityKit/WidgetKit/AppIntents API surface: HIGH — sourced from the activitykit skill (itself
  citing developer.apple.com) plus a direct fetch of the `LiveActivityIntent` doc page this
  session; no API signature in this document was invented from training-data memory
- Codebase-specific findings (Pitfalls 1–4, the `.captureStop` reuse pattern): HIGH — verified by
  direct reading of the actual source files, not inferred
- Cross-process stop-signal semantics (full disarm vs. stop-capture-only): MEDIUM — a real
  ambiguity in the phase's own requirement text, correctly flagged rather than resolved by
  guessing
- Live Activity real-world cadence/background reliability: LOW — matches this project's own
  documented position (`docs/WORKING-AGREEMENT.md`, `docs/SPIKES.md` Spike 4 not-run) that
  Simulator cannot prove this and no device run has happened yet

**Research date:** 2026-08-30
**Valid until:** 30 days (stable first-party APIs; re-check if Xcode/iOS SDK version changes before
planning is acted on)
