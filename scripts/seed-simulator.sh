#!/usr/bin/env bash
#
# Fill a simulator's library with plausible recordings.
#
# A fresh simulator has no takes, so everything interesting in the library — the
# context menu, search, merge, the day groupings, the still-syncing mark — has
# nothing to attach to and cannot be looked at. This makes those states real.
#
#   scripts/seed-simulator.sh [device-udid]
#
# Audio is genuine: `say` writes a real AAC file, because the app opens every
# file with AVAudioPlayer on scan and deletes the ones it cannot read. Silence
# or a touched empty file would be pruned before it ever reached the list.
#
# Start times come from each file's creation date, which is why SetFile is here:
# without it every take lands today and the day grouping never renders.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="ltd.hatcher.transcripts"
DEV="${1:-$(xcrun simctl list devices booted -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
for runtime in d.values():
    for dev in runtime:
        if dev.get("state")=="Booted": print(dev["udid"]); raise SystemExit
print("", end="")')}"

[[ -n "$DEV" ]] || { echo "✗ no booted simulator — boot one or pass a UDID" >&2; exit 1; }
echo "▶ device $DEV"

DATA="$(xcrun simctl get_app_container "$DEV" "$BUNDLE_ID" data)"
CAPTURES="$DATA/Library/Application Support/Captures"
echo "▶ $CAPTURES"

# Replace rather than add. Seeding twice used to leave two of everything, which
# looks like a duplication bug in the app rather than in this script — exactly
# the wrong thing for a tool whose job is to make the UI legible.
rm -rf "$CAPTURES"
mkdir -p "$CAPTURES"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
META="$TMP/meta.json"
echo '{}' > "$META"

# title | summary | exported | days-ago | HH:MM | spoken text
# An empty title means the row falls back to its date, which is the common case
# and the one rename exists for.
seed() {
  local title="$1" summary="$2" exported="$3" ago="$4" clock="$5" text="$6"
  local id; id="$(uuidgen)"
  local audio="$CAPTURES/$id.m4a"

  say -o "$audio" --data-format=aac --file-format=m4af "$text"
  printf '%s\n' "$text" > "$CAPTURES/$id.txt"

  local stamp; stamp="$(python3 -c "
import datetime, sys
d = datetime.date.today() - datetime.timedelta(days=$ago)
print(d.strftime('%m/%d/%Y') + ' $clock:00')")"
  SetFile -d "$stamp" -m "$stamp" "$audio"

  python3 - "$META" "$id" "$title" "$summary" "$exported" <<'PY'
import json, sys
path, take_id, title, summary, exported = sys.argv[1:6]
meta = json.load(open(path))
entry = {"exported": exported == "yes"}
if title:   entry["title"] = title
if summary: entry["summary"] = summary
meta[take_id] = entry
json.dump(meta, open(path, "w"))
PY
  echo "  ✓ ${title:-（untitled）}"
}

# Invented, like everything demo-library.py writes: the same fictional product
# team, so a shot that shows local takes beside shared transcripts reads as one
# person's week. Nothing here may name a real client, colleague or relative —
# these rows end up on the App Store and in a public repo.
seed "Standup — release week" \
     "The beta is feature-complete. Priya is closing the last onboarding bug; Marcus starts the walkthrough on Thursday." \
     yes 0 "08:40" \
     "Quick standup. The beta is feature complete as of last night. Priya is closing the last onboarding bug this morning, and Marcus starts the five person walkthrough on Thursday. Nothing is blocked."

seed "" "" no 1 "17:50" \
     "Note to self. Send Dana the signup numbers before the pricing call, and book the big room for Thursday's walkthrough."

seed "Walkthrough prep" \
     "Five testers booked for Thursday. The script now starts from an empty library so the new copy gets tested." \
     yes 1 "10:05" \
     "For the walkthrough we have five people booked on Thursday. I rewrote the script so every session starts from an empty library, which means the new empty state copy actually gets seen instead of skipped."

seed "Release notes ideas" \
     "Lead with the moved permission prompt; keep the list to three items." \
     yes 3 "18:30" \
     "Thinking about the release notes. Lead with the permission prompt moving after the first recording, since that is the change people will notice. Then the empty state, then search. Three items, no more."

cp "$META" "$CAPTURES/takes-meta.json"
echo "▶ wrote takes-meta.json"
echo "✓ seeded — relaunch the app to pick it up"
