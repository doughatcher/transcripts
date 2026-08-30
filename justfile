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
# for TestFlight to process a build. Development signing, from the App Store
# Connect key in .env.signing — which is fine here and is exactly why this is
# not the path a store build takes; see `testflight`.
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

# Upload a build to TestFlight and App Store Connect, by way of CI.
#
# This used to archive and upload from here, and that produced a build Apple
# rejected while the identical commit built by .github/workflows/testflight.yml
# was accepted. The local path signed with a *development* identity, and it ran
# none of the checks the workflow makes on the exported IPA: the assertion that
# no networking symbol reached the binary — which is the App Store privacy
# answer, verified rather than promised — and the ITMS-90626 Siri-description
# check, which matters because App Store processing applies that one *after*
# upload and then discards the build silently.
#
# Two upload paths meant one of them was always the untested one. So this is a
# thin wrapper now: push, dispatch the workflow, follow it. Slower than a local
# archive, and it produces builds that are accepted.
testflight:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "$(git status --porcelain)" ]]; then
      echo "✗ Working tree is dirty. CI builds what you push, so commit first." >&2
      exit 1
    fi
    REMOTE="$(git remote -v | awk '/github\.com.*\(push\)/{print $1; exit}')"
    [[ -n "$REMOTE" ]] || { echo "✗ no git remote points at github.com" >&2; exit 1; }
    echo "▶ Pushing to $REMOTE"
    git push -q "$REMOTE" HEAD:main
    VERSION="$(grep -o 'MARKETING_VERSION: "[^"]*"' project.yml | tail -1 | sed 's/.*"\(.*\)"/\1/')"
    echo "▶ Dispatching the TestFlight workflow for $VERSION"
    gh workflow run testflight.yml -f version="$VERSION"
    sleep 8
    RUN="$(gh run list --workflow=testflight.yml --limit 1 --json databaseId -q '.[0].databaseId')"
    echo "▶ https://github.com/hatcher-ltd/transcripts/actions/runs/$RUN"
    gh run watch "$RUN" --exit-status
