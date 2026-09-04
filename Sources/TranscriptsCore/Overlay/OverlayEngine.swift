import Foundation

/// Turns a live call into the handful of lines worth glancing at: facts as they
/// are stated, and answers to questions that were asked — but only answers the
/// record actually supports.
///
/// The order matters and is the whole design: **retrieve, then phrase**. A
/// question is answered by finding passages (earlier in this call, or in the
/// user's notes) that bear on it and asking the model to write one sentence
/// *from those passages only*; the result is then checked against the passage it
/// claimed to use, and dropped if it doesn't hold up. The model is a phrasing
/// step over retrieved text, never a source. On a live call, in front of other
/// people, a confidently invented answer is worse than an empty overlay.
///
/// An actor because it runs model calls off the main thread while the recorder,
/// two speech analyzers and the UI are all live; the caller hops back to the
/// main actor in `onUpdate`.
public actor OverlayEngine {
    /// How the engine is allowed to spend time and what it may say.
    public struct Options: Sendable {
        /// Minimum seconds between fact passes. On-device generation takes
        /// seconds, so this is a floor, not a schedule.
        public var factInterval: TimeInterval
        /// Turns of context handed to a fact pass.
        public var factWindowTurns: Int
        /// Candidate passages shown to the model for one question.
        public var candidateCount: Int
        /// No usable language model in the chain: retrieve and quote, don't
        /// phrase. See `OverlayEngine.init`.
        public var retrievalOnly: Bool
        /// Cards kept in memory (the panel shows fewer).
        public var maxCards: Int

        public init(factInterval: TimeInterval = 20, factWindowTurns: Int = 40,
                    candidateCount: Int = 4, retrievalOnly: Bool = false,
                    maxCards: Int = 50) {
            self.factInterval = factInterval
            self.factWindowTurns = factWindowTurns
            self.candidateCount = candidateCount
            self.retrievalOnly = retrievalOnly
            self.maxCards = maxCards
        }
    }

    private let model: any ChatModel
    private var vault: PassageIndex?
    private let options: Options
    private let onUpdate: @Sendable (OverlayDigest) -> Void

    /// This call's own turns, retrievable the same way notes are.
    private let callIndex = PassageIndex()
    private var turns: [AttributedSegment] = []
    private var pendingQuestions: [(text: String, at: Double)] = []
    private var cards: [OverlayCard] = []
    /// Where the topic boundaries are. The lanes are scoped to the segment on
    /// the floor, which is what keeps the opening small talk out of a serious
    /// stretch of the call. See `TopicSegmenter`.
    private var segmenter = TopicSegmenter()
    private var passRunning = false
    private var lastFactPass: Date?
    /// Injected so tests don't sleep. Production passes `Date.init`.
    private let now: @Sendable () -> Date

    /// `vault` nil = answer from this call only. `retrievalOnly` should be set
    /// when the resolved chain is just `ExtractiveChatModel`: it has no language
    /// model behind it and answers `jsonFormat` requests with a fixed routing
    /// stub, which would arrive here as a parse failure on every question. Better
    /// to quote the best-matching passage and say where it came from.
    public init(model: any ChatModel,
                vault: PassageIndex?,
                options: Options = Options(),
                now: @escaping @Sendable () -> Date = Date.init,
                onUpdate: @escaping @Sendable (OverlayDigest) -> Void) {
        self.model = model
        self.vault = vault
        self.options = options
        self.now = now
        self.onUpdate = onUpdate
    }

    /// Feeds one finalized turn. Cheap: detection is string work, and the
    /// expensive pass is kicked off only if one is not already in flight.
    public func ingest(speaker: String, start: Double, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(AttributedSegment(speaker: speaker, start: start, text: trimmed))
        // Cards can be appended before any read pass has named a topic, so the
        // opening segment is opened by the first turn and named later.
        segmenter.begin(at: start)
        callIndex.add(Passage(text: trimmed, source: .thisCall(at: start)))
        if let q = QuestionDetector.question(in: trimmed) {
            pendingQuestions.append((text: q, at: start))
        }
        // Straight to the screen, ahead of any model work. The collapsed pill
        // shows what was just said, and it should track the room rather than the
        // summarizer — a HUD that lags a generation pass reads as broken.
        publish()
        schedulePass()
    }

    /// Timer hook, so a call with no questions still accrues facts.
    public func tick() { schedulePass() }

    /// Attaches the notes index once it has been built.
    ///
    /// Indexing a large vault is seconds of file reading, and a recording must
    /// not wait on it — so the engine starts answering from the call alone and
    /// gains the notes when they arrive. Questions asked before then are already
    /// answered and are not retried: re-answering a question the meeting has
    /// moved past is noise.
    public func attach(vault: PassageIndex) {
        self.vault = vault
    }

    /// Runs one pass now and waits for it. Tests use this; production uses
    /// `ingest`/`tick` and lets the pass run detached.
    public func runPassNow() async {
        await runPass()
    }

    public func snapshot() -> [OverlayCard] { cards }

    /// The lanes, each holding its most recent useful item — scoped to the
    /// topic on the floor, with every topic the call has been on alongside them
    /// so the panel can page back without another round trip to the actor.
    public func digest() -> OverlayDigest {
        let segments = segmenter.segments
        guard !segments.isEmpty else {
            // No turn has landed yet (or a test is driving passes directly).
            // Nothing to segment by, so the lanes span the whole call.
            return OverlayDigest(
                lastSpoken: turns.last?.text ?? "",
                conclusion: cards.last { $0.kind == .conclusion },
                facts: cards.filter { $0.kind == .fact }.suffix(Self.factLaneDepth).reversed(),
                lastQuestion: cards.last { $0.kind == .question })
        }

        // Cards are filed by when they were said, not by which segment was open
        // when they were appended. A boundary commits at the moment the new
        // topic *started*, which is earlier than the pass that confirmed it, and
        // filing by timestamp means the cards from that gap move with it.
        // One pass, so a long call does not re-scan every card per topic — and
        // so filing goes through the segmenter's own lookup, which knows a topic
        // can be discontinuous and that anything said before the first turn
        // belongs to the opening segment.
        var byTopic: [UUID: [OverlayCard]] = [:]
        for card in cards {
            guard let seg = segmenter.segment(containing: card.at) else { continue }
            byTopic[seg.id, default: []].append(card)
        }

        let topics = segments.map { seg -> TopicDigest in
            let mine = byTopic[seg.id] ?? []
            return TopicDigest(
                id: seg.id,
                title: seg.displayTitle,
                startedAt: seg.startedAt,
                endedAt: seg.endedAt,
                conclusion: mine.last { $0.kind == .conclusion },
                facts: Array(mine.filter { $0.kind == .fact }.suffix(Self.factLaneDepth).reversed()),
                lastQuestion: mine.last { $0.kind == .question },
                isCurrent: seg.id == segmenter.currentID)
        }
        let index = topics.firstIndex(where: \.isCurrent) ?? topics.count - 1
        let current = topics[index]
        return OverlayDigest(
            lastSpoken: turns.last?.text ?? "",
            conclusion: current.conclusion,
            facts: current.facts,
            lastQuestion: current.lastQuestion,
            topics: topics,
            currentTopicIndex: index)
    }

    /// Facts shown at once. More than a few and the lane stops being glanceable.
    static let factLaneDepth = 3

    private func publish() { onUpdate(digest()) }

    // MARK: - Passes

    /// Single-flight. A queued pass would be answering a question the meeting
    /// moved past two minutes ago, which is worse than not answering it.
    private func schedulePass() {
        guard !passRunning else { return }
        let factsDue = lastFactPass.map { now().timeIntervalSince($0) >= options.factInterval } ?? true
        guard !pendingQuestions.isEmpty || factsDue else { return }
        passRunning = true
        Task { [weak self] in
            await self?.runPass()
            await self?.endPass()
        }
    }

    private func endPass() { passRunning = false }

    private func runPass() async {
        let questions = pendingQuestions
        pendingQuestions = []
        for question in questions {
            let card = await answer(question.text, at: question.at)
            append(card)
        }

        let factsDue = lastFactPass.map { now().timeIntervalSince($0) >= options.factInterval } ?? true
        if factsDue, !options.retrievalOnly, !turns.isEmpty {
            lastFactPass = now()
            let at = turns.last?.start ?? 0
            let read = await readWindow()

            // Topic first: a boundary committed here decides which segment this
            // pass's own cards are filed under, and therefore what they are
            // deduped against.
            if let topic = read.topic {
                segmenter.observe(title: topic, at: at)
            }

            // A conclusion that restates the one already showing is not news.
            if let conclusion = read.conclusion,
               QuestionDetector.normalized(conclusion).count > 8,
               !restatesConclusion(conclusion, at: at) {
                append(OverlayCard(kind: .conclusion, headline: conclusion,
                                   source: .thisCall(at: at), at: at))
            }
            for fact in read.facts where QuestionDetector.normalized(fact).count > 8 {
                guard !alreadyShown(fact, at: at) else { continue }
                append(OverlayCard(kind: .fact, headline: fact, source: .thisCall(at: at), at: at))
            }
        }
    }

    // MARK: - Questions

    /// Retrieve, phrase, verify. Any step failing yields an `.unsourced` card:
    /// the question is still worth showing — it tells the user what the overlay
    /// heard being asked — but without an answer attached to it.
    private func answer(_ question: String, at: Double) async -> OverlayCard {
        let candidates = retrieve(for: question, before: at)
        guard let best = candidates.first else {
            return OverlayCard(kind: .question, headline: question, source: .unsourced, at: at)
        }

        if options.retrievalOnly {
            return OverlayCard(kind: .question, headline: question,
                               answer: Self.condense(best.passage.text),
                               source: best.passage.source, at: at)
        }

        let passages = candidates.map(\.passage)
        guard let reply = try? await model.chat(system: Self.answerSystemPrompt,
                                                user: Self.answerPrompt(question: question, passages: passages),
                                                jsonFormat: true, maxTokens: 200),
              let parsed = Self.parseAnswer(reply),
              parsed.passage >= 1, parsed.passage <= passages.count,
              !parsed.answer.isEmpty else {
            return OverlayCard(kind: .question, headline: question, source: .unsourced, at: at)
        }

        let cited = passages[parsed.passage - 1]
        guard Self.isGrounded(answer: parsed.answer, in: cited.text) else {
            return OverlayCard(kind: .question, headline: question, source: .unsourced, at: at)
        }
        return OverlayCard(kind: .question, headline: question,
                           answer: parsed.answer, source: cited.source, at: at)
    }

    /// Merges the two corpora into one ranked candidate list. Call passages from
    /// at or after the question are dropped: the question turn is itself in the
    /// index, and "answering" a question with the question is the most obvious
    /// way this feature could embarrass itself.
    private func retrieve(for question: String, before: Double) -> [ScoredPassage] {
        var found = callIndex.search(question, limit: options.candidateCount).filter {
            if case .thisCall(let at) = $0.passage.source { return at < before - 0.5 }
            return true
        }
        if let vault {
            found += vault.search(question, limit: options.candidateCount)
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(options.candidateCount))
    }

    static let answerSystemPrompt = """
    You answer one question asked in a meeting, using ONLY the numbered passages given to you.
    Reply with strict JSON and nothing else: {"passage": <number>, "answer": "<one sentence>"}
    `passage` is the number of the single passage your answer comes from.
    If no passage answers the question, reply exactly {"passage": 0, "answer": ""}.
    Never use knowledge from outside the passages. Never guess. Never explain.
    """

    static func answerPrompt(question: String, passages: [Passage]) -> String {
        let listed = passages.enumerated()
            .map { "[\($0.offset + 1)] \(condense($0.element.text))" }
            .joined(separator: "\n")
        return "QUESTION: \(question)\n\nPASSAGES:\n\(listed)\n\nReturn the JSON now."
    }

    struct ParsedAnswer { let passage: Int; let answer: String }

    /// Tolerant of the fences and preamble small models wrap JSON in.
    static func parseAnswer(_ raw: String) -> ParsedAnswer? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return nil
        }
        struct Shape: Decodable { let passage: Int?; let answer: String? }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: Data(raw[start...end].utf8)) else {
            return nil
        }
        return ParsedAnswer(passage: shape.passage ?? 0,
                            answer: (shape.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The guard that makes "never invents" a property of the code rather than
    /// of the prompt: most of what the answer asserts has to appear in the
    /// passage it cited. A model that ignores its instructions and answers from
    /// its own knowledge fails this and the card degrades to the bare question.
    static func isGrounded(answer: String, in passage: String) -> Bool {
        let answerTerms = Set(ExtractiveChatModel.tokenize(answer))
        guard !answerTerms.isEmpty else { return false }
        let passageTerms = Set(ExtractiveChatModel.tokenize(passage))
        let shared = answerTerms.intersection(passageTerms).count
        return Double(shared) / Double(answerTerms.count) >= 0.5
    }

    // MARK: - Facts

    /// One read of the recent window, producing both lanes the model feeds:
    /// where the discussion landed, and the figures worth keeping. One call
    /// rather than two — on-device generation is the budget here, and the two
    /// answers come from the same excerpt anyway.
    private func readWindow() async -> (topic: String?, conclusion: String?, facts: [String]) {
        let window = turns.suffix(options.factWindowTurns)
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        guard let reply = try? await model.chat(system: Self.readSystemPrompt, user: window,
                                                jsonFormat: true, maxTokens: 300),
              let parsed = Self.parseRead(reply) else { return (nil, nil, []) }

        // Same rule as an answer: if the excerpt doesn't support it, it doesn't
        // go on screen. The topic is exempt — it names the excerpt rather than
        // asserting anything about it, so there is nothing to ground it against.
        let conclusion = parsed.conclusion.flatMap { Self.isGrounded(answer: $0, in: window) ? $0 : nil }
        let facts = parsed.facts.filter { Self.isGrounded(answer: $0, in: window) }
        return (parsed.topic, conclusion, facts)
    }

    static let readSystemPrompt = """
    Read this meeting excerpt and report only what it actually says.
    Reply with strict JSON and nothing else: \
    {"topic": "...", "conclusion": "...", "facts": ["...", "..."]}
    `topic` names what this excerpt is about, as a noun phrase of at most five words. \
    Name the subject, not the activity: "Q3 pricing", never "a discussion" or "the \
    meeting". Small talk is a subject like any other — call it "weather" or "weekend \
    plans" rather than reaching for a work topic that is not being discussed.
    `conclusion` is one short sentence saying where the discussion landed — a decision, \
    an outcome, an agreement. Use "" if it did not land anywhere.
    `facts` are concrete figures and specifics: numbers, dates, names, owners, deadlines. \
    Each at most ten words. Use [] if there are none.
    Omit opinions and anything you are inferring rather than reading. Small talk belongs \
    in `topic`, never in `facts`.
    """

    struct ParsedRead { let topic: String?; let conclusion: String?; let facts: [String] }

    static func parseRead(_ raw: String) -> ParsedRead? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return nil
        }
        struct Shape: Decodable { let topic: String?; let conclusion: String?; let facts: [String]? }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: Data(raw[start...end].utf8)) else {
            return nil
        }
        let conclusion = shape.conclusion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = shape.topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedRead(
            topic: (topic?.isEmpty ?? true) ? nil : topic,
            conclusion: (conclusion?.isEmpty ?? true) ? nil : conclusion,
            facts: (shape.facts ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
    }

    // MARK: - Repetition

    /// The model restates the same point across overlapping windows, and a HUD
    /// that repeats itself is noise — but only *within* one topic. A figure
    /// raised again after the subject changed is the speaker saying it bears on
    /// this too, and hiding it would hide the point of the restatement.
    ///
    /// Asking the cards rather than keeping a running set is what makes that
    /// work. A set would have to be cleared at each boundary, and the pass that
    /// commits the boundary would then re-emit the facts it had just filed —
    /// filing them twice under the new topic.
    private func alreadyShown(_ fact: String, at: Double) -> Bool {
        let key = QuestionDetector.normalized(fact)
        return sameTopic(as: at).contains {
            $0.kind == .fact && QuestionDetector.normalized($0.headline) == key
        }
    }

    /// Only the conclusion *currently showing* counts as a restatement: a call
    /// that returns to an earlier landing point after covering other ground is
    /// saying something, where the same sentence twice running is not.
    private func restatesConclusion(_ conclusion: String, at: Double) -> Bool {
        let last = sameTopic(as: at).last { $0.kind == .conclusion }
        guard let last else { return false }
        return QuestionDetector.normalized(last.headline) == QuestionDetector.normalized(conclusion)
    }

    /// Cards filed under the same topic as something said at `at`.
    private func sameTopic(as at: Double) -> [OverlayCard] {
        guard let seg = segmenter.segment(containing: at) else { return cards }
        return cards.filter { seg.contains($0.at) }
    }

    // MARK: - Cards

    private func append(_ card: OverlayCard) {
        cards.append(card)
        if cards.count > options.maxCards { cards.removeFirst(cards.count - options.maxCards) }
        publish()
    }

    /// Passages go into a prompt and onto a HUD; a whole paragraph does neither
    /// any good. Cut at a sentence boundary when there is one nearby.
    static func condense(_ text: String, limit: Int = 400) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        if let stop = cut.lastIndex(of: "."), cut.distance(from: cut.startIndex, to: stop) > limit / 2 {
            return String(cut[...stop])
        }
        return cut + "…"
    }
}
