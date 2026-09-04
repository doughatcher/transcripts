import Foundation

/// Where an overlay answer came from. Every answer carries one: the overlay
/// shows facts and answers *during* a live call, where a confidently invented
/// sentence is worse than silence, so the provenance is part of the card rather
/// than something the UI may or may not choose to render.
public enum OverlaySource: Equatable, Sendable {
    /// Said earlier in this same call, at this many seconds into the recording.
    case thisCall(at: Double)
    /// Found in a note under the knowledge root.
    case note(title: String, path: String)
    /// The question was asked and nothing in the call or the vault answers it.
    /// Shown as the bare question — the overlay never fills this in from the
    /// model's own knowledge.
    case unsourced

    public var noteTitle: String? {
        if case .note(let title, _) = self { return title }
        return nil
    }

    public var notePath: String? {
        if case .note(_, let path) = self { return path }
        return nil
    }

    /// The attribution line shown under an answer. `at` is rendered by the
    /// caller, which owns the clock format.
    public var isFromThisCall: Bool {
        if case .thisCall = self { return true }
        return false
    }
}

/// One line in the overlay: either a fact someone stated, or a question someone
/// asked (with its answer, when one could be grounded).
public struct OverlayCard: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        /// A number, date, name, owner or deadline that was stated.
        case fact
        /// Where a stretch of discussion landed — the thing you look up for when
        /// you have lost the thread.
        case conclusion
        case question
    }

    public let id: UUID
    public var kind: Kind
    /// The fact as stated, or the question as asked.
    public var headline: String
    /// One sentence, present only when `source` is not `.unsourced`.
    public var answer: String?
    public var source: OverlaySource
    /// Seconds into the recording — what the card is sorted by, and what lets a
    /// card be traced back to the moment in the transcript.
    public var at: Double

    public init(id: UUID = UUID(), kind: Kind, headline: String,
                answer: String? = nil, source: OverlaySource, at: Double) {
        self.id = id
        self.kind = kind
        self.headline = headline
        self.answer = answer
        self.source = source
        self.at = at
    }
}


/// One topic's worth of the digest — the lanes, scoped to a single stretch of
/// the call that was about one thing.
public struct TopicDigest: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Never empty: an unnamed opening segment reads as "Opening".
    public var title: String
    public var startedAt: Double
    /// Nil for the topic on the floor.
    public var endedAt: Double?
    public var conclusion: OverlayCard?
    public var facts: [OverlayCard]
    public var lastQuestion: OverlayCard?
    /// The topic currently being discussed. Exactly one is current.
    public var isCurrent: Bool

    public init(id: UUID = UUID(), title: String, startedAt: Double, endedAt: Double? = nil,
                conclusion: OverlayCard? = nil, facts: [OverlayCard] = [],
                lastQuestion: OverlayCard? = nil, isCurrent: Bool = false) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.conclusion = conclusion
        self.facts = facts
        self.lastQuestion = lastQuestion
        self.isCurrent = isCurrent
    }

    public var isEmpty: Bool {
        conclusion == nil && facts.isEmpty && lastQuestion == nil
    }
}

/// What the overlay puts on screen, arranged the way it is read rather than the
/// order it arrived.
///
/// A chronological stack of cards is the wrong shape for a glance: during a call
/// you are not catching up on history, you are asking one of three questions —
/// *what was just said*, *where did we land*, *what was that number*, *what did
/// they just ask me*. So the digest is those lanes, each holding only its most
/// recent, useful item.
///
/// The lanes are scoped to the topic currently on the floor, not to the whole
/// call. That is what stops the opening small talk from occupying the fact lane
/// for an hour: when the conversation moves on, the weather does not follow it,
/// it stays in the segment where it was said and is still reachable by paging
/// back through `topics`. See `TopicSegmenter`.
public struct OverlayDigest: Equatable, Sendable {
    /// The most recent line of transcript, verbatim. No model involved, so it
    /// updates the moment a turn is finalized — this is what makes the collapsed
    /// pill feel live rather than lagging a summarization pass.
    public var lastSpoken: String
    /// Where the current topic last landed.
    public var conclusion: OverlayCard?
    /// Facts and figures from the current topic, most recent first.
    public var facts: [OverlayCard]
    /// The last question asked in the current topic, with its answer when one
    /// could be grounded.
    public var lastQuestion: OverlayCard?
    /// Every topic the call has been on, in the order they started. The pager
    /// reads this; the lanes above are the current entry, hoisted so callers
    /// that do not page keep working unchanged.
    public var topics: [TopicDigest]
    /// Index into `topics` of the topic on the floor. Nil before the first turn.
    public var currentTopicIndex: Int?

    public init(lastSpoken: String = "", conclusion: OverlayCard? = nil,
                facts: [OverlayCard] = [], lastQuestion: OverlayCard? = nil,
                topics: [TopicDigest] = [], currentTopicIndex: Int? = nil) {
        self.lastSpoken = lastSpoken
        self.conclusion = conclusion
        self.facts = facts
        self.lastQuestion = lastQuestion
        self.topics = topics
        self.currentTopicIndex = currentTopicIndex
    }

    public var isEmpty: Bool {
        lastSpoken.isEmpty && conclusion == nil && facts.isEmpty && lastQuestion == nil
    }

    /// The topic on the floor.
    public var currentTopic: TopicDigest? {
        guard let currentTopicIndex, topics.indices.contains(currentTopicIndex) else { return nil }
        return topics[currentTopicIndex]
    }
}
