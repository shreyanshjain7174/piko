---
phase: piko-01-shared-contracts
plan: 01
subsystem: PikoKit
tags: [testing, codable, xcodegen]
requires: []
provides: [pikokit-regression-tests, import-allowlist-test, dual-target-build-proof]
affects: [PikoBridge, PikoAudio, PikoTranscribe, PikoBrain, PikoMemory, PikoUI]
tech-stack:
  added: []
  patterns: [swift-testing-round-trip-coding, filesystem-based-import-allowlist-check]
key-files:
  created:
    - Tests/PikoKitTests/ImportAllowlistTests.swift
  modified:
    - Tests/PikoKitTests/ContractTests.swift
    - Sources/PikoKit/Contracts.swift
decisions:
  - "Task 3 (dual-target Xcode build) ran fully — xcodegen and xcodebuild were both available and both schemes built successfully, so criterion #3 is now proven directly, not just structurally."
metrics:
  duration: "~15 minutes"
  completed: 2026-08-27
---

# Phase 1 Plan 01: Verify, harden, and close Wave 0 test gaps in PikoKit — Summary

One-liner: Added Codable round-trip tests for SessionState/CaptureResult/EditPair, an automated
Foundation-only import allowlist test, and confirmed both the `Piko` app and `PikoKeyboard`
extension build against `PikoKit` via a real `xcodegen`+`xcodebuild` dual-target build.

## What Was Done

### Task 1: Codable round-trip and existence tests
Added four `@Test` functions to `Tests/PikoKitTests/ContractTests.swift`:
- `sessionStateCoding` — round-trips a `SessionState` through `JSONEncoder`/`JSONDecoder`
- `captureResultCoding` — round-trips a `CaptureResult` (exercising the nested `Timings` struct)
- `editPairCoding` — round-trips an `EditPair`
- `appGroupAndSignalAreSinglyDefined` — asserts `AppGroup.identifier` is non-empty and
  `Signal.allCases.count == 5`, a regression guard against silent case drift

No existing test (`staleSession`, `draftCoding`, `routing`, `mockRewrite`) was modified.

**Verify:** `swift test --filter PikoKitTests` → **PASS** (9/9 tests, including the 4 new ones;
existing 5 tests untouched and still passing).

### Task 2: Import allowlist test + doc comment
Created `Tests/PikoKitTests/ImportAllowlistTests.swift` with one `@Test func importAllowlist()`.
It resolves `Sources/PikoKit` relative to `#filePath`, lists all `.swift` files there, asserts the
list is non-empty (guards against silent pass on a path-resolution bug), then for every line in
every file that trims to an `import ` prefix, asserts the trimmed line is exactly
`"import Foundation"` — failure messages include the file name and offending line.

Added a one-line doc comment above `AppGroup.identifier` in `Sources/PikoKit/Contracts.swift`
stating the string must match `com.apple.security.application-groups` in every target's
entitlements and is mirrored by hand in `App/project.yml`. The identifier's value
(`group.dev.piko.shared`) was not changed.

**Verify:** `swift test --filter PikoKitTests` → **PASS** (9/9 tests, including the new
`importAllowlist` test). `grep -rn '^import ' Sources/PikoKit/` still shows only
`import Foundation` in both `Contracts.swift` and `Protocols.swift`.

### Task 3: Dual-target Xcode build (best-effort, non-gating)
**Outcome: PASS** — both tools were available and both builds succeeded.

- `xcodegen --version` → 2.46.0; `xcodebuild -version` → Xcode 26.0.1 (17A400). Both present, no
  tool-unavailable fallback needed.
- `cd App && xcodegen generate` → succeeded, produced `App/Piko.xcodeproj` (gitignored, not
  committed).
- `xcodebuild -project Piko.xcodeproj -scheme Piko -sdk iphonesimulator -destination
  'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**
  (includes `PikoKeyboard` and `PikoWidgets` extensions embedded as PlugIns of the `Piko` app
  target).
- `xcodebuild -project Piko.xcodeproj -scheme PikoKeyboard -sdk iphonesimulator -destination
  'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**.

Both schemes link against the same `PikoKit` product with no type redeclaration, no compile
errors importing `PikoKit`, and no duplicate-symbol link errors. This directly satisfies Phase 1
ROADMAP.md success criterion #3 ("Both the app target and the keyboard extension target build
against `PikoKit` without duplicating any of these types") by an actual dual-target build, not
just by SPM-layer structural inference.

Generated artifacts from this task (`App/Piko.xcodeproj`, and the `Info.plist`/`.entitlements`
files XcodeGen writes under `App/Piko/`, `App/PikoKeyboard/`, `App/PikoWidgets/`) are build
byproducts of running `xcodegen generate` from `project.yml` and were left untracked/uncommitted,
consistent with this task's "verification only, no files modified" scope. `App/Piko.xcodeproj/`
is already covered by `.gitignore`; the generated `Info.plist`/`.entitlements` files are not
currently gitignored but were not added to the commit for this plan since they are regenerable
build output, not authored source — flagging this as a minor gitignore gap for a future plan to
close if XcodeGen output should never appear as untracked cruft.

## Full Suite Verification

`swift test` (no filter) → **PASS**, 9/9 tests, 0 failures. `PikoKitTests` is currently the only
test target in the package (`PikoBrain`'s `SystemBrain`/`MockBrain` are exercised via
`@testable import PikoBrain` inside `ContractTests.swift`, not a separate target), so this run is
equivalent to the full suite required by plan verification.

## Deviations from Plan

None — plan executed exactly as written. Task 3 ran to full completion (pass) rather than
hitting the tool-unavailable or fail-with-reason branches, which the plan explicitly anticipated
as possible outcomes but did not require.

## Self-Check

- `Tests/PikoKitTests/ContractTests.swift` contains `func sessionStateCoding`, `func
  captureResultCoding`, `func editPairCoding`, and `Signal.allCases.count == 5` — confirmed by
  direct read after edit.
- `Tests/PikoKitTests/ImportAllowlistTests.swift` exists and contains `func importAllowlist` —
  confirmed by direct read after creation.
- `Sources/PikoKit/Contracts.swift` contains `App/project.yml` in the new doc comment — confirmed.
- Commit `75e8ac1` (Task 1) and `6745fc2` (Task 2) both exist in `git log` on branch
  `piko-01-shared-contracts-plan01`.

## Self-Check: PASSED

## Commits

- `75e8ac1` — `test(pikokit): add Codable round-trip coverage for SessionState/CaptureResult/EditPair`
- `6745fc2` — `test(pikokit): enforce Foundation-only imports and document AppGroup mirror point`

(Task 3 made no source changes, so no commit is associated with it.)
