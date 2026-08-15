import Foundation

/// Tier A of speaker naming (#6): meetings name their own speakers — "Back to
/// Tracy" … Speaker 2 answers — so the summarize model is asked to map generic
/// diarization labels to real names *when the transcript itself provides the
/// evidence*. Pure logic; no voice biometrics involved.
public enum SpeakerNames {

    /// Parses a `**Speakers:**` bullet section from model output:
    ///
    ///     **Speakers:**
    ///     - Speaker 2: Tracy
    ///     - Speaker 3: Karthik
    public static func mapping(from summary: String) -> [String: String] {
        var out: [String: String] = [:]
        var inSection = false
        for line in summary.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.range(of: #"^\*{0,2}Speakers:?\*{0,2}$"#, options: .regularExpression) != nil {
                inSection = true
                continue
            }
            guard inSection else { continue }
            if l.isEmpty || l.hasPrefix("**") { break }   // section ended
            guard let match = l.range(of: #"Speaker \d+"#, options: .regularExpression) else { continue }
            let label = String(l[match])
            let after = l[match.upperBound...].drop { ":—–- ".contains($0) }
            let name = String(after)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            if isPlausibleName(name) { out[label] = name }
        }
        return out
    }

    /// Keeps only mappings the transcript actually *evidences*. Mere occurrence
    /// is not evidence — "Rick and Morty" in a feature description must not
    /// name a speaker Rick, and "I talked to Marc yesterday" must not name a
    /// present speaker Marc. A name counts only when it's used *at* someone:
    ///
    /// - **addressed**: the name sits in vocative position (start/end of a
    ///   sentence, or next to a hand-off cue like "thanks," / "back to" /
    ///   "you're up") in a turn adjacent to the mapped speaker's turn, or
    /// - **self-introduced**: the mapped speaker's own turn opens with
    ///   "I'm …" / "my name is …" / "this is …".
    public static func validated(_ mapping: [String: String], transcript: String) -> [String: String] {
        let turns = parseTurns(transcript)
        return mapping.filter { label, name in
            hasAddressEvidence(for: label, name: name, in: turns)
        }
    }

    /// (speaker, text) sequence parsed from `**X:** …` markdown turns.
    static func parseTurns(_ transcript: String) -> [(speaker: String, text: String)] {
        var out: [(String, String)] = []
        for rawLine in transcript.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("**"), let close = line.range(of: ":**") else { continue }
            let speaker = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            let text = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            out.append((speaker, text))
        }
        return out
    }

    static let handoffCues = [
        "thanks", "thank you", "hi", "hey", "good morning", "morning",
        "good evening", "welcome", "back to", "over to", "go ahead",
        "you're up", "up next", "take it away",
    ]

    static func hasAddressEvidence(for label: String, name: String,
                                   in turns: [(speaker: String, text: String)]) -> Bool {
        let nameWords = name.lowercased().split(separator: " ").filter { $0.count >= 3 }
        guard let firstWord = nameWords.first else { return false }
        let first = String(firstWord)

        for (i, turn) in turns.enumerated() {
            // Self-introduction in the mapped speaker's own turn.
            if turn.speaker == label {
                let head = turn.text.lowercased().prefix(80)
                if head.range(of: "(i'm|i’m|i am|my name is|this is)\\s+[^.]{0,20}\(first)",
                              options: .regularExpression) != nil {
                    return true
                }
            }
            // Addressed from a turn adjacent to the mapped speaker's turn.
            let adjacent = (i > 0 && turns[i - 1].speaker == label)
                || (i + 1 < turns.count && turns[i + 1].speaker == label)
            guard adjacent, turn.speaker != label else { continue }
            for sentence in turn.text.lowercased()
                .components(separatedBy: CharacterSet(charactersIn: ".!?")) {
                guard let r = sentence.range(of: first) else { continue }
                let words = sentence.split(separator: " ").map(String.init)
                guard let idx = words.firstIndex(where: { $0.contains(first) }) else { continue }
                // Vocative position: among the first or last three words…
                if idx <= 2 || idx >= max(0, words.count - 3) { return true }
                // …or flanked by a hand-off cue.
                let before = sentence[..<r.lowerBound].suffix(24)
                let after = sentence[r.upperBound...].prefix(24)
                if handoffCues.contains(where: { before.contains($0) || after.contains($0) }) {
                    return true
                }
            }
        }
        return false
    }

    /// Rewrites `**Speaker 2:**` turn labels to `**Tracy:**` in a transcript body.
    public static func apply(_ mapping: [String: String], to body: String) -> String {
        var out = body
        for (label, name) in mapping {
            out = out.replacingOccurrences(of: "**\(label):**", with: "**\(name):**")
        }
        return out
    }

    /// 1–3 words, letters (plus common name punctuation), not a non-answer.
    static func isPlausibleName(_ name: String) -> Bool {
        let rejects: Set<String> = ["unknown", "unclear", "n/a", "na", "none", "unidentified", "not named", "?"]
        guard !name.isEmpty, name.count <= 40,
              !rejects.contains(name.lowercased()) else { return false }
        let words = name.split(separator: " ")
        guard (1...3).contains(words.count) else { return false }
        return words.allSatisfy { w in
            w.first?.isLetter == true && w.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" || $0 == "." }
        }
    }
}
