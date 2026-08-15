import Foundation
import TranscriptsCore

/// Abstraction over a speech-to-text engine. The native implementation will be
/// `WhisperKitTranscriber` (added in a later phase once the WhisperKit SwiftPM
/// dependency is resolved — see Package.swift). Keeping a protocol means swapping
/// the engine, or pointing at a cloud STT, is a one-line change.
public protocol Transcriber: Sendable {
    /// Returns the plain-text transcript for an audio file.
    func transcribe(audioURL: URL, model: String) async throws -> String
    /// Returns the transcript as timestamped segments (seconds from track start).
    /// Engines with real timing override this; the default wraps the plain
    /// transcript in a single untimed segment.
    func transcribeSegments(audioURL: URL, model: String) async throws -> [TranscriptSegment]
}

public extension Transcriber {
    public func transcribeSegments(audioURL: URL, model: String) async throws -> [TranscriptSegment] {
        let text = try await transcribe(audioURL: audioURL, model: model)
        return [TranscriptSegment(start: 0, end: 0, text: text)]
    }
}

/// Splits the system-audio track into per-speaker time spans (diarization),
/// matching against enrolled voice profiles when available. `micAudio` lets
/// the implementation refresh the operator's own profile from the one track
/// whose speaker is known by construction.
public protocol Diarizer: Sendable {
    func diarize(systemAudio: URL, micAudio: URL?) async throws -> DiarizationOutcome
}

/// Placeholder transcriber used until WhisperKit is wired. It produces a clearly
/// marked stub so the rest of the pipeline (summarize → classify → persist) can be
/// exercised end to end without the model download.
public struct StubTranscriber: Transcriber {
    public func transcribe(audioURL: URL, model: String) async throws -> String {
        "[transcription pending — WhisperKit not yet wired. Audio at \(audioURL.lastPathComponent)]"
    }
}

/// Native Transcribe stage. Writes `transcript.md` with frontmatter that carries
/// the recording metadata forward (matches the on-disk contract in DESIGN §6).
public struct TranscribeStage: PipelineStage {
    public let id: StageID = .transcribe
    public let transcriber: Transcriber
    public let model: String
    /// Optional speaker diarization for the system-audio side of a call. When nil
    /// (or when it fails) the other participants are labeled as one voice.
    public let diarizer: (any Diarizer)?

    public init(transcriber: Transcriber, model: String, diarizer: (any Diarizer)? = nil) {
        self.transcriber = transcriber
        self.model = model
        self.diarizer = diarizer
    }

    /// Uses the on-device `SpeechTranscriber` engine on macOS 26+, falling back to
    /// the stub on older systems (where the pipeline still runs, just without real
    /// speech-to-text).
    public init(model: String, rememberVoices: Bool = false, matchThreshold: Float = 0.65) {
        if #available(macOS 26, iOS 26, *) {
            self.transcriber = SpeechTranscriberEngine()
        } else {
            self.transcriber = StubTranscriber()
        }
        self.model = model
        // No diarizer → the other side stays a single "Others" (the reliable
        // default). Diarization + name-matching only when the user opts in, since
        // naming voices is best-effort and will occasionally misattribute.
        self.diarizer = rememberVoices
            ? FluidAudioDiarizer(rememberVoices: true, matchThreshold: matchThreshold) : nil
    }

    public func run(_ context: inout PipelineContext) async throws {
        let audioURL = context.archivedAudioURL ?? context.recording.audioURL
        let rec = context.recording

        // Speaker attribution when both call sides were captured: the mic track is
        // you by construction; the system track is everyone else, optionally split
        // into distinct voices by diarization. Any failure falls back to the plain
        // mixed-track transcript — attribution must never cost a recording.
        var transcriptBlock: String?
        var speakers: [String] = []
        var speakerConfidence: [String: Float] = [:]
        var speakerAffiliations: [String: String] = [:]
        if let micURL = rec.micAudioURL, let sysURL = rec.systemAudioURL {
            if let attributed = await attributedTranscript(
                micURL: micURL, sysURL: sysURL, offset: rec.systemAudioStartOffset ?? 0) {
                transcriptBlock = attributed.markdown
                speakers = attributed.speakers
                speakerConfidence = attributed.confidence
                speakerAffiliations = attributed.affiliations
                // Stash anonymous-cluster embeddings so a later name confirm can
                // enroll the voice without re-processing audio (#6 Tier B).
                if !attributed.embeddings.isEmpty,
                   let data = try? JSONEncoder().encode(attributed.embeddings) {
                    let embURL = context.scratchDir.appendingPathComponent("speaker-embeddings.json")
                    try? data.write(to: embURL, options: .atomic)
                    context.userInfo["speakerEmbeddings"] = embURL.path
                }
                // Cut a few seconds of each cluster's voice while the system track
                // is still on disk, so the naming grid can play "who is this?" back
                // (#6). Best-effort — a missing clip just means no play button.
                let clips = await cutSpeakerClips(attributed.sampleWindows, from: sysURL,
                                                  into: context.scratchDir)
                if !clips.isEmpty, let data = try? JSONEncoder().encode(clips) {
                    let clipsURL = context.scratchDir.appendingPathComponent("speaker-clips.json")
                    try? data.write(to: clipsURL, options: .atomic)
                    context.userInfo["speakerClips"] = clipsURL.path
                }
                // Match confidence per named speaker (cosine 0…1), for the
                // frontmatter and downstream trust decisions.
                if !attributed.confidence.isEmpty,
                   let data = try? JSONEncoder().encode(attributed.confidence) {
                    context.userInfo["speakerConfidence"] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        if transcriptBlock == nil {
            let text = try await transcriber.transcribe(audioURL: audioURL, model: model)
            transcriptBlock = Self.formatTranscript(text)
        }
        // One unique, timestamped base name shared by the transcript (.md) and the
        // archived audio (.m4a), so successive recordings never overwrite each other.
        let slug = rec.slug
        context.userInfo["slug"] = slug
        let audioFileName = "\(slug).m4a"

        let iso = ISO8601DateFormatter()
        var fm: [String] = []
        fm.append("title: \"\(rec.title ?? Self.fallbackTitle(for: rec))\"")
        // The calendar meeting name (from the captured Teams window title), kept
        // distinct from the summary-derived `title` so a maintenance skill can
        // match this recording to its Outlook invite by name + time.
        if let meeting = MeetingName.pick(from: rec.windowTitles) {
            fm.append("meeting: \"\(meeting.replacingOccurrences(of: "\"", with: "'"))\"")
            context.userInfo["meetingName"] = meeting
        }
        fm.append("recorded_at: \(iso.string(from: rec.startedAt))")
        if let ended = rec.endedAt { fm.append("ended_at: \(iso.string(from: ended))") }
        if let dur = rec.durationSeconds { fm.append("duration_seconds: \(Int(dur.rounded()))") }
        if let app = rec.activeApp?.appName { fm.append("active_app: \"\(app)\"") }
        if let bid = rec.activeApp?.bundleID { fm.append("active_app_bundle_id: \"\(bid)\"") }
        fm.append("source: scribe")
        fm.append("audio_file: \(audioFileName)")
        if !speakers.isEmpty {
            fm.append("speakers: [\(speakers.map { "\"\($0)\"" }.joined(separator: ", "))]")
        }
        // Per-speaker match certainty (cosine 0…1) for the voices named by matching
        // an enrolled voice — so a downstream reader can weight a name. Me, Others,
        // Speaker N, and transcript-evidence names have no acoustic score and are
        // omitted (their absence means "not acoustically matched").
        let scored = speakers.filter { speakerConfidence[$0] != nil }
        if !scored.isEmpty {
            fm.append("speaker_confidence:")
            for name in scored {
                let c = speakerConfidence[name] ?? 0
                fm.append("  \"\(name)\": \(String(format: "%.2f", c))  # \(SpeakerMatch.band(c, threshold: 0.65))")
            }
        }
        // Who was in the room, from the matched speakers' affiliations — the orgs
        // present, plus each named speaker's org/group, for downstream queries.
        let affiliated = speakers.filter { speakerAffiliations[$0] != nil }
        if !affiliated.isEmpty {
            let orgs = Affiliation.orgs(in: affiliated.compactMap { speakerAffiliations[$0] })
            fm.append("orgs: [\(orgs.map { "\"\($0)\"" }.joined(separator: ", "))]")
            fm.append("speaker_affiliations:")
            for name in affiliated {
                fm.append("  \"\(name)\": \"\(speakerAffiliations[name] ?? "")\"")
            }
        }

        let doc = "---\n\(fm.joined(separator: "\n"))\n---\n\n## Transcript\n\n\(transcriptBlock ?? "")\n"
        let url = context.scratchDir.appendingPathComponent("\(slug).md")
        try doc.write(to: url, atomically: true, encoding: .utf8)
        context.transcriptURL = url
    }

    /// Transcribes both call sides with timestamps, diarizes the system side into
    /// distinct voices when possible, and interleaves everything into speaker
    /// turns on the mic track's timeline. Returns nil when there's nothing usable
    /// (caller falls back to the mixed transcript).
    /// Cuts one short m4a per speaker label from the diarized system track, at the
    /// windows `SpeakerTurns.sampleWindows` picked. Returns label → clip path for
    /// the labels that produced a usable clip.
    private func cutSpeakerClips(_ windows: [String: (start: Double, seconds: Double)],
                                 from sysURL: URL, into dir: URL) async -> [String: String] {
        var clips: [String: String] = [:]
        for (label, window) in windows {
            let safe = label.replacingOccurrences(of: " ", with: "-")
            let out = dir.appendingPathComponent("clip-\(safe).m4a")
            if let url = await AudioMixer.clip(sysURL, from: window.start, seconds: window.seconds,
                                               into: out, log: { Log.write($0) }) {
                clips[label] = url.path
            }
        }
        return clips
    }

    private func attributedTranscript(
        micURL: URL, sysURL: URL, offset: Double
    ) async -> (markdown: String, speakers: [String], embeddings: [String: [Float]],
                sampleWindows: [String: (start: Double, seconds: Double)],
                confidence: [String: Float], affiliations: [String: String])? {
        do {
            let noSpeech = "[no speech detected]"
            let mine = try await transcriber.transcribeSegments(audioURL: micURL, model: model)
                .filter { $0.text != noSpeech }
            let theirs = try await transcriber.transcribeSegments(audioURL: sysURL, model: model)
                .filter { $0.text != noSpeech }

            var spans: [SpeakerSpan] = []
            var embeddings: [String: [Float]] = [:]
            var confidence: [String: Float] = [:]
            var affiliations: [String: String] = [:]
            if let diarizer, !theirs.isEmpty {
                do {
                    let outcome = try await diarizer.diarize(systemAudio: sysURL, micAudio: micURL)
                    // Named voices (from our matcher) pass through; anonymous
                    // clusters become "Speaker N". Re-key embeddings/confidence to
                    // the display labels so downstream speaks the same language.
                    let map = SpeakerTurns.labelMap(outcome.spans)
                    spans = SpeakerTurns.renumber(outcome.spans)
                    for (id, emb) in outcome.embeddings { embeddings[map[id] ?? id] = emb }
                    for (id, c) in outcome.confidence { confidence[map[id] ?? id] = c }
                    for (id, a) in outcome.affiliations { affiliations[map[id] ?? id] = a }
                } catch {
                    Log.write("transcribe: diarization unavailable (\(error)) — labeling the other side as one voice")
                }
            }

            let labeled = mine.map { AttributedSegment(speaker: "Me", start: $0.start, text: $0.text) }
                + SpeakerTurns.assign(theirs, spans: spans, fallback: "Others")
                    .map { AttributedSegment(speaker: $0.speaker, start: $0.start + offset, text: $0.text) }
            let turns = SpeakerTurns.turns(labeled)
            guard !turns.isEmpty else { return nil }
            Log.write("transcribe: attributed \(turns.count) turn(s) across \(SpeakerTurns.speakers(turns).count) speaker(s)")
            // Sample windows are on the system track's own timeline (no offset) —
            // the same track we clip from — and keyed by the display labels.
            let windows = SpeakerTurns.sampleWindows(spans)
            return (SpeakerTurns.markdown(turns), SpeakerTurns.speakers(turns), embeddings, windows, confidence, affiliations)
        } catch {
            Log.write("transcribe: attribution failed (\(error)) — using the mixed transcript")
            return nil
        }
    }

    /// Breaks a single run-on transcript into readable paragraphs so the stored `.md`
    /// is legible. Shared with the viewer via `TranscriptFormatter`.
    public static func formatTranscript(_ text: String) -> String {
        TranscriptFormatter.format(text)
    }

    /// A readable stand-in title until the Summarize stage derives a better one
    /// from the content — e.g. "Xcode — Jul 1, 3:08 PM".
    private static func fallbackTitle(for rec: Recording) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let when = df.string(from: rec.startedAt)
        if let app = rec.activeApp?.appName, !app.isEmpty {
            return "\(app) — \(when)"
        }
        return "Recording — \(when)"
    }
}
