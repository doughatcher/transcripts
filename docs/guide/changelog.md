# Changelog

## 1.0.6

- Settings stops lagging when you click between its tabs. Every render was
  enumerating audio devices, resolving the chosen input again for each row, and
  asking the system about the login item — and because the tab bar rebuilds all
  five tabs, one click paid for all of it. The device enumeration also wrote the
  config file to disk mid-render, which invalidated the pane it was drawing.

## 1.0.5

- The iPhone and iPad icon is the violet tile the Mac already wore. The white
  one had no edge against the App Store's white page or a light home screen.
- Sessions can be made in Settings ▸ Sorting ▸ Sessions instead of only by
  hand-editing `routing.json` — name, folder, when it ends, and what runs when
  it does. Starting one from Shortcuts always worked; the picker was just empty
  unless you had edited the file.
- A title containing `#` or `_` survives being read. "C# to F# Migration" was
  being filed as "C to F Migration" — in the transcript, its filename and the
  Recordings list — because unwrapping the model's markdown reached inside the
  title instead of stopping at its ends.
- A transcript mirrored into an Obsidian vault no longer offers to play audio
  that was deliberately left behind in the knowledge root.
- A transcript that reads but has no body says so, instead of showing an empty
  page.

## 1.0.3

- The menu-bar mark is one line of text over a waveform, not three stacked
  rows. The fuller mark was a picture of a document, and at 16 points a picture
  of a document is a smudge — beside wifi and battery it was visibly busier
  than every neighbour. It sits lower too: a solid line over a mostly-empty
  waveform puts the optical centre above the geometric one, which read as the
  icon floating above its neighbours.
- A shared recording could play back truncated. Its audio was copied straight
  to its final name in the cache, so a copy interrupted partway left a short
  file that every later play accepted as complete.
- A transcript that hadn't finished syncing could appear in the library as a
  bare filename with no date and no audio, and never ask to be downloaded.

## 1.0.2

- Recordings are named after what was said in them again. The summarizer is
  asked for a title and reliably gives one, but wrapped in whatever markdown it
  favours — and a decorated `**TITLE: …**` was not being read, so a recording
  kept the name of the window it was captured from. The two apps then disagreed
  about what to fall back to: the same call was “with Candidate” on the Mac and
  “Microsoft Teams — Aug 24” on the iPad, when it was an interview with a name.
  `scripts/repair-titles.py` puts the recovered titles into recordings made
  before the fix.
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
