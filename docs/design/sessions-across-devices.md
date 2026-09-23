# Sessions across devices

Status: **built.** `RemoteSession` groups tagged captures and the Mac completes
them. Four gaps were closed on 2026-09-23:

- The tags are persisted, so a relaunch between import and the end of the
  evening no longer forgets them.
- Tagged recordings file into the session's destination.
- Completion waits until every recording in the run has finished processing.
  Before, it ran at import, with no transcripts yet, and then counted as done.
- The Mac re-checks on a five-minute timer and at launch, not only after an
  import, so a run that closes later by the clock still completes.

macOS 26 also added time-of-day automations, so the "only iOS can automate"
premise below no longer holds: either device can start a session.

## The problem

The device at the table is the iPad. The device that can finish the job is the
Mac. They are rarely awake at the same time.

Three constraints, all verified rather than assumed:

- **iOS cannot run the completion action.** `ProcessCommandRunner` is
  `#if os(macOS) || os(Linux)` — there is no `Process` in the iOS sandbox. The
  "publish to adventure-log" half can only ever happen on the Mac.
- **A session that is not recording gets suspended on iOS.** The `audio`
  background mode keeps the app alive *while capturing*. Between takes, iOS
  suspends it and no timer runs, so idle timeouts and hard stops cannot fire
  there.
- **Closing the cover is not an end signal.** It locks the device, which during
  background audio correctly does *not* stop recording — and it happens every
  time the iPad is set down mid-game.

## The shape

**The iPad records and tags. The Mac groups and completes.**

1. iPad starts a session (Shortcuts automation — iOS has real time-of-day
   personal automations, unlike macOS).
2. Every capture it exports carries the session id in its `DeviceCapture`
   sidecar.
3. The Mac ingests tagged captures whenever it next wakes, groups them by tag,
   decides whether the session is over, and runs `onComplete` once.

## The part that is easy to get wrong

**Session end must be derived from the captures' timestamps, not from the Mac's
clock.**

If the Mac wakes on Tuesday and finds five captures tagged `dnd`, asking "has
this been idle for an hour?" against *now* is meaningless — it has been idle for
twelve. The end is a property of the recordings, not of the moment they were
noticed.

So: sort the tagged captures by `startedAt`, and end the session at the first
gap exceeding `idleTimeout`, or at the `hardStop` boundary, whichever comes
first. A pure function over a list of timestamps, which means it is testable the
same way `SessionLifecycle` is, and it gives the same answer whether the Mac
wakes ten minutes or ten days later.

```
endOfSession(captures, profile) -> (endedAt: Date, reason: EndReason)?
```

Returns nil while the run is still open — the most recent capture is within
`idleTimeout` of *now* and before `hardStop`. That is the only place the present
legitimately enters the calculation.

## Consequences worth planning for

- **The sidecar gains a field**, so `DeviceCapture.currentSchema` goes to 3. The
  Mac's ingest gate is `schema <= currentSchema`, so an older Mac correctly
  refuses a newer sidecar rather than silently dropping the tag.
- **Two sources of session membership** — live (Mac was awake and watching) and
  tagged (derived at ingest). They must converge on one session rather than
  producing two, so the tag is the identity and the live clock is an
  optimisation for the case where the Mac happens to be present.
- **Completion stays idempotent.** The existing marker already separates *ended*
  from *completed* for exactly this reason; tag-based grouping must write
  through the same store rather than inventing a second record.
- **The iPad needs its own Start/End intents.** They exist only in
  `TranscriptsMac` today.

## Why this is the right default, not a special case

Most people do not have a Mac awake in the room while they record. Tagging on
the capture device and completing wherever the capable machine happens to be is
the general shape; the live-clock session built today is the narrow case where
both are true at once.
