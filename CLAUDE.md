# Piko — agent instructions

Read this first, every session. It is short so that it gets read.

---

## What we are building and why

Piko is an on-device voice companion for iPhone. Hold a button anywhere in iOS, speak, and
cleaned-up text lands in the text field you were already in. A small language model on the phone
tidies it into something the user would actually have typed, and learns their phrasing from
every correction they make.

**The single claim everything else serves:** nothing leaves the device. No server, no account,
no sync. Turn on airplane mode and the product is unchanged.

That claim is not marketing. It is the architecture, the moat, and the reason the business model
works (see `docs/MONETISATION.md`). Any change that weakens it — a "just this one" network call,
a crash reporter that ships transcripts, an opt-out analytics SDK — is a product decision, not an
implementation detail. Raise it, do not merge it.

**Why it can exist at all:** iOS forbids keyboard extensions from opening the microphone and
forbids anything from starting a recording in the background, but *allows* a session started in
the foreground to keep running. That asymmetry is the whole product. `docs/ARCHITECTURE.md`
explains the armed session; `docs/CONSTRAINTS.md` is the sourced list of walls.

---

## Non-negotiable engineering rules

1. **Nothing heavy in the keyboard target.** It may link `PikoKit`, `PikoBridge` and `PikoUI`,
   nothing else. No model, no audio, no database. The ceiling is ~60 MB and jetsam kills without
   a crash log. CI enforces this — do not "temporarily" work around the check.
2. **No network in the core loop.** Arm, capture, transcribe, rewrite, insert — all offline. Any
   network call sits behind an explicit user-facing opt-in and is visible while it is on.
3. **Audio sessions and Live Activities start in the foreground.** If you are calling
   `setActive(true)` or `Activity.request` from background code, the design is wrong, not the API.
4. **Protocols before implementations.** `Transcriber`, `Brain`, `Memory`, `SessionChannel` exist
   so pieces swap and mock. Do not reach past them into a concrete type.
5. **Simulator results don't count** for memory, background audio, or Live Activity cadence.
   State which you ran on, every time.
6. **Faithfulness over style in the rewriter.** A model that invents a sentence in the user's
   voice is worse than one that leaves an "um" in. Eval accordingly.

## Build

- Xcode 26.3+, iOS 26 target, Swift 6 strict concurrency.
- `make project` regenerates `App/Piko.xcodeproj` from `App/project.yml` (XcodeGen).
  Never hand-edit the `.xcodeproj`; it is generated.
- `make test` runs SPM module tests — no simulator needed.
- Schemes: `Piko`, `PikoKeyboard`, `PikoWidgets`.

## Style

- `async`/`await` over completion handlers; `AsyncStream` for anything continuous.
- Actors for mutable state crossing tasks.
- Swift Testing (`@Test`) for new tests, not XCTest.
- No force unwraps outside tests.

---

## How to work here

Full version in `docs/WORKING-AGREEMENT.md`. The compressed form:

- **Offer options before executing.** Two or three, at least one non-obvious, one-line trade-off
  each, a recommendation, then proceed. This project rewards sideways thinking — the entire
  architecture is a workaround someone refused to accept as impossible.
- **Ask yourself: what would this look like if the obvious approach were forbidden?** On iOS it
  often is.
- **Suggest unprompted.** A better API, a fitting skill, a cheaper data model, a launch angle —
  say it in one line even if nobody asked.
- **Search before assuming.** iOS 26/27 APIs moved; training data lies about them. Use the
  `apple-docs` MCP server rather than guessing a signature.
- **Report honestly.** Unverified claims get labelled as unverified in the same sentence.

## Reach for tooling before hand-rolling

`docs/TOOLING.md` has setup and the full list. Quick map:

| Need | Use |
|---|---|
| Build, run, read compiler errors, run tests | `xcode` MCP (`xcrun mcpbridge`, Xcode 26.3+) |
| Boot a simulator, install to device, drive the UI | `xcodebuild` MCP (XcodeBuildMCP) |
| Any Apple API question | `apple-docs` MCP — before writing the call, not after it fails |
| SpeechAnalyzer, Foundation Models, ActivityKit, App Intents, Bluetooth, background modes | `swift-ios-skills` plugin skills |
| Designing the Piko character or screens in Figma | `figma-swiftui`, `figma-use`, `figma-generate-design` |
| Any chart or dashboard, anywhere | `dataviz` skill — before the first line of chart code |
| A landing page, artifact, or visual deliverable | `artifact-design`, then `artifact-diagramming` if a diagram earns its place |
| Analytics, if we ever add any | `product-tracking-skills` — design the plan, don't sprinkle events |
| Launch content, X threads, funnel work | `x-growth` skill |
| A repeatable workflow worth keeping | `skill-creator` — turn it into a skill instead of re-explaining it |

If a task looks like something a skill covers, load the skill first. If nothing fits and the task
will recur, propose writing a skill for it.

## Where things live

`README.md` has the module table. If a file doesn't obviously belong to one module, it belongs in
`PikoKit`.

- `docs/SPEC.md` — what v0.1 is and is not
- `docs/CONSTRAINTS.md` — the sourced iOS walls
- `docs/ARCHITECTURE.md` — the armed session, process boundaries, data contracts
- `docs/MODELS.md` — model tiers, open weights, the fine-tune path
- `docs/SPIKES.md` — five gating experiments; fill in the results
- `docs/MONETISATION.md` — what's free forever and what isn't
- `docs/TOOLING.md` — MCP servers, skills, editor setup
- `web/index.html` — the launch page
