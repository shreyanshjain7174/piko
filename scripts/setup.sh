#!/usr/bin/env bash
# One-time setup for the agent toolchain. Safe to re-run.
set -euo pipefail

say() { printf "\033[1m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*"; }

say "Checking Xcode…"
if ! command -v xcodebuild >/dev/null; then
  warn "Xcode not found. Install it, then run: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
XCODE_VER=$(xcodebuild -version | head -1 | awk '{print $2}')
say "  Xcode $XCODE_VER"
case "$XCODE_VER" in
  26.[3-9]*|26.[1-9][0-9]*|27*|2[89]*) say "  built-in MCP server available" ;;
  *) warn "  Xcode 26.3+ needed for the built-in MCP server. XcodeBuildMCP still works." ;;
esac

say "Checking XcodeGen…"
command -v xcodegen >/dev/null || { warn "  missing — brew install xcodegen"; }

say "Registering MCP servers with Claude Code…"
if command -v claude >/dev/null; then
  claude mcp add --transport stdio xcode -- xcrun mcpbridge || true
  claude mcp add --transport stdio xcodebuild -- npx -y xcodebuildmcp@latest mcp || true
  claude mcp add --transport stdio apple-docs -- npx -y @kimsungwhee/apple-docs-mcp@latest || true
  claude mcp list || true
else
  warn "  claude CLI not found — .mcp.json at the repo root declares the same three servers."
fi

cat <<'NOTE'

Remaining manual steps:
  1. Xcode → Settings → Intelligence → enable "Model Context Protocol"
  2. In Claude Code:
       /plugin marketplace add dpearson2699/swift-ios-skills
       /plugin install all-ios-skills@swift-ios-skills
  3. Set DEVELOPMENT_TEAM in App/project.yml before building to a device
  4. Register the App Group group.dev.piko.shared on your developer account

Then: make project && make open
NOTE
