# Installing

## Homebrew

```
brew install --cask doughatcher/tap/transcripts
```

That taps the repository and installs Transcripts into `/Applications`. To
update later:

```
brew upgrade --cask transcripts
```

If you installed with Homebrew, prefer `brew upgrade` over the app's own
updater. Both fetch the same build, but only Homebrew keeps its records
straight, and an app that updates itself underneath Homebrew leaves the two
disagreeing about what is installed.

To remove it completely, including recordings metadata and logs:

```
brew uninstall --zap --cask transcripts
```

`--zap` also deletes `~/Library/Application Support/Transcripts`. Your
recordings themselves live in the folder you chose and are never touched.

## Direct download

Download Transcripts from [transcripts.doughatcher.com](https://transcripts.doughatcher.com),
open the disk image, and drag **Transcripts** to **Applications**. The disk
image is signed and notarized by Apple, the same as the app inside it. Each
release is also on GitHub as a zip, for scripts and for anyone who prefers
one.

The app checks for updates on launch and can install them itself.

## Mac App Store or download

There will be two ways to get the Mac app. The download above, and Homebrew, is
the full app. A Mac App Store edition is on its way for people who would rather
install from the store. It is the same app, with the same transcription, live
transcript, overlay, speaker names, summaries and the other side of calls. But
the store only accepts apps that stay inside Apple's sandbox, and a few things
cannot:

- **It cannot run your own scripts.** Custom-script sorting, the Handoff
  pipeline, script stages, and a session's "When it ends, run" command are not
  in it. **Open with** takes a link such as `obsidian://open?path={path_encoded}`,
  not a shell command. If you use any of these, use the download.
- **It cannot start a Homebrew-installed Ollama for you.** It opens Ollama.app if
  you have it; with only the command-line install, start `ollama serve`
  yourself.
- **It asks for folders instead of reading paths.** On first launch it offers
  to keep recordings in iCloud Drive and opens on it: click **Choose**. Picking
  iCloud Drive or the **Transcripts** folder inside it comes to the same thing,
  because Transcripts uses that folder either way and creates it if needed. It's
  the folder your iPhone and iPad use, and it becomes both your library and
  where phone recordings arrive, so everything syncs as it does with the
  download. Choose **Keep on This Mac Only** and recordings stay in the
  app's own storage until you pick a folder in Settings. It does not find your
  Obsidian vault by itself either: choose it in Settings ▸ Sorting ▸ Obsidian.
- **It asks before recording a call.** A new install starts in ask-first mode:
  when a call begins, Transcripts shows a notification and records only if you
  say so. Switch it to record automatically in Settings ▸ General.
- **The App Store updates it.** It has no updater of its own, no beta channel,
  and does not offer to move itself into Applications.

Settings do not carry over between the two, because the store edition keeps its
own. Your recordings do: they are in the folder you chose, so pointing the store
edition at that folder brings the whole library back. Speaker names you taught
the download stay with the download. Run one edition or the other, not both at
once, or both will try to record the same call.

## Managed Macs

A work Mac under MDM — Jamf, Intune, Kandji — usually has no admin rights, a
read-only `/Applications`, and a proxy in front of GitHub. Transcripts installs
anyway, because it is signed and notarized by Apple and asks for nothing an
ordinary user cannot grant. The steps differ only in where it goes.

- **Download from wherever your network allows.** This site is a plain
  Cloudflare host; [GitHub releases](https://github.com/doughatcher/transcripts/releases)
  carry the identical build if the proxy prefers that one. Take the newest
  pre-release there, not the release marked "Latest".
- **Just open it.** Transcripts offers to move itself into `~/Applications` —
  your own Applications folder, which needs no administrator — and reopens from
  there. macOS treats that folder exactly like the system one: Spotlight,
  Launchpad and login items all see it. (Homebrew installs to the same place;
  see below. To do it by hand, drag the app there yourself.)
- **Gatekeeper lets it run.** It checks the notarization ticket. No
  right-click-Open, no admin password.
- **Grant the microphone** when macOS asks. That is a normal per-user consent
  and is never locked by MDM.
- **The other side of a call needs one more permission,** and it is an ordinary
  Allow dialog: Transcripts reads the system audio mix directly, which macOS
  grants per-user like the microphone. Decline it and calls record your
  microphone only — which on a laptop in a meeting room still catches everyone —
  and the menu says so.
- **You do not need Screen Recording.** It was the old way of capturing call
  audio and it is the one switch a managed Mac tends to lock behind an admin
  password. If something offers it to you, you can decline.

With Homebrew, the same thing in one line:

```
brew install --cask doughatcher/tap/transcripts --appdir=~/Applications
```

### For IT

Everything a software catalog (Jamf Self Service, Intune Company Portal, Kandji
Self Service) usually asks for:

| | |
|---|---|
| Bundle ID | `ltd.hatcher.transcripts` |
| Team ID | `6Q9BX97LMS` (Hatcher LLC), signed with Developer ID and notarized |
| Download | the disk image on this site, the same build as a disk image or zip on [GitHub releases](https://github.com/doughatcher/transcripts/releases), or `brew install --cask doughatcher/tap/transcripts` |
| Checksum | `sha256` in [appcast.json](https://transcripts.doughatcher.com/appcast.json), which the app's own updater also verifies |
| Installs to | `~/Applications` by default. No administrator, no helper tools, no kernel or system extensions |
| Requires | macOS 14 or later, Apple Silicon or Intel |
| Source | [MIT licensed](https://github.com/doughatcher/transcripts); every release is tagged |

**There is nothing to pre-approve.** Transcripts asks for two things, both
ordinary per-user prompts: the **microphone**, and **system audio recording**
(the other side of a call). macOS does not let MDM grant either one in advance.
A privacy (PPPC) profile can only *deny* the microphone. So no profile makes the
prompts go away, and none is needed for them to work. **Screen Recording is not
used** and needs no policy. Speech recognition runs on the device and is not a
separate permission.

**Network.** The Mac app makes three kinds of outgoing request, none carrying a
recording or a transcript:

- an update check to `transcripts.doughatcher.com`;
- a one-time download of the speaker-recognition models from `huggingface.co`;
- a one-time download of the summary model from `huggingface.co`, only on Macs
  without Apple Intelligence.

If a user points it at their own Ollama server, that traffic stays on
`localhost`. Nothing listens for incoming connections, and there are no
analytics or telemetry.

**Data.** Recordings and transcripts go to the folder the user chooses, often
iCloud Drive or OneDrive, so your policy on those services applies to them.
Settings and history live in `~/Library/Application Support/Transcripts` and the
log in `~/Library/Logs/Transcripts.log`. `brew uninstall --zap` removes both.

**Recording consent** is the user's responsibility and is stated at install and
in Settings. Users in all-party-consent places can set Transcripts to ask before
it records a call.

To check a machine without guessing, run the built-in self-test:

```
TRANSCRIPTS_SELFCHECK=1 ~/Applications/Transcripts.app/Contents/MacOS/Transcripts
```

It records two seconds from the microphone and from the system together, and exits **0**
when both work, **1** if the microphone flow is broken, **2** if the microphone
is authorized but delivering silence, and **3** if the microphone is fine and
only system audio is unavailable — the expected answer when Screen Recording is
locked.

Use 1.1.0-beta.3 or later. Earlier notarized builds could not reach the
microphone at all. Up to 1.1.0-beta.10 the self-test checked the two sources one
after the other, and on its own the system-audio check got nothing, so those
builds could answer **3** on a Mac where calls recorded both sides perfectly.
Trust a recording over that answer on those builds.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel
- Apple Intelligence, optionally — summaries use it when present and fall back
  to a built-in summarizer when it isn't

## iPhone and iPad

The mobile app comes from the App Store. It records and transcribes on its own,
and shares a folder with the Mac if you have one — see
[iPhone, iPad and Mac](/guide/handoff/).

---

Next: [Getting started](/guide/)
