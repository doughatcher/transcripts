# Sorting and routing

Transcripts files each finished recording into a folder in your vault. This page
is about `routing.json` — the file that decides where, and what happens
afterwards.

You never have to open it. Settings ▸ Sorting covers the common choices. But it
is plain JSON, deliberately hand-editable, and everything below is reachable
there.

## Where it lives

```
<your folder>/.transcripts/routing.json
```

Beside your recordings rather than inside the app, so it travels with the vault
and can be versioned with it. Transcripts writes a starter file the first time
it runs.

## The shape

```json
{
  "mode": "automatic",
  "fallback": "transcripts/",
  "confidenceThreshold": 0.55,
  "destinations": [
    { "path": "Cases/Northwind/transcripts/", "keywords": ["northwind", "nw"] }
  ],
  "sessions": []
}
```

Every key is optional. A missing one falls back to its default, and an
unreadable file falls back to the defaults entirely rather than stopping
recordings from being filed — a typo should cost you sorting, not your audio.

## Modes

**`automatic`** — the default. Transcripts discovers every folder in your vault
ending in `transcripts/` and treats each as a candidate. It matches on keywords
first, and only asks the on-device model when the keywords are ambiguous. Cheap
and predictable in the common case; the model is a tie-breaker, not the
mechanism.

**`script`** — hands the decision to a command of yours. It receives the
recording's paths and context, and prints a vault-relative folder. Print nothing
and the recording goes to `fallback`; print `handled` and Transcripts assumes
your script filed it itself.

**`off`** — everything goes to `fallback`. Nothing is inferred.

## Destinations and keywords

```json
{ "path": "Cases/Northwind/transcripts/", "keywords": ["northwind", "acquisition"] }
```

`path` is relative to your vault. `keywords` are matched against the transcript
and the meeting's window title — so a Teams call named "Northwind sync" routes
on the title alone, before a word is transcribed.

Curated destinations are merged with the auto-discovered ones; listing a folder
here adds keywords to it rather than replacing the discovery.

`confidenceThreshold` is how sure the model must be (0–1) before its answer is
accepted. Below it, the recording goes to `fallback`. Raise it if things are
being filed too eagerly; lower it if too much lands in the fallback folder.

---

## Sessions

A recording is the wrong unit for some things. A D&D night, a workshop, a day of
interviews — one occasion, several recordings, with breaks in between. A session
groups them, and runs something once when the whole thing is over.

```json
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
      "environment": { "SLUG": "${slug}", "TRANSCRIPTS": "${transcripts}" }
    }
  }
]
```

| Key | Meaning |
| --- | --- |
| `id` | Stable identifier. Used by the Shortcuts action, and by the marker on disk. Renaming it while a session runs orphans that session. |
| `name` | What you see in the menu and in Shortcuts. |
| `destination` | Files this session's recordings here, skipping the usual sorting entirely. Optional. |
| `idleTimeout` | Seconds of no recording before the session ends by itself. `0` disables it. Default one hour. |
| `hardStop` | Local `"HH:mm"` backstop. The first occurrence at or after the start — so a 22:00 session with a `01:00` stop ends in the small hours, not before it began. |
| `onComplete` | Runs **once**, when the session is genuinely over. |

### When a session ends

Three ways, in priority order:

1. **You end it** — from the menu, or the *End Session* Shortcuts action.
2. **`hardStop`** — the wall-clock backstop, checked first, so a session past its
   stop time ends whether or not someone is still recording.
3. **`idleTimeout`** — nothing recorded for long enough.

The default timeout is deliberately generous. The two failure modes are not
equal: ending late costs you a delayed action, while ending early splits one
evening into two sessions and runs your completion action on half a game.

A session survives the app quitting, crashing, or being replaced by a new build
mid-evening. If it ended while the app was away, the completion action runs on
the next launch — late, but exactly once.

### What `onComplete` receives

An ordinary command, with `${...}` substitutions — the same convention the
pipeline's external stages use:

| Variable | |
| --- | --- |
| `${sessionID}` · `${sessionName}` | from the profile — the *kind* of session |
| `${sessionLabel}` | what you called this particular one, if you passed a label |
| `${slug}` | `2026-08-17-session-42-the-sunken-keep` — the date plus the label, falling back to the id |
| `${startedAt}` · `${endedAt}` | ISO 8601 |
| `${endReason}` | `explicit`, `idle` or `hardStop` |
| `${recordingCount}` | how many recordings the session gathered |
| `${transcripts}` | transcript paths, newline-separated |
| `${audio}` | audio paths, newline-separated |

Newline-separated lists so a shell can loop over them without quoting games:

```bash
while IFS= read -r f; do cat "$f" >> "$OUT/transcript.md"; done <<< "$TRANSCRIPTS"
```

A failing script is logged and otherwise ignored. The session is over and the
recordings are already filed; a broken publish step should not put the app into
an error state hours later. Check `~/Library/Logs/Transcripts.log`.

### Starting one

From the menu — **Start session**, which appears once you have a profile — or
from Shortcuts, where Transcripts provides **Start Session** and **End Session**
actions.

The Start action takes three things:

- **Session** — which profile, picked from your `routing.json`.
- **Label** — optional free text naming *this* occasion: "Session 42, The Sunken
  Keep". It shows in the menu, arrives as `${sessionLabel}`, and shapes
  `${slug}` — so a journal folder gets named after the night rather than after
  the campaign.
- **Start recording** — on by default. Turn it off if you would rather let call
  detection decide, or if your trigger is only a clock and might fire before you
  have arrived.

Because these are Shortcuts actions they automate. The best trigger is a
**location and a time together** — arriving at the place where you play, on the
evening you play — because that fires when you are already at the table. A
time-only automation is the case where you might want the recording toggle off.

On iPhone and iPad this is a personal automation. On the Mac, a `launchd` job or
a calendar event running:

```bash
shortcuts run "Start Session"
```

Ending is symmetrical, and stops an in-progress recording first — a session that
ended mid-take would otherwise complete without the very recording you were
still making.

---

Next: [iPhone, iPad and Mac](/guide/handoff/)
