<h1 align="center">Transcripts</h1>

<p align="center">
  Voice notes and meeting transcripts, recorded and transcribed on your own
  device.<br>
  <a href="https://transcripts.hatcher.ltd">transcripts.hatcher.ltd</a> ·
  <a href="https://transcripts.hatcher.ltd/guide/">User guide</a> ·
  <a href="https://github.com/hatcher-ltd/transcripts-support/issues">Issues</a>
</p>

---

Two apps sharing a core.

**macOS** — a menu-bar recorder. Notices when a call starts, captures your
microphone *and* the other participants as separate tracks, transcribes and
summarizes on-device, tells the speakers apart, and files the result into your
vault. Writes a **live transcript** to a plain file while the call is still
running, so an AI assistant can be pointed at a meeting during it.

**iPhone and iPad** — a pocket recorder, complete on its own. Records with the
screen locked, transcribes live on the device, and hands finished takes to the
Mac through a folder they share. With iCloud on both, there is nothing to
configure.

Nothing is uploaded. The iOS app contains no networking code at all; the Mac
app's only outbound request is its update check.

## Layout

```
Sources/
  TranscriptsCore/     shared, zero external dependencies — pipeline, config,
                       routing, models, audio maths, speaker profiles
  TranscriptsEngine/   macOS only — FluidAudio (diarization), MLX (local LLM)
  TranscriptsMac/      the menu-bar app
  Transcripts/         the iOS app
  TranscriptsWidgets/  iOS Live Activity
docs/guide/            the user guide, rendered to the site
site/                  marketing page + guide generator
```

`TranscriptsEngine` is macOS-only on purpose: MLX alone would drag a ~1.8 GB
model download onto a phone, and its licence along with it. The iOS target
compiles `TranscriptsCore`'s sources directly rather than linking the package,
which is what keeps the shipping iOS binary free of third-party code.

## Building

Requires Xcode 26+ (Xcode 27 for iOS 27 devices) and the Metal toolchain —
without it, mlx-swift silently ships no shaders and the summarizer takes the
process down at first use:

```bash
xcodebuild -downloadComponent MetalToolchain
brew install xcodegen just
```

```bash
just project                    # regenerate Transcripts.xcodeproj from project.yml
scripts/make-signing-cert.sh    # one-time: stable identity so TCC grants persist
scripts/make-app.sh             # build the Mac app, install to ~/Applications, launch
swift test                      # 164 tests, TranscriptsCore
python3 site/build.py --serve   # the site, on :8000
```

The `.xcodeproj` is generated — `project.yml` is the source of truth.

## Releasing

```bash
scripts/release.sh 1.0.0-beta.1
```

Builds, signs with Developer ID, notarizes, staples, zips, checksums, and writes
both `appcast.json` and the Homebrew cask from the same artifact — so the in-app
updater and `brew` can never disagree about what version exists. Refuses to run
without a Developer ID certificate unless `NOTARIZE=0` is explicit.

Then `npx wrangler pages deploy site/public --project-name=transcripts`, and copy
`dist/transcripts.rb` into
[hatcher-ltd/homebrew-tap](https://github.com/hatcher-ltd/homebrew-tap).

## Privacy

Full policy: [docs/guide/privacy.md](docs/guide/privacy.md).

Recording consent is your responsibility — laws vary by country and state, and
some require every participant's consent. Only record where you lawfully may.

## License

Copyright © 2026 Doug Hatcher. All rights reserved. This source is private and
not licensed for redistribution — see [LICENSE](LICENSE). Third-party components
and their terms are listed in [NOTICE](NOTICE).
