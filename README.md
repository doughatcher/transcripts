<h1 align="center">Transcripts</h1>

A pocket recorder for iPhone and iPad. It captures clean audio, transcribes it
live **on this device**, and keeps a browsable library. Nothing is uploaded,
ever — there is no server, no account, and no third-party code.

- **Record anywhere.** Capture survives the screen locking and app switching;
  a Live Activity on the Lock Screen / Dynamic Island shows recording is alive.
- **Read it as you speak.** On-device speech recognition streams a live
  transcript while you record.
- **Your files, your folder.** Recordings land in a folder you pick — iCloud
  Drive, OneDrive, Dropbox, or on-device. Each recording is plain `m4a` audio
  plus a JSON sidecar; there is no proprietary library format to escape from.
- **Mac handoff, optional.** Point a Mac at the same folder and heavier
  processing (speaker attribution, summaries) can happen there. The phone app
  is complete without it.

### Handing off to a Mac

Each recording is written to `<folder>/Inbox/` as `<uuid>.m4a` plus a
`<uuid>.json` sidecar. Audio is written first and the sidecar last, so a
watcher can treat "sidecar present" as "capture complete" — which matters on
cloud folders that materialize files progressively.

"Set up for me" creates a `Transcripts/` folder inside the parent you pick. If
you're pairing with a Mac watcher that already expects a differently-named
folder, use **Choose a folder** instead and point at that folder directly —
the sidecar format is what the two sides agree on, not the folder name.

## Build

Requires Xcode 26 (iOS 26 SDK for on-device summarization; the app itself runs
on iOS 17+).

```bash
brew install xcodegen just
just build       # generate the project and build for the simulator
just open        # open in Xcode for device runs
```

The `Transcripts.xcodeproj` is generated — `project.yml` is the source of
truth.

## Privacy

Audio, transcripts, and settings never leave the device. The privacy manifest
(`Sources/Transcripts/PrivacyInfo.xcprivacy`) declares no data collection, no
tracking, and no tracking domains, because there are none.

Recording consent is your responsibility — only record where legally permitted.

## License

[MIT](LICENSE) © 2026 Doug Hatcher
