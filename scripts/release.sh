#!/usr/bin/env bash
#
# Cut a release: build, sign, notarize, zip, checksum, and stage everything the
# three download paths need — the site, the in-app updater, and Homebrew.
#
# One artifact, one manifest, three consumers. The appcast is the keystone: the
# updater and the cask both read the same file, so a release cannot half-ship
# with brew offering one version and the app another.
#
#   scripts/release.sh 0.1.0-beta.1
#   NOTARIZE=0 scripts/release.sh 0.1.0-beta.1   # local dry run, unsigned
#
# Notarization needs a Developer ID certificate (paid Apple Developer Program)
# and a stored keychain profile:
#   xcrun notarytool store-credentials transcripts-notary \
#     --apple-id <you> --team-id <TEAMID> --password <app-specific-password>

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: scripts/release.sh <version>   e.g. 0.1.0-beta.1" >&2; exit 2; }

APP_NAME="Transcripts"
BUNDLE_ID="ltd.hatcher.transcripts"
SITE="$ROOT/site/public"
ZIP_NAME="$APP_NAME-$VERSION.zip"
NOTARIZE="${NOTARIZE:-1}"
BASE_URL="${BASE_URL:-https://transcripts.hatcher.ltd}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for x in "$HOME/Downloads/Xcode-beta.app" /Applications/Xcode-beta.app /Applications/Xcode.app; do
    [[ -d "$x" ]] && { export DEVELOPER_DIR="$x/Contents/Developer"; break; }
  done
fi

# --- 1. Version the build ----------------------------------------------------
# MARKETING_VERSION lives in project.yml, and a manually-specified Info.plist
# does not inherit it — the keys are threaded through by hand there, so bumping
# the spec is what actually moves CFBundleShortVersionString.
#
# The two platforms cannot share a version string. Apple requires
# CFBundleShortVersionString to be three period-separated integers, so a
# pre-release like 1.0.0-beta.1 is rejected outright by App Store Connect —
# while the Mac's updater is deliberately pre-release aware and wants exactly
# that. So: the Mac target gets the full version, the iOS targets get its
# numeric core, and TestFlight iterations move the build number instead.
IOS_VERSION="${VERSION%%-*}"
IOS_BUILD="${IOS_BUILD:-1}"
echo "▶ Version — macOS $VERSION · iOS $IOS_VERSION (build $IOS_BUILD)"

python3 - "$VERSION" "$IOS_VERSION" "$IOS_BUILD" <<'PY'
import re, sys
version, ios_version, ios_build = sys.argv[1], sys.argv[2], sys.argv[3]
spec = open("project.yml").read()

# Targets appear in spec order: Transcripts (iOS), TranscriptsWidgets (iOS),
# TranscriptsMac. Split on the target headers so each gets the right value
# rather than a global replace stamping the Mac's string onto iOS.
parts = re.split(r"(?m)^  (\w+):$", spec)
out = [parts[0]]
for name, body in zip(parts[1::2], parts[2::2]):
    if name == "TranscriptsMac":
        body = re.sub(r'MARKETING_VERSION: "[^"]*"', f'MARKETING_VERSION: "{version}"', body)
    else:
        body = re.sub(r'MARKETING_VERSION: "[^"]*"', f'MARKETING_VERSION: "{ios_version}"', body)
        body = re.sub(r'CURRENT_PROJECT_VERSION: "[^"]*"', f'CURRENT_PROJECT_VERSION: "{ios_build}"', body)
    out.append(f"  {name}:\n")
    out.append(body)
open("project.yml", "w").write("".join(out))
PY
xcodegen generate >/dev/null

# --- 2. Build + bundle -------------------------------------------------------
echo "▶ Building"
NO_INSTALL=1 NO_LAUNCH=1 scripts/make-app.sh >/dev/null
APP="$ROOT/.build/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "✗ no app bundle at $APP" >&2; exit 1; }

# --- 3. Developer ID sign + notarize ----------------------------------------
# Without this the download is a Gatekeeper wall for everyone who is not us.
# The local self-signed identity is fine for development and useless for
# distribution, so refuse to publish one by accident.
if [[ "$NOTARIZE" == "1" ]]; then
  DEVID="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
  if [[ -z "$DEVID" ]]; then
    cat >&2 <<'MSG'
✗ No "Developer ID Application" certificate found.

  Notarization requires the paid Apple Developer Program. Until enrollment
  completes, build an unsigned artifact for local testing with:

      NOTARIZE=0 scripts/release.sh <version>

  — but do not publish it: every downloader will hit Gatekeeper.
MSG
    exit 1
  fi
  echo "▶ Signing — $DEVID"
  codesign --force --deep --options runtime --timestamp \
    --sign "$DEVID" --identifier "$BUNDLE_ID" "$APP"

  echo "▶ Notarizing (this takes a few minutes)"
  TMPZIP="$(mktemp -d)/$ZIP_NAME"
  ditto -c -k --keepParent "$APP" "$TMPZIP"
  xcrun notarytool submit "$TMPZIP" --keychain-profile transcripts-notary --wait
  xcrun stapler staple "$APP"
  echo "  ✓ stapled"
else
  echo "▶ Skipping notarization (NOTARIZE=0) — NOT publishable"
fi

# --- 4. Site first, THEN artifacts into it -----------------------------------
# Order matters and got this wrong once: build.py wipes site/public before
# rendering, so writing the zip and the appcast first meant the site build
# deleted both — deploying a page whose download button 404s. The site is
# rendered first now, and the artifacts land in the finished directory.
echo "▶ Building site"
python3 site/build.py >/dev/null
echo "  ✓ site rendered"

# --- 5. Zip + checksum -------------------------------------------------------
mkdir -p "$SITE"
ZIP="$SITE/$ZIP_NAME"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE="$(stat -f%z "$ZIP")"
echo "▶ $ZIP_NAME — $(( SIZE / 1024 / 1024 )) MB, sha256 ${SHA:0:16}…"

# --- 6. Appcast --------------------------------------------------------------
# Read by the in-app updater AND the Homebrew cask. Notes come from the guide's
# changelog if present, so release notes are written where the docs live.
NOTES="$(sed -n "/^## $VERSION\$/,/^## /p" docs/guide/changelog.md 2>/dev/null | sed '1d;$d' | sed 's/"/\\"/g' | tr '\n' ' ' || true)"
[[ -n "$NOTES" ]] || NOTES="See the user guide for what's new."

cat > "$SITE/appcast.json" <<JSON
{
  "version": "$VERSION",
  "url": "$BASE_URL/$ZIP_NAME",
  "sha256": "$SHA",
  "size": $SIZE,
  "minimumSystemVersion": "14.0",
  "notes": "$NOTES"
}
JSON
echo "  ✓ appcast.json"

# Stable alias so the site's download button never needs editing.
cp "$ZIP" "$SITE/$APP_NAME-macos.zip"

# --- 7. Homebrew cask --------------------------------------------------------
# Written here rather than hand-maintained in the tap, so the checksum can never
# disagree with the artifact it describes.
mkdir -p "$ROOT/dist"
CASK="$ROOT/dist/transcripts.rb"
cat > "$CASK" <<RUBY
cask "transcripts" do
  version "$VERSION"
  sha256 "$SHA"

  url "$BASE_URL/Transcripts-#{version}.zip"
  name "Transcripts"
  desc "Voice notes and meeting transcripts, recorded and transcribed on-device"
  homepage "$BASE_URL"

  livecheck do
    url "$BASE_URL/appcast.json"
    strategy :json do |json|
      json["version"]
    end
  end

  depends_on macos: ">= :sonoma"

  app "Transcripts.app"

  zap trash: [
    "~/Library/Application Support/Transcripts",
    "~/Library/Logs/Transcripts.log",
    "~/Library/Preferences/ltd.hatcher.transcripts.plist",
  ]
end
RUBY
echo "  ✓ dist/transcripts.rb"

cat <<DONE

✓ Release $VERSION staged.

  Publish:
    npx wrangler pages deploy site/public --project-name=transcripts
  Then copy the cask into the tap:
    cp dist/transcripts.rb ../homebrew-tap/Casks/transcripts.rb \
      && (cd ../homebrew-tap && git commit -am "transcripts $VERSION" && git push)

  Users then:
    brew install --cask hatcher-ltd/tap/transcripts
DONE
