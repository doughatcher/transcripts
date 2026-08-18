# Changelog

## 1.0.0

The first release under this name.

**Mac**

- Menu-bar recorder with automatic call detection — captures your microphone and
  the other participants as separate tracks.
- On-device transcription and summaries. Apple Intelligence when present, a
  built-in summarizer when not.
- Live transcript written to a plain file during the call, so an assistant can
  read the meeting while it is still happening.
- Speaker attribution, correctable — reassigning a voice updates both the
  profile and the transcript.
- Automatic filing into your vault by keyword and on-device model.
- **Import audio from anywhere** — share a call recording, a Voice Memo or any
  audio file into Transcripts and it joins your library with its original
  timestamp.
- **Sessions**: group an evening's recordings under one name, with their own
  folder and an action that runs once when it ends. Start and end them from
  Shortcuts — with an optional label for the occasion and recording that begins
  straight away — so a weekly game can record itself.
- Defaults to iCloud Drive when you have it, so the Mac and the phone meet with
  nothing configured.

**iPhone and iPad**

- Records with the screen locked or another app in front, with a Live Activity
  on the Lock Screen and Dynamic Island.
- Live on-device transcription; refuses to transcribe rather than send audio to
  a server on a device that cannot do it locally.
- Hands recordings to the Mac through a shared folder — iCloud, OneDrive,
  Dropbox, or on-device.

**Known limits**

- Speaker names are a best-effort guess from voice and will occasionally be
  wrong. Settings ▸ Voices is how you correct them, and each correction
  retrains.
- The Mac app is unsandboxed by necessity: capturing other apps' audio and
  writing to a folder you choose are both outside the sandbox.
- It has been in daily use for months, but by very few people. Early Access is
  about widening that — the untested part is the variety of setups, not the app.
