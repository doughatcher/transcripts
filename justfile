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

# Build and install straight onto the paired iPhone and iPad, without waiting
# for TestFlight to process a build. Same headless signing as `testflight`.
#
# Devices are addressed by devicectl identifier, never by name: this iPad is
# named with a Unicode right quote that does not survive shell round-tripping,
# and matching by name fails with CoreDeviceError 1000. `just devices` prints
# the identifiers.
devices: project
    #!/usr/bin/env bash
    set -euo pipefail
    set -a; source .env.signing; set +a
    KEY="$(eval echo "$ASC_KEY_PATH")"
    echo "▶ Building for device"
    xcodebuild -project Transcripts.xcodeproj -scheme Transcripts -configuration Debug \
      -destination 'generic/platform=iOS' -derivedDataPath .build/ios-device \
      DEVELOPMENT_TEAM=6Q9BX97LMS \
      -allowProvisioningUpdates \
      -authenticationKeyPath "$KEY" \
      -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
      build > .build/ios-device.log 2>&1 \
      || { echo "✗ build failed — tail of .build/ios-device.log:" >&2; tail -25 .build/ios-device.log >&2; exit 1; }
    APP=.build/ios-device/Build/Products/Debug-iphoneos/Transcripts.app
    # Every paired physical device, so a new one is picked up without editing
    # this recipe. A device that is locked or off refuses the install; that is
    # reported per device rather than failing the whole run.
    xcrun devicectl list devices --json-output .build/devices.json > /dev/null
    IDS="$(python3 -c "
    import json
    d = json.load(open('.build/devices.json'))['result']['devices']
    for x in d:
        p = x.get('deviceProperties', {})
        h = x.get('hardwareProperties', {})
        # reality distinguishes a real device from a simulator; platform alone
        # does not, and a shutdown simulator answers 'paired'.
        if (h.get('platform') == 'iOS' and h.get('reality') == 'physical'
                and x.get('connectionProperties', {}).get('pairingState') == 'paired'):
            print(x['identifier'], p.get('name', '?').replace(' ', '_'))
    ")"
    [[ -n "$IDS" ]] || { echo "✗ no paired iOS devices — connect or unlock them" >&2; exit 1; }
    while read -r ID NAME; do
      [[ -n "$ID" ]] || continue
      echo "▶ Installing to ${NAME//_/ }"
      # Retry: the two ways this fails in practice are both temporary. A locked
      # device refuses outright, and the wireless tunnel drops the connection
      # ("reset by peer") often enough to be worth riding out rather than
      # reporting as a failure the user has to act on.
      for attempt in 1 2 3 4 5; do
        if xcrun devicectl device install app --device "$ID" "$APP" > .build/install-$ID.log 2>&1; then
          echo "  ✓ installed"
          break
        fi
        if [[ $attempt -eq 5 ]]; then
          echo "  ✗ failed after 5 tries — see .build/install-$ID.log" >&2
          grep -m1 -o 'NSLocalizedFailureReason = .*' .build/install-$ID.log >&2 || tail -3 .build/install-$ID.log >&2
        else
          sleep 5
        fi
      done
    done <<< "$IDS"

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
