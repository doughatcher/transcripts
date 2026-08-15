# iPhone, iPad and Mac

The mobile app is a complete recorder on its own: it captures audio, transcribes
live on the device, and keeps a browsable library. You do not need a Mac.

If you have one, the two halves join up.

## How it works

Both apps read and write one folder. The phone writes finished recordings into an
`Inbox` inside it; the Mac watches that folder, takes what appears, runs it
through the full pipeline — better transcription, speaker names, summary, filing
— and puts the result back.

The audio file is written **first** and a small description of it **last**. That
ordering is the whole trick: cloud folders materialise files gradually, so "the
audio exists" does not mean "the audio is complete". The Mac waits for the
description before touching anything, and never imports half a recording.

## Setting it up

The zero-configuration path:

- On the **Mac**, leave the default folder — `iCloud Drive/Transcripts`.
- On the **phone or iPad**, choose **Set up for me** and pick iCloud Drive.

Both sides now point at the same place with nothing typed. Recordings made on the
phone appear on the Mac within a minute or two of landing.

If you'd rather use OneDrive, Dropbox, or a folder on a NAS, use **Choose a
folder** on the phone and point the Mac at the same place in Settings ▸
Destinations. Any service that appears in the iOS Files app works, because the
handoff is a folder rather than an integration — there is no account to connect
and no permission to grant.

## What the phone does on its own

- Records with the screen locked or another app in front.
- Shows a Live Activity on the Lock Screen and Dynamic Island while capture runs.
- Transcribes live, on the device, so you can read along.
- Keeps everything if the Mac never picks it up.

The live transcript from the phone is deliberately marked as a draft. The Mac
re-transcribes from the audio, because it can do a better job with the whole file
than the phone can do a sentence at a time — and when it does, it replaces the
draft in place.

---

Next: [Settings](/guide/settings/)
