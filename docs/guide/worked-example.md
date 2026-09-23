# A worked example: Adventure Log

Everything in this guide so far has been about getting a recording filed
correctly. This page is about what happens next — what it looks like when
something else picks the transcripts up and does its own work with them.

[Adventure Log](https://github.com/doughatcher/adventure-log) is a live
companion for a Dungeons & Dragons table. It publishes a campaign journal to
[doughatcher.github.io/adventure-log](https://doughatcher.github.io/adventure-log/),
tracks hit points and combat state during play, and writes a session brief for
the next game. It is not part of Transcripts and is not built by the same
machinery. It is a separate program that happens to read what Transcripts
writes, which is the point of the example: the documents in your folder are a
format other things can consume.

![The Adventure Log journal: two campaigns, the one in play marked active, with its setting, DM and where the party was last seen](/guide/images/adventure-log-home.webp)

## During the game

The journal is what the table gets afterwards. There's a use during the game
too, because the live transcript is a plain file that grows turn by turn while
the recording runs.

On 31 August the party arrived at the Shadow Fey's lower court, where standing
is scored by the DM, point by point, for skill checks made in front of the
right people. Mid-session, with the recorder still going, Aldric's player asked
Claude to read `live.md` and suggest a way in. The answer came from what had
actually been said at the table in the previous hour. It had the running
status tally, which rooms and people the DM had described, and the fact that
another player had just announced he was working the room with Persuasion.
From that it suggested five openings that suited a diviner rather than a
courtier: proofread the bearfolk emissary's letter before it was sealed, read
an omen for the squire before his duel, and so on. It also pointed out a
thread nobody had pulled: the whole party was wearing the Winter King's
insignia, and no one had asked what that signalled at court.

None of this needed an integration. The assistant read a Markdown file the
recorder was already writing.

## What the evening looks like

A session at the table is not one recording. Someone starts the recorder before
people have settled, it stops when the pizza arrives, it starts again. By the
end of the night the folder holds several documents that are all the same
evening.

Transcripts already knows they belong together — that is what a session is, and
[Sorting and sessions](/guide/routing/) covers how it decides. What matters here
is the last step: when the session is genuinely over, `onComplete` runs once and
hands over every document in it at the same time.

That "once, with all of them" is the part worth noticing. A hook that fired per
recording would see four fragments of an evening and have no way to know it was
holding fragments. Adventure Log's importer receives the whole night in one go
and folds it into a single transcript, which is the only reason a journal entry
can read as one continuous session.

## What it does with them

The importer stitches the documents into one file, then a generator turns that
into a written journal entry, character updates, and a brief for next time.
Local models do the writing, so the campaign — which contains a great deal of
ordinary conversation between friends — never leaves the machine.

Two of its decisions are worth repeating here, because they are the kind of
thing anyone building on a recorder eventually runs into.

**It throws away everything before the game started.** A recorder that has been
running all afternoon has an afternoon in it. The importer knows when the
session began, works out a real wall-clock time for every line by combining each
document's `recorded_at` with its turn timestamps, and drops anything earlier.
The campaign journal is a public website; the work call before the game is not
part of the campaign.

**When it cannot place a line on that timeline, it refuses.** An older document
written before turns were stamped cannot be trimmed reliably, and the importer
stops rather than guessing. Publishing an untrimmed transcript to a public site
is not a mistake you can take back, so the failure is deliberately noisy and
deliberately early.

It also opens a pull request instead of pushing. A person reads the session
before it goes up.

![A journal entry written from one evening's transcripts](/guide/images/adventure-log-session.webp)

## One table, two campaigns

The table plays two campaigns in turn, depending on which DM is free. The
importer won't guess which one a night belongs to: filed under the wrong party,
a session is a mess to undo on a public site. So `--campaign` is required, and
each campaign gets its own session profile, with the campaign in the profile's
`id`:

```json
"sessions": [
  {
    "id": "courts-of-the-shadow-fey",
    "name": "D&D — Courts of the Shadow Fey",
    "destination": "Campaigns/transcripts/",
    "hardStop": "23:30",
    "onComplete": {
      "executable": "/usr/bin/python3",
      "arguments": ["scripts/import_transcripts_session.py",
                    "--campaign", "${sessionID}", "--slug", "${slug}",
                    "--started-at", "${startedAt}", "--ended-at", "${endedAt}",
                    "--transcripts", "${transcripts}"],
      "workingDirectory": "/Users/me/repos/adventure-log"
    }
  },
  { "id": "shard-sea", "name": "D&D — Shard Sea", "...": "the same" }
]
```

Starting a session is then the same act as saying which game it is.

## When the session isn't started

It happens. On 21 September the recorder ran for the whole evening, two hours
and twenty minutes of play, but nobody started the session. Transcripts did
what it does with any recording: it transcribed it, summarised it and sorted it
into the general `transcripts/` folder. No session ended, so `onComplete` never
ran and nothing reached the journal.

Nothing was lost, because the transcript is an ordinary file with its
`recorded_at` and timestamped turns. The importer takes any documents, not just
a session's, so the night went up by hand the next morning:

```
python3 scripts/import_transcripts_session.py \
  --campaign courts-of-the-shadow-fey --slug 2026-09-21-courts-of-the-shadow-fey \
  --started-at 2026-09-21T22:37:31Z --ended-at 2026-09-22T00:59:10Z \
  --transcripts ".../transcripts/2026-09-21-1837-duel-court-update-summary.md"
```

It kept all 895 turns, dropped none from outside the evening, and opened a pull
request to read before publishing.

## Why this is the shape to copy

Nothing above required Transcripts to know anything about D&D. The app files
Markdown into a folder with a stable front matter block and timestamped turns;
`onComplete` says when a session is finished and what it contained. Everything
specific to the campaign lives in the other program.

If you are building something similar, the mechanics of the hook — what it
receives, when it fires, and how to test it without waiting for a real session —
are in [Sorting and sessions](/guide/routing/), and the full configuration is in
the [routing.json reference](/guide/reference/).

---

Next: [Privacy](/guide/privacy/)
