# Phase 6 Validation Architecture

**Phase:** On-Device Cleanup & Routing
**Nyquist:** enabled
**Status:** ready for execution

## Requirement Map

| Requirement | Planned proof | Phase gate |
|---|---|---|
| CLNP-01 | Injected inference contract tests; iOS compilation of real Foundation Models call; coordinator ships cleaned result | Run Spike 5 rewrite corpus on physical Apple Intelligence device |
| CLNP-02 | Cancellation-ignoring hard-deadline unit test; coordinator raw-text fallback tests | Measure 60-word transcript on oldest supported device; timeout must return raw text without visible failure |
| CLNP-03 | Route corpus plus injected-inference call counter remains zero | Automated test is sufficient |

## Automated Sampling

| Plan | Task | Wave | Automated command |
|---|---|---:|---|
| 06-01 | 1 | 1 | `swift test --filter PikoBrainTests` |
| 06-01 | 2 | 1 | `swift build` |
| 06-01 | 3 | 1 | `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` |
| 06-03 | 1 | 1 | `swift test --filter PikoKitTests` |
| 06-03 | 2 | 1 | `swift test --filter PikoKeyboardTests && swift test --filter PikoAudioTests` |
| 06-03 | 3 | 1 | `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` |
| 06-02 | 1 | 2 | `swift test --filter RoutePrefilterTests` |
| 06-02 | 2 | 2 | `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4' -only-testing:PikoTranscribeTests` |
| 06-02 | 3 | 2 | `xcodebuild test -scheme Piko-Package -destination 'platform=iOS Simulator,id=6CD5F4FC-463D-4516-AFDC-2F69B2BAF7C4'` |

All implementation tasks have an automated check. No `MISSING` test references or Wave 0 prerequisites remain;
TDD tasks create their tests before implementation in the same task.

## Physical Device Gate

Before declaring Phase 6 fully complete, run Spike 5 on the oldest supported Apple Intelligence device and
record device model, OS build, 60-word input, output-faithfulness result, elapsed `brainMS`, and whether raw-text
fallback occurred. If hardware is unavailable, report Phase 6 as code complete / device verification pending.
