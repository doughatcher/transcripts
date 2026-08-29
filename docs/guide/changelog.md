# Changelog

## 1.0.2

- The Obsidian mirror refuses to run when it would write over the copy it is
  mirroring — pointing it at the knowledge root used to blank the `audio_file`
  the filed transcript needs to find its own audio.

## 1.0.1

The release the first iPad taught us to make.

**Obsidian**

- Transcripts finds your vault and files a copy of every finished transcript
  into it, in the same folder Sorting routed it to — on by default if you use
  Obsidian, and a Settings row away from being a different vault or none. It is
  a copy rather than a move, because the iCloud folder is what your phone and
  iPad read their library from and a vault carried by Obsidian Sync is not
  something they can see. Markdown only: the audio stays in the knowledge root
  rather than filling a synced vault with recordings.

**iPhone and iPad**

- Shared transcripts now actually open on the device that didn't write them.
  Reading a transcript from the workspace folder went through without the
  folder's security scope and without asking iCloud to download the file — on
  the Mac that wrote the file both are free, on an iPad both fail silently, so
  a transcript showed its title and summary over an empty page. Reads now
  carry the scope, request the download, and say "fetching" or "not synced
  yet" instead of showing nothing.
- Shared transcripts can be played. The Mac has always archived the audio next
  to the markdown and named it in the frontmatter; the app now reads that and
  puts the same scrubber on a shared transcript that local recordings have.
- Transcripts render their structure — section headings, bold speaker names
  and bullets — instead of literal `##` and `**`.
- Long transcripts no longer freeze the pane on open, and the library scan
  reads only each file's frontmatter instead of paging whole meetings into
  memory on every refresh.
- Search also matches a shared transcript's summary.

**Mac**

- A menu-bar icon of our own: the Transcripts mark — text lines over a
  waveform, matching the app icon — is the new default. It dims when
  auto-record is off, shows solid while watching, and while recording only its
  waveform pulses with the input level. The plain waveform and microphone
  styles remain in Settings, and the waveform style now dims when idle too.

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
