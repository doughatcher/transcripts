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

Download the zip from [transcripts.hatcher.ltd](https://transcripts.hatcher.ltd),
unzip it, and drag **Transcripts.app** to your Applications folder.

The app checks for updates on launch and can install them itself.

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
