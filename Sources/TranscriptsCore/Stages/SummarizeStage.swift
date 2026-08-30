import Foundation

/// Native Summarize stage. Reads the transcript produced upstream, asks the local
/// Ollama model for a concise title + markdown summary, and folds both back into
/// the single transcript document: it fills the `title:`/`description:` frontmatter
/// and inserts a `## Summary` section above `## Transcript`. Keeping everything in
/// one `<slug>.md` file is what makes the menu-bar "recents → open in viewer"
/// experience clean (one artifact per recording, plus its `.m4a`).
///
/// Resilient by design: if the model is unreachable the transcript still stands on
/// its own — we log and move on rather than failing the whole pipeline, so a
/// recording is never lost just because Ollama is down.
public struct SummarizeStage: PipelineStage {
    public let id: StageID = .summarize
    private let model: any ChatModel

    /// Inject any backend (on-device FoundationModels, Ollama, …).
    public init(model: any ChatModel) {
        self.model = model
    }

    /// Convenience that defaults to Ollama; the app injects the configured
    /// provider via `init(model:)` instead.
    public init(config: AppConfig) {
        self.model = OllamaClient(config: config.ollama)
    }

    public func run(_ context: inout PipelineContext) async throws {
        guard let transcriptURL = context.transcriptURL else {
            // Nothing to summarize (e.g. a text-only note); skip quietly.
            return
        }
        let original = try String(contentsOf: transcriptURL, encoding: .utf8)
        let (frontmatter, body) = Self.splitFrontmatter(original)

        // Don't spend a model call on empty/near-empty transcripts.
        let transcriptText = Self.transcriptBody(body)
        let meaningful = transcriptText
            .replacingOccurrences(of: "[no speech detected]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard meaningful.count > 8 else { return }

        let raw: String
        do {
            raw = try await Self.summarize(transcriptText, with: model)
        } catch {
            // Model unavailable — leave the transcript as-is. Better a bare
            // transcript than a dropped recording.
            return
        }

        let (title, summaryBody) = Self.extractTitle(from: raw)
        let description = Self.extractTLDR(from: summaryBody)

        // Publish the content-derived title so Persist can rename the artifacts
        // to the standard `<stamp>-<title-slug>` form and the app can display it.
        // NOT for the extractive fallback (it marks its output): word-frequency
        // titles are a stand-in, not worth renaming files over — and a meeting-
        // window name like "Rollout Daily Standup" beats them every time.
        let isExtractive = raw.contains("generated without a language model")
        if let title, !isExtractive { context.userInfo["summaryTitle"] = title }

        var fm = frontmatter
        if let title { fm = Self.upsert(fm, key: "title", value: "\"\(Self.escape(title))\"") }
        if let description { fm = Self.upsert(fm, key: "description", value: "\"\(Self.escape(description))\"") }

        // Tier A speaker naming (#6): when the model matched generic labels to
        // names *and* the transcript actually contains those names, rename the
        // turn labels and the frontmatter speakers list.
        var namedBody = body
        let names = SpeakerNames.validated(SpeakerNames.mapping(from: summaryBody),
                                           transcript: transcriptText)
        if !names.isEmpty {
            namedBody = SpeakerNames.apply(names, to: namedBody)
            for (label, name) in names {
                fm = fm.replacingOccurrences(of: "\"\(label)\"", with: "\"\(Self.escape(name))\"")
            }
            // Publish the mapping so the app can pair names with the voice
            // embeddings captured at transcribe time (voice-profile suggestions).
            if let data = try? JSONEncoder().encode(names) {
                context.userInfo["speakerNames"] = String(decoding: data, as: UTF8.self)
            }
        }

        let rebuilt = "---\n\(fm)\n---\n\n## Summary\n\n\(summaryBody)\n\n\(namedBody)"
        try rebuilt.write(to: transcriptURL, atomically: true, encoding: .utf8)
        // Single-file artifact: no separate summary.md, so Persist copies just the
        // consolidated transcript + the audio.
    }

    // MARK: - Summarization

    /// Character budget for a single prompt. Apple's on-device FoundationModels has
    /// a ~4,096-token context window (instructions + prompt + response); at roughly
    /// 4 chars/token, ~12k chars of transcript leaves headroom for the system prompt
    /// and the generated summary. Anything longer used to throw
    /// `exceededContextWindowSize`, silently dropping the whole chain down to the
    /// extractive fallback — which is why long meetings got first-words titles.
    static let promptCharBudget = 12_000

    static let summarySystemPrompt = """
    You summarize a meeting transcript. Respond in Markdown with EXACTLY this shape:
    First line: `TITLE: <3-7 word title>`
    Then a blank line, then `**TL;DR:** <one sentence>`,
    then `**Key Points:**` as a short bullet list,
    then `**Action Items:**` as a bullet list (owner + task when stated, else `N/A`).
    If the transcript labels speakers generically (Speaker 1, Speaker 2, …) AND \
    the conversation itself reveals who they are (people addressed or introduced \
    by name), end with `**Speakers:**` as a bullet list like `- Speaker 2: Tracy` \
    — only for speakers you are confident about; omit the section entirely when unsure. \
    A name that is merely mentioned is NOT identification: references to absent \
    people, products, or pop culture (e.g. "Rick and Morty") never name a speaker.
    Be faithful to the transcript; do not invent.
    """

    /// One-shot when the transcript fits the context budget; otherwise map-reduce:
    /// condense each chunk into terse notes, then write the title + summary from
    /// the combined notes. Keeps every model call inside the on-device window.
    static func summarize(_ transcript: String, with model: any ChatModel) async throws -> String {
        if transcript.count <= promptCharBudget {
            let user = "TRANSCRIPT:\n\n\(transcript)\n\nWrite the summary now."
            return try await model.chat(system: summarySystemPrompt, user: user, jsonFormat: false, maxTokens: 1024)
        }

        let chunks = chunk(transcript, budget: promptCharBudget)
        let condenseSystem = """
        You condense one part of a longer meeting transcript. Respond with 3-6 terse
        Markdown bullets covering the topics discussed, decisions made, and any action
        items (owner + task when stated). No preamble, no headings — bullets only.
        Be faithful to the transcript; do not invent.
        """
        var notes: [String] = []
        for (i, part) in chunks.enumerated() {
            let user = "TRANSCRIPT PART \(i + 1) OF \(chunks.count):\n\n\(part)\n\nWrite the bullets now."
            let condensed = try await model.chat(system: condenseSystem, user: user, jsonFormat: false, maxTokens: 300)
            notes.append(condensed.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var combined = notes.joined(separator: "\n")
        if combined.count > promptCharBudget {
            combined = String(combined.prefix(promptCharBudget))
        }
        let user = """
        CONDENSED NOTES FROM A MEETING (in chronological order):

        \(combined)

        Write the summary now.
        """
        return try await model.chat(system: summarySystemPrompt, user: user, jsonFormat: false, maxTokens: 1024)
    }

    /// Splits text into chunks of at most `budget` characters, preferring sentence
    /// boundaries, then word boundaries, so no chunk starts mid-thought.
    static func chunk(_ text: String, budget: Int) -> [String] {
        guard budget > 0, text.count > budget else { return [text] }
        var chunks: [String] = []
        var current = ""
        for sentence in splitKeepingSentences(text) {
            if current.count + sentence.count > budget, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            if sentence.count > budget {
                // Pathological run-on: split on words.
                for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
                    if current.count + word.count + 1 > budget, !current.isEmpty {
                        chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                        current = ""
                    }
                    current += current.isEmpty ? String(word) : " \(word)"
                }
            } else {
                current += sentence
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    /// Splits on sentence-ending punctuation, keeping the delimiter and trailing
    /// whitespace with the sentence so rejoining chunks loses nothing.
    private static func splitKeepingSentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var afterTerminator = false
        for ch in text {
            if afterTerminator, !ch.isWhitespace {
                out.append(cur)
                cur = ""
                afterTerminator = false
            }
            cur.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                afterTerminator = true
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: - Parsing helpers

    /// Splits `---\n<fm>\n---\n<body>` into (frontmatter, body-with-leading-newline-trimmed).
    static func splitFrontmatter(_ text: String) -> (frontmatter: String, body: String) {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return ("", text) }
        let fm = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        let body = String(text[end.upperBound...]).trimmingCharacters(in: .newlines)
        return (fm, body)
    }

    /// Returns just the transcript prose (drops the `## Transcript` heading).
    static func transcriptBody(_ body: String) -> String {
        let text: String
        if let r = body.range(of: "## Transcript") {
            text = String(body[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = body
        }
        // Turn timestamps come back out before the model sees this. They are for
        // a reader jumping to a moment; to a summarizer they are a few hundred
        // tokens of noise spent on nothing, on the long meetings where context is
        // already the scarce thing.
        return SpeakerTurns.stripStamps(text)
    }

    /// Pulls a leading `TITLE: ...` line out of the model output; returns the title
    /// (if any) and the remaining summary body.
    ///
    /// Decoration-tolerant, because the models actually decorate it. Asking for
    /// "First line: `TITLE: <3-7 word title>`" reliably gets back the title —
    /// and just as reliably gets it in whatever markdown the model favours that
    /// day: `**TITLE: Post-Sales Interview Process**`, `## Title: …`,
    /// `**Title:** …`. Matching only the bare form meant a decorated one was no
    /// title at all: the transcript kept the meeting-window name, the file kept
    /// the app-name slug, and the `TITLE:` line stayed in the summary where the
    /// reader could see exactly what had been thrown away.
    static func extractTitle(from raw: String) -> (title: String?, body: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return (nil, trimmed) }

        // Split on the first colon and treat the halves differently. The label
        // may carry decoration anywhere (`**TITLE**`, `*Title*`) so it is
        // stripped throughout; the title itself may only be stripped at its
        // ends, because those same characters are load-bearing inside it —
        // `**TITLE: C# to F# Migration**` names two languages, not "C to F".
        let line = lines[index]
        guard let colon = line.firstIndex(of: ":"),
              Self.undecorate(String(line[line.startIndex..<colon]))
                  .caseInsensitiveCompare("TITLE") == .orderedSame
        else { return (nil, trimmed) }

        let title = Self.trimDecoration(String(line[line.index(after: colon)...]))
        guard !title.isEmpty else { return (nil, trimmed) }
        lines.remove(at: index)
        return (title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Strips every markdown character, for matching a *label* — where the
    /// decoration can sit anywhere and none of it is part of the word.
    static func undecorate(_ line: String) -> String {
        line.replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Strips decoration from the ends only, for *content* — which keeps the
    /// `#` in "C#" and the `_` in "read_me" while still unwrapping `**bold**`.
    static func trimDecoration(_ text: String) -> String {
        text.replacingOccurrences(of: "^[*_`\\s]+|[*_`\\s]+$", with: "",
                                  options: .regularExpression)
    }

    /// One-line description from the `**TL;DR:**` bullet, if present.
    static func extractTLDR(from summary: String) -> String? {
        for line in summary.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if let r = l.range(of: "TL;DR:", options: [.caseInsensitive]) {
                let text = String(l[r.upperBound...])
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    /// Replaces `key: ...` in frontmatter if present, else appends it.
    static func upsert(_ frontmatter: String, key: String, value: String) -> String {
        var lines = frontmatter.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) {
            lines[idx] = "\(key): \(value)"
        } else {
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
    }
}
