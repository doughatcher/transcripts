#!/usr/bin/env python3
"""Recover titles the summarizer produced but the app failed to read.

`SummarizeStage.extractTitle` only matched a bare `TITLE:` line, so a model
that decorated it — `**TITLE: Post-Sales Interview Process**` — produced a
title that went nowhere: the transcript kept its meeting-window name, and the
line stayed sitting in the summary where you can see exactly what was lost.
The stage is fixed, but documents already written still carry the damage.

This puts the title where it belongs in files already on disk:

  * frontmatter `title:` becomes the model's title
  * the stranded `TITLE:` line is removed from the summary
  * the Mac's history record for that document is retitled to match, so the
    Recordings list and the phone stop disagreeing

Filenames are deliberately left alone: they are referenced by `audio_file`,
by the Mac's `documentPath`, and by the phone's dedup — renaming them to match
would be a much larger and more breakable change than the titles are worth.

    scripts/repair-titles.py                      # dry run over config's roots
    scripts/repair-titles.py --write
    scripts/repair-titles.py --root DIR [--root DIR] --write
"""

import argparse
import json
import os
import pathlib
import re
import sys

SUPPORT = pathlib.Path.home() / "Library/Application Support/Transcripts"
CONFIG = SUPPORT / "config.json"
HISTORY = SUPPORT / "history.json"
SKIP_DIRS = {"Inbox", "Processed", ".transcripts", ".obsidian", ".git"}
SKIP_NAMES = {"Transcripts Live.md"}
# How far into the summary to look. The line is first in the model's output but
# lands under a "## Summary" heading once persisted.
SCAN_LINES = 8

# Two different jobs. A *label* may carry decoration anywhere and none of it is
# part of the word, so it all goes. A *title* may only be unwrapped at its ends,
# because the same characters are load-bearing inside it: "C# to F# Migration"
# must not come out as "C to F Migration".
DECORATION = re.compile(r"[*_`#>]")
EDGE_DECORATION = re.compile(r"^[*_`\s]+|[*_`\s]+$")


def roots_from_config():
    """The knowledge root only — deliberately not the vault.

    A vault is full of other people's documents: Obsidian clipper templates
    whose frontmatter is literally `title: "<page title>"`, and transcripts from
    other producers (Plaud, and work recordings whose `source: scribe` is this
    app's own former name, so `source` cannot tell them apart). The knowledge
    root is the one place everything was written by this app. Repair there and
    re-run `mirror-backfill.py` to carry the fix into the vault.
    """
    if not CONFIG.exists():
        sys.exit(f"no config at {CONFIG} — pass --root")
    dest = json.loads(CONFIG.read_text()).get("destinations", {})
    if not dest.get("knowledgeRoot"):
        sys.exit("config names no knowledgeRoot")
    return [os.path.expanduser(dest["knowledgeRoot"])]


def looks_like_a_recording(fm):
    """Frontmatter of something this app recorded, rather than a note or a
    template that happens to contain the word TITLE."""
    keys = {line.split(":", 1)[0].strip() for line in fm if ":" in line}
    return "recorded_at" in keys and bool(keys & {"audio_file", "duration_seconds", "ended_at"})


def split_frontmatter(text):
    """Returns (frontmatter_lines, body, had_frontmatter)."""
    if not text.startswith("---\n"):
        return [], text, False
    end = text.find("\n---\n", 4)
    if end == -1:
        return [], text, False
    return text[4:end].split("\n"), text[end + 5:], True


def find_title_line(body):
    """Index and value of a stranded `TITLE:` line near the top of the body."""
    lines = body.split("\n")
    seen = 0
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        seen += 1
        if seen > SCAN_LINES:
            break
        head, sep, rest = line.partition(":")
        if sep and DECORATION.sub("", head).strip().upper() == "TITLE":
            title = EDGE_DECORATION.sub("", rest)
            if title:
                return i, title
    return None, None


def yaml_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def repair(path):
    """Returns the new text and the recovered title, or (None, None)."""
    text = path.read_text(encoding="utf-8")
    fm, body, had = split_frontmatter(text)
    if not had or not looks_like_a_recording(fm):
        return None, None
    index, title = find_title_line(body)
    if not title:
        return None, None

    lines = body.split("\n")
    del lines[index]
    # Leave one blank line where a heading was followed by the title line.
    while index < len(lines) and index > 0 and not lines[index].strip() and not lines[index - 1].strip():
        del lines[index]
    new_body = "\n".join(lines)

    replaced = False
    for i, line in enumerate(fm):
        if line.startswith("title:"):
            fm[i] = f"title: {yaml_quote(title)}"
            replaced = True
            break
    if not replaced:
        fm.insert(0, f"title: {yaml_quote(title)}")

    return "---\n" + "\n".join(fm) + "\n---\n" + new_body, title


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", action="append", default=[])
    ap.add_argument("--write", action="store_true", help="apply (default is a dry run)")
    args = ap.parse_args()

    roots = args.root or roots_from_config()
    repaired = {}

    for root in roots:
        root = pathlib.Path(root)
        if not root.is_dir():
            print(f"! skipping missing root {root}")
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in sorted(filenames):
                if not name.endswith(".md") or name in SKIP_NAMES:
                    continue
                path = pathlib.Path(dirpath) / name
                new_text, title = repair(path)
                if not title:
                    continue
                print(f"{'fix ' if args.write else 'would fix'}  {name}\n      → {title}")
                if args.write:
                    path.write_text(new_text, encoding="utf-8")
                repaired[str(path)] = title

    # Retitle the Mac's records so the Recordings list agrees with the phone.
    hist_fixed = 0
    if HISTORY.exists() and repaired:
        records = json.loads(HISTORY.read_text())
        for rec in records:
            title = repaired.get(rec.get("documentPath") or "")
            if title and rec.get("title") != title:
                print(f"{'retitle' if args.write else 'would retitle'}  record {rec.get('title')!r} → {title!r}")
                rec["title"] = title
                hist_fixed += 1
        if args.write and hist_fixed:
            HISTORY.write_text(json.dumps(records, indent=2), encoding="utf-8")

    verb = "repaired" if args.write else "to repair"
    print(f"\n{len(repaired)} document(s) {verb}, {hist_fixed} history record(s)")
    if repaired and not args.write:
        print("re-run with --write to do it")
    if args.write and hist_fixed:
        print("restart Transcripts so it reloads history.json")


if __name__ == "__main__":
    main()
