# Roadmap: Piko

## Overview

v0.1 ("the loop") is built module-by-module, following the fixed contracts in `docs/SPEC.md`,
because each module's blast radius is deliberately contained and the armed-session architecture
only works if `PikoBridge` and `PikoAudio` are solid before anything is layered on top. Phases 1–3
build the plumbing nothing else can work without (types, cross-process channel, the armed
session itself). Phases 4–6 build the actual dictation loop (keyboard UI, transcription,
cleanup). Phases 7–8 add the surrounding experience (Live Activity, history, skins) that make it
feel like a product instead of a demo. v0.2 ("the identity") and v0.3 ("the object") are tracked
as future milestones, not broken into phases yet — see `docs/ROADMAP.md` for their scope.

## Phases

- [x] **Phase 1: Shared Contracts** - `PikoKit` types, App Group, notification constants — no platform code (completed 2026-08-27)
- [x] **Phase 2: Cross-Process Bridge** - `PikoBridge` session channel with the acceptance-tested round trip (completed 2026-08-27)
- [x] **Phase 3: Armed Session** - `PikoAudio` arm/disarm/capture with interruption recovery — merged to master 2026-08-29. All 11 PikoAudioTests verified passing on iOS Simulator. VERIFICATION.md verdict PARTIALLY DONE stands: Back Tap/Action Button device binding (SESS-02/03) and 45-min soak (SESS-05) remain open, both requiring physical iPhone hardware with no Simulator/CI equivalent.
- [x] **Phase 4: Keyboard Extension & Streaming Insertion** - mic button drives the armed session, stablePrefix-based insertion (completed 2026-08-29)
- [x] **Phase 5: On-Device Transcription** - `PikoTranscribe` wired to Apple's SpeechAnalyzer/SpeechTranscriber (code complete 2026-08-29). CAPT-03/CAPT-04 (400ms first word / 30s thrash) remain open — MockTranscriber integration only; physical-device speech not measured.
- [x] **Phase 6: On-Device Cleanup & Routing** - `PikoBrain` SystemBrain rewrite + write-path routing (code complete 2026-08-29). CLNP-03 complete. CLNP-01/CLNP-02 remain open — Simulator is graceful skip, not physical Apple Intelligence quality or 600ms.
- [ ] **Phase 7: Live Activity** - armed/listening/tidying states with a working stop button
- [ ] **Phase 8: Local History & Skins** - `PikoMemory` searchable history + four Piko skins

## Phase Details

### Phase 1: Shared Contracts
**Goal**: `PikoKit` exists as the single source of truth for every cross-process type, with zero
platform dependencies, so the app and keyboard cannot drift apart.
**Depends on**: Nothing (first phase)
**Requirements**: FOUND-01
**Success Criteria** (what must be TRUE):
  1. `SessionState`, `CaptureDraft`, `CaptureResult`, `Route`, `Skin`, `Profile` types exist in
     `PikoKit` and compile with zero imports beyond Foundation
  2. App Group identifier and all cross-process notification names are defined in exactly one place
  3. Both the app target and the keyboard extension target build against `PikoKit` without
     duplicating any of these types
**Plans**: 1 plan

Plans:
- [x] 01-01: Verify, harden, and close Wave 0 test gaps in the existing PikoKit skeleton

### Phase 2: Cross-Process Bridge
**Goal**: A working, tested `SessionChannel` that the app and keyboard extension both speak,
meeting the SPEC.md acceptance numbers.
**Depends on**: Phase 1
**Requirements**: BRDG-01, BRDG-02, BRDG-03, BRDG-04
**Success Criteria** (what must be TRUE):
  1. A round-trip event from keyboard to app and back completes in under 120ms on a physical device
  2. The channel survives twenty consecutive app switches without losing or duplicating state
  3. The keyboard never receives an event with a stale/out-of-order sequence number
**Plans**: 1 plan

Plans:
- [x] 02-01: Fix session-scoped sequence ordering and DarwinChannel observer lifecycle; add PikoBridgeTests coverage for BRDG-02/03/04

### Phase 3: Armed Session
**Goal**: `PikoAudio` owns arming, disarming, and capture, and recovers from every real-world
interruption instead of crashing.
**Depends on**: Phase 2
**Requirements**: SESS-01, SESS-02, SESS-03, SESS-04, SESS-05
**Success Criteria** (what must be TRUE):
  1. A session can be armed from the container app, Back Tap, and the Action Button
  2. Phone-call interruption, route change, another app taking the session, low power mode, and
     process kill each end in either silent recovery or a re-arm prompt within 1 second — never a crash
  3. An armed session survives 45 minutes of ordinary phone use in manual testing
**Plans**: 3 plans (code complete, verification pending)

Plans:
- [x] 03-01: Implement ArmedSession protocol with arm/disarm/startCapture/stopCapture
- [x] 03-02: Implement interruption handling (call, route change, session loss, low power, kill) with re-arm prompts
- [x] 03-03: Implement ArmSessionIntent + PikoShortcuts for Back Tap/Action Button arming (SESS-02/03)
### Phase 4: Keyboard Extension & Streaming Insertion
**Goal**: The keyboard extension has a mic button that drives the armed session, and partial
transcript streams into the host field without visible thrash.
**Depends on**: Phase 3
**Requirements**: BRDG-01, CAPT-01, CAPT-02
**Success Criteria** (what must be TRUE):
  1. Tapping the mic button in the keyboard arms/drives the session via `SessionChannel`
  2. Partial transcript appears in the host text field as speech is recognized
  3. Only characters after `stablePrefix` are rewritten on each update — the stable prefix never flickers
**Plans**: 2 plans

Plans:
- [x] 04-01-PLAN.md — Keyboard extension UI with mic button wired to SessionChannel
- [x] 04-02-PLAN.md — stablePrefix-based streaming text replacement

### Phase 5: On-Device Transcription
**Goal**: `PikoTranscribe` turns audio buffers into a hypothesis stream fast enough that the loop
feels instant.
**Depends on**: Phase 3
**Requirements**: CAPT-03, CAPT-04
**Success Criteria** (what must be TRUE):
  1. First recognized words are visible within 400ms of speech starting, measured on device
  2. A continuous 30-second monologue produces no visibly thrashing partial text
  3. `Transcriber` protocol has a default SpeechAnalyzer/SpeechTranscriber implementation and a
     deterministic `MockBrain`-equivalent for tests
**Plans**: 3 plans

Plans:
- [x] 05-01-PLAN.md — AVAudioEngine tap + buffer stream
- [x] 05-02-PLAN.md — SpeechTranscriberEngine implementation
- [x] 05-03-PLAN.md — Wiring buffers→transcriber→channel

### Phase 6: On-Device Cleanup & Routing
**Goal**: `PikoBrain` cleans up the final transcript on-device within budget, and the write-path
router never taxes the fast path.
**Depends on**: Phase 5
**Requirements**: CLNP-01, CLNP-02, CLNP-03
**Success Criteria** (what must be TRUE):
  1. Final transcript has fillers removed and punctuation/casing corrected
  2. Cleanup of a 60-word transcript completes in under 600ms on the oldest supported device, or
     is skipped on that device with no user-visible failure
  3. Routing uses a regex/keyword prefilter first; the rewrite model is never invoked for routing
**Plans**: 3 plans

Plans:
- [x] 06-01-PLAN.md — SystemBrain rewrite via Foundation Models under an enforced 600ms budget (wave 1)
- [x] 06-02-PLAN.md — Prefilter-only routing plus Brain wiring into CaptureCoordinator with graceful skip (wave 2)
- [x] 06-03-PLAN.md — .agent Profile case, the Phase 6 contract addition reserved by docs/SPEC.md (wave 1)

### Phase 7: Live Activity
**Goal**: The user can see and stop an in-progress capture from the Lock Screen/Dynamic Island.
**Depends on**: Phase 3
**Requirements**: LACT-01, LACT-02
**Success Criteria** (what must be TRUE):
  1. A Live Activity starts at arm time and shows armed / listening / tidying state
  2. The stop button in the Live Activity ends the session reliably
**Plans**: TBD

Plans:
- [ ] 07-01: Implement Live Activity with armed/listening/tidying states and stop action

### Phase 8: Local History & Skins
**Goal**: Every session is recorded and searchable, and the user can pick from four Piko skins.
**Depends on**: Phase 6
**Requirements**: HIST-01, HIST-02, SKIN-01
**Success Criteria** (what must be TRUE):
  1. Every completed capture session appears in local history
  2. History is searchable by content
  3. Four skins exist and can be selected locally, with no network call involved
**Plans**: TBD

Plans:
- [ ] 08-01: Implement PikoMemory local index with search
- [ ] 08-02: Implement four Piko skins and local selection UI

## Progress

**Execution Order:** Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Shared Contracts | 1/1 | Complete   | 2026-08-27 |
| 2. Cross-Process Bridge | 1/1 | Complete   | 2026-08-27 |
| 3. Armed Session | 3/3 | Complete | 2026-08-29 |
| 4. Keyboard Extension & Streaming Insertion | 2/2 | Complete   | 2026-08-29 |
| 5. On-Device Transcription | 3/3 | Complete   | 2026-08-29 |
| 6. On-Device Cleanup & Routing | 2/3 | In Progress|  |
| 7. Live Activity | 0/1 | Not started | - |
| 8. Local History & Skins | 0/2 | Not started | - |

## Future Milestones (not yet broken into phases)

- **v0.2 — "the identity"**: router (Do/Recall), Back Tap/Action Button/Control Center arming
  polish, profile chips, edit-pair learning, personal lexicon, richer searchable history. Done
  when rewrite quality is visibly better for a two-week user than a day-one user.
- **v0.3 — "the object"**: Pebble accessory, opt-in open-weight local model. Only if v0.2 users
  arm several times a day.
