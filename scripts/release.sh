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
  # --keychain is not optional here, despite reading like it. Without it,
  # notarytool stores the profile somewhere it cannot find again:
  # `store-credentials` validates against Apple and reports success, and the
  # very next lookup says "No Keychain password item found". Naming the login
  # keychain explicitly on both the store and the read makes it persist.
  #
  #   xcrun notarytool store-credentials transcripts-notary \
  #     --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  #     --key-id <KEYID> --issuer <ISSUER> \
  #     --keychain ~/Library/Keychains/login.keychain-db
  # Submit, then poll. `--wait` crashes with a Bus error on this toolchain
  # (macOS 26 / Xcode 26.6) *after* the upload succeeds, which killed the
  # release script mid-flight while the submission sailed on to Accepted —
  # the worst shape of failure, since everything downstream was skipped for a
  # build that was actually fine.
  NOTARY_ARGS=(--keychain-profile transcripts-notary
               --keychain "${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}")
  # `|| true`, and to a file rather than a pipe: the crash lands *after* the
  # upload and the id have been printed, and under `set -eo pipefail` either
  # form would take the script down with a submission already in flight.
  SUBMIT_LOG="$ROOT/.build/notarytool-submit.log"
  xcrun notarytool submit "$TMPZIP" "${NOTARY_ARGS[@]}" > "$SUBMIT_LOG" 2>&1 || true
  SUBMIT_ID="$(awk '/^  id: /{print $2; exit}' "$SUBMIT_LOG")"
  if [[ -z "$SUBMIT_ID" ]]; then
    echo "✗ notarytool did not return a submission id:" >&2
    cat "$SUBMIT_LOG" >&2
    exit 1
  fi
  echo "  submission $SUBMIT_ID"

  NOTARY_STATUS="In Progress"
  for _ in $(seq 1 90); do
    sleep 20
    NOTARY_STATUS="$(xcrun notarytool info "$SUBMIT_ID" "${NOTARY_ARGS[@]}" 2>/dev/null \
      | awk '/status:/{ $1=""; sub(/^ /,""); print; exit }')"
    [[ "$NOTARY_STATUS" == "In Progress" ]] || break
    printf '.'
  done
  echo
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "✗ notarization $NOTARY_STATUS — details:" >&2
    xcrun notarytool log "$SUBMIT_ID" "${NOTARY_ARGS[@]}" 2>&1 | head -40 >&2
    exit 1
  fi
  echo "  ✓ accepted"
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

MANIFEST=$(cat <<JSON
{
  "version": "$VERSION",
  "url": "$BASE_URL/$ZIP_NAME",
  "sha256": "$SHA",
  "size": $SIZE,
  "minimumSystemVersion": "14.0",
  "notes": "$NOTES"
}
JSON
)

# Two channels, one artifact. A pre-release writes ONLY the beta manifest, so
# stable riders are never offered it. A stable release writes both, so someone
# on the beta train still receives a finished version once it is newer than the
# last beta — otherwise opting into betas would strand you on them.
printf '%s\n' "$MANIFEST" > "$SITE/appcast-beta.json"
if [[ "$VERSION" == *-* ]]; then
  echo "  ✓ appcast-beta.json (pre-release — stable channel untouched)"
  # Carry forward the published STABLE manifest, if there is one. Fetched and
  # checked rather than copied blindly: an earlier build wrote a pre-release
  # into appcast.json, which would have offered a beta to everyone who had
  # deliberately not asked for one.
  if curl -fsS --max-time 20 "$BASE_URL/appcast.json" -o "$SITE/.appcast-prev.json" 2>/dev/null; then
    PREV=$(python3 -c "import json;print(json.load(open('$SITE/.appcast-prev.json'))['version'])" 2>/dev/null || echo "")
    if [[ -n "$PREV" && "$PREV" != *-* ]]; then
      mv "$SITE/.appcast-prev.json" "$SITE/appcast.json"
      echo "  ✓ appcast.json (preserved stable $PREV)"
    else
      rm -f "$SITE/.appcast-prev.json"
      echo "  · no stable release published — stable channel left empty"
    fi
  fi
else
  printf '%s\n' "$MANIFEST" > "$SITE/appcast.json"
  echo "  ✓ appcast.json + appcast-beta.json"
fi

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

  depends_on macos: :sonoma

  app "Transcripts.app"

  zap trash: [
    "~/Library/Application Support/Transcripts",
    "~/Library/Logs/Transcripts.log",
    "~/Library/Preferences/ltd.hatcher.transcripts.plist",
  ]
end
RUBY
echo "  ✓ dist/transcripts.rb"

# --- 8. Publish --------------------------------------------------------------
# Deploy and tap-push happen here rather than as copy-paste instructions,
# because a release that is three commands is a release where someone
# eventually runs two of them. The gate is notarization, not caution: an
# unsigned build cannot reach this point unless NOTARIZE=0 was passed
# deliberately, and that path refuses to publish.
if [[ "${PUBLISH:-1}" == "1" && "$NOTARIZE" == "1" ]]; then
  echo "▶ Deploying site"
  npx wrangler pages deploy "$SITE" --project-name=transcripts --commit-dirty=true 2>&1 | tail -2

  TAP="${TAP_DIR:-$HOME/repos/homebrew-tap}"
  if [[ -d "$TAP/.git" ]]; then
    echo "▶ Updating the tap"
    cp "$CASK" "$TAP/Casks/transcripts.rb"
    git -C "$TAP" pull -q --rebase 2>/dev/null || true
    if git -C "$TAP" diff --quiet -- Casks/transcripts.rb; then
      echo "  · cask unchanged"
    else
      git -C "$TAP" commit -q -am "transcripts $VERSION" && git -C "$TAP" push -q
      echo "  ✓ tap updated to $VERSION"
    fi
  else
    echo "  ! no tap checkout at $TAP — skipping (clone hatcher-ltd/homebrew-tap there)"
  fi

  # The three consumers must agree. Verified against what is actually served,
  # not against local files, because the failure this catches is a deploy that
  # silently did not land.
  echo "▶ Verifying published release"
  sleep 5
  CHANNEL="appcast.json"; [[ "$VERSION" == *-* ]] && CHANNEL="appcast-beta.json"
  PUB=$(curl -fsS --max-time 30 "$BASE_URL/$CHANNEL" | python3 -c "import json,sys;print(json.load(sys.stdin)['sha256'])" 2>/dev/null || echo "")
  TAPSHA=$(grep -oE '[a-f0-9]{64}' "$TAP/Casks/transcripts.rb" 2>/dev/null | head -1 || echo "")
  if [[ "$PUB" == "$SHA" && "$TAPSHA" == "$SHA" ]]; then
    echo "  ✓ manifest, cask and artifact all agree (${SHA:0:16}…)"
  else
    echo "  ✗ MISMATCH — manifest=${PUB:0:16}… cask=${TAPSHA:0:16}… built=${SHA:0:16}…" >&2
    exit 1
  fi

  cat <<DONE

✓ Published $VERSION → $BASE_URL
  brew install --cask hatcher-ltd/tap/transcripts
DONE
else
  cat <<DONE

✓ Release $VERSION staged (not published).
  PUBLISH=0 or NOTARIZE=0 was set — nothing was deployed and the tap is untouched.
  Staged at: $SITE
DONE
fi
