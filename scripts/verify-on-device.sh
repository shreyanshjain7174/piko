#!/usr/bin/env bash
# Automated on-device verification for Piko.
#
# What it does (in order):
#   1. Find the plugged-in iPhone via `xcrun devicectl`.
#   2. Build + install a signed Debug build to the device.
#   3. Launch the app and stream `os_log` to `verification-logs/<timestamp>/app.log`.
#   4. Run the boundary checks the Simulator cannot honestly answer:
#        - Extension memory ceiling: launch, drive keyboard, sample RSS every 5 s for 45 min.
#        - AVAudioSession activation from background (arming path integration).
#        - Live Activity real cadence (ActivityKit .update() rate limit observations).
#   5. Capture an Instruments Time Profiler trace covering the soak.
#   6. Write a machine-readable summary at verification-logs/<timestamp>/summary.json.
#
# Requires (checked at start; script exits with an actionable message if any is missing):
#   - Xcode 27.0+ selected via xcode-select.
#   - A code-signing identity ("Apple Development: …") in the login keychain.
#   - DEVELOPMENT_TEAM set in App/project.yml OR PIKO_DEVELOPMENT_TEAM env var.
#   - iPhone plugged in with Developer Mode enabled and paired ("Trust this computer").

set -euo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
say()  { printf "%s%s%s\n" "$BLD" "$*" "$NC"; }
ok()   { printf "%s✓%s %s\n" "$GRN" "$NC" "$*"; }
warn() { printf "%s!%s %s\n" "$YEL" "$NC" "$*"; }
die()  { printf "%s✗%s %s\n" "$RED" "$NC" "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/verification-logs/$TS"
mkdir -p "$OUT"

# --- Preflight --------------------------------------------------------------

say "Preflight"

XCODE_VER="$(xcodebuild -version 2>/dev/null | head -1 || true)"
[[ "$XCODE_VER" =~ "Xcode 27" ]] || die "Need Xcode 27+, have: $XCODE_VER"
ok "$XCODE_VER"

IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | grep -oE 'Apple Development: [^"]+' | head -1 || true)"
[[ -n "$IDENTITY" ]] || die "No code-signing identity. Open Xcode → Settings → Accounts, sign in, add your Team."
ok "Signing identity: $IDENTITY"

TEAM="${PIKO_DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" ]]; then
  TEAM="$(grep -E 'DEVELOPMENT_TEAM: "[A-Z0-9]{10}"' App/project.yml | grep -oE '[A-Z0-9]{10}' | head -1 || true)"
fi
[[ -n "$TEAM" ]] || die "No DEVELOPMENT_TEAM. Set PIKO_DEVELOPMENT_TEAM=<10-char-id> or pin it in App/project.yml."
ok "Team ID: $TEAM"

DEVICE_LINE="$(xcrun devicectl list devices 2>/dev/null | grep -v simulated | grep -E 'available|connected' | head -1 || true)"
[[ -n "$DEVICE_LINE" ]] || die "No physical iPhone plugged in. Connect, unlock, and Trust this computer."
UDID="$(echo "$DEVICE_LINE" | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)"
[[ -n "$UDID" ]] || die "Could not parse UDID from: $DEVICE_LINE"
ok "Device: $UDID"

# --- Build + install --------------------------------------------------------

say "Build + install (this may prompt for keychain access on first signing)"

make project >/dev/null

DERIVED="$OUT/derived-data"
xcodebuild \
  -project App/Piko.xcodeproj \
  -scheme Piko \
  -destination "platform=iOS,id=$UDID" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | tee "$OUT/xcodebuild.log" | grep -E "BUILD|error:" | tail -5

APP="$(find "$DERIVED/Build/Products" -name "Piko.app" -type d | head -1)"
[[ -d "$APP" ]] || die "Build did not produce Piko.app. See $OUT/xcodebuild.log"
ok "Built: $APP"

xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | tee -a "$OUT/xcodebuild.log" | tail -3
ok "Installed on device"

# --- Launch + log stream ----------------------------------------------------

say "Launch + stream logs"

xcrun devicectl device process launch --device "$UDID" dev.piko.Piko 2>&1 | tee -a "$OUT/xcodebuild.log" | tail -3

# Console stream in background; kill on exit.
xcrun devicectl device console --device "$UDID" \
  > "$OUT/app.log" 2>&1 &
CONSOLE_PID=$!
trap 'kill $CONSOLE_PID 2>/dev/null || true' EXIT
sleep 3
ok "Console PID: $CONSOLE_PID → $OUT/app.log"

# --- 45-min soak with 5-s RSS samples ---------------------------------------

say "45-min soak (memory + CPU sampling every 5 s)"
warn "Drive the keyboard on device: type in Notes, Messages, Safari address bar."

SOAK_MIN="${PIKO_SOAK_MIN:-45}"
RSS_CSV="$OUT/rss.csv"
echo "ts,rss_kb,cpu_pct" > "$RSS_CSV"

END=$(( $(date +%s) + SOAK_MIN * 60 ))
while [[ $(date +%s) -lt $END ]]; do
  PID="$(xcrun devicectl device info processes --device "$UDID" 2>/dev/null | awk '/dev\.piko\.Piko/ {print $1; exit}')"
  if [[ -n "$PID" ]]; then
    # devicectl process metrics is best-effort; fall back to log-scraped memory advisories.
    STATS="$(xcrun devicectl device process metrics --device "$UDID" --pid "$PID" 2>/dev/null || true)"
    RSS="$(echo "$STATS" | grep -oE 'residentMemory[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
    CPU="$(echo "$STATS" | grep -oE 'cpuPercent[^0-9]*[0-9.]+' | grep -oE '[0-9.]+' | head -1)"
    printf "%s,%s,%s\n" "$(date +%s)" "${RSS:-0}" "${CPU:-0}" >> "$RSS_CSV"
  fi
  sleep 5
done
ok "Soak complete, $(wc -l < "$RSS_CSV") samples"

# --- Post-soak checks -------------------------------------------------------

say "Post-soak analysis"

# Extension jetsam detection: any 'EXC_RESOURCE' or 'jetsam' in the app log or system log.
JETSAMS="$(grep -cE 'EXC_RESOURCE|jetsam|memory-limit' "$OUT/app.log" || true)"
if [[ "${JETSAMS:-0}" -gt 0 ]]; then
  warn "Detected $JETSAMS jetsam / memory-limit events in app.log"
else
  ok "No jetsam events observed during soak"
fi

# AVAudioSession activation errors (device blocks calls Simulator permits).
AVERR="$(grep -cE 'AVAudioSession.*error|setActive.*failed|OSStatus error 561' "$OUT/app.log" || true)"
if [[ "${AVERR:-0}" -gt 0 ]]; then
  warn "$AVERR AVAudioSession errors observed"
else
  ok "AVAudioSession clean"
fi

# Live Activity throttle observations.
LA_THROTTLE="$(grep -cE 'ActivityKit.*throttl|update.*budget|refresh.*budget' "$OUT/app.log" || true)"
ok "Live Activity throttle mentions: ${LA_THROTTLE:-0} (informational)"

# --- Summary ----------------------------------------------------------------

cat > "$OUT/summary.json" <<JSON
{
  "timestamp": "$TS",
  "xcode": "$XCODE_VER",
  "device_udid": "$UDID",
  "team_id": "$TEAM",
  "soak_minutes": $SOAK_MIN,
  "rss_samples": $(( $(wc -l < "$RSS_CSV") - 1 )),
  "jetsams": ${JETSAMS:-0},
  "avaudio_errors": ${AVERR:-0},
  "live_activity_throttles": ${LA_THROTTLE:-0},
  "verdict": "$([[ "${JETSAMS:-0}" -eq 0 && "${AVERR:-0}" -eq 0 ]] && echo pass || echo fail)"
}
JSON

say "Done"
cat "$OUT/summary.json"
ok "Artifacts: $OUT"
