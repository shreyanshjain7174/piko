# Tooling — agents, MCP servers, editor

The goal: Claude Code (or Codex, or Cursor) can build, run on a simulator or device, read the
compiler errors, and look up Apple documentation without you copy-pasting anything.

## 1. Xcode's own MCP server — start here

Xcode 26.3 and later ship an MCP server. It is the shortest path and needs no Node.

Enable it: **Xcode → Settings (⌘,) → Intelligence → "Enable Model Context Protocol"**.

Then connect your agent:

```bash
# Claude Code
claude mcp add --transport stdio xcode -- xcrun mcpbridge

# Codex
codex mcp add xcode -- xcrun mcpbridge

# verify
claude mcp list
```

Exposes: project file hierarchy and schemes, build for a scheme and destination, compiler errors
and warnings with file and line, and test runs with structured results. Local connections only.

## 2. XcodeBuildMCP — when you need more

Maintained by Sentry. Broader surface: simulator lifecycle, device code signing, test product
preparation, UI automation. Requires Node 18+ and Xcode 16+.

```bash
claude mcp add --transport stdio xcodebuild -- npx -y xcodebuildmcp@latest mcp
```

Use it when Xcode's built-in server does not cover what you need — booting a specific simulator,
installing to a device, driving the UI. Running both is fine; give them distinct names so tool
calls stay unambiguous.

## 3. Apple documentation MCP

Keeps the agent from inventing API signatures — the single biggest failure mode when writing
Swift against fast-moving frameworks.

```bash
claude mcp add --transport stdio apple-docs -- npx -y apple-docs-mcp@latest
```

Searches iOS/macOS/SwiftUI/UIKit docs, WWDC sessions, and code samples. There are several
implementations (`kimsungwhee/apple-docs-mcp`, `MightyDillah/apple-doc-mcp`, `g-cqd/apple-docs`
which is offline-first); pick one and stick with it. `sosumi.ai` is a good manual fallback for
reading a single page as clean markdown.

The `.mcp.json` at the repo root declares all three, so anyone cloning gets the same setup.

## 4. Agent skills

Install as plugins in Claude Code:

```
/plugin marketplace add dpearson2699/swift-ios-skills
/plugin install all-ios-skills@swift-ios-skills
```

That marketplace carries 84 skills for iOS 26+ and Swift 6.3. The ones that matter for Piko:

| Skill | Why we need it |
|---|---|
| `speech-recognition` | SpeechAnalyzer / SpeechTranscriber — the whole transcribe module |
| `on-device-ai` | Foundation Models, guided generation, tool calling |
| `core-ml` | If and when we bring our own weights |
| `activitykit` | Live Activity and Dynamic Island |
| `app-intents` | Action Button, Control Center, the stop button |
| `background-processing` | The armed session's survival rules |
| `bluetooth` | The Pebble accessory in v0.3 |
| `simulator` | Faster agent loops |
| `swift-concurrency` | Every module is async by design |
| `swift-testing` | The test suite |
| `app-store-review` | Full Access keyboards get extra scrutiny — read this before submitting |

Install the themed bundles instead of all 84 if the full set is noisy:
`swiftui-skills@swift-ios-skills`, `swift-core-skills@swift-ios-skills`.

`twostraws/swift-agent-skills` is a curated index of the wider ecosystem worth browsing. Read any
third-party skill before installing it — a skill is instructions your agent will follow.

## 5. VS Code

`.vscode/extensions.json` recommends the official Swift extension (SourceKit-LSP), which gives
completion, diagnostics and jump-to-definition outside Xcode. You will still need Xcode itself
for Interface Builder-free things like entitlements, capabilities, provisioning and running on a
device — VS Code is for writing, Xcode is for shipping.

## 6. CLAUDE.md

`CLAUDE.md` at the repo root tells the agent the scheme names, the module rules, and the two
things it must never do (put weight in the keyboard target, add a network call to the core
loop). Keep it short enough that it is read every session.

## Sources

- Apple — [Xcode 26.3 unlocks the power of agentic coding](https://www.apple.com/newsroom/2026/02/xcode-26-point-3-unlocks-the-power-of-agentic-coding/)
- [How to use Xcode's MCP server](https://bleepingswift.com/blog/xcode-mcp-server-ai-workflow)
- [Using Xcode MCP with Claude Code](https://danielsaidi.com/blog/2026/04/30/using-xcode-mcp-with-claude-code)
- [getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP)
- [kimsungwhee/apple-docs-mcp](https://github.com/kimsungwhee/apple-docs-mcp)
- [dpearson2699/swift-ios-skills](https://github.com/dpearson2699/swift-ios-skills)
- [twostraws/swift-agent-skills](https://github.com/twostraws/swift-agent-skills)
