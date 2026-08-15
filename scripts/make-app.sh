#!/usr/bin/env bash
#
# Package the SwiftPM `Transcripts` executable into a proper, ad-hoc-signed macOS
# .app bundle and (optionally) install + launch it.
#
# Why this exists: a bare `.build/**/Transcripts` binary has no stable bundle identity,
# so macOS TCC will NOT grant it Microphone or Screen Recording access — the mic
# silently returns zeroed buffers and you get an empty recording. A real .app
# bundle with an Info.plist and a (ad-hoc) code signature is what lets TCC prompt
# and remember the grant. This is the same thing Xcode does when you hit Run.
#
# Usage:
#   scripts/make-app.sh                 # build (release), bundle, install to ~/Applications, relaunch
#   CONFIG=debug scripts/make-app.sh    # debug build instead
#   NO_LAUNCH=1 scripts/make-app.sh     # build + install but don't launch
#   NO_INSTALL=1 scripts/make-app.sh    # build the bundle in .build/ only

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Prefer the full Xcode toolchain when present (needed for the macOS 26 Speech
# stack and for `swift test`). Falls back to whatever `swift` is on PATH.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  # Prefer the beta toolchain when installed — it owns the Metal Toolchain
  # component, without which mlx-swift ships no shaders and the summarizer
  # takes the process down at first use.
  for x in "$HOME/Downloads/Xcode-beta.app" /Applications/Xcode-beta.app /Applications/Xcode.app; do
    [[ -d "$x" ]] && { export DEVELOPER_DIR="$x/Contents/Developer"; break; }
  done
fi

CONFIG="${CONFIG:-release}"
APP_NAME="Transcripts"
BUNDLE_ID="ltd.hatcher.transcripts"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"

# Never kill a Transcripts that is mid-recording: the in-flight AAC has no header yet,
# so the audio is unrecoverable. (2026-07-13: two live-call fragments were lost
# exactly this way.) FORCE=1 overrides for the rare deliberate case.
HISTORY="$HOME/Library/Application Support/Transcripts/history.json"
if [[ "${FORCE:-0}" != "1" && "${NO_INSTALL:-0}" != "1" && -f "$HISTORY" ]] && pgrep -xq "$APP_NAME"; then
  if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if any(r.get("status") in ("recording", "processing") for r in d) else 1)
' "$HISTORY" 2>/dev/null; then
    echo "✗ Transcripts is recording or processing a capture right now — not killing it." >&2
    echo "  Re-run after the meeting ends (or FORCE=1 to override deliberately)." >&2
    exit 4
  fi
fi

# Built with xcodebuild, not `swift build`. SwiftPM's command-line build system
# has no Metal rule, so it silently skips mlx-swift's shaders and the resulting
# app has no default.metallib — MLX then kills the process (not throws) the first
# time the built-in summarizer runs, so Transcripts vanished mid-summarize with no
# crash report (2026-08-03). Upstream mlx-swift states the same: "SwiftPM
# (command line) cannot build the Metal shaders ... the ultimate build has to be
# done via Xcode." xcodebuild also needs Xcode's separately-downloaded Metal
# Toolchain component (xcodebuild -downloadComponent MetalToolchain).
XC_CONFIG="Release"
[[ "$CONFIG" == "debug" ]] && XC_CONFIG="Debug"
DERIVED="$ROOT/.build/xcode"

echo "▶ Building $APP_NAME ($XC_CONFIG, xcodebuild) …"
xcodebuild build \
  -scheme "$APP_NAME" \
  -configuration "$XC_CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED" \
  > "$ROOT/.build/xcodebuild.log" 2>&1 \
  || { echo "✗ build failed — tail of .build/xcodebuild.log:" >&2; tail -30 "$ROOT/.build/xcodebuild.log" >&2; exit 1; }

PRODUCTS="$DERIVED/Build/Products/$XC_CONFIG"
BIN_PATH="$PRODUCTS/$APP_NAME"
[[ -x "$BIN_PATH" ]] || { echo "✗ built binary not found at $BIN_PATH" >&2; exit 1; }

# Assemble the bundle in .build so a rebuild is clean.
APP_STAGE="$ROOT/.build/$APP_NAME.app"
rm -rf "$APP_STAGE"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"

cp "$BIN_PATH" "$APP_STAGE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Sources/TranscriptsMac/Support/Info.plist" "$APP_STAGE/Contents/Info.plist"
printf 'APPL????' > "$APP_STAGE/Contents/PkgInfo"

# App icon. Regenerate with `just icon` after editing scripts/make-icon.swift.
if [[ -f "$ROOT/Sources/TranscriptsMac/Support/Transcripts.icns" ]]; then
  cp "$ROOT/Sources/TranscriptsMac/Support/Transcripts.icns" "$APP_STAGE/Contents/Resources/Transcripts.icns"
fi

# SwiftPM emits each dependency's resources as a sibling .bundle next to the
# binary; copying only the executable leaves them behind. MLX finds its compiled
# Metal shaders (mlx-swift_Cmlx.bundle/default.metallib) by scanning bundles
# relative to the main bundle, and when it can't it kills the process instead of
# throwing — an app that summarizes once and vanishes (2026-08-03).
shopt -s nullglob
RES_BUNDLES=("$PRODUCTS"/*.bundle)
shopt -u nullglob
if (( ${#RES_BUNDLES[@]} )); then
  echo "▶ Bundling ${#RES_BUNDLES[@]} SwiftPM resource bundle(s) …"
  for b in "${RES_BUNDLES[@]}"; do
    cp -R "$b" "$APP_STAGE/Contents/Resources/"
    echo "    $(basename "$b")"
  done
fi

# The MLX shaders are only produced when the build host has Xcode's Metal
# Toolchain component; the build skips them silently otherwise. Catch that here
# rather than shipping an app whose built-in summarizer takes the process down.
if [[ "$(uname -m)" == "arm64" && "${REQUIRE_METAL:-1}" != "0" ]]; then
  if ! find "$APP_STAGE/Contents/Resources" -name 'default.metallib' | grep -q .; then
    echo "✗ MLX Metal shaders (default.metallib) missing from the build." >&2
    echo "  Install the toolchain, then rebuild:" >&2
    echo "      xcodebuild -downloadComponent MetalToolchain" >&2
    echo "  (REQUIRE_METAL=0 to build anyway — the built-in MLX summarizer will" >&2
    echo "   be skipped and summaries fall back to the extractive floor.)" >&2
    exit 1
  fi
  echo "  ✓ MLX Metal shaders present"
fi

# Sign with a STABLE identity so TCC (Microphone, Screen Recording) keeps its grant
# across rebuilds. Ad-hoc signing regenerates the code identity on every compile,
# which invalidates the grant — macOS then reports `authorized` but feeds the app
# SILENCE. The "Transcripts Local Signing" self-signed cert (see scripts/make-signing-cert.sh)
# gives a fixed identity; we fall back to ad-hoc only if it isn't installed.
SIGN_ID="-"
SIGN_DESC="ad-hoc (unstable — TCC grants won't persist; run scripts/make-signing-cert.sh)"
if security find-identity -p codesigning 2>/dev/null | grep -q "Transcripts Local Signing"; then
  SIGN_ID="Transcripts Local Signing"
  SIGN_DESC="Transcripts Local Signing (stable)"
fi

# Sign WITHOUT entitlements. This app is unsandboxed, so it needs none — mic and
# screen-recording access come purely from TCC consent + the Info.plist usage
# strings. Signing a self-signed (no provisioning profile) app WITH sandbox
# entitlements like `com.apple.security.device.audio-input` is a known way to end
# up "authorized" but silent.
echo "▶ Signing — $SIGN_DESC …"
codesign --force --sign "$SIGN_ID" \
  --identifier "$BUNDLE_ID" \
  --timestamp=none \
  "$APP_STAGE"

codesign --verify --strict "$APP_STAGE" && echo "  ✓ signature valid ($SIGN_DESC)"

if [[ -n "${NO_INSTALL:-}" ]]; then
  echo "✓ Bundle staged at $APP_STAGE (not installed)"
  exit 0
fi

# Stop any running copy so we can replace the bundle in place.
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

mkdir -p "$INSTALL_DIR"
APP_DEST="$INSTALL_DIR/$APP_NAME.app"
rm -rf "$APP_DEST"
cp -R "$APP_STAGE" "$APP_DEST"
echo "✓ Installed to $APP_DEST"

if [[ -z "${NO_LAUNCH:-}" ]]; then
  echo "▶ Launching …"
  open "$APP_DEST"
  echo "✓ $APP_NAME is running — look for its icon in the menu bar."
  echo "  First recording will prompt for Microphone access (grant it in the dialog"
  echo "  or System Settings ▸ Privacy & Security ▸ Microphone)."
fi
