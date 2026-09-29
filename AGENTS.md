# Agent instructions

This repo's full agent contract lives in `CLAUDE.md`. It is written to be tool-agnostic — Codex,
Cursor, Windsurf, Xcode's own coding assistant and Claude Code should all follow it as written.

Read `CLAUDE.md` first, then `docs/CONSTRAINTS.md` before proposing any architecture change.

The three things most likely to go wrong if you skip it:

1. Adding a heavy dependency to the keyboard extension target. There is a ~60 MB ceiling and the
   process dies silently. CI fails the build for this on purpose.
2. Calling `AVAudioSession.setActive(true)` or `Activity.request` from background code. Both are
   blocked by iOS. The armed session exists to work around exactly this.
3. Inventing an API signature for SpeechAnalyzer, Foundation Models or ActivityKit. These changed
   in iOS 27 (and iOS 26 reshuffled the same surfaces just before it). Look them up through the
   `apple-docs` MCP server.

House habits, in one line each: offer two or three options before executing, at least one
non-obvious; suggest improvements unprompted; label anything you could not verify; a Simulator
result is not a device result.
