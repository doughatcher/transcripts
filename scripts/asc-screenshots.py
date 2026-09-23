#!/usr/bin/env python3
"""Replace the App Store screenshots with the ones store-shots.sh made.

    set -a && . ./.env.signing && set +a
    python3 scripts/asc-screenshots.py --dry-run     # say what would change
    python3 scripts/asc-screenshots.py               # do it

Writes to App Store Connect, unlike asc.py, and only to one place: the
screenshot sets of the newest version that is still editable (preparing,
rejected, or developer-rejected). A version that is waiting for review or live
is refused rather than touched — editing a queued submission's metadata can
knock it out of the queue.

Each family keeps the display type it already has. Apple's slot names lag its
device names (the 6.9" phone is filed under APP_IPHONE_67), so guessing a type
from the pixel size is how a set lands somewhere no storefront shows. Only when
a family has no set at all is one created, with the current largest type.

Upload follows Apple's three-step dance: reserve (POST, which answers with
upload operations), PUT the bytes to each operation, then commit (PATCH with
the file's MD5). A reservation that is never committed shows up as a broken
thumbnail, so a failure part-way is reported with the id to delete.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("asc", ROOT / "scripts" / "asc.py")
asc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(asc)

API = "https://api.appstoreconnect.apple.com/v1/"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "REJECTED", "METADATA_REJECTED",
            "DEVELOPER_REJECTED", "INVALID_BINARY"}
# Newest-first fallbacks, used only when a family has no set yet.
DEFAULT_TYPE = {"iphone": "APP_IPHONE_67", "ipad": "APP_IPAD_PRO_3GEN_129"}
PREFIX = {"iphone": "APP_IPHONE_", "ipad": "APP_IPAD_"}


def call(method: str, path: str, body: dict | None = None) -> dict:
    url = path if path.startswith("https://") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {asc.token()}",
        "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"✗ {method} {path} → HTTP {e.code}: {e.read().decode()[:800]}")


def put_chunk(op: dict, blob: bytes) -> None:
    chunk = blob[op["offset"]:op["offset"] + op["length"]]
    headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
    req = urllib.request.Request(op["url"], data=chunk, method=op["method"], headers=headers)
    with urllib.request.urlopen(req, timeout=120):
        pass


def target_type(kind: str, sets: list[dict]) -> tuple[str, str | None]:
    """(displayType, existing set id or None) for one device family."""
    mine = [s for s in sets if s["attributes"]["screenshotDisplayType"].startswith(PREFIX[kind])]
    if not mine:
        return DEFAULT_TYPE[kind], None
    # The set that currently carries the most screenshots is the one the
    # storefront is showing; ties go to the largest display.
    mine.sort(key=lambda s: (len(s.get("relationships", {}).get("appScreenshots", {}).get("data", []) or []),
                             s["attributes"]["screenshotDisplayType"]))
    best = mine[-1]
    return best["attributes"]["screenshotDisplayType"], best["id"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=str(ROOT / "dist" / "appstore"))
    ap.add_argument("--bundle-id", default="ltd.hatcher.transcripts")
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    shots = Path(args.dir)

    app = call("GET", f"apps?filter[bundleId]={args.bundle_id}&limit=1")["data"][0]["id"]
    versions = call("GET", f"apps/{app}/appStoreVersions?limit=20")["data"]
    versions.sort(key=lambda v: v["attributes"].get("createdDate") or "", reverse=True)
    newest = versions[0]
    state = newest["attributes"].get("appStoreState") or newest["attributes"].get("appVersionState")
    vs = newest["attributes"]["versionString"]
    if state not in EDITABLE:
        raise SystemExit(f"✗ {vs} is {state}; refusing to change screenshots on a version "
                         "that is not editable. Create the next version first.")
    print(f"▶ {vs} ({state})")

    locs = call("GET", f"appStoreVersions/{newest['id']}/appStoreVersionLocalizations?limit=50")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == args.locale), None)
    if not loc:
        raise SystemExit(f"✗ no {args.locale} localization on {vs}")
    sets = call("GET", f"appStoreVersionLocalizations/{loc['id']}/appScreenshotSets"
                       "?include=appScreenshots&limit=50")["data"]

    for kind in ("iphone", "ipad"):
        files = sorted(shots.glob(f"{kind}/*.png"))
        if not files:
            print(f"  – {kind}: nothing in {shots / kind}, leaving it alone")
            continue
        dtype, set_id = target_type(kind, sets)
        old = []
        if set_id:
            old = call("GET", f"appScreenshotSets/{set_id}/appScreenshots?limit=50")["data"]
        print(f"  {kind}: {dtype} — replace {len(old)} with {len(files)}: "
              + ", ".join(f.name for f in files))
        if args.dry_run:
            continue

        if not set_id:
            set_id = call("POST", "appScreenshotSets", {"data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": dtype},
                "relationships": {"appStoreVersionLocalization": {
                    "data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]["id"]
        for shot in old:
            call("DELETE", f"appScreenshots/{shot['id']}")

        for f in files:
            blob = f.read_bytes()
            made = call("POST", "appScreenshots", {"data": {
                "type": "appScreenshots",
                "attributes": {"fileName": f.name, "fileSize": len(blob)},
                "relationships": {"appScreenshotSet": {
                    "data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
            try:
                for op in made["attributes"]["uploadOperations"]:
                    put_chunk(op, blob)
            except Exception as e:  # noqa: BLE001 — report the orphan, then stop
                raise SystemExit(f"✗ upload of {f.name} failed ({e}); delete appScreenshots/{made['id']}")
            call("PATCH", f"appScreenshots/{made['id']}", {"data": {
                "type": "appScreenshots", "id": made["id"],
                "attributes": {"uploaded": True,
                               "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
            print(f"    ✓ {f.name}")

        # Apple processes the image after the commit; a failure there is only
        # visible as assetDeliveryState, so wait for it rather than assume.
        for _ in range(30):
            now = call("GET", f"appScreenshotSets/{set_id}/appScreenshots?limit=50")["data"]
            states = [s["attributes"].get("assetDeliveryState", {}).get("state") for s in now]
            if all(s == "COMPLETE" for s in states):
                print(f"    ✓ {len(now)} processed")
                break
            if any(s == "FAILED" for s in states):
                errs = [s["attributes"]["assetDeliveryState"].get("errors") for s in now]
                raise SystemExit(f"✗ Apple rejected a screenshot: {errs}")
            time.sleep(4)
        else:
            print("    … still processing; check App Store Connect in a minute")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
