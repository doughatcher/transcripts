#!/usr/bin/env bash
#
# Render the Mac app icon: scripts/make-icon.swift --macos → .iconset → .icns
#
# The .icns is committed rather than built on every run, because compiling the
# generator costs a few seconds and the artwork changes about never. Re-run this
# (or `just icon`) after editing make-icon.swift.
#
# Note the macOS artwork is NOT the iOS one: Apple's grid wants an inset rounded
# rect with a shadow, where iOS is full-bleed and masked by the system.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

OUT="Sources/TranscriptsMac/Support/Transcripts.icns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/Transcripts.iconset"
mkdir -p "$SET"

echo "▶ Rendering artwork …"
swift scripts/make-icon.swift "$TMP/mac.png" --macos >/dev/null

echo "▶ Scaling to the iconset sizes …"
# name:pixels — iconutil requires exactly these names, and a missing one makes
# it fail with a bare "Failed to generate ICNS" and no hint which.
for entry in \
  icon_16x16:16      icon_16x16@2x:32 \
  icon_32x32:32      icon_32x32@2x:64 \
  icon_128x128:128   icon_128x128@2x:256 \
  icon_256x256:256   icon_256x256@2x:512 \
  icon_512x512:512   icon_512x512@2x:1024
do
  name="${entry%%:*}"
  px="${entry##*:}"
  sips -z "$px" "$px" "$TMP/mac.png" --out "$SET/$name.png" >/dev/null
done

iconutil -c icns "$SET" -o "$OUT"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
