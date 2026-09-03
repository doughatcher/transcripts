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

Download the zip from [transcripts.doughatcher.com](https://transcripts.doughatcher.com),
unzip it, and drag **Transcripts.app** to your Applications folder.

The app checks for updates on launch and can install them itself.

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

If IT is willing to pre-approve it fleet-wide, what they need for a PPPC
profile: bundle `ltd.hatcher.transcripts`, team `6Q9BX97LMS`, services
**Microphone** and **Screen Recording**. Then the prompts never appear.

To check a machine without guessing, run the built-in self-test:

```
TRANSCRIPTS_SELFCHECK=1 ~/Applications/Transcripts.app/Contents/MacOS/Transcripts
```

It records a second from the microphone and from the system, and exits **0**
when both work, **1** if the microphone flow is broken, **2** if the microphone
is authorized but delivering silence, and **3** if the microphone is fine and
only system audio is unavailable — the expected answer when Screen Recording is
locked.

Use 1.1.0-beta.3 or later. Earlier notarized builds could not reach the
microphone at all.

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
