import Foundation
import TranscriptsCore

/// The live, during-the-call transcript file — the thing that lets the user run
/// a Claude session against a meeting *while it's happening* ("read the live
/// transcript and draft the follow-up"). Speaker-labeled turns are appended as
/// the analyzers finalize them.
///
/// Written to three stable, well-known places on every update:
/// - `~/Library/Application Support/Transcripts/live.md` (durable Transcripts-side copy)
/// - `<knowledgeRoot>/.transcripts/live.md` (where vault-based agent sessions look)
/// - `<knowledgeRoot>/Transcripts Live.md` (the human view — Obsidian refuses to
///   open anything under a dot-folder, so the viewable copy must be visible;
///   both vault copies are gitignored)
///
/// The whole file is rewritten atomically per turn (a call transcript is tens of
/// KB — trivial) so turns from the two tracks land in timeline order no matter
/// what order the engines finalize them in. Content persists after the call ends
/// (marked "call ended") and is replaced when the next recording begins.
@MainActor
public final class LiveTranscript {
    /// `AttributedSegment` rather than a private twin of it: it is already
    /// (speaker, start, text), and it is what `SpeakerTurns` coalesces.
    private var turns: [AttributedSegment] = []
    private var header = ""
    private var footer = ""
    private let paths: [URL]
    /// The phrase each track is part-way through saying, keyed by speaker.
    ///
    /// Kept out of `turns` on purpose: this text is a running guess that gets
    /// replaced wholesale, and the transcript is a record. It is rendered below
    /// the transcript, clearly marked, so a reader — or an assistant asked what
    /// is being said *right now* — sees the live edge without the record ever
    /// containing anything that was later retracted.
    private var partials: [String: String] = [:]
    /// Volatile results arrive many times a second. The file is rewritten whole
    /// on every flush, so they are coalesced rather than written through.
    private var partialFlushAt = Date.distantPast
    private static let partialInterval: TimeInterval = 0.7

    /// `vaultRoot` nil (or unwritable) degrades to the App Support copy only.
    public init(vaultRoot: URL?) {
        var targets = [HistoryStore.dir.appendingPathComponent("live.md")]
        if let vaultRoot {
            let dir = vaultRoot.appendingPathComponent(".transcripts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            targets.append(dir.appendingPathComponent("live.md"))
            targets.append(vaultRoot.appendingPathComponent("Transcripts Live.md"))
        }
        paths = targets
    }

    /// Starts a fresh live document (replacing the previous call's content).
    public func begin(title: String, startedAt: Date, windowTitles: [String]) {
        let iso = ISO8601DateFormatter().string(from: startedAt)
        var lines = ["---", "title: \"Live: \(title)\"", "started_at: \(iso)", "status: recording"]
        if !windowTitles.isEmpty {
            lines.append("window_titles: [\(windowTitles.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }.joined(separator: ", "))]")
        }
        lines.append("---")
        header = lines.joined(separator: "\n")
            + "\n\n> Live transcript — updates every few seconds while the call records.\n\n## Transcript\n"
        footer = ""
        turns = []
        flush()
    }

    /// Adds a finalized turn at its position on the recording timeline.
    public func append(speaker: String, start: Double, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(AttributedSegment(speaker: speaker, start: start, text: trimmed))
        // The finalized text supersedes whatever guess was showing for this track.
        partials[speaker] = nil
        flush()
    }

    /// Updates the in-progress line for one track. Cheap to call often.
    public func setPartial(speaker: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard partials[speaker] != trimmed else { return }
        partials[speaker] = trimmed.isEmpty ? nil : trimmed
        guard Date().timeIntervalSince(partialFlushAt) >= Self.partialInterval else { return }
        partialFlushAt = Date()
        flush()
    }

    /// Swaps the header title when a better meeting name appears mid-call
    /// (join-screen chrome → the real meeting window).
    public func retitle(_ title: String) {
        guard let range = header.range(of: #"title: "Live: [^"]*""#, options: .regularExpression) else { return }
        header = header.replacingCharacters(
            in: range, with: "title: \"Live: \(title.replacingOccurrences(of: "\"", with: "'"))\"")
        flush()
    }

    /// Marks the document finished (the batch pipeline's vault doc supersedes it).
    public func end() {
        partials = [:]
        footer = "\n> Call ended \(ISO8601DateFormatter().string(from: Date())) — the final summarized document is in the vault.\n"
        header = header.replacingOccurrences(of: "status: recording", with: "status: ended")
        flush()
    }

    private func flush() {
        // Coalesce consecutive same-speaker turns in timeline order — same shape
        // the batch document uses.
        let merged = SpeakerTurns.turns(turns.sorted { $0.start < $1.start })
        // Stamped, like the batch document. This is the file an assistant is
        // pointed at mid-call, and "what was said around twenty minutes in" is
        // most of what anyone asks it.
        let body = SpeakerTurns.markdown(merged, timed: true)
        var edge = ""
        if !partials.isEmpty {
            edge = "\n## Being said now\n\n"
                + partials.keys.sorted().compactMap { key in
                    partials[key].map { "> **\(key):** \($0)…" }
                }.joined(separator: "\n>\n")
                + "\n\n> Not yet final — this text is still being revised and is\n"
                + "> replaced by the transcript above once the speaker finishes.\n"
        }
        let doc = header + "\n" + body + "\n" + edge + footer
        for url in paths {
            try? doc.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
