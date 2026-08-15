import Foundation

/// Turns a run-on speech transcript into readable paragraphs. Speech-to-text emits
/// one long unbroken line, so this groups sentences into ~balanced paragraphs. Used
/// both when writing new transcripts and when *rendering* old ones in the viewer, so
/// every transcript reads well regardless of how it was stored.
public enum TranscriptFormatter {
    /// Target characters per paragraph (a comfortable reading block).
    private static let target = 360

    /// Returns the text broken into paragraphs separated by blank lines. Short or
    /// non-prose input (e.g. "[no speech detected]") is returned unchanged.
    public static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240, !trimmed.hasPrefix("[") else { return trimmed }

        let sentences = splitSentences(trimmed)
        guard sentences.count > 1 else { return trimmed }

        var paragraphs: [String] = []
        var current = ""
        for s in sentences {
            current = current.isEmpty ? s : current + " " + s
            if current.count >= target {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            // Fold a short trailing remainder into the previous paragraph.
            if current.count < 120, let last = paragraphs.popLast() {
                paragraphs.append(last + " " + current)
            } else {
                paragraphs.append(current)
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Splits prose into sentences, keeping terminators. Guards against splitting on
    /// common abbreviations so "e.g." / "U.S." don't fragment paragraphs.
    public static func splitSentences(_ text: String) -> [String] {
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "vs", "e.g", "i.e", "etc", "u.s", "a.m", "p.m", "st", "jr", "sr"]
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard ch == "." || ch == "!" || ch == "?" else { continue }
            // Don't break inside a decimal like 3.5.
            if ch == ".", i + 1 < chars.count, chars[i + 1].isNumber { continue }
            // Don't break on a known abbreviation.
            let lastWord = current.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init) ?? ""
            let stripped = lastWord.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            if abbreviations.contains(stripped) { continue }
            // Only break at a sentence boundary followed by whitespace (or end).
            if i + 1 >= chars.count || chars[i + 1] == " " || chars[i + 1] == "\n" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
