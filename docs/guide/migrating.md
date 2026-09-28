# Moving your data

Between the two Mac editions, to a new Mac, or out of the app entirely.

## Your transcripts are already portable

The recordings themselves — the `.m4a` audio and the Markdown transcripts — live
in the library folder you chose, as ordinary files. They are never "in" the app,
so they never need migrating: point any copy of Transcripts (or your iPhone and
iPad) at the same folder and every recording is there. Moving to a new Mac means
moving that folder, or letting iCloud Drive or OneDrive carry it.

What the app itself keeps is smaller: the recordings list (the history behind
the menu and the Recordings window) and the remembered voices. Each edition
keeps its own copy —

- **Direct download**: `~/Library/Application Support/Transcripts`
- **Mac App Store**: the same path, but inside the app's sandbox container
  under `~/Library/Containers`

— and that difference is why switching editions used to look like your
recordings had vanished. They hadn't; the new edition just had an empty list.

## Import, from Settings

In the copy you are moving **to**: Settings ▸ Sorting ▸ **Import from another
copy of Transcripts…**, and pick the other copy's data folder — the panel opens
on the usual place. The recordings list and the remembered voices come over;
the transcripts stay where they are.

Importing never replaces anything. A recording already in the list, a voice
profile already trained here, stay as they are — so it is safe to run twice,
and safe on a copy you have already been using.

## Import and export, from the command line

The same migration, scriptable — and the way to hand it to an AI assistant.
The app's binary understands two subcommands:

```
/Applications/Transcripts.app/Contents/MacOS/Transcripts export > state.json
```

```
/Applications/Transcripts.app/Contents/MacOS/Transcripts import < state.json
```

`export` writes the recordings list and remembered voices to stdout as JSON;
`import` merges such a bundle from stdin, with the same never-replace rules as
the Settings button. Quit the app before importing — a running copy would save
its own list over the merge.

The two editions pipe together directly:

```
~/Applications/Transcripts.app/Contents/MacOS/Transcripts export | /Applications/Transcripts.app/Contents/MacOS/Transcripts import
```

stdin and stdout are the interface on purpose: the store edition is sandboxed,
and a file path passed as an argument is a path it cannot open — but a pipe is
handed to it already open, so the shell can carry the bundle between editions
without either one needing to read the other's files.

## What moves, and what doesn't

Moves: the recordings list, and the remembered voices (profiles and samples).

Stays put, by design: the transcripts and audio (your library folder — point
the new copy at it), and each edition's settings. The editions genuinely
differ — custom scripts and the Handoff pipeline exist only in the direct
download — so settings are worth a minute in the new copy rather than a copy
of the old file.

An imported recording plays and opens as long as its files are in the library
the new copy can see. A recording whose audio only ever lived in the other
edition's private captures folder — one that was still processing, or failed —
shows in the list but can't be replayed from here.

## If you moved by hand and the list came up empty

Older versions had nothing above, and copying `history.json` into the store
edition's container by hand could end with the list still empty — and worse,
the file quietly rewritten. Two things changed. The app now reads every record
it can rather than none: one record it cannot decode costs that record, not
the list. And when that happens, it first preserves the untouched original
beside the file as `history.json.rejected`, so nothing is lost to the rewrite.

If a by-hand move already emptied your list, nothing is actually gone: the
other edition still has its history. Run the import above — from Settings or
the command line — and the list comes back.
