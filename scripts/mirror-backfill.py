#!/usr/bin/env python3
"""Copy transcripts already in the knowledge root into the Obsidian vault.

The vault mirror runs at the end of the pipeline, so it only ever sees new
recordings. Turning it on therefore gives you a vault that starts from today
and a library that starts from whenever you began — which reads, in Obsidian,
as though the transcripts simply stop. This closes that gap once.

Same rules as the mirror itself (PersistStage): markdown only, into the same
routed subfolder, with `audio_file` swapped for an `audio_path` pointing at
where the audio actually stayed. Never overwrites a file already in the vault.

    scripts/mirror-backfill.py                    # read config, dry run
    scripts/mirror-backfill.py --write            # actually copy
    scripts/mirror-backfill.py --root A --vault B # explicit paths
"""

import argparse
import json
import os
import pathlib
import sys

CONFIG = pathlib.Path.home() / "Library/Application Support/Transcripts/config.json"
# The handoff folders and the live-transcript scratch file are mechanism, not
# content — the same set the iOS library scan skips.
SKIP_DIRS = {"Inbox", "Processed", ".transcripts", ".obsidian", ".git"}
SKIP_NAMES = {"Transcripts Live.md"}


def from_config():
    if not CONFIG.exists():
        sys.exit(f"no config at {CONFIG} — pass --root and --vault")
    dest = json.loads(CONFIG.read_text()).get("destinations", {})
    root, vault = dest.get("knowledgeRoot"), dest.get("vaultMirror")
    if not root:
        sys.exit("config has no knowledgeRoot")
    if not vault:
        sys.exit("config has no vaultMirror — set it in Settings ▸ Sorting ▸ Obsidian first")
    return os.path.expanduser(root), os.path.expanduser(vault)


def rewrite_audio_keys(text, audio_dir):
    """`audio_file` names a sibling; in the vault there is no sibling. Point at
    where the audio actually is instead of leaving a dangling name."""
    if not text.startswith("---\n"):
        return text
    end = text.find("\n---\n", 4)
    if end == -1:
        return text
    head, body = text[4:end], text[end + 5:]
    out = []
    for line in head.split("\n"):
        if line.startswith("audio_file:"):
            name = line.split(":", 1)[1].strip().strip("\"'")
            out.append("audio_file: ")
            if name:
                out.append(f"audio_path: {os.path.join(audio_dir, name)}")
        else:
            out.append(line)
    return "---\n" + "\n".join(out) + "\n---\n" + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root")
    ap.add_argument("--vault")
    ap.add_argument("--write", action="store_true", help="copy (default is a dry run)")
    args = ap.parse_args()

    root, vault = (args.root, args.vault) if args.root and args.vault else from_config()
    root, vault = pathlib.Path(root), pathlib.Path(vault)
    if not root.is_dir():
        sys.exit(f"knowledge root is not a directory: {root}")
    if not vault.is_dir():
        sys.exit(f"vault is not a directory: {vault}")
    if not (vault / ".obsidian").is_dir():
        sys.exit(f"not an Obsidian vault (no .obsidian): {vault}")

    copied = skipped = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in sorted(filenames):
            if not name.endswith(".md") or name in SKIP_NAMES:
                continue
            src = pathlib.Path(dirpath) / name
            target = vault / src.relative_to(root)
            if target.exists():
                skipped += 1
                continue
            print(f"{'copy' if args.write else 'would copy'}  {src.relative_to(root)}")
            if args.write:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(
                    rewrite_audio_keys(src.read_text(encoding="utf-8"), dirpath),
                    encoding="utf-8")
            copied += 1

    verb = "copied" if args.write else "to copy"
    print(f"\n{copied} {verb}, {skipped} already in the vault")
    if copied and not args.write:
        print("re-run with --write to do it")


if __name__ == "__main__":
    main()
