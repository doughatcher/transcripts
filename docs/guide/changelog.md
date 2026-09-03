# Changelog

## 1.1.0-beta.8

**Mac**

- Transcripts installs itself. Open it from wherever it landed — Downloads,
  the Desktop, a folder someone sent you — and it offers to move into
  `~/Applications`, your own Applications folder, and reopen from there. No
  administrator, and nothing to know about where Mac apps are supposed to
  live. That was three pieces of Mac lore standing between a colleague and a
  working app, and it is the step people actually got stuck on. Say no and it
  will not ask again.
- The site links to the source, and says what a managed Mac actually needs.
  The advice to avoid GitHub is gone — corporate proxies were the reason, and
  the release downloads get through now, so both routes are offered. The
  Screen Recording advice is gone too: since beta.7 it is not used, and it was
  the one permission a managed Mac tends to lock behind an admin password.

## 1.1.0-beta.7

**Mac**

- The other side of a call no longer needs Screen Recording. Transcripts reads
  the system mix through a Core Audio tap now, and macOS grants that with an
  ordinary Allow dialog — no administrator, no trip through System Settings.
  That pane was the wall on managed laptops: Screen Recording has no inline
  prompt, so approving it needs an admin password many people cannot supply. A
  Mac that already granted Screen Recording keeps using it, so a setup that
  works today is left alone. The permission remains optional either way —
  decline it and recordings are microphone-only, which on a call means your
  side of it.
- Being muted no longer looks like a broken microphone. Muting in Teams, Slack
  or Control Center silences every input on the machine at once, and that was
  being read as a dead device: Transcripts would switch microphones under you
  — in one case as far as an iPhone — chasing signal that no device on the Mac
  was being given, and fragmenting the recording each time it tried. It now
  recognises the difference and says so instead. Your own side resumes the
  moment you unmute.
- macOS's internal audio aggregates are out of the microphone list.
  `CADefaultDeviceAggregate` appears whenever a call app turns on echo
  cancellation, and it was being offered as something to record from, named
  after an implementation detail. Aggregates you made yourself are still
  listed.

## 1.1.0-beta.4

**Mac**

- Voices in a room are named while the recording is still going. With **the
  microphone records a room** on, each turn in the live transcript gets a
  speaker — Speaker 1, Speaker 2, or a remembered name — instead of everything
  being "Me" until the finished document arrived. It is a live guess and not
  the record: a short interjection may take the label of whoever was already
  talking, two similar voices may come out as more speakers than there are,
  and nothing is revised once written. The finished document is unchanged and
  remains the version to trust. On a call nothing changes at all — the other
  side still arrives on its own track, which is better evidence than any
  clustering.
- A long stretch from one speaker breaks into paragraphs instead of growing
  into a single block. Each paragraph carries the time it began, so clicking a
  timestamp lands on the words you are reading rather than at the top of a
  ten-minute run.
- The transport icon is drawn at the size of its neighbours. It was about
  two-thirds the size of the other menu-bar icons, which read as "small"
  without being something you could name.

## 1.1.0-beta.3

**Mac**

- The microphone works in the downloaded build. beta.2's notarized signature
  did not carry the audio-input entitlement, and under the hardened runtime
  that refuses the microphone outright — no permission prompt, no error, no
  audio. Builds made on the developer's own machine never showed it, which is
  how it shipped. If beta.2 recorded nothing for you, this is why.
- Releases are now built, signed and notarized on GitHub rather than on a
  laptop. Nothing visible changes; it is what stops the fault above from going
  out the same way twice.

## 1.1.0-beta.2

**Mac**

- Restarting Transcripts while it is recording no longer ends the recording. It
  picks the same one back up: the piece already captured is set aside, capture
  resumes within a second or two, and stopping reassembles every piece into one
  recording on a single timeline. Quit it, crash it, or rebuild it mid-session —
  the evening still comes out as one take. Only the gap has to be short (about
  ten minutes); a marker left by a crash days ago is filed, not resumed.
- The menu says "Resumed after relaunch" while that is in effect, so it is never
  something you have to take on faith.
- The menu-bar icon now follows tape-transport convention by default: a square
  when stopped, a hollow record light while auto-record is watching, and a
  filled disc while rolling that flashes from red towards white and swells as
  the room gets louder. Three shapes rather than one shape in three shades —
  which is the difference between reading the state and squinting at it — and a
  disc that brightens when somebody speaks, so a dead microphone looks different
  from a quiet room. The Transcripts mark, the waveform and the microphone are all
  still there in Settings, unchanged; an existing install keeps whichever it was
  already set to.
- Live text now appears as it is spoken rather than when the recogniser decides
  a phrase has ended. The overlay's pill shows the words mid-sentence, and the
  live transcript file grows a **Being said now** section at the bottom carrying
  the same not-yet-final text. The transcript itself is untouched by this: it
  still only ever contains finalised turns, because a record that revises itself
  is not a record.
- **Recordings of a room** are now split by voice. A microphone with five people
  in front of it used to come out labelled entirely as you, because the whole
  attribution path assumed a call — mic is you, system audio is everyone else.
  Turn on "My microphone records a room" in Settings and the microphone track is
  diarized instead, each voice getting a number or a remembered name. Detected
  calls are unaffected.
- Voices are matched against every sample remembered for a person rather than
  the average of them, and one person can now own several voices in a room
  recording. Both exist for the same reason: someone running a character at a
  table does not sound like themselves, and averaging the two produced a
  voiceprint matching neither.
- A new **overlay**: a small glass panel floating over your call. At rest it
  shows the last thing said, straight from the transcript with no summarizing in
  the way. Hover it and it opens into three lanes — the last conclusion, facts
  and figures, and the last question with its answer. The live transcript was
  already writing all of this down, but reading it meant looking away from the
  meeting, which is the one thing you cannot do during a meeting.
- Answers come only from earlier in the same call or from the Markdown notes
  under your transcripts folder, and every one says which, and when. The model
  phrases an answer out of text that was found first; it is never the source. A
  question nothing supports is shown unanswered rather than filled in, and an
  answer that does not hold up against the passage it came from is discarded
  before it reaches the screen — on a live call an invented answer is worse than
  an empty panel. The same rule governs the conclusion and the figures.
- Off by default. Settings ▸ General ▸ Overlay, with a separate switch for
  whether your notes are searched. Everything stays on your Mac.
- With no language model available the overlay quotes instead of phrasing: it
  shows the best-matching passage verbatim with its source, and leaves the
  conclusion and figures lanes empty rather than guessing at them.

## 1.1.0-beta.1

**iPhone and iPad**

- Transcripts filed by the Mac can be renamed, archived and deleted from the
  phone. Only recordings still waiting to be picked up could be, which left the
  finished article — most of the library, and all of what a phone is usually
  doing — with no way to fix a title the model got wrong. Swipe one way to
  rename, the other to archive; delete is behind a long press and asks first.
  Renaming changes the title inside the transcript, so every device sees it,
  and leaves the filename alone so nothing that links to the note breaks.
- Archiving moves a transcript and its audio into an `Archive` folder beside
  your transcripts, keeping the folder it was filed into. Nothing is deleted,
  every device sees the same archive, and unarchiving puts it back exactly
  where it was. Deleting moves both to the Trash, where Files can still
  recover them.

**Mac**

- The transcript reader can play the recording it was made from. It could show
  you what the model heard and give you no way to hear it, which is worst on
  the lines it got wrong — a garbled sentence is visibly wrong and
  unrecoverable without the tape.

**Both**

- Transcripts carry the time each speaker started, and clicking one jumps the
  audio there. The timings were always being computed and thrown away one line
  before the document was written. Turns now read `**Me:** [12:04] …`, in the
  finished document and in the live mid-call transcript an assistant reads
  during a meeting.
- Recordings made before this update have no timestamps and read exactly as
  they did. New ones get them; there is nothing to migrate, and nothing to
  turn on.

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
