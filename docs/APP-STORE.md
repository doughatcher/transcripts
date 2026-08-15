# App Store submission kit

Everything needed to fill in App Store Connect, with the reasoning behind each
answer so you can defend it if review pushes back. Verified against the code on
15 August 2026.

---

## 1. App Privacy questionnaire ("nutrition label")

This is separate from `PrivacyInfo.xcprivacy` and it is the one people get
wrong. Apple asks per data type: *do you collect this?* "Collect" means
transmitting off the device — data that stays on device is **not** collected.

**Answer: "Data Not Collected" for every category.**

Justification if asked, and it is verifiable in the source:

- The iOS app contains **no networking code**. No `URLSession`, no
  `URLRequest`, no `Network.framework`, no sockets, no third-party SDKs (zero
  dependencies). Verifiable by inspection of the binary — the symbols are
  simply absent.
- Recordings and transcripts are written to local files and to a folder the
  user explicitly grants access to via `UIDocumentPicker`. Files a user places
  in their own iCloud/OneDrive/Dropbox folder are synced by that provider under
  the user's own account — that is the user's file movement, not collection by
  this app.
- Speech recognition sets `requiresOnDeviceRecognition = true` and hard-refuses
  to run on devices lacking on-device support, rather than degrading to
  server-side recognition.

⚠️ Do **not** tick "Audio Data" merely because the app records audio. The
question is about collection, not about the app's subject matter.

---

## 2. Notes for Review

Paste into App Store Connect ▸ App Review Information ▸ Notes.

> Transcripts is an offline voice recorder with live on-device transcription.
>
> **No account is required** and there is nothing to sign in to. To test:
> launch the app, choose any folder when prompted (On My iPad/iPhone is fine),
> tap New Recording, grant microphone and speech-recognition permission, and
> speak. Text appears live as you talk. Stop the recording and it appears in
> the library with its transcript.
>
> **Privacy.** The app contains no networking code whatsoever — no analytics,
> no accounts, no servers, no third-party SDKs. Live transcription uses Apple's
> on-device speech recognition with `requiresOnDeviceRecognition = true`; on a
> device without on-device support the app disables live text and says so
> rather than sending audio to a server. Summaries, where available, use
> Apple's on-device foundation model.
>
> **Background audio.** The app declares the `audio` background mode because a
> pocket recorder must keep capturing when the screen locks or the user
> switches apps. Without it iOS suspends the app mid-recording, which
> terminates the audio session and leaves the recording file unfinalized. A
> Live Activity shows the user that capture is still running.
>
> **Recording consent.** The app is a recorder; the user decides what to
> record. Guidance about consent laws is provided in the App Store description
> and in our privacy policy.

---

## 3. Store listing copy

**Name (30 char max):** `Transcripts`

**Subtitle (30 char max):** `Live meeting transcripts`
*(24 chars. Alternates: `Transcripts, as you speak` (25), `Live notes for every call` (25).)*

**Promotional text (170 char max, editable without a new build):**

> Live transcripts of every meeting, on all your devices. Records, transcribes
> and summarizes on-device — no account, no cloud, nothing to set up.

**Description:**

> Transcripts writes down what you say, as you say it, on your own device.
>
> **Read it while you record**
> Words appear on screen as you speak, using on-device speech recognition. No
> waiting for a file to upload and come back as text — and on the Mac, the live
> transcript is a plain file you can point an AI assistant at during the call.
>
> **It keeps recording**
> Lock the screen, switch apps, take a call — capture continues, and a Live
> Activity on the Lock Screen and Dynamic Island shows it is still running.
>
> **Your files, your folder**
> Recordings are saved as ordinary .m4a audio with a plain-text transcript
> beside each one. Choose where they go: iCloud Drive, OneDrive, Dropbox, or
> just on your device. There is no proprietary library to escape from and
> nothing to export — the files are already yours.
>
> **Genuinely private**
> No servers, no accounts, no analytics, no advertising. Transcripts sends your
> audio nowhere: it requires on-device speech recognition and switches live text
> off rather than fall back to a server. Your recordings go only where you put
> them.
>
> ---
> Recording laws vary by location, and some places require the consent of
> everyone in a conversation. Please make sure you may lawfully record before
> you do.

**Keywords (100 char max, comma-separated, no spaces after commas):**

`voice recorder,transcription,speech to text,meeting,notes,offline,private,dictation,memo,interview`
*(98 chars. Do not repeat words already in the name or subtitle — Apple indexes
those separately.)*

**Support URL:** `https://transcripts.hatcher.ltd`
**Privacy Policy URL:** `https://transcripts.hatcher.ltd/privacy` (source: `docs/PRIVACY.md`)

---

## 4. Age rating

Expect **4+**. The questionnaire asks about violence, sexual content, gambling,
horror, drugs, and — newer — social media features and user-generated content
sharing. Answer "None" throughout: the app has no social features, no user
content sharing, no web view, and no ad network.

---

## 5. Pre-submission checklist

- [ ] Individual Apple Developer enrollment active; **verify the team selector
      in App Store Connect is your own team, not Blue Acorn, LLC**, before
      creating the app record. An app created under another team belongs to
      that team, and moving it later needs a formal Apple app transfer.
- [ ] App name "Transcripts" reserved
- [ ] Bundle id `ltd.hatcher.transcripts` registered under **your** team
- [ ] Xcode signing Team set to your team (not BA)
- [ ] Privacy policy live at a public URL
- [ ] EU trader status declared (see below)
- [ ] App icon finalized (transcript lines with a live waveform — replace if a
      designer pass is wanted, but it is submission-ready as is)
- [ ] Screenshots: 6.9" iPhone and 13" iPad, required sizes
- [ ] `ITSAppUsesNonExemptEncryption=false` — already set in `project.yml`
- [ ] Privacy manifests present for app and widget — already done
- [ ] TestFlight build installed and exercised on a real device

### EU trader status

Under the Digital Services Act, developers distributing in the EU must declare
trader status. **If you declare as a trader, Apple publicly displays your name,
address, phone and email on the App Store listing** — for an individual
enrollment that means a home address published on a public page.

- Free, non-monetized app → non-trader status is generally available.
- Any monetization → trader, and the contact details are published.

If Transcripts will ever charge, stand up Hatcher Ltd as a real entity and use a
business address before listing, rather than transferring afterward.
