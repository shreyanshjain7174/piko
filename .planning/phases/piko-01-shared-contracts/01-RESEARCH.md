# Phase 1: Shared Contracts - Research

**Researched:** 2026-08-27
**Domain:** Swift Package Manager shared types, App Group cross-process constants, Swift 6.2 strict concurrency
**Confidence:** HIGH

## Summary

The phase goal is largely **already met** by the existing skeleton. `Sources/PikoKit/Contracts.swift`
and `Protocols.swift` define `AppGroup`, `Signal`, `SessionPhase`, `SessionState`, `CaptureDraft`,
`Route`, `CaptureResult`, `EditPair`, `Profile`, `Skin`, `SessionChannel`, `Transcriber`, `Brain`,
`Memory`, and `PikoError` — all matching `docs/SPEC.md`'s contract almost exactly, all `Codable`
and `Sendable`, all with zero non-Foundation imports. `swift build` and `swift test` both pass
right now on this machine (macOS host, Swift 6.2 toolchain) `[VERIFIED: ran in repo this session]`.

**Primary recommendation:** This phase's plan should be framed as **verify, harden, and fill
gaps** rather than "build from scratch": (1) add the notification-name pairing the keyboard
target actually needs (Darwin notifications, not just the `Signal` enum, since `Signal` alone
carries no cross-process delivery mechanism — see Pitfall below), (2) add a `swift build` for a
non-Apple platform (or at minimum confirm the macOS build already proves the "Foundation-only"
property), and (3) confirm `PikoKitTests` explicitly exercises Codable round-trips and Sendable
usage across a `Task` boundary for every cross-process type, not just two of them.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Cross-process type definitions | PikoKit (shared package target) | — | Single source of truth per SPEC.md; no platform tier owns this, it's pure data |
| App Group identifier + file names | PikoKit (constant) | App/Piko, App/PikoKeyboard entitlements | Constant lives once in code; entitlement *string* must match by hand in each target's `.entitlements` file (SPM cannot write entitlements) |
| Darwin notification names | PikoKit (constant, `Signal` enum) | PikoBridge (actual `CFNotificationCenter` calls) | Names must be shared; the *posting/observing* mechanism is out of scope for this phase (that's Phase 2 / PikoBridge) |
| Compile-time API-extension-safety | PikoKit source (Foundation-only) | App target build settings (`APPLICATION_EXTENSION_API_ONLY`) | PikoKit enforces it by never importing UIKit; project.yml should still set the extension-safety flag as defense in depth |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Foundation | ships with Swift 6.2 toolchain | `Codable`, `Date`, `UUID`, `AsyncStream` | Only dependency permitted per SPEC.md and CONSTRAINTS |
| Swift Testing | ships with Xcode 26 / Swift 6.2 | `@Test`, `#expect` | Already in use in `Tests/PikoKitTests/ContractTests.swift`; project skill `swift-testing` confirms this is current Apple-recommended default over XCTest for new packages |

No third-party packages are needed or appropriate for this phase — `Package.swift` has zero
`dependencies:` entries and the phase goal explicitly forbids adding any.

### Supporting
None. This phase has no supporting libraries by design (SPEC.md: "Types and protocols only, no
platform APIs, no dependencies").

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) for cross-process signal | `NSUbiquitousKeyValueStore`, App Group `NSFileCoordinator` + `NSFilePresenter` | Darwin notifications are the standard low-latency (sub-ms) mechanism for "something changed" signaling between App Group siblings; file coordination is heavier and is for the payload, not the signal. This phase only needs to define the *names* — the transport is Phase 2 (PikoBridge) scope. |
| `UserDefaults(suiteName:)` for state | Raw JSON files in the App Group container (current skeleton approach: `draft.json`, `result.json`, `state.json`) | Either works for `Codable` payloads. File-based avoids `UserDefaults` plist-size and type-coercion quirks and gives an explicit atomic-write point (`NSFileCoordinator`) for the ~120ms round-trip budget in BRDG-02. The skeleton's `AppGroup.draftFile` / `resultFile` / `stateFile` naming already commits to the file-based approach — this is a Phase 2 decision, not Phase 1's, but Phase 1's constants must support whichever Phase 2 picks (they already do, since file names are already there). |

No installation needed.

## Package Legitimacy Audit

Not applicable — this phase adds zero external packages (Foundation is part of the toolchain,
not a registry dependency).

## Architecture Patterns

### System Architecture Diagram

```
                    ┌─────────────────────────────────────────┐
                    │              PikoKit (Foundation only)   │
                    │                                           │
                    │  AppGroup (identifier, file names)        │
                    │  Signal (Darwin notification name enum)   │
                    │  SessionPhase / SessionState              │
                    │  CaptureDraft / CaptureResult / EditPair   │
                    │  Route / Profile / Skin                   │
                    │  SessionChannel / Transcriber / Brain /    │
                    │    Memory  (protocols only, no impl)       │
                    └───────────────┬───────────────────────────┘
                                    │  import PikoKit
                     ┌──────────────┼───────────────────┐
                     ▼                                  ▼
        ┌─────────────────────────┐      ┌───────────────────────────┐
        │  App/Piko (container)    │      │  App/PikoKeyboard (ext.)   │
        │  full platform access    │      │  ~60MB ceiling, no audio,  │
        │  implements protocols    │      │  no model — reads/writes   │
        │                          │      │  PikoKit types only        │
        └─────────────────────────┘      └───────────────────────────┘
```

A reader can trace: PikoKit defines the vocabulary → both targets import it → neither target
defines its own copy → the App Group identifier constant is the one thing that must also be
typed correctly (by hand, not by code sharing) into each target's `.entitlements` file, since
SPM has no mechanism to generate Xcode entitlements.

### Recommended Project Structure
Already matches SPEC.md — no changes needed:
```
Sources/PikoKit/
├── Contracts.swift   # AppGroup, Signal, SessionPhase, SessionState, CaptureDraft,
│                     #   Route, CaptureResult, EditPair, Profile, Skin
└── Protocols.swift   # SessionChannel, Transcriber, Brain, Memory, PikoError
Tests/PikoKitTests/
└── ContractTests.swift
```

### Pattern 1: App Group identifier + Darwin notification names as a single enum namespace
**What:** `public enum AppGroup { public static let identifier = "..." }` and
`public enum Signal: String, Sendable, CaseIterable { case captureStart = "dev.piko.capture.start" ... }`
**When to use:** Any constant that both processes must agree on byte-for-byte. Using `enum` (not
`struct`) with only `static let` members prevents accidental instantiation and keeps the
namespace un-instantiable — idiomatic Swift for "this is a namespace, not a value."
**Example (current code, already correct):**
```swift
// Source: Sources/PikoKit/Contracts.swift (this repo)
public enum AppGroup {
    public static let identifier = "group.dev.piko.shared"
    public static let draftFile = "draft.json"
}
public enum Signal: String, Sendable, CaseIterable {
    case captureStart = "dev.piko.capture.start"
}
```
`[VERIFIED: read from repo]`

### Pattern 2: Codable + Sendable value types for cross-process payloads
**What:** Every cross-process type (`SessionState`, `CaptureDraft`, `CaptureResult`, `EditPair`)
is a `struct` conforming to `Codable, Sendable, Equatable`, with all stored properties themselves
`Sendable` (`String`, `Int`, `Date`, `UUID`, other `Codable & Sendable` structs/enums). This is
the correct Swift 6.2 shape: value-type structs with only `Sendable` members get **implicit**
`Sendable` conformance from the compiler, but declaring it explicitly (as the skeleton does) is
still recommended because it (a) documents intent, (b) causes a compile error immediately if a
future edit adds a non-Sendable stored property, rather than silently losing the conformance.
`[ASSUMED — standard Swift 6 strict-concurrency guidance; not independently re-verified against
a dated WWDC26 session this pass, but consistent with SE-0302/SE-0337 Sendable rules and the
project's own `SWIFT_STRICT_CONCURRENCY: complete` setting in `App/project.yml`]`
**When to use:** Any type that crosses the App Group boundary (written by one process, read by
another as raw bytes/JSON) or crosses an `async`/`Task` boundary within a single process.
**Example (current code, already correct):**
```swift
// Source: Sources/PikoKit/Contracts.swift (this repo)
public struct CaptureDraft: Codable, Sendable, Equatable {
    public var sequence: Int
    public var text: String
    public var stablePrefix: Int
    public var startedAt: Date
}
```

### Pattern 3: Enums for closed cross-process vocabularies
**What:** `SessionPhase`, `Route`, `Profile`, `Skin` are all `Codable, Sendable` enums (three are
`String`-raw-valued, `CaseIterable`). Raw-string enums are the right choice here specifically
*because* the value crosses a JSON boundary — a raw-value enum's `Codable` synthesis serializes
as the string, which is stable across app/extension rebuilds even if enum case *order* changes
(unlike a bare `Int`-backed enum, where reordering cases would silently break already-serialized
data — not a concern yet since there's no persisted history in Phase 1, but worth being
deliberate about now since `CaptureResult` will be persisted by `PikoMemory` in Phase 8).
**When to use:** Any fixed, closed set of cross-process states.

### Anti-Patterns to Avoid
- **Classes for cross-process payloads:** A `class` conforming to `Sendable` requires either
  `final` + all-immutable-`let` stored properties, or manual unchecked conformance — strictly
  worse than a `struct` here with no upside. The skeleton correctly uses `struct` throughout.
- **`NSObject`/`@objc` bridging in PikoKit:** Would pull in Foundation's Objective-C runtime
  dependency surface unnecessarily and has no benefit for pure-Swift cross-process JSON. Not
  present in the current skeleton — keep it that way.
- **Putting the Darwin-notification *posting* mechanism in PikoKit:** `CFNotificationCenter` calls
  belong in `PikoBridge` (Phase 2), not `PikoKit`. PikoKit should only ever hold the *names*
  (`Signal` raw values), never the transport code — mixing the two would blur the module boundary
  the roadmap explicitly protects ("Modules and their single-purpose contracts are fixed... do
  not blur module boundaries").

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON encode/decode for cross-process payloads | Custom string serialization | `Codable` + `JSONEncoder`/`JSONDecoder` (already used in `ContractTests.swift`) | Handles `Date`/`UUID` formatting, versioning-tolerant decode, zero extra dependency |
| "Is this session still alive" staleness check | Ad-hoc timestamp math scattered across call sites | `SessionState.isLive(now:tolerance:)` (already implemented as a method on the type) | Keeps the staleness rule in one place — PikoKit — so the app and keyboard can never disagree on the tolerance window |
| Namespacing constants | Global top-level `let` constants | `enum` namespace with `static let` (already the pattern used) | Prevents instantiation, gives autocomplete grouping, matches Swift API design guidelines for non-instantiable namespaces |

**Key insight:** Every "don't hand-roll" risk for this phase is already avoided in the skeleton.
The main risk going forward is *scope creep* — adding a platform import (e.g. reaching for
`UIKit.UIPasteboard` or `os.log` with subsystem-specific APIs) into PikoKit during a later phase
because it's convenient, silently breaking the "compiles for macOS too" guarantee.

## Common Pitfalls

### Pitfall 1: `Signal` enum alone does not deliver cross-process notifications
**What goes wrong:** A future contributor sees `Signal.captureStart` and assumes posting/observing
"just works" because the type exists. `Signal` is only the *name* — nothing in PikoKit posts a
Darwin notification. That plumbing is explicitly out of scope (`PikoBridge`, Phase 2).
**Why it happens:** The enum's presence in `PikoKit` reads like a complete feature.
**How to avoid:** The Phase 1 plan/verification step should assert (via a doc comment already
present, or a test) that `PikoKit` contains no `CFNotificationCenter`/`DistributedNotificationCenter`
calls — i.e., confirm the boundary, not just confirm the names exist.
**Warning signs:** Any `import Darwin` or `CFNotificationCenterGetDarwinNotifyCenter` appearing
inside `Sources/PikoKit/`.

### Pitfall 2: App Group identifier string must match by hand in three places
**What goes wrong:** `AppGroup.identifier` in code, and the `com.apple.security.application-groups`
entitlement value in `App/Piko/Piko.entitlements`, `App/PikoKeyboard/PikoKeyboard.entitlements`,
and `App/PikoWidgets/PikoWidgets.entitlements` are four independent strings today. SPM cannot
generate or check Xcode entitlement files. A typo in any entitlement (already correctly matching
`group.dev.piko.shared` in the current `App/project.yml`) silently breaks cross-process
communication with no compile-time signal — it fails at runtime with a permissions error.
**Why it happens:** Entitlements live in `.entitlements` plist files generated by `project.yml`
(XcodeGen), which SPM's `Package.swift` cannot see or validate.
**How to avoid:** This phase's verification step cannot fully close this gap (it's an XcodeGen /
Xcode-project concern, arguably Phase 2's problem when the bridge is wired up), but the plan
should at minimum note the string must be kept in sync, and ideally the test suite or a doc
comment on `AppGroup.identifier` should point at `App/project.yml` as the place it's mirrored.
`[VERIFIED: confirmed all three entitlements plus AppGroup.identifier already match, by reading
App/project.yml and Sources/PikoKit/Contracts.swift this session]`

### Pitfall 3: Confusing "zero dependencies" with "zero risk of platform leakage"
**What goes wrong:** `Package.swift` declares no `dependencies:` array entries for `PikoKit`
(true today), but a contributor could still `import UIKit` or `import os` with an iOS-only API
directly in a `.swift` file without adding a package dependency — Foundation itself exposes some
platform-conditional APIs. "No dependencies" (Package.swift) and "no platform APIs" (import
statements) are two different guarantees and both must be checked.
**Why it happens:** SPM's dependency graph only tracks package-level dependencies, not import
statements within a target's own sources.
**How to avoid:** See Step 4 verification approach below — building for a second platform
(macOS, already declared in `Package.swift`) is a real compiler-enforced check for *some* platform
leakage (anything UIKit-only won't compile on macOS) but does not catch iOS-only Foundation APIs
that also happen to exist on macOS. A `grep -rn '^import ' Sources/PikoKit/` check for anything
beyond `Foundation` is the more precise net.

## Code Examples

### Verifying "Foundation only" at both grep and compiler level
```bash
# Source: verified by running in this repo, this session
grep -rn '^import ' Sources/PikoKit/
# → only "import Foundation" in both files, confirmed today

swift build --sdk macosx   # or plain `swift build` on this macOS host
# → Build complete! (already passes today; Package.swift declares .macOS(.v15)
#    as a package-wide platform, so this is a real, already-working check —
#    not a hypothetical one)
```

### Codable round-trip test pattern (extend the existing one to all six types)
```swift
// Source: Tests/PikoKitTests/ContractTests.swift (existing pattern in this repo)
@Test("drafts survive a round trip")
func draftCoding() throws {
    let draft = CaptureDraft(sequence: 7, text: "hey can we push it", stablePrefix: 12)
    let data = try JSONEncoder().encode(draft)
    let back = try JSONDecoder().decode(CaptureDraft.self, from: data)
    #expect(back == draft)
}
```
The same pattern should exist for `SessionState`, `CaptureResult`, `EditPair` (currently only
`CaptureDraft` has an explicit round-trip test; `SessionState` has a staleness test but no
Codable round-trip test).

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| XCTest for package tests | Swift Testing (`@Test`, `#expect`) | Default since Xcode 16 / Swift 6, reinforced in Xcode 26 tooling | Already adopted correctly in `ContractTests.swift`; no action needed |
| Manual `Sendable` unchecked conformance | Compiler-checked `Sendable` on plain value types under `SWIFT_STRICT_CONCURRENCY: complete` | Swift 6 language mode (`swift-tools-version: 6.2` in this repo) | The skeleton already builds under strict concurrency; no unchecked conformances present |

**Deprecated/outdated:** Nothing in this phase's scope relies on a deprecated API.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Explicit `Sendable` conformance on structs-of-Sendable-members is best practice (vs. relying on implicit synthesis) in Swift 6.2 | Architecture Patterns, Pattern 2 | Low — worst case is a stylistic nit, not a functional bug; both approaches compile identically today |
| A2 | Darwin notifications (not App Group `NSFilePresenter` or CloudKit) are the intended transport for `Signal` | Alternatives Considered, Pitfall 1 | Low for Phase 1 (transport is Phase 2's decision) — but if wrong, `Signal`'s doc comments should say so before Phase 2 planning locks in a different transport |

## Open Questions

1. **Should `PikoKit` gain a lightweight "extension-safety" CI check beyond the macOS build?**
   - What we know: `swift build` on macOS already fails if UIKit is imported anywhere in
     `PikoKit`, because macOS (non-Catalyst) has no UIKit.
   - What's unclear: Whether that's sufficient, or whether the plan should also add a `grep`-based
     import allowlist test (catches iOS-only Foundation symbols that also compile on macOS, which
     the macOS build alone would not catch).
   - Recommendation: Add both — they're cheap and each catches a different failure mode (see
     Pitfall 3). Leave the final call to the planner/verifier since it's a two-line addition either way.

2. **Does the App Group identifier string need a single-source-of-truth mechanism beyond code +
   manual entitlements?**
   - What we know: `AppGroup.identifier` in `PikoKit` and the three `.entitlements` files in
     `App/project.yml` currently match.
   - What's unclear: Whether Phase 1's plan should add a doc-comment cross-reference (cheap, does
     nothing to prevent drift) versus deferring any tooling to Phase 2 when the bridge starts
     actually depending on the value being correct at runtime.
   - Recommendation: Doc comment now (near-zero cost), defer any generated/validated approach to
     Phase 2 since that's when a wrong value first causes an observable failure.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Swift toolchain | Building/testing PikoKit | ✓ | 6.2 (swiftlang-6.2.0.19.9) | — |
| `swift build` / `swift test` CLI | Verification step | ✓ | confirmed working this session | — |
| Xcode / XcodeGen project (`App/project.yml`) | Confirming both app targets build against PikoKit | Not invoked this session (no `.xcodeproj` generated yet — `project.yml` exists, `xcodegen generate` has not been run) | — | Phase 1 plan can verify via `swift build`/`swift test` alone; full dual-target Xcode build is a reasonable Phase 1 verification step but requires running `xcodegen generate` first if not already part of the repo's setup flow |

**Missing dependencies with no fallback:** None — this phase's verification can be fully
satisfied by SPM CLI tools already confirmed working.

**Missing dependencies with fallback:** Generated `.xcodeproj` (via XcodeGen) is not present yet;
if the plan wants an actual dual-target Xcode build as its verification step (stronger than
`swift build`, since it also proves the app-extension link step succeeds), it needs
`xcodegen generate` run first — reasonable as a Wave 0 setup task, not a blocker.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (bundled with Swift 6.2 toolchain) |
| Config file | none — package test target declared in `Package.swift` (`PikoKitTests`) |
| Quick run command | `swift test --filter PikoKitTests` |
| Full suite command | `swift test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| FOUND-01 | All six cross-process types exist and compile with zero non-Foundation imports | unit + build | `grep -rn '^import ' Sources/PikoKit/ \| grep -v Foundation` (expect empty) then `swift build` | ✅ (types exist); ❌ grep-check script itself — Wave 0 |
| FOUND-01 | Each cross-process type round-trips through `Codable` (JSON) unchanged | unit | `swift test --filter PikoKitTests` | ✅ for `CaptureDraft`; ❌ for `SessionState`, `CaptureResult`, `EditPair` — Wave 0 |
| FOUND-01 | App Group identifier and every `Signal` case are defined exactly once | unit (existence) | `swift test --filter PikoKitTests` (a test asserting `Signal.allCases.count == 5` and identifier non-empty is a cheap regression guard) | ❌ — Wave 0, trivial addition |
| FOUND-01 | Both app target and keyboard-extension target build against PikoKit without duplicating types | build | `xcodegen generate && xcodebuild -project App/Piko.xcodeproj -scheme Piko build` (or the Xcode MCP server's build tool per `docs/TOOLING.md`) | ❌ — requires XcodeGen run first; reasonable Wave 0/plan-execution step, not a blocker |

### Sampling Rate
- **Per task commit:** `swift test --filter PikoKitTests` (sub-second today)
- **Per wave merge:** `swift build && swift test`
- **Phase gate:** Full `swift test` green, plus (if the plan includes the dual-target Xcode build
  as an explicit success-criterion check) a passing `xcodebuild` for both `Piko` and
  `PikoKeyboard` schemes before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] Add `Codable` round-trip tests for `SessionState`, `CaptureResult`, `EditPair` (only
      `CaptureDraft` currently has one; `SessionState` has a staleness test but not a coding test)
- [ ] Add a trivial existence/uniqueness test for `AppGroup` and `Signal` (guards against
      accidental duplication or typo drift)
- [ ] Add an import-allowlist check (grep-based script or a `Tests` case) asserting
      `Sources/PikoKit/*.swift` imports only `Foundation`
- [ ] (Optional, stronger) Run `xcodegen generate` once and confirm `xcodebuild` succeeds for
      both the `Piko` and `PikoKeyboard` schemes, satisfying success criterion #3 from
      ROADMAP.md directly rather than by SPM-build proxy

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No auth surface in this phase — pure type definitions |
| V3 Session Management | No | `SessionState` here is an in-memory/on-disk app-lifecycle concept, not an auth session |
| V4 Access Control | No | No access-control logic in scope |
| V5 Input Validation | Marginal | `Codable` decode of untrusted-in-principle App Group files is the only "input" surface; `JSONDecoder` throwing on malformed data is the standard control, already exercised implicitly by `Codable` conformance |
| V6 Cryptography | No | Nothing is encrypted or signed in this phase; App Group container isolation (OS-level) is the relevant protection and is out of PikoKit's scope |

### Known Threat Patterns for this phase's stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malformed/truncated JSON in an App Group file read by the keyboard extension (e.g., app killed mid-write) causing a crash | Denial of Service | `Codable` decode is already a `throws` API — callers (Phase 2's `PikoBridge`) must catch and treat decode failure as "no draft available," not a crash. Nothing to do in Phase 1 beyond keeping types `Codable` (already true); flag for Phase 2's plan. |
| Enum raw-value drift between app and keyboard binaries built from different commits (e.g., a new `Signal` case added but keyboard extension not rebuilt) | Tampering (data integrity, not malicious) | Single source of truth in `PikoKit` + both targets depending on the same package version at build time (already the architecture: `App/project.yml` points both targets at the same local `Piko` package path) is the mitigation. No additional code needed in Phase 1. |

## Sources

### Primary (HIGH confidence)
- This repository: `Sources/PikoKit/Contracts.swift`, `Protocols.swift`, `Package.swift`,
  `App/project.yml`, `Tests/PikoKitTests/ContractTests.swift`, `docs/SPEC.md`,
  `docs/CONSTRAINTS.md`, `docs/ARCHITECTURE.md` — read directly this session
- `swift build` / `swift test` executed directly in the repo this session (Swift 6.2.0.19.9,
  arm64-apple-macosx26.0 host)

### Secondary (MEDIUM confidence)
- Apple — App Extension Programming Guide (archived, 2018 revision) — general app-extension
  lifecycle/memory/entitlement guidance; confirms the container-app/extension separation model,
  though the document predates SPM-based extension targets and Swift 6 concurrency, so it is not
  authoritative for the SPM-specific questions in this research

### Tertiary (LOW confidence)
- None used — training-data claims about Swift 6 Sendable synthesis rules are marked `[ASSUMED]`
  above rather than presented as verified, since no current Swift Evolution/WWDC26 source was
  fetched to re-confirm them this pass (they are however consistent with the project's own
  passing `swift build` under `SWIFT_STRICT_CONCURRENCY: complete`, which is itself a real
  compiler check, not just a claim).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — verified directly by reading the repo and running the build/test commands
- Architecture: HIGH — matches docs/SPEC.md and docs/ARCHITECTURE.md verbatim, confirmed against actual source
- Pitfalls: MEDIUM — grounded in the repo's real structure (entitlements, project.yml), but the
  SPM/App-Extension interaction claims (Pitfall 3, extension-API-only build settings) are
  reasoned from general Swift/Xcode knowledge rather than a freshly-fetched current-year Apple doc

**Research date:** 2026-08-27
**Valid until:** Effectively indefinite for this phase's narrow scope (pure Swift value types,
no external dependencies to go stale) — re-check only if Swift's Sendable/Codable synthesis rules
change in a future language mode, which is not anticipated within this milestone.
