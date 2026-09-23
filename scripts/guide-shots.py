#!/usr/bin/env python3
"""Photograph the entire user guide, from generated data, in one pass.

    python3 scripts/guide-shots.py                 # re-shoot docs/guide/images/
    python3 scripts/guide-shots.py --keep          # ...and keep the scratch tree
    python3 scripts/guide-shots.py --no-install    # leave them in /tmp instead

Twelve images ship with the guide. Ten of them used to be `screencapture` of
whatever the author's own copy of the app happened to be showing, and every one
of those published something real: meeting titles, folder names, a whole
transcript with people's names in it, a room's worth of conversation in the
overlay, and a desktop whose weather widget named the city. Two were replaced by
hand in September 2026; the other ten stayed up because re-taking them was a
half-hour of stage-managing a live recording, and nobody has a spare live
recording.

So nothing here is photographed off a screen. `demo-library.py` invents the
library, this script stages a whole fake home around it, and the app renders its
own views offscreen (see `DocCapture`). That removes every reason the old path
got stuck:

  * no Screen Recording permission, so no TCC prompt and no silent wallpaper;
  * no window server, so it runs over SSH, on a locked Mac, with the lid shut;
  * no live recording to stage — the mid-call states are posed (`poseForCapture`);
  * nothing real is reachable, so there is nothing to redact afterwards.

Containment is by construction, and it is the point. The app runs against a
config written here rather than derived from the user's, a history file made by
the demo generator, and a fake Obsidian registry — and it refuses to start
without the config and support-directory overrides (see `DocCapture`), so a
half-set environment stops rather than quietly photographing real meetings.

Note what is *not* used: a redirected `HOME`. On macOS `NSHomeDirectory()` reads
the password database, not the environment, so a scratch `HOME` moves nothing —
`~/Documents/Transcripts` in a config still resolves under the real home. The
staged folders are therefore real folders in the real home, created on the way
in and removed on the way out, and the script refuses to touch one that already
exists rather than write a demo library on top of somebody's meetings.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home()

# What the guide's readers will see as paths, and therefore what has to exist
# while the shots are taken. Named to read well in a manual rather than as
# scratch space — "Knowledge root /var/folders/24/mpmbdh7n…" documents nothing.
LIBRARY = HOME / "Documents" / "Meetings"
VAULT = HOME / "Documents" / "Field Notes"
SECOND_VAULT = HOME / "Documents" / "Notes Archive"
STAGED = (LIBRARY, VAULT, SECOND_VAULT)

# The microphones the General pane lists. Real hardware is whatever the person
# running this has plugged in, which is how four of the author's interfaces came
# to be named in the guide; these are invented and identical on every machine.
MICS = [
    ("demo-builtin", "MacBook Pro Microphone"),
    ("demo-display", "Studio Display Microphone"),
    ("demo-usb", "Jabra Speak 75"),
]

# Every image the guide references, and the format it references it in. The
# guide's markdown names these files; a shot missing from here is a shot the
# guide will show a broken image for.
SHOTS = {
    "settings-general": "png",
    "settings-voices": "png",
    "settings-sorting": "png",
    "settings-pipeline": "png",
    "settings-about": "png",
    "menu-idle": "webp",
    "menu-recording": "webp",
    "remember-voice": "webp",
    "document-summary": "webp",
    "document-transcript": "webp",
    "live-edge": "webp",
    "overlay": "webp",
}

# Seconds since 2001-01-01, which is how Foundation encodes a bare `Date`.
# speakers.json is decoded with a plain JSONDecoder, unlike history.json.
def apple_time(dt: datetime) -> float:
    epoch = datetime(2001, 1, 1, tzinfo=timezone.utc)
    return (dt - epoch).total_seconds()


def guide_config() -> dict:
    """The config the guide is shot against — written, not derived.

    Deriving it from the user's own config is what leaked the employer name into
    settings-voices.png: the old harness copied the live file and overrode only
    the destinations, so every field nobody thought about — the home
    organization, the Ollama host, the names of the audio interfaces — shipped
    as-is, and any field added later would have shipped too.

    Written from scratch it fails the other way. `AppConfig` decodes tolerantly
    (every key falls back to a built-in default), so a key this file has never
    heard of takes the app's default rather than the user's value: new settings
    are absent from the shots until someone chooses to stage them, which is the
    direction you want to be wrong in.
    """
    return {
        # Tilde form on purpose: the panes show the stored string, so this is
        # also the path the guide's readers see. It has to be both a real
        # directory (the app reads it) and one worth printing in a manual.
        "destinations": {
            "knowledgeRoot": f"~/{LIBRARY.relative_to(HOME)}",
            "deviceInbox": f"~/{LIBRARY.relative_to(HOME)}",
            "vaultMirror": f"~/{VAULT.relative_to(HOME)}",
            "vaultMirrorDetected": True,
        },
        # A capture run must not be able to open the microphone or file a
        # recording, whatever else it does.
        "autoRecordOnMicActivation": False,
        "captureSystemAudio": False,
        "consentMode": "oneParty",
        "menuBarIcon": "transport",
        # The Voices pane is only worth a picture with this on.
        "rememberVoices": True,
        "nameMatchConfidence": 0.65,
        "homeOrganization": "Northwind",
        "recentsLimit": 12,
        # Paired with TRANSCRIPTS_FAKE_INPUTS below: the favourite is starred and
        # ordered in the General pane, so the pane is shot in the state it is
        # worth documenting rather than with an empty favourites list.
        "favoriteInputUIDs": [MICS[0][0]],
        "favoriteInputNamesByUID": {uid: name for uid, name in MICS},
        "llmProvider": "appleOnDevice",
        "overlay": {"enabled": True, "searchNotes": True},
    }


def speaker_store(now: datetime) -> dict:
    """A few remembered voices for the Voices pane.

    The cast is the demo library's (see demo-library.py) so the guide reads as
    one product being used rather than a dozen unrelated screenshots. The
    embeddings are three numbers rather than a real 256-dimension voiceprint —
    nothing here is matched against anything, and a real one would be a
    biometric template checked into a public repo.
    """
    def profile(name, meetings, days_ago, affiliation, is_self=False):
        return {
            "name": name,
            "isSelf": is_self,
            "affiliation": affiliation,
            "updatedAt": apple_time(now - timedelta(days=days_ago)),
            "samples": [
                {"meetingID": f"{name.lower()}-{i}", "embedding": [0.1, 0.2, 0.3],
                 "date": apple_time(now - timedelta(days=days_ago + i))}
                for i in range(meetings)
            ],
        }

    return {
        "profiles": [
            profile("Me", 7, 0, None, is_self=True),
            profile("Priya", 5, 0, "Northwind"),
            profile("Marcus", 4, 1, "Northwind"),
            profile("Dana", 3, 1, "Northwind"),
            profile("Sam", 1, 1, "Northwind"),
        ],
        "suggestions": [],
        "declinedNames": [],
        "declinedEmbeddings": [],
    }


LIVE_TRANSCRIPT = """---
title: Onboarding flow review
---

# Live transcript

**Priya:** So this is the flow as it stands. Three steps, and the permission
prompt is the second one.

**Me:** That's the part I keep tripping over. We ask for the microphone before
they've seen a single thing the app does.
"""


def stage(scratch: Path, quiet: bool) -> tuple[Path, dict]:
    """Stages the library, the vaults and the app's state; returns the env."""
    support = scratch / "support"
    for d in (LIBRARY, support, VAULT / ".obsidian", SECOND_VAULT / ".obsidian"):
        d.mkdir(parents=True, exist_ok=True)

    print("▶ generating the demo library")
    cmd = [sys.executable, str(ROOT / "scripts" / "demo-library.py"),
           "--root", str(LIBRARY)]
    if quiet:
        cmd.append("--quiet")
    subprocess.run(cmd, check=True)

    history = LIBRARY / ".demo-history.json"
    if not history.exists():
        raise SystemExit("✗ demo-library.py wrote no .demo-history.json")
    shutil.copy(history, support / "history.json")

    now = datetime.now(timezone.utc)
    (support / "speakers.json").write_text(
        json.dumps(speaker_store(now), indent=2), encoding="utf8")
    (support / "config.json").write_text(
        json.dumps(guide_config(), indent=2), encoding="utf8")
    # Its presence is what puts "Open live transcript" in the recording menu.
    (LIBRARY / "Transcripts Live.md").write_text(LIVE_TRANSCRIPT, encoding="utf8")

    # Obsidian's own registry, in Obsidian's own shape: the app reads this file
    # directly, so it is the only way to put fictional vault names in the
    # Sorting pane. `ts` is milliseconds and orders the list.
    registry = scratch / "obsidian.json"
    registry.write_text(json.dumps({"vaults": {
        "aaaa": {"path": str(VAULT), "ts": 1_780_000_000_000, "open": True},
        "bbbb": {"path": str(SECOND_VAULT), "ts": 1_770_000_000_000},
    }}, indent=2), encoding="utf8")

    out = scratch / "out"
    out.mkdir(exist_ok=True)

    env = dict(
        os.environ,
        TRANSCRIPTS_CONFIG=str(support / "config.json"),
        TRANSCRIPTS_SUPPORT_DIR=str(support),
        TRANSCRIPTS_OBSIDIAN_REGISTRY=str(registry),
        TRANSCRIPTS_FAKE_INPUTS=",".join(f"{uid}={name}" for uid, name in MICS),
        TRANSCRIPTS_CAPTURE_DOCS=str(out),
    )
    return out, env


def to_webp(png: Path, dest: Path) -> None:
    """PNG → WebP, losslessly: these are flat UI renders with small text on
    them, where lossy compression shows as fringing on the type and saves
    little, because there is no photographic detail to throw away."""
    subprocess.run(["cwebp", "-quiet", "-lossless", "-z", "9",
                    str(png), "-o", str(dest)], check=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default=str(ROOT / ".build" / "Transcripts.app"),
                    help="the app to shoot with (default: the staged build)")
    ap.add_argument("--out", default=str(ROOT / "docs" / "guide" / "images"))
    ap.add_argument("--no-install", action="store_true",
                    help="write to .build/guide-shots/ instead of the guide")
    ap.add_argument("--keep", action="store_true",
                    help="leave the staged library and vaults in place")
    ap.add_argument("--quiet", action="store_true",
                    help="quieten the library generator")
    args = ap.parse_args()

    binary = Path(os.path.expanduser(args.app)) / "Contents" / "MacOS" / "Transcripts"
    if not binary.exists():
        print(f"✗ no binary at {binary} — run scripts/make-app.sh first",
              file=sys.stderr)
        return 1
    if not shutil.which("cwebp"):
        print("✗ cwebp not found — brew install webp", file=sys.stderr)
        return 1

    # These are real directories in the real home — `HOME` cannot be redirected
    # (see the module docstring) — so one that already exists is somebody's, not
    # ours to write a demo library into and delete afterwards.
    existing = [d for d in STAGED if d.exists()]
    if existing:
        print("✗ already exists: " + ", ".join(str(d) for d in existing),
              file=sys.stderr)
        print("  Move it aside, or edit LIBRARY/VAULT in this script.",
              file=sys.stderr)
        return 1

    scratch = Path(tempfile.mkdtemp(prefix="transcripts-guide-"))
    try:
        out, env = stage(scratch, args.quiet)

        print("▶ rendering the guide")
        run = subprocess.run([str(binary)], env=env, capture_output=True,
                             text=True, timeout=300)
        sys.stdout.write(run.stdout)
        if run.returncode != 0:
            sys.stderr.write(run.stderr)
            print(f"✗ capture exited {run.returncode}", file=sys.stderr)
            return 1

        missing = [n for n in SHOTS if not (out / f"{n}.png").exists()]
        if missing:
            print(f"✗ never rendered: {', '.join(missing)}", file=sys.stderr)
            return 1

        if args.no_install:
            # Out of the scratch tree, which this function's `finally` deletes.
            kept = ROOT / ".build" / "guide-shots"
            shutil.rmtree(kept, ignore_errors=True)
            shutil.copytree(out, kept)
            print(f"\nImages are in {kept}")
            return 0

        dest = Path(os.path.expanduser(args.out))
        dest.mkdir(parents=True, exist_ok=True)
        print(f"▶ installing into {dest}")
        for name, fmt in SHOTS.items():
            src = out / f"{name}.png"
            if fmt == "webp":
                to_webp(src, dest / f"{name}.webp")
            else:
                shutil.copy(src, dest / f"{name}.png")
            size = (dest / f"{name}.{fmt}").stat().st_size
            print(f"  ✓ {name}.{fmt}  {size // 1024} KB")

        # The site carries its own copy of the guide's images; rebuilding is how
        # they get there, and forgetting is how the site keeps showing the old
        # ones after the repo has been cleaned.
        print("▶ rebuilding the site")
        subprocess.run([sys.executable, str(ROOT / "site" / "build.py")], check=True)
        return 0
    finally:
        if args.keep:
            print(f"\nStaged at {scratch}, {LIBRARY}, {VAULT}, {SECOND_VAULT}")
        else:
            shutil.rmtree(scratch, ignore_errors=True)
            # Only ever the directories this run created, and only because it
            # created them: the guard in main() is what makes that true.
            for d in STAGED:
                shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
