import Foundation

/// A zero-dependency `ChatModel` fallback: no daemon, no network, no model download.
/// It produces a serviceable extractive summary (title + TL;DR + key points) using
/// classic sentence scoring, and a safe default routing decision for classification.
///
/// This is what keeps the app fully self-contained: when Apple's on-device
/// `FoundationModels` isn't available, summarization still yields a usable
/// result instead of failing. Quality is below a real LLM, so on-device
/// FoundationModels is preferred when present.
public struct ExtractiveChatModel: ChatModel {
    public init() {}

    public func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
        if jsonFormat {
            // Classification without a language model: no opinion — return an empty
            // destination so ClassifyStage cleanly applies the configured fallback.
            return #"{"destination":"","confidence":0,"note":"routed without a language model"}"#
        }
        return Self.summarize(Self.transcript(from: user))
    }

    /// Pulls the transcript out of the Summarize prompt (everything after
    /// "TRANSCRIPT:"), falling back to the whole message.
    static func transcript(from user: String) -> String {
        if let r = user.range(of: "TRANSCRIPT:") {
            var body = String(user[r.upperBound...])
            if let end = body.range(of: "\n\nWrite the summary") { body = String(body[..<end.lowerBound]) }
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return user
    }

    static func summarize(_ raw: String) -> String {
        // Attributed transcripts carry `**Me:** / **Others:**` markers on every
        // turn — strip them before scoring or the speaker names become the
        // "most frequent words" and end up in the title.
        let text = stripSpeakerLabels(raw)
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else {
            return "TITLE: Recording\n\n**TL;DR:** (no transcript content)\n\n**Key Points:**\n- N/A\n\n**Action Items:**\n- N/A"
        }

        let freq = wordFrequencies(text)
        // Score each sentence by summed word frequency, length-normalized.
        let scored = sentences.enumerated().map { (i, s) -> (idx: Int, sentence: String, score: Double) in
            let words = tokenize(s)
            guard !words.isEmpty else { return (i, s, 0) }
            let sum = words.reduce(0.0) { $0 + (freq[$1] ?? 0) }
            return (i, s, sum / Double(words.count))
        }

        let top = scored.sorted { $0.score > $1.score }.prefix(5)
        let tldr = top.first?.sentence ?? sentences[0]
        // Key points in original order for readability.
        let keyPoints = top.sorted { $0.idx < $1.idx }.map { clip($0.sentence, words: 26) }

        let title = deriveTitle(from: tldr, keywords: topKeywords(freq, count: 4))
        var out = "TITLE: \(title)\n\n"
        out += "**TL;DR:** \(clip(tldr, words: 40))\n\n"
        out += "**Key Points:**\n"
        out += keyPoints.map { "- \($0)" }.joined(separator: "\n")
        out += "\n\n**Action Items:**\n- (extract manually — generated without a language model)"
        return out
    }

    // MARK: - Text utilities

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.count > 12 { out.append(s) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count > 12 { out.append(tail) }
        return out
    }

    static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stopwords.contains($0) }
    }

    static func wordFrequencies(_ text: String) -> [String: Double] {
        var freq: [String: Double] = [:]
        for w in tokenize(text) { freq[w, default: 0] += 1 }
        if let maxV = freq.values.max(), maxV > 0 {
            for k in freq.keys { freq[k]! /= maxV } // normalize 0…1
        }
        return freq
    }

    /// Titles from raw speech read badly ("Um, I don't know…"), so drop filler
    /// words first and, when too little substance remains, fall back to the
    /// transcript's top keywords instead of whatever was said first.
    static func deriveTitle(from sentence: String, keywords: [String] = []) -> String {
        let meaningful = sentence
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }
            .map(String.init)
            .filter { !fillerWords.contains($0.lowercased()) }
        if meaningful.count >= 3 {
            return meaningful.prefix(7).joined(separator: " ")
        }
        if !keywords.isEmpty {
            return keywords.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ", ")
        }
        let cleaned = sentence
            .split(separator: " ").prefix(7).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:"))
        return cleaned.isEmpty ? "Recording" : cleaned
    }

    /// Highest-frequency content words, most frequent first. Filler never
    /// qualifies — a standup's "thank you all, great, right" must not become
    /// the title just because it was said often.
    static func topKeywords(_ freq: [String: Double], count: Int) -> [String] {
        freq.filter { !fillerWords.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(count)
            .map(\.key)
    }

    /// Removes `**Speaker:**` turn markers from an attributed transcript.
    static func stripSpeakerLabels(_ text: String) -> String {
        text.replacingOccurrences(of: #"\*\*[^*\n]{1,32}:\*\*\s*"#,
                                  with: "", options: .regularExpression)
    }

    /// Conversational filler that should never appear in a title. Includes the
    /// scoring stopwords plus spoken-language tics and contractions.
    static let fillerWords: Set<String> = stopwords.union([
        "um", "uh", "uhm", "hmm", "mhm", "mm", "eh", "ah", "oh", "so", "well",
        "right", "sure", "yes", "yep", "yea", "nah", "no", "hey", "hi", "hello",
        "i", "i'm", "i'll", "i'd", "i've", "we", "we're", "we'll", "we've",
        "it", "it's", "its", "he", "she", "me", "my", "mine", "our", "ours",
        "a", "an", "of", "to", "in", "on", "at", "is", "am", "be", "do", "does",
        "did", "don't", "don’t", "didn't", "didn’t", "doesn't", "doesn’t",
        "can't", "can’t", "won't", "won’t", "isn't", "isn’t", "aren't", "aren’t",
        "wasn't", "wasn’t", "gotta", "wanna", "lemme", "actually", "basically",
        "literally", "maybe", "guys", "guess", "say", "said", "see", "want",
        "need", "let", "let's", "let’s", "now", "today", "back", "good", "great",
        "thank", "thanks", "appreciate", "welcome", "everyone", "everybody",
        "folks", "alright", "bye", "goodbye", "cheers", "sounds", "perfect",
        "awesome", "cool", "nice",
    ])

    static func clip(_ s: String, words: Int) -> String {
        let parts = s.split(separator: " ")
        guard parts.count > words else { return s }
        return parts.prefix(words).joined(separator: " ") + "…"
    }

    static let stopwords: Set<String> = [
        "the","and","for","are","but","not","you","your","with","that","this","have","has","had",
        "was","were","will","would","can","could","should","its","their","them","they","then",
        "there","here","what","when","where","which","who","how","why","all","any","from","into",
        "out","about","just","like","really","yeah","okay","gonna","kind","sort","stuff","thing",
        "things","know","think","mean","going","get","got","one","two","also","because","been",
    ]
}
