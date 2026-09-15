#!/usr/bin/env bash
#
# Build Transcripts.app and install it to ~/Applications.
#
# Why a real bundle: a bare executable has no stable bundle identity, so macOS
# TCC will not grant it Microphone or Screen Recording — the mic silently
# returns zeroed buffers and you get an empty recording. The Info.plist and a
# code signature are what let TCC prompt and remember the grant.
#
# Usage:
#   scripts/make-app.sh                 # build (release), install, launch
#   CONFIG=debug scripts/make-app.sh    # debug build
#   NO_LAUNCH=1 scripts/make-app.sh     # build + install, don't launch
#   NO_INSTALL=1 scripts/make-app.sh    # stage in .build/ only

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# An unset DEVELOPER_DIR is not the only broken one. A shell that exports
# /Library/Developer/CommandLineTools passes a -z test but ships no Platforms
# and no xcodebuild, so the probe below used to be skipped and the build died
# much later with an error that named none of this. Running through `just`
# masked it, because the justfile exports Xcode's path over the top. Test for a
# toolchain that can actually build, not for a variable that happens to be set.
if [[ ! -d "${DEVELOPER_DIR:-}/Platforms/MacOSX.platform" ]]; then
  # Prefer the beta toolchain when installed — it owns the Metal Toolchain
  # component, without which mlx-swift ships no shaders and the summarizer
  # takes the process down at first use.
  for x in "$HOME/Downloads/Xcode-beta.app" /Applications/Xcode-beta.app /Applications/Xcode.app; do
    [[ -d "$x" ]] && { export DEVELOPER_DIR="$x/Contents/Developer"; break; }
  done
  if [[ ! -d "${DEVELOPER_DIR:-}/Platforms/MacOSX.platform" ]]; then
    echo "✗ no full Xcode found — DEVELOPER_DIR=${DEVELOPER_DIR:-<unset>} has no Platforms/." >&2
    echo "  Install Xcode, or point DEVELOPER_DIR at its Contents/Developer." >&2
    exit 1
  fi
fi

APP_NAME="Transcripts"
SCHEME="TranscriptsMac"          # NOT "Transcripts" — that is the iOS app.
BUNDLE_ID="ltd.hatcher.transcripts"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
CONFIG="${CONFIG:-release}"
XC_CONFIG="Release"; [[ "$CONFIG" == "debug" ]] && XC_CONFIG="Debug"
DERIVED="$ROOT/.build/xcode"

# Rebuilding during a live recording is expected — a session can run for hours
# and waiting it out is not a dev loop. Two things make it safe, and both live in
# the app rather than here: captures are LPCM-in-CAF (readable at any truncation
# point), and SIGTERM is handled, so the app carries the recording forward and
# the next launch resumes the meeting instead of filing half of it.
#
# This used to refuse outright, from the days when the live file was AAC and a
# kill lost it. That is no longer true; see Recorder.start and RelaunchState.

# xcodebuild, not `swift build`: SwiftPM's command-line build system has no
# Metal rule, so it silently skips mlx-swift's shaders and the app ships with no
# default.metallib — MLX then kills the process (not throws) the first time the
# built-in summarizer runs. Needs Xcode's separately-downloaded Metal Toolchain
# (xcodebuild -downloadComponent MetalToolchain).
# Sign with a STABLE identity so TCC keeps its grant across rebuilds. Ad-hoc
# signing regenerates the code identity every compile, which invalidates the
# grant — macOS then reports `authorized` and feeds the app SILENCE.
#
# WITHOUT entitlements: this app is unsandboxed, and a self-signed build
# carrying sandbox entitlements is a known way to end up authorized but silent.
#
# Resolved BEFORE the build, because project.yml names this identity as the
# target's CODE_SIGN_IDENTITY: on a machine without it in the keychain — any
# CI runner — xcodebuild refuses at build-description time and never compiles
# a line. There is nothing to fail over: the bundle is re-signed below either
# way, and release.sh signs it again with Developer ID. So when the identity
# is absent, build unsigned and let the signing step downstream be the one
# that decides the identity.
SIGN_ID="-"; SIGN_DESC="ad-hoc (unstable — run scripts/make-signing-cert.sh)"
XCSIGN=(CODE_SIGNING_ALLOWED=NO)
if security find-identity -p codesigning 2>/dev/null | grep -q "$APP_NAME Local Signing"; then
  SIGN_ID="$APP_NAME Local Signing"; SIGN_DESC="$APP_NAME Local Signing (stable)"
  XCSIGN=()
fi

# Transcripts.xcodeproj is generated and gitignored — project.yml is the source
# of truth. Regenerate here rather than only in the justfile's `project` recipe,
# so a direct `scripts/make-app.sh` cannot build against whatever the spec said
# the last time someone ran xcodegen by hand. Skipping this is how a beta.10
# checkout produced, signed and installed an app stamped beta.7.
echo "▶ Generating Transcripts.xcodeproj from project.yml …"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet && echo "  ✓ project in sync with project.yml"
elif [[ -d "$ROOT/Transcripts.xcodeproj" ]]; then
  echo "  ! xcodegen not installed — building the existing project, which may be" >&2
  echo "    stale against project.yml. brew install xcodegen" >&2
else
  echo "✗ no Transcripts.xcodeproj and no xcodegen to generate it." >&2
  echo "  brew install xcodegen" >&2
  exit 1
fi

echo "▶ Building $APP_NAME ($XC_CONFIG) …"
mkdir -p "$ROOT/.build"
BUILD_LOG="$ROOT/.build/xcodebuild.log"
XCARGS=(build
  ${XCSIGN[@]+"${XCSIGN[@]}"}
  -project "$ROOT/Transcripts.xcodeproj"
  -scheme "$SCHEME"
  -configuration "$XC_CONFIG"
  -destination "platform=macOS,arch=$(uname -m)"
  -derivedDataPath "$DERIVED")

# Locally the log is noise and lives in a file. In CI it is the only evidence
# there will ever be: GitHub serves a job's log only once the job ends, so a
# build that hangs rather than fails leaves a file nobody can read and a step
# that says nothing for forty minutes. Stream it there, and let the workflow
# keep the file as an artifact.
set +e
if [[ -n "${CI:-}" ]]; then
  NSUnbufferedIO=YES xcodebuild "${XCARGS[@]}" 2>&1 | tee "$BUILD_LOG"
  BUILD_RC=${PIPESTATUS[0]}
else
  xcodebuild "${XCARGS[@]}" > "$BUILD_LOG" 2>&1
  BUILD_RC=$?
fi
set -e
if [[ "$BUILD_RC" -ne 0 ]]; then
  echo "✗ build failed — tail of .build/xcodebuild.log:" >&2
  tail -30 "$BUILD_LOG" >&2
  exit 1
fi

BUILT="$DERIVED/Build/Products/$XC_CONFIG/$APP_NAME.app"
[[ -d "$BUILT" ]] || { echo "✗ no bundle at $BUILT" >&2; exit 1; }

APP_STAGE="$ROOT/.build/$APP_NAME.app"
rm -rf "$APP_STAGE"
cp -R "$BUILT" "$APP_STAGE"

# The MLX shaders only exist when the build host has the Metal Toolchain; the
# build skips them silently otherwise. Catch it here rather than shipping an app
# whose summarizer takes the process down.
if [[ "$(uname -m)" == "arm64" && "${REQUIRE_METAL:-1}" != "0" ]]; then
  if ! find "$APP_STAGE/Contents" -name 'default.metallib' | grep -q .; then
    echo "✗ MLX Metal shaders (default.metallib) missing from the build." >&2
    echo "      xcodebuild -downloadComponent MetalToolchain" >&2
    echo "  (REQUIRE_METAL=0 to build anyway — summaries fall back to the extractive floor.)" >&2
    exit 1
  fi
  echo "  ✓ MLX Metal shaders present"
fi

echo "▶ Signing — $SIGN_DESC …"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" \
  --timestamp=none "$APP_STAGE" 2>/dev/null
codesign --verify --strict "$APP_STAGE" && echo "  ✓ signature valid"

if [[ -n "${NO_INSTALL:-}" ]]; then
  echo "✓ Staged at $APP_STAGE (not installed)"
  exit 0
fi

# Graceful stop: SIGTERM, then wait for the app to actually go. It carries any
# live recording forward on the way out, which is what makes the relaunch pick
# the meeting back up. SIGKILL only if it will not leave.
# Match the macOS bundle layout rather than the process name. An iOS Simulator
# run of this same app is also called "Transcripts", so `pgrep -x` matches it
# too, and a leftover simulator process then holds the wait loop below open for
# its full 15s and trips the SIGKILL fallback — which is exactly what can cut
# short the carry-forward this path exists to protect. Only a macOS bundle has
# Contents/MacOS; the iOS bundle is Transcripts.app/Transcripts.
MAC_PROC="$APP_NAME.app/Contents/MacOS/$APP_NAME"
if pgrep -fq "$MAC_PROC"; then
  RECORDING=""
  HISTORY="$HOME/Library/Application Support/$APP_NAME/history.json"
  if [[ -f "$HISTORY" ]] && python3 -c '
import json, sys
sys.exit(0 if any(r.get("status") == "recording" for r in json.load(open(sys.argv[1]))) else 1)
' "$HISTORY" 2>/dev/null; then RECORDING=" (recording — carrying it forward)"; fi
  echo "▶ Stopping the running $APP_NAME$RECORDING …"
  pkill -f "$MAC_PROC" 2>/dev/null || true
  for _ in $(seq 1 60); do
    pgrep -fq "$MAC_PROC" || break
    sleep 0.25
  done
  if pgrep -fq "$MAC_PROC"; then
    echo "  ! did not exit in 15s — forcing" >&2
    pkill -9 -f "$MAC_PROC" 2>/dev/null || true
    sleep 0.5
  fi
fi
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_STAGE" "$INSTALL_DIR/$APP_NAME.app"
echo "✓ Installed to $INSTALL_DIR/$APP_NAME.app"

if [[ -z "${NO_LAUNCH:-}" ]]; then
  # LaunchServices can still be holding the old bundle a moment after it is
  # replaced and answers -600 (procNotFound). Retrying costs nothing; failing
  # here leaves a carried-forward recording with no app to resume it, which is
  # the one outcome this whole path exists to avoid.
  for attempt in 1 2 3 4 5; do
    if open "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null; then break; fi
    [[ $attempt -eq 5 ]] && { echo "✗ could not launch $APP_NAME — run: open '$INSTALL_DIR/$APP_NAME.app'" >&2; exit 1; }
    sleep 1
  done
  echo "✓ $APP_NAME is running — look for the Transcripts mark in the menu bar."
fi
