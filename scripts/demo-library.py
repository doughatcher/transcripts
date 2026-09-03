#!/usr/bin/env python3
"""Fill a folder with a demo library worth photographing.

The screenshots in the guide were taken against a real library, which meant
every shot published real meeting titles, real folder names, and in two cases
a whole transcript. Re-shooting by hand only moves the problem: whatever is on
screen that day is what ships.

So the library is generated instead. The content here is invented — a fictional
product team at a fictional company — which makes the screenshots reproducible,
keeps private material out of a public repo, and lets the shots be composed:
the day groupings, the folder routing, the speaker names and the summary
structure are all chosen to show the app at its best rather than whatever the
week happened to contain.

    python3 scripts/demo-library.py [--root PATH] [--quiet]

Audio is real, not silence. The app opens every file with AVAudioPlayer during
its scan and prunes the ones it cannot read, so a touched empty file would
vanish before it reached the list. `say` writes genuine AAC, and the words are
the transcript's own opening line, so scrubbing the player during a screenshot
lands on speech rather than a tone.

File creation dates are set deliberately. The library groups by day — Today,
Yesterday, Monday — and without backdating, every take lands today and the
grouping that makes the sidebar look like a library never renders.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Folder each transcript is routed into, relative to the root. Most land in the
# default `transcripts/`; one sits under a client folder so the shots show that
# routing exists without needing a second screenshot to explain it.
DEFAULT_FOLDER = "transcripts"
CLIENT_FOLDER = "Northwind/transcripts"


class Take:
    """One recording: its metadata, its summary, and its dialogue."""

    def __init__(self, *, days_ago, hour, minute, title, description,
                 speakers, key_points, actions, dialogue, folder=DEFAULT_FOLDER,
                 duration=None):
        self.days_ago = days_ago
        self.hour = hour
        self.minute = minute
        self.title = title
        self.description = description
        self.speakers = speakers
        self.key_points = key_points
        self.actions = actions
        self.dialogue = dialogue
        self.folder = folder
        # Derived from the dialogue when not given, so the player's duration and
        # the visible timestamps never disagree.
        self.duration = duration or (dialogue[-1][0] + 14 if dialogue else 30)

    def started(self, now):
        base = now - timedelta(days=self.days_ago)
        return base.replace(hour=self.hour, minute=self.minute, second=0, microsecond=0)

    def slug(self, now):
        s = self.started(now)
        stem = "".join(c if c.isalnum() else "-" for c in self.title.lower())
        while "--" in stem:
            stem = stem.replace("--", "-")
        return f"{s:%Y-%m-%d-%H%M}-{stem.strip('-')[:40]}"


def hhmm(seconds: int) -> str:
    return f"{seconds // 60}:{seconds % 60:02d}"


TAKES = [
    Take(
        days_ago=0, hour=9, minute=12,
        title="Onboarding flow review",
        description="The team walks the new three-step onboarding, agrees the "
                    "permission prompt lands too early, and moves it after the "
                    "first recording.",
        speakers=["Me", "Priya", "Marcus"],
        key_points=[
            "The microphone prompt currently appears before anyone has seen what "
            "the app does, and roughly a third of testers decline it there.",
            "Moving the prompt to just after the first Start recording gives it a "
            "reason to exist, and testers who saw it there accepted it.",
            "The empty state needs a line of copy — new accounts open on a blank "
            "list with nothing suggesting what to do next.",
        ],
        actions=[
            ("Move the microphone prompt to follow the first recording", "Priya"),
            ("Write the empty-state copy for the library", "Me"),
            ("Re-run the five-person walkthrough once both land", "Marcus"),
        ],
        dialogue=[
            (2, "Priya", "So this is the flow as it stands. Three steps, and the "
                         "permission prompt is the second one."),
            (11, "Me", "That's the part I keep tripping over. We ask for the "
                       "microphone before they've seen a single thing the app does."),
            (24, "Marcus", "Which is exactly where we lose them. A third of the "
                           "testers declined at that screen, and once they decline "
                           "there's no good way to ask again."),
            (39, "Priya", "If we move it after the first Start recording, the ask "
                          "has a reason attached. You pressed record, we need the "
                          "microphone."),
            (52, "Me", "Let's try that. And the empty state needs a line of copy — "
                       "right now a new account opens onto nothing at all."),
            (66, "Marcus", "I'll re-run the walkthrough with five people once both "
                           "of those are in."),
        ],
    ),
    Take(
        days_ago=1, hour=15, minute=30,
        title="Pricing for the team plan",
        description="A per-seat price is agreed at nine dollars with a three-seat "
                    "minimum; annual billing is deferred until churn data exists.",
        speakers=["Me", "Dana"],
        key_points=[
            "Nine dollars per seat with a three-seat minimum clears support cost "
            "at the volumes currently forecast.",
            "Annual billing is deferred — there is no churn data yet to price a "
            "discount against.",
            "Existing single-user licences convert at their current price rather "
            "than being repriced.",
        ],
        actions=[
            ("Model the three-seat minimum against last quarter's signups", "Dana"),
            ("Draft the upgrade path for existing licences", "Me"),
        ],
        dialogue=[
            (3, "Dana", "Nine a seat is where I'd start. It clears support cost at "
                        "the volumes we're forecasting."),
            (14, "Me", "With a minimum? A two-person team at nine dollars barely "
                       "covers the billing overhead."),
            (26, "Dana", "Three seats minimum. That's twenty-seven, which is a "
                         "number people don't think very hard about."),
            (38, "Me", "And annual? I'd rather not guess at a discount before we "
                       "know what churn looks like."),
            (49, "Dana", "Agreed, leave annual out. We can add it once we have two "
                         "quarters to look at."),
        ],
    ),
    Take(
        days_ago=1, hour=11, minute=5,
        title="Customer interview — Northwind",
        description="Northwind's operations lead describes recording site visits "
                    "on a phone with no signal and needing them filed by project.",
        speakers=["Me", "Sam"],
        key_points=[
            "Site visits happen where there is no mobile signal, so anything "
            "requiring a live upload is unusable in the field.",
            "Recordings need to file themselves by project — filing by hand at the "
            "end of a week does not happen.",
            "Playback matters more than the transcript for their use: they replay "
            "what a client said rather than reading it.",
        ],
        actions=[
            ("Check that offline capture holds a full day of visits", "Me"),
            ("Ask whether project names could come from the calendar", "Sam"),
        ],
        dialogue=[
            (4, "Sam", "Most of what I record is on site, and half those sites have "
                       "no signal at all. Anything that needs to upload as it goes "
                       "is no use to me."),
            (18, "Me", "It records locally and files when you're back on a network. "
                       "Does a full day of visits fit before that becomes a problem?"),
            (31, "Sam", "A day would be plenty. The bigger thing is filing. If I "
                        "have to sort a week of recordings on a Friday, I won't."),
            (46, "Me", "So they'd need to route themselves by project."),
            (55, "Sam", "By project, yes. And honestly I replay them more than I "
                        "read them — I want to hear what the client actually said."),
        ],
        folder=CLIENT_FOLDER,
    ),
    Take(
        days_ago=3, hour=14, minute=20,
        title="Design critique: the settings window",
        description="Five tabs are judged one too many; Sorting folds into "
                    "Pipeline and the About pane keeps the version prominent.",
        speakers=["Me", "Priya"],
        key_points=[
            "Five tabs is one more than the window can carry — Sorting and "
            "Pipeline are the same idea seen twice.",
            "The version string belongs on About where people look for it when "
            "filing a bug.",
        ],
        actions=[("Fold Sorting into Pipeline behind a disclosure", "Priya")],
        dialogue=[
            (5, "Priya", "Five tabs. Every time I open this I read all five before "
                         "I find the one I meant."),
            (16, "Me", "Sorting and Pipeline are really the same idea, aren't they. "
                       "Where things go, and what happens to them on the way."),
            (29, "Priya", "Fold Sorting in behind a disclosure. Four tabs reads as "
                          "a window; five reads as a list."),
        ],
    ),
    Take(
        days_ago=4, hour=10, minute=0,
        title="Sprint retro",
        description="The release checklist is blamed for two late Fridays and is "
                    "moved into CI; standups move to asynchronous notes.",
        speakers=["Me", "Priya", "Marcus", "Dana"],
        key_points=[
            "Two of the last three releases ran late on a Friday because the "
            "checklist was run by hand.",
            "Standup has become a status readout nobody acts on; notes cover it.",
        ],
        actions=[
            ("Move the release checklist into CI", "Marcus"),
            ("Trial asynchronous standup for two weeks", "Dana"),
        ],
        dialogue=[
            (3, "Marcus", "Two of the last three releases went out late on a Friday, "
                          "and both times it was the checklist."),
            (15, "Dana", "Which is a script we're running with our eyes. Put it in "
                         "CI and it either passes or it doesn't."),
            (28, "Priya", "Can we also talk about standup? It's a status readout. "
                          "Nobody's acted on anything said in one for a month."),
            (42, "Me", "Two weeks of notes instead, and we look again."),
        ],
    ),
    Take(
        days_ago=6, hour=16, minute=45,
        title="Bug triage",
        description="Twelve reports reduce to three causes; the settings lag is "
                    "traced to device enumeration running on every render.",
        speakers=["Me", "Marcus"],
        key_points=[
            "Twelve reports collapse into three underlying causes.",
            "The settings lag is device enumeration running on every render, "
            "which also writes the config file mid-draw.",
        ],
        actions=[("Cache the device list for the life of the window", "Marcus")],
        dialogue=[
            (2, "Marcus", "Twelve reports since Friday, but they're three bugs "
                          "wearing different hats."),
            (13, "Me", "The settings one is the loud one. People are calling it "
                       "lag, which usually means we're doing work in a draw call."),
            (27, "Marcus", "We're enumerating audio devices on every render. And "
                           "writing the config file while we do it."),
            (39, "Me", "Cache it for the life of the window."),
        ],
    ),
    Take(
        days_ago=9, hour=13, minute=15,
        title="Roadmap planning",
        description="Search and export are chosen for the quarter; the plugin "
                    "system is deferred for lack of a second use case.",
        speakers=["Me", "Dana", "Priya"],
        key_points=[
            "Search and export carry the quarter; both are asked for weekly.",
            "The plugin system is deferred — one hypothetical consumer is not "
            "enough to design an interface against.",
        ],
        actions=[("Write the search spec before the next planning session", "Priya")],
        dialogue=[
            (4, "Dana", "Search and export are the two things people ask for every "
                        "single week. Everything else is a maybe."),
            (17, "Priya", "The plugin system keeps coming back, though."),
            (26, "Me", "With one hypothetical consumer. I'd rather design that "
                       "interface against two real ones than none."),
        ],
    ),
]


def markdown(take: Take, now: datetime, audio_name: str) -> str:
    started = take.started(now)
    ended = started + timedelta(seconds=take.duration)
    speakers = ", ".join(f'"{s}"' for s in take.speakers)

    key = "\n".join(f"- {p}" for p in take.key_points)
    acts = "\n".join(f"- {what} ({who})" for what, who in take.actions)
    lines = "\n\n".join(
        f"**{who}** [{hhmm(t)}] {text}" for t, who, text in take.dialogue
    )

    return f"""---
title: "{take.title}"
recorded_at: {started.astimezone(timezone.utc):%Y-%m-%dT%H:%M:%SZ}
ended_at: {ended.astimezone(timezone.utc):%Y-%m-%dT%H:%M:%SZ}
duration_seconds: {take.duration}
active_app: "Transcripts"
active_app_bundle_id: "ltd.hatcher.transcripts"
source: scribe
audio_file: {audio_name}
speakers: [{speakers}]
description: "{take.description}"
sorted: true
---

## Summary

**TL;DR:** {take.description}

**Key Points:**

{key}

**Action Items:**

{acts}

**Speakers:**

{chr(10).join(f"- {s}" for s in take.speakers)}

## Transcript

{lines}
"""


def write_audio(path: Path, text: str, quiet: bool) -> bool:
    """Real AAC via `say`. The app prunes files AVAudioPlayer cannot open."""
    try:
        subprocess.run(
            ["say", "-o", str(path), "--data-format=aac", text[:220]],
            check=True, capture_output=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        if not quiet:
            print(f"  ! audio for {path.name} failed: {exc}", file=sys.stderr)
        return False


def backdate(path: Path, when: datetime, quiet: bool) -> None:
    """Day grouping reads creation date; without this everything lands today."""
    stamp = when.strftime("%m/%d/%Y %H:%M:%S")
    for tool in (["SetFile", "-d", stamp, str(path)],
                 ["SetFile", "-m", stamp, str(path)]):
        try:
            subprocess.run(tool, check=True, capture_output=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            if not quiet:
                print(f"  ! could not backdate {path.name} "
                      "(SetFile needs Xcode command line tools)", file=sys.stderr)
            return
    os.utime(path, (when.timestamp(), when.timestamp()))


def history_records(now: datetime, root: Path) -> list[dict]:
    """The Recordings window lists `HistoryStore`, not the library folder.

    `allRecents` maps `history.json` out of Application Support, so markdown on
    disk alone leaves the window empty however correct the library is. These are
    the records that make the generated takes visible.
    """
    out = []
    for i, take in enumerate(TAKES):
        started = take.started(now)
        ended = started + timedelta(seconds=take.duration)
        stem = take.slug(now)
        doc = root / take.folder / f"{stem}.md"
        aud = root / take.folder / f"{stem}.m4a"
        out.append({
            # Stable ids so regenerating does not reshuffle selection state.
            "id": f"00000000-0000-4000-8000-{i:012d}",
            "title": take.title,
            "recordedAt": started.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "endedAt": ended.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "activeApp": "Transcripts",
            "isCall": len(take.speakers) > 2,
            "status": "completed",
            "audioPath": str(aud) if aud.exists() else None,
            "documentPath": str(doc),
            "destination": take.folder,
        })
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default="~/Demo/Transcripts",
                    help="where to build the library (default: ~/Demo/Transcripts)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    root = Path(os.path.expanduser(args.root))
    now = datetime.now().astimezone()

    if root.exists():
        # Regenerating is the normal case — the shots get re-taken often — so a
        # stale take from a previous run must not survive into the screenshots.
        for existing in sorted(root.rglob("*")):
            if existing.is_file():
                existing.unlink()

    made = 0
    for take in TAKES:
        folder = root / take.folder
        folder.mkdir(parents=True, exist_ok=True)
        stem = take.slug(now)
        md, m4a = folder / f"{stem}.md", folder / f"{stem}.m4a"

        opening = take.dialogue[0][2] if take.dialogue else take.description
        if not write_audio(m4a, opening, args.quiet):
            m4a = None

        md.write_text(markdown(take, now, m4a.name if m4a else ""), encoding="utf8")

        started = take.started(now)
        for f in (md, m4a):
            if f:
                backdate(f, started, args.quiet)
        made += 1
        if not args.quiet:
            print(f"  ✓ {take.folder}/{stem}.md")

    history = root / ".demo-history.json"
    history.write_text(json.dumps(history_records(now, root), indent=2),
                       encoding="utf8")

    if not args.quiet:
        print(f"\n{made} takes in {root}")
        print(f"history for the Recordings window: {history.name}")
        print("Point the app at it:")
        print(f'  python3 scripts/demo-screenshots.py --use "{root}"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
