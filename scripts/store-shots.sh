#!/usr/bin/env bash
#
# App Store screenshots for iPhone 6.9" and iPad 13", from invented data.
#
#   scripts/store-shots.sh            # shoot into dist/appstore/
#   KEEP=1 scripts/store-shots.sh     # leave the simulators booted afterwards
#
# Nothing is photographed off a real library. Each run creates its own pair of
# simulators, so the ones you use keep their state, and deletes them at the end.
# The shared-transcript side of the library comes from demo-library.py and the
# local takes from seed-simulator.sh — both a fictional product team — so the
# shots can be retaken at any time without anything to redact.
#
# Tapping is the one thing simctl cannot do, so every screen is reached with a
# DEBUG launch argument instead (see ContentView and Destination):
#
#   --seed-workspace           a destination, so the app is past first run
#   --seed-select-transcript   open the newest shared transcript
#   --seed-select-take         open the richest local take
#   --seed-select-recorder     open the recorder (the iPad does this anyway)
#
# The build is Debug for that reason. Every build a user can install is Release,
# so none of those arguments exist outside the simulator.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="ltd.hatcher.transcripts"
OUT="${OUT:-dist/appstore}"
DERIVED=".build/store-sim"
LOG=".build/store-shots.log"
mkdir -p .build

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Two ways this Mac can be unable to run a simulator at all, both of which
# otherwise surface as a vague failure several minutes into the build.
SIMCHECK="$(xcrun simctl list runtimes 2>&1 || true)"
if grep -qi "out of date" <<< "$SIMCHECK"; then
  echo "✗ CoreSimulator is older than this Xcode expects. Finish Xcode's install:" >&2
  echo "  sudo xcodebuild -runFirstLaunch" >&2
  exit 1
fi
if ! grep -q "^iOS " <<< "$SIMCHECK"; then
  echo "✗ no iOS simulator runtime is installed:" >&2
  echo "  xcodebuild -downloadPlatform iOS" >&2
  exit 1
fi

echo "▶ Generating the project"
xcodegen generate --quiet

echo "▶ Building for the simulator (Debug) — log in $LOG"
xcodebuild build -project Transcripts.xcodeproj -scheme Transcripts \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1 \
  || { echo "✗ build failed — tail of $LOG:" >&2; tail -30 "$LOG" >&2; exit 1; }
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Transcripts.app"
[[ -d "$APP" ]] || { echo "✗ no app at $APP" >&2; exit 1; }

# Newest installed iOS runtime, and the largest phone and tablet it offers. By
# pattern rather than by exact name so a new Xcode's "iPhone 18 Pro Max" is
# picked up without editing this; the pixel check below is what actually holds
# the line on size.
read -r RUNTIME IPHONE_TYPE IPAD_TYPE < <(python3 - <<'PY'
import json, re, subprocess
def j(*a): return json.loads(subprocess.check_output(["xcrun", "simctl", "list", *a, "-j"]))
rts = [r for r in j("runtimes")["runtimes"]
       if r.get("isAvailable") and r.get("platform", r["name"].split()[0]) == "iOS"]
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
rt = rts[-1]
supported = {t["identifier"]: t["name"] for t in rt.get("supportedDeviceTypes", [])} \
            or {t["identifier"]: t["name"] for t in j("devicetypes")["devicetypes"]}
def pick(patterns):
    for pat in patterns:
        hits = sorted((n, i) for i, n in supported.items() if re.fullmatch(pat, n))
        if hits: return hits[-1][1]
    raise SystemExit(f"no device type matching {patterns}")
phone = pick([r"iPhone \d+ Pro Max", r"iPhone \d+ Plus"])
pad = pick([r"iPad Pro 13-inch \(M\d\)", r"iPad Pro \(12\.9-inch\).*", r"iPad Air 13-inch.*"])
print(rt["identifier"], phone, pad)
PY
)
echo "▶ Runtime $RUNTIME"

# App Store Connect's required sizes, portrait. A function rather than an
# associative array: macOS ships bash 3.2, which has none.
# Simulators this run made, removed on the way out however the run ends. An
# EXIT trap rather than a RETURN one: bash keeps a RETURN trap set inside a
# function armed for every later function return, which would delete the
# simulator after its first screenshot.
CREATED=""
cleanup() {
  [[ -n "${KEEP:-}" ]] && { echo "▶ KEEP set — simulators left booted:$CREATED"; return; }
  for d in $CREATED; do
    xcrun simctl shutdown "$d" > /dev/null 2>&1 || true
    xcrun simctl delete "$d" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT

want() { case "$1" in iphone) echo 1320x2868 ;; ipad) echo 2064x2752 ;; esac; }

shoot_device() {
  local kind="$1" type="$2"
  local dir="$OUT/$kind"
  local dev
  dev="$(xcrun simctl create "Transcripts Shots ($kind)" "$type" "$RUNTIME")"
  echo "▶ [$kind] $(basename "$type") → $dev"
  CREATED="$CREATED $dev"

  xcrun simctl boot "$dev"
  xcrun simctl bootstatus "$dev" -b > /dev/null
  xcrun simctl ui "$dev" appearance light
  # Apple's own marketing time and a full, quiet status bar.
  xcrun simctl status_bar "$dev" override --time "9:41" \
    --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 \
    --batteryState charged --batteryLevel 100
  xcrun simctl install "$dev" "$APP"
  # Granted up front, or the first screen is the permission explainer rather
  # than the app — needsPermissionPriming reads the microphone state alone.
  xcrun simctl privacy "$dev" grant microphone "$BUNDLE_ID"

  # One launch to let the app mint its workspace bookmark (it must happen
  # in-process), then fill that workspace and the local captures.
  xcrun simctl launch "$dev" "$BUNDLE_ID" --seed-workspace > /dev/null
  sleep 4
  xcrun simctl terminate "$dev" "$BUNDLE_ID" || true
  local data
  data="$(xcrun simctl get_app_container "$dev" "$BUNDLE_ID" data)"
  python3 scripts/demo-library.py --root "$data/Documents/Transcripts" --quiet
  scripts/seed-simulator.sh "$dev" > /dev/null

  mkdir -p "$dir"
  rm -f "$dir"/*.png
  local n=0
  shot() {
    local name="$1"; shift
    n=$((n + 1))
    xcrun simctl terminate "$dev" "$BUNDLE_ID" > /dev/null 2>&1 || true
    xcrun simctl launch "$dev" "$BUNDLE_ID" --seed-workspace "$@" > /dev/null
    # The library is filled by a detached scan and re-scanned at +4s, and a
    # transcript is selected 2s after that. Shooting sooner photographs a list
    # that is still arriving.
    sleep 10
    local file
    file="$dir/$(printf '%02d' "$n")-$name.png"
    xcrun simctl io "$dev" screenshot --type=png "$file" > /dev/null 2>&1
    local size
    size="$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')"
    if [[ "$size" == "$(want "$kind")" ]]; then
      echo "  ✓ $file ($size)"
    else
      echo "  ! $file is $size, App Store Connect wants $(want "$kind")" >&2
    fi
  }

  # The phone is a stack, so each screen is its own shot. The iPad shows the
  # list beside whatever is selected, so its "library" shot is the recorder
  # and a separate one would be a duplicate.
  shot transcript --seed-select-transcript
  shot take --seed-select-take
  if [[ "$kind" == "iphone" ]]; then
    shot library
    shot recorder --seed-select-recorder
  else
    shot recorder
  fi
}

shoot_device iphone "$IPHONE_TYPE"
shoot_device ipad "$IPAD_TYPE"

echo "✓ Screenshots in $OUT — upload with: python3 scripts/asc-screenshots.py"
