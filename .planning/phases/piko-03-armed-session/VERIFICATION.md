---
phase: piko-03-armed-session
verified: 2026-08-29T13:20:00Z
status: gaps_found
score: 1/3 must-haves fully verified (2 partially verified, code-complete but device-unverified)
overrides_applied: 0
gaps:
  - truth: "A session can be armed from the container app, Back Tap, and the Action Button"
    status: partial
    reason: "Container-app arming is real and verified by reading (arm() gated on isForeground, wired to a tappable Arm button, AppComposition is the sole construction site). Back Tap/Action Button arming is code-complete (ArmSessionIntent + PikoShortcuts exist, compile, and pass-through to the same arm()) but the actual OS-level binding — does Back Tap/Action Button really invoke this intent, does openAppWhenRun=true actually foreground the app before perform() runs — has never been exercised. No physical device was available; docs/SPIKES.md Spike 6 explicitly records 'not run this session.'"
    artifacts:
      - path: "App/Piko/ArmSessionIntent.swift"
        issue: "Correct code, zero runtime evidence"
      - path: "App/Piko/PikoShortcuts.swift"
        issue: "Correct code, zero runtime evidence"
    missing:
      - "Physical iPhone (15 Pro+ for Action Button) with DEVELOPMENT_TEAM filled in App/project.yml, Back Tap bound in Settings > Accessibility > Touch, Action Button bound in Settings, both triggered, Spike 6 Result line updated"
  - truth: "Phone-call interruption, route change, another app taking the session, low power mode, and process kill each end in silent recovery or a re-arm prompt within 1 second — never a crash"
    status: partial
    reason: "FSM logic is implemented and matches the five interruption types on inspection (call/other-app collapse to .began since iOS does not distinguish them; route change and low-power-enabled also drive disarm(); process kill is handled at next launch via the pre-existing SessionState.isLive() staleness check, not a live FSM transition). 11 Swift Testing functions exist that assert this logic in isolation using synthetic NotificationCenter posts and a mock InterruptionSource. However every one of these tests is wrapped in #if os(iOS) and has never been executed on any platform in this delivery — swift test on this macOS host runs 0 of them (confirmed independently), and no iOS Simulator/device test run happened (confirmed independently — the auto-generated PikoAudio Xcode scheme has no test action configured, verified by attempting xcodebuild test just now, which fails with 'Scheme PikoAudio is not currently configured for the test action'). Additionally the tests validate that a transition occurs, not that it occurs within 1 second — the suite's own doc comment says as much. Process-kill recovery (no crash) is fundamentally something only a real device relaunch after termination can prove; this has not been done."
    artifacts:
      - path: "Sources/PikoAudio/SessionCoordinator.swift"
        issue: "Switch-statement logic reviewed and appears correct against the five interruption types, but the assertion is from code reading, not execution"
      - path: "Tests/PikoAudioTests/SessionCoordinatorInterruptionTests.swift"
        issue: "4 tests, never executed (iOS-guarded, no test run occurred on any platform)"
      - path: "Tests/PikoAudioTests/AVAudioSessionInterruptionSourceTests.swift"
        issue: "3 tests, never executed (iOS-guarded, no test run occurred on any platform)"
    missing:
      - "An actual test-execution run (xcodebuild test against an iOS Simulator, with a scheme test action configured, or a physical device) of the 11 PikoAudioTests functions"
      - "Manual process-kill verification: arm on device, force-kill Piko, relaunch, confirm re-arm banner and no crash"
      - "Manual timing check that recovery/re-arm-prompt genuinely lands within 1 second, not just 'the FSM transitions'"
deferred: []
human_verification:
  - test: "Bind 'Arm Piko' to Back Tap (Settings > Accessibility > Touch > Back Tap) and to the Action Button on an iPhone 15 Pro+, trigger both, confirm arm() runs and the app foregrounds correctly"
    expected: "Both gestures foreground Piko and transition phase to .armed within about 1 second, matching the in-app Arm button's behavior"
    why_human: "AppIntent system-gesture binding has no Simulator or CI equivalent; requires a physical iPhone with Back Tap/Action Button hardware"
  - test: "Run all 11 PikoAudioTests functions (4 arming, 4 interruption FSM, 3 notification translation) on an iOS Simulator or device, not just macOS swift test"
    expected: "All 11 tests pass, confirming the FSM logic that was only verified by code reading in this report"
    why_human: "Requires configuring a test action on an Xcode scheme (or a CI job) that this verification session did not set up; #if os(iOS) guards mean zero of these tests compile or run under plain `swift test` on macOS"
  - test: "Arm a session, then: take an incoming call, change audio route (connect/disconnect AirPods), let another app grab the session, enable Low Power Mode, and force-kill the app — five separate real-world interruptions"
    expected: "Each ends in either silent recovery or a re-arm prompt within ~1 second; the app never crashes"
    why_human: "Real interruption sources (Phone app, CallKit, actual Bluetooth hardware, Settings toggle, process termination) cannot be synthesized outside a physical device; SessionCoordinatorInterruptionTests only proves the FSM reacts correctly to synthetic events fed directly into a mock, not that real OS notifications actually arrive and are shaped as assumed"
  - test: "Arm a session and use the phone normally (calls, video, camera, AirPods connect/disconnect, backgrounding) for 45 continuous minutes"
    expected: "Session survives the full 45 minutes per docs/SPIKES.md Spike 2, with no unexpected disarm or crash"
    why_human: "Long-duration real-world soak test; not automatable in an SPM/Simulator test run, explicitly out of scope for this session per the plan's own SESS-05 scope note"
---

# Phase 3: Armed Session Verification Report

**Phase Goal:** `PikoAudio` owns arming, disarming, and capture, and recovers from every real-world interruption instead of crashing.
**Verified:** 2026-08-29T13:20:00Z
**Status:** gaps_found (device-verification gaps, not code defects — see verdict below)
**Re-verification:** No — initial verification

## Verdict

**PARTIALLY DONE. Not DONE.**

The code-complete work for Phase 3 is real, substantive, and — on inspection — logically correct. `SessionCoordinator` is a genuine `AVAudioSession`-backed state machine, not a stub; `AVAudioSessionInterruptionSource` is a genuine three-notification-source bridge, not a fake; `ArmSessionIntent`/`PikoShortcuts` are a genuine, minimal `AppIntent` pass-through, not a placeholder. All three summaries are honest about what they did and did not do — nothing in them was found to overstate reality.

But two of the three success criteria have a hard physical-device dependency the summaries themselves flag, and this verification independently found a **third** gap the summaries under-stated: **none of the 11 new Phase 3 tests (SESS-01 arming, SESS-04 interruption FSM, notification translation) have ever actually been executed**, on this machine or any other, in this delivery. They are compiled-but-never-run. This matters because "13/15 passing" — the headline number carried into this verification request — is entirely Phase 1/2 tests (`PikoKitTests`, `PikoBridgeTests`); it verifies nothing about Phase 3's own behavior. Independently confirmed by running `swift test` myself (same 13/15 split, same two pre-existing App-Group-container failures) and by attempting `xcodebuild test -scheme PikoAudio` against a booted iPhone 16 Simulator, which failed immediately with "Scheme PikoAudio is not currently configured for the test action" — there is no working path in this repo today to run the Phase 3 tests at all without additional scheme configuration.

Given that:
- Criterion 1 (Back Tap/Action Button arming) is code-complete but **zero-percent** device-verified — not partially, not "probably fine," genuinely untested end-to-end.
- Criterion 2 (interruption recovery) is logically sound by code review, and its unit tests are well-designed, but those tests have **never run**, and the "never a crash" / "within 1 second" clauses are exactly the parts a unit test with a mock cannot prove — that requires real OS notifications and a real clock.
- Criterion 3 (45-minute soak) was **explicitly not attempted**, by the plan's own design (SESS-05 scope note in 03-02-SUMMARY.md), and remains an open manual entry in `docs/SPIKES.md` Spike 2.

Phase 3 should be marked **PARTIALLY DONE**: the architecture and its automatable proof are in place and correct as far as static analysis and code review can tell, but calling it DONE would misrepresent a phase whose stated goal is explicitly about real-world interruption survival — the one thing that hasn't been observed to happen even once, in a simulator or on a device, in this delivery.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can arm a session from the container app | ✓ VERIFIED | `AppComposition.shared.session.arm()` wired to a real, reachable "Arm" button in `ArmView` (App/Piko/PikoApp.swift); `arm()` implementation in `SessionCoordinator.swift` calls real `AVAudioSession.setCategory`/`setActive`, gated on `isForeground()`; `swift build` succeeds independently confirmed |
| 2 | User can arm a session via Back Tap | ✗ FAILED (code done, device-unverified) | `ArmSessionIntent`/`PikoShortcuts` exist and compile (confirmed via `xcodebuild -scheme Piko -sdk iphonesimulator build`, not attempted again here but summary's claim is plausible given code review); no physical device available this session or during this verification; `docs/SPIKES.md` Spike 6 still reads "not run this session" |
| 3 | User can arm a session via the Action Button | ✗ FAILED (code done, device-unverified) | Same `ArmSessionIntent`/`PikoShortcuts` code path as Back Tap (single intent, single registration); same zero-device-testing gap |
| 4 | Phone-call interruption ends in silent recovery or re-arm prompt within 1s, never a crash | ? UNCERTAIN | FSM logic reviewed and correct on inspection (`.began` → `disarm()`); test exists (`beganDrivesPhaseToIdle`) but never executed; real CallKit/Phone-app interruption never triggered |
| 5 | Route change ends in silent recovery or re-arm prompt within 1s, never a crash | ? UNCERTAIN | Same pattern: `.routeChanged` → `disarm()`, test exists (`routeChangedDrivesPhaseToIdle`) but never executed; real hardware route change (e.g. AirPods) never triggered |
| 6 | Another app taking the session ends in silent recovery or re-arm prompt within 1s, never a crash | ? UNCERTAIN | Handled identically to phone-call interruption (`InterruptionSource.swift` comment: "iOS does not distinguish 'call' from 'another app took the session'"); same untested-in-execution caveat |
| 7 | Low power mode ends in silent recovery or re-arm prompt within 1s, never a crash | ? UNCERTAIN | `.lowPowerModeChanged(enabled: true)` → `disarm()` reviewed correct; test exists (`lowPowerModeEnabledDrivesPhaseToIdle`) but never executed; real `ProcessInfo` low-power toggle never triggered |
| 8 | Process kill ends in silent recovery or re-arm prompt within 1s, never a crash | ? UNCERTAIN | Handled via launch-time `SessionState.isLive()` staleness check (Phase 1 mechanism, reused unchanged) wired into `ArmView`'s `.task`; logically sound but "never a crash" after a real `kill -9`/force-quit has not been observed even once |
| 9 | An armed session survives 45 minutes of ordinary phone use | ✗ FAILED (not attempted) | Explicitly out of scope for this session per 03-02-SUMMARY.md's own "SESS-05 Scope Note"; remains an open manual entry, `docs/SPIKES.md` Spike 2 Result: "not run" |

**Score:** 1/9 fully verified, 4 code-correct-but-execution-unverified, 2 code-correct-but-device-unverified, 1 not attempted, 1 (this one folds into #4/6) — see rollup below.

**Rollup against the three stated success criteria:**

| Success Criterion | Status |
|---|---|
| 1. Armed from container app, Back Tap, Action Button | PARTIAL — container app ✓ verified; Back Tap/Action Button code-complete, 0% device-tested |
| 2. Five interruption types recover or re-arm within 1s, never crash | PARTIAL — FSM logic correct by code review; automated tests exist but have never been run on any platform; "never a crash" and "within 1s" are unmeasured |
| 3. Survives 45 minutes of ordinary use | NOT DONE — explicitly not attempted this session, by design |

### Required Artifacts

| Artifact | Expected | Status | Details |
|---|---|---|---|
| `Sources/PikoAudio/ArmedSession.swift` | Protocol contract for arm/disarm/startCapture/stopCapture | ✓ VERIFIED | Present, matches `SPEC.md`'s `func startCapture() throws` / `func stopCapture()` shape exactly; contains an honest `TODO(spike 2): AVAudioEngine implementation` comment — see Scope Note below |
| `Sources/PikoAudio/SessionCoordinator.swift` | Real `ArmedSession` conformer over `AVAudioSession` | ✓ VERIFIED | 90 lines, `#if os(iOS)`-guarded, real `AVAudioSession.setCategory`/`setActive` calls, `isForeground` gate, `sessionEpoch` counter, heartbeat task, interruption-consuming task — not a stub |
| `Sources/PikoAudio/InterruptionSource.swift` | `InterruptionSource`/`InterruptionEvent` contract + `NullInterruptionSource` | ✓ VERIFIED | Present, unguarded, matches summary claim exactly |
| `Sources/PikoAudio/AVAudioSessionInterruptionSource.swift` | Real conformer merging 3 notification sources | ✓ VERIFIED | 47 lines, `#if os(iOS)`-guarded, three independent `Task`s (interruption/route-change/low-power) merged into one `AsyncStream`, defensive `guard let`/`@unknown default` unwrapping — not a stub |
| `App/Piko/AppComposition.swift` | Sole `DarwinChannel`+`SessionCoordinator` construction site | ✓ VERIFIED | 19 lines, single `private init()`, `AVAudioSessionInterruptionSource()` wired (not `NullInterruptionSource`, confirming Plan 03-02 landed) |
| `App/Piko/PikoApp.swift` (`ArmView`) | Reachable Arm button + re-arm banner | ✓ VERIFIED | Button wired to `AppComposition.shared.session.arm()`; `showReArmBanner` combines live-interruption and stale-launch cases; both `.task` blocks present and match claims |
| `App/Piko/ArmSessionIntent.swift` | AppIntent entry point for Back Tap/Action Button | ✓ VERIFIED (exists+substantive) / ✗ UNVERIFIED (device) | 15 lines, `openAppWhenRun = true`, pure 2-line pass-through to `session.arm()` — matches claim; never exercised end-to-end |
| `App/Piko/PikoShortcuts.swift` | AppShortcutsProvider registration | ✓ VERIFIED (exists+substantive) / ✗ UNVERIFIED (device) | 13 lines, single `AppShortcut` registration — matches claim; never exercised end-to-end |
| `Tests/PikoAudioTests/*` (5 files, 11 `@Test` functions) | Coverage for SESS-01 arming + SESS-04 FSM + notification translation | ✓ VERIFIED (exist, substantive, logically sound) / ✗ FAILED (never executed) | All 5 files read in full; assertions are real (not tautological), cover the documented transitions, use a race-against-timeout pattern for async proof — but 0 of 11 have ever run, on macOS or iOS, in this delivery |

### Key Link Verification

| From | To | Via | Status | Details |
|---|---|---|---|---|
| `ArmView` Arm button | `SessionCoordinator.arm()` | `AppComposition.shared.session.arm()` in a `Task` | ✓ WIRED | Direct call, error caught and displayed |
| `ArmSessionIntent.perform()` | `SessionCoordinator.arm()` | `AppComposition.shared.session.arm()` | ✓ WIRED (code) / ? UNTESTED (runtime) | Same call site as the in-app button — no second code path, good design; but `openAppWhenRun` foregrounding-before-perform() timing is an unverified assumption |
| `AVAudioSessionInterruptionSource.events` | `SessionCoordinator.disarm()` | `Task` in `SessionCoordinator.init` consuming `interruptions.events`, `switch` on event type | ✓ WIRED (code) | Switch statement correctly routes `.began`/`.routeChanged`/`.lowPowerModeChanged(true)` to `disarm()`; confirmed via source read line-by-line |
| `SessionCoordinator.phase` | `ArmView.phaseText` | `.task { for await phase in session.phase { phaseText = ... } }` | ✓ WIRED | Direct subscription, updates UI state |
| `AppComposition.channel.readState()` | `ArmView.staleAtLaunch` | `.task { if let state = ..., !state.isLive() { staleAtLaunch = true } }` | ✓ WIRED | Reuses Phase 1's `isLive()` — no new heuristic invented, low regression risk |

### Data-Flow Trace (Level 4)

Not applicable in the usual sense (no list/dashboard rendering pipeline in this phase). The one dynamic-data path — `SessionCoordinator.phase` AsyncStream → `ArmView.phaseText` Text — was traced and confirmed to carry real state, not a hardcoded value: `phaseContinuation.yield(currentPhase)` is called from every state-transition method (`arm`, `disarm`, `startCapture`, `stopCapture`) with `currentPhase` freshly mutated immediately before each yield.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|---|---|---|---|
| `swift build` succeeds | `swift build` | `Build complete!` | ✓ PASS |
| `swift test` full suite | `swift test` | 15 tests, 13 passed, 2 failed (App Group container, documented pre-existing environment limitation from Phase 1/2, unrelated to Phase 3) | ✓ PASS (matches claim exactly) |
| PikoAudio package tests actually execute | `xcodebuild test -scheme PikoAudio -destination 'platform=iOS Simulator,name=iPhone 16'` | `error: Scheme PikoAudio is not currently configured for the test action` | ✗ FAIL — no working path exists in this repo today to execute the 11 Phase 3 tests without additional scheme setup |
| Claimed commits exist with claimed content | `git log --oneline`, `git show --stat d1f8d5d`, `git show --stat 01157d5` | All 10 claimed commit hashes present in `git log`; spot-checked 2 match their claimed messages/authorship | ✓ PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|---|---|---|---|---|
| SESS-01 | 03-01 | Arm from container app | ✓ SATISFIED | Real Arm button, real `AVAudioSession` calls, 4 tests exist (unexecuted but logically match implementation) |
| SESS-02 | 03-03 | Arm via Back Tap | ✗ BLOCKED | Code complete; SESS-02 explicitly NOT marked complete by its own summary — no device verification |
| SESS-03 | 03-03 | Arm via Action Button | ✗ BLOCKED | Same as SESS-02 — same intent, same unverified path |
| SESS-04 | 03-02 | Interruption recovery (5 types), re-arm prompt within 1s | ? NEEDS HUMAN | FSM logic correct on inspection; tests exist but never run; "within 1 second" and "never a crash" are exactly the parts requiring a real device |
| SESS-05 | 03-02 | 45-minute soak | ✗ BLOCKED | `requirements-completed` in 03-02-SUMMARY.md frontmatter lists SESS-05, but the summary's own "SESS-05 Scope Note" clarifies this reflects scope-of-touched-work, not that the soak was run. The soak itself was not attempted. |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|---|---|---|---|---|
| `Sources/PikoAudio/ArmedSession.swift` | 19 | `TODO(spike 2): AVAudioEngine implementation` | ℹ️ Info, not a blocker | References `docs/SPIKES.md` Spike 2 (formal follow-up), so passes the debt-marker gate. See Scope Note below — this is intentionally out of Phase 3's scope per `SPEC.md`'s protocol contract, not an incomplete Phase 3 deliverable. |
| `App/Piko/PikoApp.swift` | 24 | `// TODO: history list, skin picker` | ℹ️ Info, not a blocker | Explicitly out of scope for v0.1's single screen; matches phases 7-8 (Live Activity, history) not yet started |
| — | — | No `FIXME`/`XXX` markers found anywhere in `Sources/PikoAudio/` or `App/Piko/` | — | Clean |

**Scope Note — "capture" in the phase goal:** The roadmap phase goal text reads "PikoAudio owns arming, disarning, and **capture**." Reading the actual code: `startCapture()`/`stopCapture()` only flip the `SessionPhase` enum (`.armed` ↔ `.capturing`) — there is no `AVAudioEngine`, no tap installed, no PCM buffer ever produced. This looks alarming in isolation, but `docs/SPEC.md`'s `ArmedSession` protocol contract defines these two methods exactly this way (`func startCapture() throws // legal only while armed`) with no buffer-plumbing signature, and `REQUIREMENTS.md` maps the actual audio-buffer-to-transcript requirements (CAPT-01 through CAPT-04) to Phase 4 and Phase 5, both of which depend on Phase 3 rather than being part of it. Read this way, "capture" in the Phase 3 goal means the **legal state machine for capture** (you cannot capture without first arming), not the buffer engine itself — and none of the three stated success criteria for Phase 3 test actual microphone recording. This is **not counted as a gap** against Phase 3, but it is flagged here so the verdict isn't read as silently overlooking it.

## Human Verification Required

See YAML frontmatter `human_verification` section for the four items (Back Tap/Action Button binding, PikoAudioTests execution, five interruption types on real hardware, 45-minute soak) with full test/expected/why-human detail.

## Gaps Summary

Three things stand between "code complete" and "phase done":

1. **Back Tap / Action Button (SESS-02, SESS-03):** code exists, compiles, and passes through to the exact same `arm()` the in-app button uses — a sound design — but has genuinely never been triggered by a real gesture on a real device. This was known going in and is honestly documented in 03-03-SUMMARY.md and `docs/SPIKES.md` Spike 6.

2. **Interruption recovery (SESS-04):** the FSM is implemented correctly as far as static code review can tell, and the unit tests that exist are well-designed and match the implementation 1:1. But this verification independently discovered that **all 11 of Phase 3's own tests have never been executed** — not on macOS (blocked by `#if os(iOS)`), and not on iOS Simulator either (attempted `xcodebuild test -scheme PikoAudio` just now; failed immediately because no test action is configured on that scheme). The "13/15 passing" figure that was cited going into this verification is real and accurate, but it is exclusively Phase 1/2 tests — it provides zero evidence about Phase 3's behavior. "Never a crash" and "within 1 second" are precisely the properties a synthetic-event unit test cannot establish; they require real OS notifications and a stopwatch on a real device.

3. **45-minute soak (SESS-05):** not attempted, by explicit design choice recorded in 03-02-SUMMARY.md. This was known going in.

None of these are code defects. Everything read in `Sources/PikoAudio/` and `App/Piko/` this session is real, substantive work that matches its own summaries honestly — no fabricated tests, no placeholder returns, no silently-skipped requirements dressed up as done. The gap is entirely about **execution evidence**: nothing in the "recovers from every real-world interruption instead of crashing" half of the phase goal has been observed to actually happen, even once, in this delivery.

**Recommendation:** Keep Phase 3 open. Do not advance to Phase 4 treating SESS-02/03/04/05 as settled. Before closing Phase 3:
- Fill in `DEVELOPMENT_TEAM` in `App/project.yml`, install on a physical iPhone, and run through `docs/SPIKES.md` Spikes 2 and 6 for real, updating their Result lines.
- Configure a test action on an Xcode scheme (or add a CI job) so the 11 `PikoAudioTests` functions actually execute at least once, ideally on iOS Simulator as a fast pre-device check before the full physical-device pass.

---
*Verified: 2026-08-29T13:20:00Z*
*Verifier: Claude (gsd-verifier)*

---

## Addendum: PikoAudioTests Simulator execution (2026-08-29, later same day)

Following this verification's own recommendation, the 11 `PikoAudioTests` functions were
executed for the first time, on iOS Simulator (iPhone 17, iOS 26.0.1), via
`xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=...'`
(the `Piko-Package` aggregate scheme has a working test action; the auto-generated
per-module `PikoAudio` scheme referenced above still does not).

Running them for real — not just reading them — surfaced **3 genuine bugs**, none of which
were visible from code review alone:

1. `SessionCoordinatorArmingTests.swift` and `SessionCoordinatorInterruptionTests.swift` were
   missing `import PikoKit` — `SessionPhase`/`PikoError` failed to resolve. Real compile
   failure, not a review-visible defect.
2. `AVAudioSessionInterruptionSourceTests.swift` posts to the process-wide
   `NotificationCenter.default`; Swift Testing runs suite tests concurrently by default, so
   one test's notification post was observed by a sibling test's
   `AVAudioSessionInterruptionSource` instance and consumed as its "first event," causing 2 of
   3 tests to intermittently report the wrong event. Fixed by marking the suite `.serialized`.
3. `nonRecoveringEventsDoNotDisarm` raced a second concurrent `AsyncStream` consumer against a
   200ms timeout; cancelling the losing race silently poisoned the underlying shared stream
   storage, so the real `.began`-driven `.idle` read immediately afterward returned `nil`
   forever. Fixed by restructuring so the only cancellation-based race happens strictly after
   the real assertion already succeeded (true last use of the iterator).

All 3 fixes committed (`d809f2d`). After fixing:
- All 11 `PikoAudioTests` pass on iOS Simulator.
- Full package Simulator suite (26 tests across 3 bundles: PikoAudioTests, PikoKitTests,
  PikoBridgeTests) passes clean, `xcodebuild test -scheme Piko-Package` exit 0.
- macOS `swift build`/`swift test` unaffected — same 13/15 split, same 2 pre-existing
  App-Group-in-unsigned-SPM environment failures as before, unrelated to Phase 3.

**Updated status for gap #2 (interruption recovery, SESS-04):** the "PikoAudioTests never
executed" execution-evidence gap is now **CLOSED**. The FSM's automated proof is no longer
just logically-sound-by-review — it has actually run and passed, and running it for real
caught 3 real bugs review had missed, which is direct evidence the exercise was worthwhile
rather than a formality. The narrower "within 1 second" wall-clock claim and "never crashes
on a real device" claim are still unverified by this addendum and still require a physical
device — that part of gap #2 remains open exactly as originally reported.

**Unchanged, still open exactly as before:**
- Gap #1 (Back Tap / Action Button, SESS-02/03): zero physical-device verification. No
  physical iPhone was available for this addendum either.
- Gap #3 (45-minute soak, SESS-05): not attempted, by design, unchanged.

**Xcode MCP tooling:** `.mcp.json` declares `xcode` (`xcrun mcpbridge`) and `xcodebuild`
(`xcodebuildmcp`) MCP servers for this purpose. Neither was available as a connected tool in
this session — `xcrun mcpbridge` requires enabling in Xcode Settings > Intelligence, and
`xcodebuildmcp` requires actually being launched as a connected MCP server, neither of which
is configured in this environment. Plain `xcodebuild`/`xcrun simctl` terminal commands were
used instead, achieving the same Simulator build-and-test outcome the MCP tools would have
wrapped. Flagging this honestly rather than claiming MCP tool usage that did not happen.

*Addendum by: GitHub Copilot (Claude Sonnet 5), 2026-08-29*
