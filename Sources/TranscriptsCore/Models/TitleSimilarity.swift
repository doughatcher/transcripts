import Foundation

/// Do two short names refer to the same thing?
///
/// Used wherever the app has to decide whether two labels describe one subject:
/// whether a topic on the overlay has changed, and whether two recordings being
/// merged look like the same meeting. Both are the same judgement made about
/// strings a model or a meeting window produced, so they share one answer.
///
/// Deliberately not fuzzy string distance. "Q3 pricing" and "Q4 pricing" are one
/// character apart and are different subjects; "Pricing" and "Q3 pricing for
/// enterprise" share no prefix and are the same one. Content words are the
/// signal, so that is what this compares.
public enum TitleSimilarity {
    /// Words that carry no subject. Without stripping these, "Discussion of the
    /// budget" and "Discussion of the timeline" share three tokens of four and
    /// every title in a call collapses into one.
    public static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "for", "on", "in", "to", "with",
        "about", "regarding", "re", "our", "their", "its", "this", "that",
        "discussion", "discussing", "topic", "conversation", "talk", "talking",
        "meeting", "call", "update", "updates", "general", "misc", "other",
    ]

    /// Overlap measured against the *shorter* title, so a subset counts as the
    /// same subject rather than a new one: a name given at two levels of detail
    /// is the common case, not a difference.
    public static func score(_ a: String, _ b: String) -> Double {
        let ta = terms(a), tb = terms(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count))
    }

    public static func terms(_ s: String) -> Set<String> {
        let all = normalized(s).split(separator: " ").map(String.init)
        let meaningful = all.filter { !stopwords.contains($0) && $0.count > 1 }
        // A title that is nothing but stopwords still has to compare as
        // something, or every such title matches every other.
        return Set(meaningful.isEmpty ? all : meaningful)
    }

    /// Lowercased, punctuation stripped, whitespace collapsed.
    public static func normalized(_ s: String) -> String {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
