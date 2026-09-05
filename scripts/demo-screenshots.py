#!/usr/bin/env python3
"""Photograph the Mac app against a generated library.

Run `demo-library.py` first; this points a copy of the app at what it made and
captures the windows the guide uses.

    python3 scripts/demo-screenshots.py --app <path/to/Transcripts.app>

The copy runs on its own config via `TRANSCRIPTS_CONFIG`, so the instance you
actually use keeps running, keeps its own settings, and keeps watching for
meetings. The demo config also turns off auto-record and the vault mirror: a
screenshot session must not be able to start a recording or write into anyone's
notes.

Capturing another app's windows needs Screen Recording permission for whatever
runs this. macOS asks once, and until it is granted `screencapture` silently
returns desktop wallpaper instead of the window — so every shot is checked for
being suspiciously uniform rather than trusted.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BUNDLE = "ltd.hatcher.transcripts"

# Swift rather than pyobjc, which is not installed: CGWindowListCopyWindowInfo is
# the only way to turn "the app's Recordings window" into an id screencapture
# will take. Printed as TSV so the caller need not parse plists.
WINDOW_LISTER = r"""
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for w in raw {
    guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid,
          let id = w[kCGWindowNumber as String] as? Int else { continue }
    let name = (w[kCGWindowName as String] as? String) ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let wd = (b["Width"] as? Double) ?? 0, ht = (b["Height"] as? Double) ?? 0
    print("\(id)\t\(Int(wd))\t\(Int(ht))\t\(name)")
}
"""


def demo_config(root: Path) -> dict:
    """The live config with the library swapped and anything risky switched off.

    Derived from the real config rather than written from scratch, because
    `AppConfig` decoding is all-or-nothing: a JSON file missing a key it requires
    throws, every call site is `(try? ConfigStore().load()) ?? .default`, and
    `.default` resolves the library to iCloud Drive — the real one. A config that
    is merely incomplete therefore does not fail loudly, it silently photographs
    exactly the material this whole script exists to keep out of the repo.
    """
    live = Path(os.path.expanduser(
        "~/Library/Application Support/Transcripts/config.json"))
    cfg = json.loads(live.read_text(encoding="utf8")) if live.exists() else {}

    cfg["destinations"] = {
        **cfg.get("destinations", {}),
        "knowledgeRoot": str(root),
        "deviceInbox": str(root),
        # No mirror: a screenshot run must not write into anyone's notes.
        "vaultMirror": "",
        "vaultMirrorDetected": False,
    }
    # ...and must not be able to open the microphone or file a recording.
    cfg["autoRecordOnMicActivation"] = False
    cfg["captureSystemAudio"] = False
    return cfg


def windows(pid: int, lister: Path) -> list[tuple[int, int, int, str]]:
    out = subprocess.run(["swift", str(lister), str(pid)],
                         capture_output=True, text=True)
    found = []
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 4:
            found.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3]))
    return found


def looks_blank(png: Path) -> bool:
    """A denied Screen Recording permission yields wallpaper, not an error."""
    try:
        out = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(png)],
            capture_output=True, text=True, check=True).stdout
        return "pixelWidth" not in out
    except subprocess.CalledProcessError:
        return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="path to a built Transcripts.app")
    ap.add_argument("--library", default="~/Demo/Transcripts")
    ap.add_argument("--out", default="/tmp/demo-shots")
    ap.add_argument("--show", default="recordings",
                    choices=["recordings", "settings", "none"],
                    help="which window to open on launch")
    ap.add_argument("--select", default="",
                    help="record UUID to open in the detail pane; 'first' picks the newest")
    ap.add_argument("--keep-running", action="store_true",
                    help="leave the demo instance up to compose shots by hand")
    args = ap.parse_args()

    app = Path(os.path.expanduser(args.app))
    binary = app / "Contents" / "MacOS" / "Transcripts"
    if not binary.exists():
        print(f"✗ no binary at {binary}", file=sys.stderr)
        return 1

    library = Path(os.path.expanduser(args.library))
    if not library.exists():
        print(f"✗ no library at {library} — run scripts/demo-library.py first",
              file=sys.stderr)
        return 1

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="transcripts-demo-"))
    cfg = scratch / "config.json"
    cfg.write_text(json.dumps(demo_config(library), indent=2), encoding="utf8")

    lister = scratch / "windows.swift"
    lister.write_text(WINDOW_LISTER, encoding="utf8")

    # HOME redirection rather than an override per store. The Recordings window
    # reads HistoryStore at a hardcoded ~/Library/Application Support/Transcripts,
    # which no config setting moves — so overriding the config alone opened the
    # window on the real recording history while the demo library sat unread.
    # Relocating HOME moves the config, the history and the captures together.
    fake_home = scratch / "home"
    support = fake_home / "Library" / "Application Support" / "Transcripts"
    support.mkdir(parents=True, exist_ok=True)
    shutil.copy(cfg, support / "config.json")
    demo_history = library / ".demo-history.json"
    if demo_history.exists():
        shutil.copy(demo_history, support / "history.json")
    else:
        print("  ! no .demo-history.json — the window will be empty. "
              "Re-run scripts/demo-library.py.", file=sys.stderr)

    if args.select == "first":
        try:
            recs = json.loads((library / ".demo-history.json").read_text())
            recs = recs.get("records", recs) if isinstance(recs, dict) else recs
            args.select = sorted(recs, key=lambda r: r.get("recordedAt", ""),
                                 reverse=True)[0]["id"]
            print(f"  · selecting newest take {args.select}")
        except Exception as exc:
            print(f"  ! could not resolve --select first: {exc}", file=sys.stderr)
            args.select = ""

    env = dict(os.environ,
               TRANSCRIPTS_SUPPORT_DIR=str(support),
               TRANSCRIPTS_CONFIG=str(support / "config.json"),
               TRANSCRIPTS_SHOW=args.show,
               **({"TRANSCRIPTS_SELECT": args.select} if args.select else {}))
    print(f"▶ launching demo instance\n  config  {cfg}\n  library {library}")
    proc = subprocess.Popen([str(binary)], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(8)  # menu bar item, first library scan, window open
        if proc.poll() is not None:
            print("✗ the demo instance exited immediately", file=sys.stderr)
            return 1

        found = windows(proc.pid, lister)
        print(f"▶ {len(found)} window(s) for pid {proc.pid}")
        for wid, w, h, name in found:
            print(f"    {wid}  {w}x{h}  {name!r}")

        # Bring it forward first: an unfocused window photographs with grey
        # traffic lights and a dimmed title, which reads as a screenshot of an
        # app nobody is using.
        subprocess.run(["osascript", "-e",
                        'tell application "System Events" to set frontmost of '
                        f'(first process whose unix id is {proc.pid}) to true'],
                       capture_output=True)
        time.sleep(1.5)

        shot_count = 0
        for wid, w, h, name in found:
            if w < 200 or h < 150:
                continue  # status item, not a window worth keeping
            slug = "".join(c if c.isalnum() else "-" for c in (name or "window").lower())
            png = out / f"{slug.strip('-') or f'window-{wid}'}.png"
            subprocess.run(["screencapture", f"-l{wid}", "-o", "-x", str(png)],
                           check=False)
            if png.exists() and not looks_blank(png):
                print(f"  ✓ {png.name}")
                shot_count += 1
            else:
                print(f"  ! {png.name} came back empty — Screen Recording "
                      "permission is probably not granted", file=sys.stderr)

        if args.keep_running:
            print(f"\nInstance left running (pid {proc.pid}). Kill it with:\n"
                  f"  kill {proc.pid}")
            proc = None
        return 0 if shot_count else 1
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
