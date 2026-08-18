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

seed "Nalli — ERP sync and checkout" \
     "Orders placed in the admin panel are not syncing to the ERP. Vishal is investigating; a hotfix is planned for Friday." \
     yes 0 "09:15" \
     "Right, the ERP sync issue. Orders placed via the Magento admin panel are not reaching the ERP at all, and the ones that do arrive are deducting quantity twice. Vishal thinks it is the API response handling. We agreed to hotfix it Friday and re-test the checkout flow afterwards."

seed "" "" no 0 "14:40" \
     "Quick note to self before I forget. Ask Lavanya about the retainer model, and whether they want the CDN credit refunded or rolled into next month."

seed "person Starts cry som" "" yes 1 "11:02" \
     "So the thing about the schema is that it was never really designed, it accreted. Every integration added a column and nobody ever took one away."

seed "Weekly catchup — Echidna" \
     "Timeline slipped again. Shipment mail trigger and customer order sync remain open." \
     yes 1 "16:30" \
     "On the timeline, customer orders sync should be done by Friday since Kaushal is testing locally with production data. The shipment mail trigger is still open and we have not heard back from the eShipz team about their changes."

seed "Book — chapter one notes" \
     "Segregated school chapter. Need to check the year with Dad before writing the transition." \
     yes 4 "20:12" \
     "For chapter one I keep going back and forth on the segregated school stretch. I need to ask him directly what year the school actually closed, because the two accounts I have do not agree and I do not want to guess in print."

cp "$META" "$CAPTURES/takes-meta.json"
echo "▶ wrote takes-meta.json"
echo "✓ seeded — relaunch the app to pick it up"
