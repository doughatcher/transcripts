# routing.json reference

The complete schema, for anyone who would rather edit the file than the
settings pane. Everything here is also reachable from Settings ▸ Sorting; this
page exists because some of it is faster to type than to click, and because
sessions have no UI for creating them yet.

```bash
# Where it lives. Written on first run; safe to hand-edit while the app runs.
<your folder>/.transcripts/routing.json
```

## Top level

```json
{
  "mode": "automatic",
  "fallback": "transcripts/",
  "confidenceThreshold": 0.55,
  "destinations": [],
  "script": null,
  "sessions": []
}
```

| Key | Type | Default | |
| --- | --- | --- | --- |
| `mode` | `"automatic"` · `"script"` · `"off"` | `"automatic"` | How a destination is chosen. |
| `fallback` | string | `"transcripts/"` | Vault-relative folder used when nothing else decides. |
| `confidenceThreshold` | number 0–1 | `0.55` | How sure the model must be before its answer is taken. |
| `destinations` | array | `[]` | Curated folders and their keywords. |
| `script` | command \| null | `null` | Used when `mode` is `"script"`. |
| `sessions` | array | `[]` | Named multi-recording occasions. |

Every key is optional. A missing one takes its default, and a file that fails to
parse falls back to defaults entirely rather than stopping recordings from being
filed — a typo should cost you sorting, not your audio. Parse failures are
logged.

## `destinations[]`

```json
{
  "destinations": [
    {
      "path": "Cases/Northwind/transcripts/",
      "keywords": ["northwind", "nw", "acquisition"]
    }
  ]
}
```

| Key | Type | |
| --- | --- | --- |
| `path` | string | Vault-relative. Conventionally ends in `transcripts/`. |
| `keywords` | string[] | Matched case-insensitively against the transcript **and** the meeting's window title. |

In `automatic` mode these are merged with folders discovered by scanning the
vault for `*/transcripts/`. Listing one here adds keywords to it rather than
replacing the discovery.

Because window titles are matched, a call named "Northwind sync" routes on the
title alone — before a word has been transcribed.

## `script`

Used when `"mode": "script"`. An `ExternalCommand` (below). Print a
vault-relative folder on stdout; print nothing to fall through to `fallback`;
print `handled` to tell Transcripts your script filed the recording itself.

```json
{
  "mode": "script",
  "script": {
    "executable": "/usr/bin/python3",
    "arguments": ["${HOME}/bin/sort.py", "${transcriptPath}"],
    "timeoutSeconds": 60
  }
}
```

## `sessions[]`

A session groups several recordings made on one occasion — an evening's game, a
workshop, a day of interviews — and runs something **once**, when the whole
thing is over.

```json
{
  "sessions": [
    {
      "id": "dnd",
      "name": "Curse of the Sunfall",
      "destination": "Campaigns/CotSF/transcripts/",
      "idleTimeout": 3600,
      "hardStop": "23:30",
      "onComplete": {
        "executable": "/bin/bash",
        "arguments": ["-c", "~/bin/publish-session.sh"],
        "environment": {
          "SLUG": "${slug}",
          "TRANSCRIPTS": "${transcripts}"
        }
      }
    }
  ]
}
```

| Key | Type | Default | |
| --- | --- | --- | --- |
| `id` | string | *required* | Stable identifier. Referenced by the Shortcuts action and by the on-disk marker. Renaming it while a session runs orphans that session. |
| `name` | string | `id` | Shown in the menu and in Shortcuts. |
| `destination` | string \| null | `null` | Files this session's recordings here, skipping classification entirely. |
| `idleTimeout` | seconds | `3600` | Quiet time before the session ends by itself. `0` disables. |
| `hardStop` | `"HH:mm"` \| null | `null` | Local wall-clock backstop. |
| `onComplete` | command \| null | `null` | Runs once when the session ends. |

### How a session ends

Three ways, evaluated in this order:

1. **Explicitly** — the menu, or the *End Session* action.
2. **`hardStop`** — checked first, so a session past its stop time ends whether
   or not someone is still recording. Resolved to the first occurrence at or
   after the session's start, so a 22:00 session with `"01:00"` ends in the
   small hours rather than before it began.
3. **`idleTimeout`** — measured from the end of the last recording, not its
   start, so a three-hour take is not mistaken for three hours of silence.

A malformed `hardStop` is ignored rather than fatal: a typo costs you the
backstop, not the session.

### Sessions recorded on a phone or iPad

The mobile apps can start a session too, and every recording made during one is
tagged with it in the capture's sidecar. The Mac reconstructs the evening from
those tags when it next ingests — which need not be the same day.

This is why the end conditions are defined against the recordings rather than a
clock. A Mac that wakes on Tuesday cannot ask "has this been idle for an hour";
it has been idle for twelve. Instead the recordings are sorted, and a gap longer
than `idleTimeout` marks where one evening ended and the next began. The answer
is the same whether the Mac wakes ten minutes later or ten days.

Completed runs are remembered, so an evening is published exactly once no matter
how many times its recordings are re-scanned.

## `ExternalCommand`

The shape used by `script`, `onComplete`, and every pipeline stage.

```json
{
  "executable": "/bin/bash",
  "arguments": ["-c", "echo hello"],
  "workingDirectory": "/Users/you/repos/thing",
  "environment": { "KEY": "${slug}" },
  "timeoutSeconds": 600
}
```

| Key | Type | Default | |
| --- | --- | --- | --- |
| `executable` | string | *required* | Absolute path. Not resolved through `PATH`. |
| `arguments` | string[] | `[]` | |
| `workingDirectory` | string \| null | `null` | |
| `environment` | object | `{}` | Merged over the inherited environment. |
| `timeoutSeconds` | number | `600` | Killed past this. |

`arguments` and `environment` values support `${...}` substitution.

### Session substitutions

Available to `onComplete`:

| Variable | Example |
| --- | --- |
| `${sessionID}` | `dnd` |
| `${sessionName}` | `Curse of the Sunfall` |
| `${sessionLabel}` | `Session 42` — empty if none was given |
| `${slug}` | `2026-08-17-session-42` — the label if there is one, else the id |
| `${startedAt}` · `${endedAt}` | ISO 8601 |
| `${endReason}` | `explicit` · `idle` · `hardStop` |
| `${recordingCount}` | `4` |
| `${transcripts}` | transcript paths, newline-separated |
| `${audio}` | audio paths, newline-separated |

Lists are newline-separated so a shell can iterate them without quoting games:

```bash
#!/usr/bin/env bash
set -euo pipefail

OUT="$HOME/repos/adventure-log/data/sessions/$SLUG"
mkdir -p "$OUT"

# One transcript per line; concatenate them in order.
while IFS= read -r f; do
  [ -n "$f" ] && cat "$f" >> "$OUT/transcript.md"
done <<< "$TRANSCRIPTS"

cd "$HOME/repos/adventure-log"
git add "data/sessions/$SLUG"
git commit -m "session $SLUG"
git push          # the workflow builds and deploys from here
```

A failing command is logged and otherwise ignored — the session is over and the
recordings are already filed, so a broken publish step should not put the app
into an error state hours later.

```bash
# Where to look when a hook does not do what you expected.
tail -f ~/Library/Logs/Transcripts.log
```

## A complete example

```json
{
  "mode": "automatic",
  "fallback": "transcripts/",
  "confidenceThreshold": 0.6,
  "destinations": [
    { "path": "Cases/Northwind/transcripts/", "keywords": ["northwind", "nw"] },
    { "path": "Team/transcripts/",            "keywords": ["standup", "retro"] }
  ],
  "sessions": [
    {
      "id": "dnd",
      "name": "Curse of the Sunfall",
      "destination": "Campaigns/CotSF/transcripts/",
      "idleTimeout": 5400,
      "hardStop": "23:30",
      "onComplete": {
        "executable": "/bin/bash",
        "arguments": ["-c", "~/bin/publish-session.sh"],
        "environment": { "SLUG": "${slug}", "TRANSCRIPTS": "${transcripts}" }
      }
    }
  ]
}
```

---

Next: [iPhone, iPad and Mac](/guide/handoff/)
