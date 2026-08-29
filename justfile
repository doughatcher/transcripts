# Transcripts — pocket recorder for iOS.
# `brew install xcodegen just` to bootstrap.

export DEVELOPER_DIR := "/Applications/Xcode.app/Contents/Developer"

default: build

# Regenerate Transcripts.xcodeproj from project.yml (the xcodeproj is not
# checked in — the spec is the source of truth).
project:
    xcodegen generate

# Build for the iOS Simulator (no signing required).
build: project
    xcodebuild build -project Transcripts.xcodeproj -scheme Transcripts \
      -destination 'generic/platform=iOS Simulator' \
      CODE_SIGNING_ALLOWED=NO | tail -5

# Open in Xcode (for device runs, signing, archives).
open: project
    open Transcripts.xcodeproj

# Archive the iOS app and upload it to TestFlight. Signing and profiles are
# minted headlessly from the App Store Connect API key in .env.signing
# (gitignored) — there is no Apple ID signed into Xcode on this machine, so
# -allowProvisioningUpdates alone would fail with "No Accounts".
# Version and build number come from project.yml; scripts/release.sh stamps
# them, so run this after a release (or bump them by hand for a TestFlight-only
# iteration).
testflight: project
    #!/usr/bin/env bash
    set -euo pipefail
    set -a; source .env.signing; set +a
    KEY="$(eval echo "$ASC_KEY_PATH")"
    echo "▶ Archiving iOS"
    xcodebuild archive -project Transcripts.xcodeproj -scheme Transcripts \
      -destination 'generic/platform=iOS' \
      -archivePath .build/Transcripts-ios.xcarchive \
      DEVELOPMENT_TEAM=6Q9BX97LMS \
      -allowProvisioningUpdates \
      -authenticationKeyPath "$KEY" \
      -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
      > .build/ios-archive.log 2>&1 \
      || { echo "✗ archive failed — tail of .build/ios-archive.log:" >&2; tail -20 .build/ios-archive.log >&2; exit 1; }
    echo "▶ Uploading to App Store Connect"
    # /usr/bin first: exportArchive builds the IPA with `rsync` from PATH and
    # passes Apple-only flags that Homebrew's rsync 3.4.1 rejects ("syntax or
    # usage error"), which surfaces as the unhelpful "Copy failed".
    PATH="/usr/bin:$PATH" xcodebuild -exportArchive \
      -archivePath .build/Transcripts-ios.xcarchive \
      -exportOptionsPlist scripts/exportOptions-appstore.plist \
      -allowProvisioningUpdates \
      -authenticationKeyPath "$KEY" \
      -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
      > .build/ios-upload.log 2>&1 \
      || { echo "✗ upload failed — tail of .build/ios-upload.log:" >&2; tail -20 .build/ios-upload.log >&2; exit 1; }
    echo "✓ Uploaded — TestFlight processes it in a few minutes."
