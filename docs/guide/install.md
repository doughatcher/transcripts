# Installing

## Homebrew

```
brew install --cask hatcher-ltd/tap/transcripts
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

- **Download from this site**, not from GitHub. Corporate proxies routinely
  block GitHub release downloads; `transcripts.doughatcher.com` is a plain
  Cloudflare host and gets through.
- **Put it in `~/Applications`**, not `/Applications`. Make the folder if it is
  not there. macOS treats it exactly like the system one — Spotlight, Launchpad
  and login items all see it. (Homebrew can do the same; see below.)
- **Open it.** Gatekeeper checks the notarization ticket and lets it run. No
  right-click-Open, no admin password.
- **Grant the microphone** when macOS asks. That is a normal per-user consent
  and is never locked by MDM.
- **Screen Recording is optional.** It is how macOS captures the other side of a
  call, and on a managed Mac that switch in Privacy & Security may be locked.
  Without it Transcripts records your microphone only — which on a laptop in a
  meeting room still catches everyone — and says so in the menu.

With Homebrew, the same thing in one line:

```
brew install --cask hatcher-ltd/tap/transcripts --appdir=~/Applications
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
