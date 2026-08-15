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
    private struct Turn {
        let start: Double
        let speaker: String
        let text: String
    }

    private var turns: [Turn] = []
    private var header = ""
    private var footer = ""
    private let paths: [URL]

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
        turns.append(Turn(start: start, speaker: speaker, text: trimmed))
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
        footer = "\n> Call ended \(ISO8601DateFormatter().string(from: Date())) — the final summarized document is in the vault.\n"
        header = header.replacingOccurrences(of: "status: recording", with: "status: ended")
        flush()
    }

    private func flush() {
        // Coalesce consecutive same-speaker turns in timeline order — same shape
        // the batch document uses.
        let merged = SpeakerTurns.turns(turns.sorted { $0.start < $1.start }
            .map { AttributedSegment(speaker: $0.speaker, start: $0.start, text: $0.text) })
        let body = SpeakerTurns.markdown(merged)
        let doc = header + "\n" + body + "\n" + footer
        for url in paths {
            try? doc.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
