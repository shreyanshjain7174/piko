# Piko — agent instructions

On-device voice companion for iOS. Read `docs/CONSTRAINTS.md` before proposing any architecture
change; every wall in it is real and sourced.

## Build

- Xcode 26.3+, iOS 26 deployment target, Swift 6.
- `make project` regenerates `App/Piko.xcodeproj` from `App/project.yml` (XcodeGen).
  Never hand-edit the `.xcodeproj` — it is generated and will be overwritten.
- Schemes: `Piko` (app), `PikoKeyboard`, `PikoWidgets`.
- `make test` runs the SPM test suite. Module tests do not need a simulator.

## Rules that are not negotiable

1. **Nothing heavy in the keyboard target.** It may depend on `PikoKit`, `PikoBridge` and
   `PikoUI` only. No model, no audio, no database. The ceiling is ~60 MB and jetsam does not
   warn you.
2. **No network in the core loop.** Arm, capture, transcribe, rewrite, insert — all offline.
   Any network call must be behind an explicit user-facing opt-in, and must be visible while on.
3. **Audio sessions and Live Activities start in the foreground.** If you find yourself calling
   `setActive(true)` or `Activity.request` from background code, the design is wrong, not the API.
4. **Protocols before implementations.** `Transcriber`, `Brain`, `Memory`, `SessionChannel` exist
   so pieces can be swapped and mocked. Do not reach past them into a concrete type.
5. **Simulator results do not count** for memory, background audio, or Live Activity cadence.
   Say so when reporting a result from one.

## Style

- Swift 6 strict concurrency. Actors for anything holding mutable state across tasks.
- `async`/`await` over completion handlers. `AsyncStream` for anything continuous.
- No force unwraps outside tests.
- Tests with Swift Testing (`@Test`), not XCTest, for new code.

## When you are unsure about an API

Use the `apple-docs` MCP server rather than guessing a signature. These frameworks moved in iOS
26 and 27 and training data is not reliable here.

## Where things live

See the table in `README.md`. If a file does not obviously belong to one module, it probably
belongs in `PikoKit`.
