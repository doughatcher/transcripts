# Recording

## Manual recordings

**Start recording** from the menu captures your microphone until you choose
**Stop & process**. That is the whole interaction. Use it for a voice note, a
thought you don't want to lose, or a conversation in the room.

![The menu while recording, with the timer, Stop & process and Open live transcript](/guide/images/menu-recording.webp)

## Recording calls

Leave **Auto** on and Transcripts watches for calls. When you join a Teams, Zoom,
Webex or Meet call and your microphone goes live, it starts recording — and it
records **both sides**: your microphone and the audio of the call, as two
separate tracks mixed into one file.

Two tracks matter more than it sounds. Because your voice arrives on its own
track, every word of yours is known to be yours with no guesswork. All the
uncertainty about who said what is confined to the other side. A single mixed
recording throws that away.

When the call ends, recording stops and processing begins.

## Consent

Recording law varies by country and by state. Some places allow one participant
to record; others require everyone to agree.

Settings ▸ General has a **Consent mode**:

- **One-party** — Transcripts records a detected call automatically.
- **Two-party** — Transcripts notifies you first and records nothing until you
  confirm you have told everyone.

Two-party mode is the honest default in jurisdictions that require all-party
consent. Transcripts gives you a recorder; whether you may lawfully use it on a
given conversation is yours to judge.

## When the microphone is dead

A surprising number of lost recordings are not lost at all — they are silent,
because the input was a webcam microphone on a closed laptop lid, or a headset
that disconnected.

Transcripts watches for this. If the level stays at nothing while it is supposed
to be recording, it tells you rather than handing you a silent file an hour
later. Settings ▸ General lets you nominate preferred microphones in order, so a
good one is chosen when it is present.

## Pausing, and what happens if things go wrong

Audio is written to disk continuously, not held in memory and saved at the end.
If the app quits, the machine sleeps, or the power goes, the audio recorded up to
that moment survives, and Transcripts offers to resume the take when it starts
again.

If Transcripts restarts while a recording is running — you quit it, it crashed,
or it was updated — it **picks the same recording back up** rather than ending
it. The piece it had already captured is set aside, recording starts again
within a second or two, and when you finally stop, every piece is reassembled
into one recording on a single timeline. The only trace is a couple of seconds
of silence where the app was away.

The menu says so while it is happening ("Resumed after relaunch"), so a restart
is never something you have to take on faith.

This holds for as long as the gap is short — about ten minutes. A marker left
behind by a crash days ago is not resumed, because starting to record out of
nowhere is worse than filing what was captured.

---

## Phone calls

**iOS does not let any third-party app record a phone call.** `CallKit` reports
only whether a call is connected — not its audio — and no audio-session mode
routes call audio to an app. During a call iOS takes the microphone
exclusively, so Transcripts cannot capture even your own side.

Transcripts knows a call has started and **stops cleanly**, keeping what it
already recorded, rather than being cut off mid-capture and leaving a take that
claims forty minutes and holds four.

What you can do instead:

- **Record the call with the Phone app** (iOS 18.1 and later announces itself
  audibly to everyone on the line, and saves the recording and a transcript into
  Notes), then **share that recording into Transcripts** — it lands in your
  library like any other recording, syncs to the Mac, and is transcribed and
  attributed properly there.
- **Put the call on speaker** and record it with an iPad or Mac in the room.
  Crude, but it captures both sides — and on the Mac you get speaker names.

## Importing audio recorded elsewhere

Anything the share sheet can hand over — a call recording exported from Notes, a
Voice Memo, an interview someone emailed you — can go into Transcripts. Share it
and pick Transcripts, or use **Open with** from Files.

Imported recordings keep **their own timestamp**, not the moment you imported
them, so a call recorded this morning and shared tonight files under this
morning — and joins the right session on the Mac.

Next: [The live transcript](/guide/live/)
