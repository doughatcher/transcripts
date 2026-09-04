import Foundation

/// One stretch of a call that was about one thing.
///
/// Bounded by seconds into the recording, because that is what every overlay
/// card is already stamped with — so a card belongs to a segment by virtue of
/// *when it was said*, and nothing has to be re-filed when a boundary lands
/// slightly earlier than the pass that noticed it.
public struct TopicSegment: Identifiable, Equatable, Sendable {
    /// One continuous stretch of call spent on this topic. Half-open: `end` is
    /// where the next topic took over, and nil means still on the floor.
    public struct Span: Equatable, Sendable {
        public var start: Double
        public var end: Double?

        public init(start: Double, end: Double? = nil) {
            self.start = start
            self.end = end
        }

        public func contains(_ at: Double) -> Bool {
            guard at >= start else { return false }
            guard let end else { return true }
            return at < end
        }
    }

    public let id: UUID
    /// Short noun phrase from the read pass. Empty until the first pass names
    /// it — a call starts before anyone knows what it is about.
    public var title: String
    /// A topic can be discontinuous: a meeting that returns to pricing after
    /// twenty minutes elsewhere is on the same topic, not a second copy of it,
    /// and the stretch in between belongs to whatever was actually discussed.
    /// One range per topic could not express that without swallowing it.
    public var spans: [Span]

    public init(id: UUID = UUID(), title: String = "", startedAt: Double, endedAt: Double? = nil) {
        self.id = id
        self.title = title
        self.spans = [Span(start: startedAt, end: endedAt)]
    }

    /// When the topic was first raised. Ordering and display only.
    public var startedAt: Double { spans.first?.start ?? 0 }
    /// Where its most recent stretch ended; nil while it is on the floor.
    public var endedAt: Double? { spans.last?.end }

    /// What the pager shows. An unnamed opening segment is still a segment.
    public var displayTitle: String { title.isEmpty ? "Opening" : title }

    public func contains(_ at: Double) -> Bool { spans.contains { $0.contains(at) } }
}

/// Splits a live call into topics, so the overlay can show what is on the floor
/// now instead of a flat digest that never forgets.
///
/// The problem this exists to solve: a single accumulating digest keeps whatever
/// landed in it first. Ten minutes into a serious conversation the lanes are
/// still showing the weather from the opening small talk, because "keep what
/// still matters" is not a judgement a small on-device model can make about a
/// bullet it is handed back on every pass. A topic boundary gives the digest the
/// eviction rule it otherwise has no way to derive.
///
/// Three choices, each guarding a specific way this goes wrong on-device against
/// raw speech-to-text:
///
/// - **Title, don't classify.** Nothing ever asks the model "did the topic
///   change?". It is asked to *name* what the window is about, and a change of
///   name is the signal. Asked for a yes/no on an ambiguous boundary a small
///   model flips from pass to pass; asked to title a window that is mostly the
///   same text as last time, it returns mostly the same title.
/// - **Confirm before committing.** A new name must survive two consecutive
///   passes. A single pass is usually a tangent — someone answering a side
///   question — and splitting on tangents shatters a meeting into stubs nobody
///   can page through.
/// - **Reopen rather than duplicate.** A name close to a recent segment returns
///   to that segment instead of appending a second one. Meetings circle back,
///   and "Pricing" twice in the pager is worse than not paging at all.
///
/// Boundaries are committed at the timestamp where the new name *first*
/// appeared, not where it was confirmed. That hands back the pass of latency
/// the confirmation rule costs, and it is why cards are filed by timestamp.
public struct TopicSegmenter: Sendable {
    /// What `observe` did, so the engine can reset its per-topic dedupe.
    public enum Outcome: Equatable, Sendable {
        /// Same topic, or a candidate still awaiting confirmation.
        case unchanged
        /// A boundary was committed and a new segment is on the floor.
        case opened(UUID)
        /// The call came back to a topic it had already been on.
        case reopened(UUID)
    }

    /// Consecutive passes a new name must survive. Two is the smallest number
    /// that rejects a one-pass tangent.
    static let confirmingPasses = 2
    /// Token overlap above which two titles are the same topic. Measured
    /// against the *smaller* title, so "Pricing" and "Q3 pricing for
    /// enterprise" match — a model naming the same subject at two levels of
    /// detail is the common case, not a boundary.
    static let mergeThreshold = 0.6
    /// How many recent segments a returning topic may reopen. Beyond a few back,
    /// re-raising a subject is better read as a new stretch of discussion.
    static let reopenLookback = 3

    public private(set) var segments: [TopicSegment] = []
    public private(set) var currentID: UUID?

    private var pendingTitle: String?
    private var pendingSince: Double = 0
    private var pendingCount = 0

    public init() {}

    public var current: TopicSegment? {
        guard let currentID else { return nil }
        return segments.first { $0.id == currentID }
    }

    /// Opens the untitled opening segment. Called when the first turn lands, so
    /// cards that arrive before any read pass still have somewhere to live.
    public mutating func begin(at: Double) {
        guard segments.isEmpty else { return }
        let seg = TopicSegment(startedAt: at)
        segments = [seg]
        currentID = seg.id
    }

    /// Feeds one read pass's name for the current window.
    @discardableResult
    public mutating func observe(title raw: String, at: Double) -> Outcome {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .unchanged }

        if segments.isEmpty { begin(at: at) }
        guard let current else { return .unchanged }

        // The opening segment has no name yet: the first pass names it. This is
        // a rename, not a boundary — the call did not change topic, we merely
        // learned what it was already about.
        if current.title.isEmpty {
            rename(current.id, to: title)
            clearPending()
            return .unchanged
        }

        // Still the same subject, however the model chose to word it this time.
        if Self.similarity(title, current.title) >= Self.mergeThreshold {
            clearPending()
            return .unchanged
        }

        // A different name. Hold it until it proves it is not a tangent.
        if let pendingTitle, Self.similarity(title, pendingTitle) >= Self.mergeThreshold {
            pendingCount += 1
        } else {
            self.pendingTitle = title
            pendingSince = at
            pendingCount = 1
        }
        guard pendingCount >= Self.confirmingPasses else { return .unchanged }

        let boundary = max(pendingSince, current.startedAt)
        let confirmed = pendingTitle ?? title
        clearPending()
        return commit(title: confirmed, at: boundary)
    }

    /// The segment a card said at `at` belongs to. Spans never overlap, so at
    /// most one matches; anything said before the first turn is filed under the
    /// opening segment rather than falling through the floor.
    public func segment(containing at: Double) -> TopicSegment? {
        segments.first { $0.contains(at) } ?? segments.first
    }

    // MARK: - Boundaries

    private mutating func commit(title: String, at boundary: Double) -> Outcome {
        closeCurrent(at: boundary)

        // Coming back to something recent reopens it rather than listing it
        // twice. Only the tail is considered: a subject raised at the top of an
        // hour-long call and again at the end is genuinely two stretches. The
        // segment being left is excluded by id, not by position — a reopened
        // topic is not last in the array, and dropping the last element would
        // exclude the wrong one and let the call reopen what it just left.
        let leaving = currentID
        let recent = segments.suffix(Self.reopenLookback + 1).filter { $0.id != leaving }
        if let match = recent.last(where: { Self.similarity(title, $0.title) >= Self.mergeThreshold }) {
            reopen(match.id, at: boundary)
            return .reopened(match.id)
        }

        let seg = TopicSegment(title: title, startedAt: boundary)
        segments.append(seg)
        currentID = seg.id
        return .opened(seg.id)
    }

    private mutating func closeCurrent(at: Double) {
        guard let i = segments.firstIndex(where: { $0.id == currentID }),
              var last = segments[i].spans.last else { return }
        // Never close before it opened: a boundary can land at the same instant
        // the stretch started when two passes disagree inside one window.
        last.end = max(at, last.start)
        segments[i].spans[segments[i].spans.count - 1] = last
    }

    /// Returning to a topic starts a *new* stretch of it rather than extending
    /// the old one, which would swallow everything discussed in between.
    private mutating func reopen(_ id: UUID, at: Double) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].spans.append(TopicSegment.Span(start: at))
        currentID = id
    }

    private mutating func rename(_ id: UUID, to title: String) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].title = title
    }

    private mutating func clearPending() {
        pendingTitle = nil
        pendingCount = 0
    }

    // MARK: - Title comparison

    /// Shared with the merge tool: "are these two names the same subject?" is
    /// one question, asked in two places. See `TitleSimilarity`.
    static func similarity(_ a: String, _ b: String) -> Double { TitleSimilarity.score(a, b) }

    static func terms(_ s: String) -> Set<String> { TitleSimilarity.terms(s) }
}
