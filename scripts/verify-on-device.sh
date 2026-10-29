#!/usr/bin/env bash
# Build/install smoke checks are not physical acceptance or a measured soak.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${PIKO_VERIFICATION_OUT:-$ROOT/verification-logs/$(date +%Y%m%d-%H%M%S)}"
MODE="${1:---smoke}"
case "$MODE" in
  --preflight|--smoke) ;;
  *) printf 'Usage: %s [--preflight|--smoke]\n' "$0" >&2; exit 1 ;;
esac
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STAGE=preflight
export OUT STAGE

write_summary() {
  RESULT="$1" python3 - <<'PY'
import json
import os
from pathlib import Path

summary = {
    "stage": os.environ["STAGE"],
    "automated_smoke": os.environ["RESULT"],
    "acceptance": "unverified",
    "keyboard_peak_rss_bytes": None,
    "container_peak_rss_bytes": None,
    "bridge_round_trip_ms": None,
    "first_inserted_word_ms": None,
    "cleanup_ms": None,
    "soak_minutes_verified": None,
    "manual_gates": {
        name: "unverified" for name in (
            "accuracy", "offline", "background_survival", "interruptions",
            "back_tap", "action_button", "keyboard_memory", "live_activity_stop"
        )
    },
}
Path(os.environ["OUT"], "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
PY
}

on_error() {
  local code=$?
  write_summary failed
  printf 'Failed during %s. Evidence: %s\n' "$STAGE" "$OUT" >&2
  exit "$code"
}
trap on_error ERR
write_summary not_run

for tool in xcodebuild xcrun xcodegen python3 security; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; false; }
done
XCODE_VER="$(xcodebuild -version | awk '/^Xcode / {print $2}')"
if [[ ! "$XCODE_VER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || [[ "${XCODE_VER%%.*}" -lt 27 ]]; then
  printf 'Piko verification requires Xcode 27+.\n' >&2
  false
fi

TEAM="${PIKO_DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" ]]; then
  TEAM="$(awk -F '"' '/DEVELOPMENT_TEAM:/ {print $2; exit}' "$ROOT/App/project.yml")"
fi
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { printf 'Set a valid PIKO_DEVELOPMENT_TEAM.\n' >&2; false; }
security find-identity -v -p codesigning > "$OUT/signing-identities.txt"
xcrun devicectl list devices --json-output "$OUT/devices.json" > "$OUT/devices.log"

UDID="$(python3 - "$OUT/devices.json" "${PIKO_DEVICE_UDID:-}" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1]))["result"]["devices"]
physical = [
    device for device in devices
    if device.get("hardwareProperties", {}).get("reality") == "physical"
    and device.get("connectionProperties", {}).get("pairingState") == "paired"
    and device.get("deviceProperties", {}).get("bootState") == "booted"
]
requested = sys.argv[2]
if requested:
    physical = [
        device for device in physical
        if requested in (device["identifier"], device["hardwareProperties"].get("udid"))
    ]
if len(physical) != 1:
    sys.exit("Connect one paired, booted physical iPhone, or set PIKO_DEVICE_UDID.")
device = physical[0]
properties = device["deviceProperties"]
if properties.get("developerModeStatus") != "enabled":
    sys.exit("Enable Developer Mode and trust this Mac on the selected iPhone.")
if int(properties["osVersionNumber"].split(".")[0]) < 27:
    sys.exit("Piko requires iOS 27+.")
print(device["hardwareProperties"]["udid"])
PY
)"
xcrun devicectl device info details --device "$UDID" \
  --json-output "$OUT/device-details.json" > "$OUT/device-details.log"
write_summary preflight_ready
if [[ "$MODE" == --preflight ]]; then
  printf 'Preflight ready, acceptance unverified. Evidence: %s\n' "$OUT"
  exit 0
fi

STAGE=build
cd "$ROOT"
make project > "$OUT/project.log" 2>&1
xcodebuild -project App/Piko.xcodeproj -scheme Piko \
  -destination "platform=iOS,id=$UDID" DEVELOPMENT_TEAM="$TEAM" \
  -derivedDataPath "$OUT/derived-data" build > "$OUT/xcodebuild.log" 2>&1

STAGE=install
APP="$OUT/derived-data/Build/Products/Debug-iphoneos/Piko.app"
[[ -d "$APP" ]] || { printf 'Missing build product: %s\n' "$APP" >&2; false; }
xcrun devicectl device install app --device "$UDID" "$APP" > "$OUT/install.log" 2>&1

STAGE=launch
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" \
  --json-output "$OUT/launch.json" > "$OUT/launch.log" 2>&1
xcrun devicectl device info processes --device "$UDID" \
  --json-output "$OUT/processes.json" > "$OUT/processes.log"
STAGE=smoke_complete
write_summary passed
printf '%s\n' \
  "Build/install/launch completed. Acceptance remains UNVERIFIED." \
  "Use Instruments to identify Piko and PikoKeyboard separately and record real memory/latency." \
  "Complete docs/SPIKES.md, including the 45-minute soak and real stop/interruptions." \
  "No console/metrics command, missing sample, or absent error string is treated as a pass." \
  "Evidence: $OUT"
exit 2
