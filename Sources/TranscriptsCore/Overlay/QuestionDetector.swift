import Foundation

/// Finds the questions in a spoken turn, without a language model.
///
/// This is a cost gate, not a classifier. Waking an on-device model on every
/// finalized turn would put the overlay minutes behind the conversation, so the
/// expensive retrieve-and-answer pass only runs on turns that look like a
/// question by shape. Being slightly generous is fine — an unanswerable
/// question costs one retrieval that returns nothing — but being noisy is not,
/// which is what the filler list is for.
public enum QuestionDetector {
    /// Below this, a "question" is a conversational tic ("why?", "right?") with
    /// nothing to retrieve against. Three keeps genuinely short ones — "who owns
    /// this?", "when's the deadline?".
    static let minimumWords = 3

    /// Openers that make a sentence a question without a question mark —
    /// speech-to-text punctuates unreliably, and a rising-intonation question
    /// often lands as a full stop.
    static let interrogatives: Set<String> = [
        "what", "whats", "when", "who", "whos", "where", "why", "how", "which", "whose",
        "do", "does", "did", "can", "could", "should", "would", "is", "are",
        "was", "were", "have", "has", "will", "am", "any",
    ]

    /// Question-shaped, but not asking for anything the record can answer:
    /// comprehension checks, call-quality checks, and requests for an opinion.
    /// Matched against the whole normalized sentence, and also against its tail
    /// so "so we'd ship in March, does that make sense" is caught.
    static let fillers: Set<String> = [
        "does that make sense", "do that make sense", "did that make sense",
        "does this make sense", "makes sense", "make sense",
        "can you hear me", "can you all hear me", "can everyone hear me",
        "can you hear me okay", "are you there", "you still there",
        "can you see my screen", "can you see this", "can you see that",
        "is that ok", "is that okay", "does that sound good", "sound good",
        "any questions", "any other questions", "any questions on that",
        "what do you think", "what are your thoughts", "how do you feel",
        "am i right", "isnt it", "arent they", "you know what i mean",
        "how are you", "hows it going", "whats up", "how you doing",
        "does anyone have anything", "anything else",
    ]

    /// True when the sentence reads as an answerable question.
    public static func isQuestion(_ sentence: String) -> Bool {
        let words = normalized(sentence).split(separator: " ").map(String.init)
        guard words.count >= minimumWords else { return false }
        guard !isFiller(words) else { return false }

        let hasMark = sentence.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        return hasMark || interrogatives.contains(words[0])
    }

    /// The question a turn is asking, if any.
    ///
    /// Takes the *last* qualifying sentence: a turn that works up to a question
    /// ("we looked at both. which one did we land on?") is asking the one at the
    /// end, and answering the preamble instead would be answering nothing.
    public static func question(in turn: String) -> String? {
        ExtractiveChatModel.splitSentences(turn)
            .last(where: isQuestion)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased, punctuation and apostrophes stripped, whitespace collapsed —
    /// so "Does that make sense?" and "does that make sense" are one string.
    static func normalized(_ s: String) -> String {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// Whole-sentence match, or a trailing tag on a longer sentence.
    private static func isFiller(_ words: [String]) -> Bool {
        let whole = words.joined(separator: " ")
        if fillers.contains(whole) { return true }
        // Tag questions hang off the end: check the last few words only, so a
        // sentence that merely contains "make sense" in the middle survives.
        for n in 2...5 where words.count > n {
            if fillers.contains(words.suffix(n).joined(separator: " ")) { return true }
        }
        return false
    }
}
