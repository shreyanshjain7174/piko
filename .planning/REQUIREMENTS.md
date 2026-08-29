# Requirements: Piko

**Defined:** 2026-08-27
**Core Value:** Dictation that starts instantly from wherever you are and inserts clean text into
whatever field you're already in, entirely on-device.

## v1 Requirements (v0.1 — "the loop")

### Foundation

- [x] **FOUND-01**: `PikoKit` defines all cross-process types (`SessionState`, `CaptureDraft`,
  `CaptureResult`, `Route`, `Skin`, `Profile`, App Group identifiers, notification names) with no
  platform APIs and no dependencies

### Session Arming

- [ ] **SESS-01**: User can arm a session from the container app
- [ ] **SESS-02**: User can arm a session via Back Tap
- [ ] **SESS-03**: User can arm a session via the Action Button
- [ ] **SESS-04**: An armed session recovers from phone-call interruption, audio-route change,
  another app taking the session, low power mode, and process kill — each surfaces a re-arm
  prompt within 1 second rather than crashing
- [ ] **SESS-05**: An armed session survives 45 minutes of ordinary phone use

### Cross-Process Bridge

- [x] **BRDG-01**: Keyboard extension's mic button drives the armed session through
  `SessionChannel`
- [x] **BRDG-02**: A round-trip event from keyboard to app and back completes in under 120ms on
  device
- [x] **BRDG-03**: The bridge survives twenty consecutive app switches without losing state
- [x] **BRDG-04**: The bridge never delivers a stale sequence number to the keyboard

### Capture & Transcription

- [ ] **CAPT-01**: Partial transcript streams into the host text field as speech is recognized
- [ ] **CAPT-02**: Streaming insertion only rewrites characters after `stablePrefix`, not the
  whole string, on every update
- [ ] **CAPT-03**: First words are visible within 400ms of speech starting
- [ ] **CAPT-04**: No visible text thrash across a continuous 30-second monologue

### On-Device Cleanup

- [ ] **CLNP-01**: Final transcript is cleaned up on-device — fillers removed, punctuation and
  casing corrected
- [ ] **CLNP-02**: Cleanup of a 60-word transcript completes in under 600ms on the oldest
  supported device, or the cleanup step becomes optional on that device
- [ ] **CLNP-03**: Routing (write/command/recall) never costs the fast path — regex/keyword
  prefilter first, tiny routing model only when unsure, rewrite model never in the routing path

### Live Activity

- [ ] **LACT-01**: A Live Activity shows armed / listening / tidying state
- [ ] **LACT-02**: The Live Activity has a working stop button that ends the session

### History

- [ ] **HIST-01**: Every capture session is recorded to local history
- [ ] **HIST-02**: Local history is searchable

### Skins

- [ ] **SKIN-01**: Four skins for the Piko character are available and selectable locally

## v2 Requirements (v0.2 — "the identity")

Deferred to the next milestone. Tracked but not in the current roadmap.

### Router

- **ROUT-01**: Text is routed to "Do" mode when appropriate
- **ROUT-02**: Text is routed to "Recall" mode when appropriate

### Identity & Learning

- **IDNT-01**: Back Tap and Action Button arming ship as first-class entry points (carried
  forward, already partially in v1 — confirm no v0.2-only refinement needed)
- **IDNT-02**: Control Center control for arming
- **IDNT-03**: Profile chips let the user pick a per-field tone without host-app detection (C7)
- **IDNT-04**: Edit-pair learning improves rewrite quality over two weeks of use
- **IDNT-05**: Personal lexicon biases transcription toward the user's own vocabulary

## v3 Requirements (v0.3 — "the object")

- **PEBL-01**: The Pebble hardware accessory can arm a session
- **MODL-01**: User can opt in to download an open-weight local model in place of SystemBrain

## Out of Scope

| Feature | Reason |
|---------|--------|
| Accounts, sync, subscriptions, any server | Zero-network is the stated product differentiator |
| Cross-app actuation ("do this in another app") | No public API; only Siri orchestrates other apps' intents (C9) |
| Persistent background agent | `BGTaskScheduler` grants opportunistic minutes only (C10) |
| iPad, Mac, Android | Different interaction model per platform; not this product |
| Teams / multi-user | No account system exists to hang this off |
| Chat interface | A different product wearing this one's clothes, per ROADMAP.md |
| Self-trained model | v0.1–v0.2 use only what ships with the OS |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| FOUND-01 | Phase 1 | Complete |
| SESS-01, SESS-02, SESS-03, SESS-04, SESS-05 | Phase 3 | Pending |
| BRDG-01 | Phase 2, Phase 4 Plan 01 | Complete (unit-tested remote-control path; device UI unverified) |
| BRDG-02, BRDG-03, BRDG-04 | Phase 2 | Pending (macOS SPM App Group gap; Simulator PikoBridgeTests 6/6) |
| CAPT-01, CAPT-02, CAPT-03, CAPT-04 | Phase 4, Phase 5 | Pending |
| CLNP-01, CLNP-02, CLNP-03 | Phase 6 | Pending |
| LACT-01, LACT-02 | Phase 7 | Pending |
| HIST-01, HIST-02 | Phase 8 | Pending |
| SKIN-01 | Phase 8 | Pending |

**Coverage:**
- v1 requirements: 21 total
- Mapped to phases: 21
- Unmapped: 0

---
*Requirements defined: 2026-08-27*
*Last updated: 2026-08-27 after initial GSD planning bootstrap*
