import Foundation
import Testing
@testable import TranscriptsCore

/// A `ChatModel` that returns whatever the test hands it, so the engine's
/// judgement can be exercised without a language model — including the case
/// that matters most: a model that ignores its instructions.
private struct StubModel: ChatModel {
    let reply: @Sendable (_ system: String, _ user: String) -> String

    init(_ reply: @escaping @Sendable (_ system: String, _ user: String) -> String) {
        self.reply = reply
    }
    init(always text: String) {
        self.reply = { _, _ in text }
    }

    func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
        reply(system, user)
    }
}

private struct FailingModel: ChatModel {
    struct Boom: Error {}
    func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
        throw Boom()
    }
}

@Suite struct QuestionDetectorTests {
    @Test func findsAQuestionMark() {
        #expect(QuestionDetector.isQuestion("When is the deadline?"))
        #expect(QuestionDetector.isQuestion("Who owns this?"))
    }

    /// Live speech-to-text punctuates unreliably, so the opener has to carry a
    /// question on its own or half of them are missed.
    @Test func findsAnUnpunctuatedQuestion() {
        #expect(QuestionDetector.isQuestion("what did we decide about the migration"))
        #expect(QuestionDetector.isQuestion("Did Priya sign off on the budget"))
    }

    @Test func ignoresStatements() {
        #expect(!QuestionDetector.isQuestion("We shipped it on Tuesday."))
        #expect(!QuestionDetector.isQuestion("I'll take that one."))
    }

    /// The noise case: question-shaped, nothing to retrieve.
    @Test func ignoresConversationalFiller() {
        #expect(!QuestionDetector.isQuestion("Right?"))
        #expect(!QuestionDetector.isQuestion("You know?"))
        #expect(!QuestionDetector.isQuestion("Does that make sense?"))
        #expect(!QuestionDetector.isQuestion("Can you hear me?"))
        #expect(!QuestionDetector.isQuestion("What do you think?"))
        #expect(!QuestionDetector.isQuestion("Any questions?"))
    }

    /// A tag hanging off the end of a real sentence is still a tag.
    @Test func ignoresTrailingTags() {
        #expect(!QuestionDetector.isQuestion("So we'd ship in March, does that make sense?"))
    }

    /// "make sense" mid-sentence is not a tag question.
    @Test func keepsAQuestionThatMerelyContainsATagPhrase() {
        #expect(QuestionDetector.isQuestion("Which part of the plan did not make sense to legal?"))
    }

    /// A turn that works up to its question is asking the last one.
    @Test func takesTheLastQuestionInATurn() {
        let turn = "We looked at both vendors. Which one did we land on?"
        #expect(QuestionDetector.question(in: turn) == "Which one did we land on?")
    }

    @Test func returnsNilWhenNothingIsAsked() {
        #expect(QuestionDetector.question(in: "That's fine by me. Let's move on.") == nil)
    }
}

@Suite struct PassageIndexTests {
    /// Writes a throwaway vault and hands back its root.
    ///
    /// Note the assertions below check note *titles*, not absolute paths: the
    /// temp directory is `/var/...` aliased to `/private/var/...` and the
    /// enumerator returns the latter, so pinning a full path would test macOS's
    /// temp-path aliasing rather than the index.
    func vault(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overlay-tests-\(UUID().uuidString)")
        for (path, body) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func ranksTheRelevantNoteFirst() throws {
        let root = try vault([
            "budget.md": "---\ntitle: \"Q3 budget\"\n---\n\nThe migration budget was capped at forty thousand dollars by finance.\n",
            "lunch.md": "# Lunch\n\nThe team liked the taco place on Fremont better than the sandwich shop.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let index = PassageIndex.vault(root: root)
        let hits = index.search("what was the migration budget capped at")
        #expect(hits.count >= 1)
        #expect(hits[0].passage.text.contains("forty thousand"))
        #expect(hits[0].passage.source.noteTitle == "Q3 budget")
        #expect(hits[0].passage.source.notePath?.hasSuffix("/budget.md") == true)
    }

    /// Without a title in frontmatter the filename is the honest label.
    @Test func fallsBackToTheFilenameForATitle() throws {
        let root = try vault([
            "Rollout notes.md": "The rollout is scheduled for the fourteenth of September this year.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let hits = PassageIndex.vault(root: root).search("when is the rollout scheduled")
        #expect(hits.first?.passage.source.noteTitle == "Rollout notes")
    }

    /// The failure this guards against is circular: the overlay writing the live
    /// transcript, then answering a question by quoting it back out of the file.
    @Test func skipsTheLiveTranscriptAndStagingFolders() throws {
        let root = try vault([
            "Transcripts Live.md": "Someone asked about the widget throughput numbers just now.\n",
            ".transcripts/live.md": "Someone asked about the widget throughput numbers just now.\n",
            "Inbox/dropped.md": "Someone asked about the widget throughput numbers just now.\n",
            "Processed/old.md": "Someone asked about the widget throughput numbers just now.\n",
            "real.md": "Widget throughput settled at nine hundred units per hour in testing.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let hits = PassageIndex.vault(root: root).search("widget throughput")
        #expect(hits.count == 1)
        #expect(hits[0].passage.text.contains("nine hundred"))
    }

    /// Headings are context, not answers — but their words should still find the
    /// paragraph underneath them.
    @Test func indexesHeadingWordsWithoutReturningTheHeading() throws {
        let root = try vault([
            "notes.md": "# Vendor selection\n\nWe went with the second one because their support hours matched ours.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let hits = PassageIndex.vault(root: root).search("vendor selection")
        #expect(hits.first?.passage.text.hasPrefix("We went with") == true)
    }

    @Test func returnsNothingWhenNoPassageSharesATerm() throws {
        let root = try vault(["notes.md": "The kitchen renovation starts in the spring, weather permitting.\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PassageIndex.vault(root: root).search("quarterly revenue forecast").isEmpty)
    }

    /// A large vault degrades to a partial index rather than eating memory.
    @Test func honoursThePassageCap() throws {
        var files: [String: String] = [:]
        for i in 0..<30 {
            files["note\(i).md"] = "Paragraph number \(i) discusses the quarterly revenue forecast in detail.\n"
        }
        let root = try vault(files)
        defer { try? FileManager.default.removeItem(at: root) }

        var limits = PassageIndex.Limits()
        limits.maxPassages = 5
        #expect(PassageIndex.vault(root: root, limits: limits).count <= 5)
    }

    @Test func skipsParagraphsTooShortToBeAnAnswer() throws {
        let root = try vault(["notes.md": "Yes.\n\nThe contract renewal window closes at the end of November.\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PassageIndex.vault(root: root).count == 1)
    }
}

@Suite struct OverlayGroundingTests {
    @Test func acceptsAnAnswerDrawnFromThePassage() {
        #expect(OverlayEngine.isGrounded(answer: "The budget was capped at forty thousand.",
                                         in: "Finance capped the migration budget at forty thousand dollars."))
    }

    /// The case the whole design exists for: a plausible sentence the passage
    /// does not support.
    @Test func rejectsAnAnswerFromNowhere() {
        #expect(!OverlayEngine.isGrounded(answer: "The vendor is headquartered in Reykjavik.",
                                          in: "Finance capped the migration budget at forty thousand dollars."))
    }

    @Test func rejectsAnAnswerWithNoContentWords() {
        #expect(!OverlayEngine.isGrounded(answer: "It is what it is.",
                                          in: "Finance capped the migration budget at forty thousand dollars."))
    }

    @Test func parsesJSONWrappedInFences() {
        let parsed = OverlayEngine.parseAnswer("```json\n{\"passage\": 2, \"answer\": \"March.\"}\n```")
        #expect(parsed?.passage == 2)
        #expect(parsed?.answer == "March.")
    }

    @Test func parsesTheNoAnswerReply() {
        #expect(OverlayEngine.parseAnswer(#"{"passage": 0, "answer": ""}"#)?.passage == 0)
    }

    @Test func survivesGarbage() {
        #expect(OverlayEngine.parseAnswer("I'm not sure I can help with that.") == nil)
    }
}

@Suite struct OverlayEngineTests {
    func engine(model: any ChatModel, vault: PassageIndex? = nil,
                options: OverlayEngine.Options = .init()) -> (OverlayEngine, @Sendable () -> OverlayDigest) {
        let box = Box()
        let engine = OverlayEngine(model: model, vault: vault, options: options,
                                   now: { Date(timeIntervalSince1970: 0) },
                                   onUpdate: { box.digest = $0 })
        return (engine, { box.digest })
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _digest = OverlayDigest()
        var digest: OverlayDigest {
            get { lock.lock(); defer { lock.unlock() }; return _digest }
            set { lock.lock(); _digest = newValue; lock.unlock() }
        }
    }

    /// No facts pass in these: `factInterval` is never reached because `now` is
    /// frozen and the first pass is consumed by the question.
    var questionsOnly: OverlayEngine.Options {
        OverlayEngine.Options(factInterval: .greatestFiniteMagnitude)
    }

    @Test func answersFromEarlierInTheCall() async {
        let model = StubModel(always: #"{"passage": 1, "answer": "Finance capped it at forty thousand."}"#)
        let (engine, _) = engine(model: model, options: questionsOnly)

        await engine.ingest(speaker: "Others", start: 10,
                            text: "Finance capped the migration budget at forty thousand dollars.")
        await engine.ingest(speaker: "Me", start: 300, text: "What was the migration budget capped at?")
        await engine.runPassNow()

        let cards = await engine.snapshot()
        #expect(cards.count == 1)
        #expect(cards[0].kind == .question)
        #expect(cards[0].answer == "Finance capped it at forty thousand.")
        #expect(cards[0].source == .thisCall(at: 10))
    }

    @Test func answersFromTheVault() async {
        let vault = PassageIndex(passages: [
            Passage(text: "The migration budget was capped at forty thousand dollars by finance.",
                    source: .note(title: "Q3 budget", path: "/vault/budget.md")),
        ])
        let model = StubModel(always: #"{"passage": 1, "answer": "It was capped at forty thousand dollars."}"#)
        let (engine, _) = engine(model: model, vault: vault, options: questionsOnly)

        await engine.ingest(speaker: "Others", start: 30, text: "What was the migration budget capped at?")
        await engine.runPassNow()

        let cards = await engine.snapshot()
        #expect(cards[0].source == .note(title: "Q3 budget", path: "/vault/budget.md"))
    }

    /// The headline guarantee. The model answers confidently from its own
    /// knowledge; the card must come back bare.
    @Test func dropsAnUngroundedAnswerToTheBareQuestion() async {
        let model = StubModel(always: #"{"passage": 1, "answer": "The vendor is headquartered in Reykjavik."}"#)
        let (engine, _) = engine(model: model, options: questionsOnly)

        await engine.ingest(speaker: "Others", start: 10,
                            text: "Finance capped the migration budget at forty thousand dollars.")
        await engine.ingest(speaker: "Me", start: 300, text: "What was the migration budget capped at?")
        await engine.runPassNow()

        let cards = await engine.snapshot()
        #expect(cards[0].answer == nil)
        #expect(cards[0].source == .unsourced)
        #expect(cards[0].headline == "What was the migration budget capped at?")
    }

    @Test func showsTheQuestionWhenNothingIsRetrieved() async {
        let model = StubModel(always: #"{"passage": 0, "answer": ""}"#)
        let (engine, _) = engine(model: model, options: questionsOnly)

        await engine.ingest(speaker: "Others", start: 30, text: "Who signed the Helvetica lease renewal?")
        await engine.runPassNow()

        let cards = await engine.snapshot()
        #expect(cards.count == 1)
        #expect(cards[0].source == .unsourced)
    }

    /// A question must never be answered by the turn that asked it.
    @Test func neverAnswersAQuestionWithItself() async {
        let model = StubModel(always: #"{"passage": 1, "answer": "The migration budget."}"#)
        let (engine, _) = engine(model: model, options: questionsOnly)

        await engine.ingest(speaker: "Me", start: 300, text: "What was the migration budget capped at?")
        await engine.runPassNow()

        #expect(await engine.snapshot()[0].source == .unsourced)
    }

    @Test func aFailingModelDegradesToTheBareQuestion() async {
        let (engine, _) = engine(model: FailingModel(), options: questionsOnly)
        await engine.ingest(speaker: "Others", start: 10,
                            text: "Finance capped the migration budget at forty thousand dollars.")
        await engine.ingest(speaker: "Me", start: 300, text: "What was the migration budget capped at?")
        await engine.runPassNow()

        #expect(await engine.snapshot()[0].source == .unsourced)
    }

    /// With only the extractive floor behind it there is no model to phrase an
    /// answer, so the overlay quotes and attributes instead of inventing.
    @Test func retrievalOnlyQuotesTheBestPassage() async {
        var options = questionsOnly
        options.retrievalOnly = true
        let (engine, _) = engine(model: ExtractiveChatModel(), options: options)

        await engine.ingest(speaker: "Others", start: 10,
                            text: "Finance capped the migration budget at forty thousand dollars.")
        await engine.ingest(speaker: "Me", start: 300, text: "What was the migration budget capped at?")
        await engine.runPassNow()

        let cards = await engine.snapshot()
        #expect(cards[0].answer == "Finance capped the migration budget at forty thousand dollars.")
        #expect(cards[0].source == .thisCall(at: 10))
    }

    @Test func collectsFactsAndDoesNotRepeatThem() async {
        let model = StubModel(always: #"{"conclusion": "", "facts": ["Rollout moved to 14 September", "Rollout moved to 14 September"]}"#)
        let (engine, _) = engine(model: model)

        await engine.ingest(speaker: "Others", start: 10,
                            text: "We moved the rollout to 14 September because of the freeze.")
        await engine.runPassNow()
        await engine.runPassNow()   // second pass, same window

        let facts = await engine.snapshot().filter { $0.kind == .fact }
        #expect(facts.count == 1)
        #expect(facts[0].headline == "Rollout moved to 14 September")
    }

    /// A "fact" the excerpt does not support is the same failure as an
    /// ungrounded answer.
    @Test func dropsAFactTheTranscriptDoesNotSupport() async {
        let model = StubModel(always: #"{"conclusion": "", "facts": ["Reykjavik office opens in the autumn"]}"#)
        let (engine, _) = engine(model: model)

        await engine.ingest(speaker: "Others", start: 10,
                            text: "We moved the rollout to 14 September because of the freeze.")
        await engine.runPassNow()

        #expect(await engine.snapshot().filter { $0.kind == .fact }.isEmpty)
    }

    @Test func surfacesTheConclusionLane() async {
        let model = StubModel(always: #"{"conclusion": "The rollout moved to 14 September.", "facts": []}"#)
        let (engine, digest) = engine(model: model)

        await engine.ingest(speaker: "Others", start: 10,
                            text: "We moved the rollout to 14 September because of the freeze.")
        await engine.runPassNow()

        #expect(digest().conclusion?.headline == "The rollout moved to 14 September.")
        #expect(digest().conclusion?.kind == .conclusion)
    }

    /// A conclusion is held to the same rule as an answer.
    @Test func dropsAConclusionTheTranscriptDoesNotSupport() async {
        let model = StubModel(always: #"{"conclusion": "Legal approved the Reykjavik lease.", "facts": []}"#)
        let (engine, digest) = engine(model: model)

        await engine.ingest(speaker: "Others", start: 10,
                            text: "We moved the rollout to 14 September because of the freeze.")
        await engine.runPassNow()

        #expect(digest().conclusion == nil)
    }

    /// The same landing point restated across overlapping windows is not news.
    @Test func doesNotRepeatTheSameConclusion() async {
        let model = StubModel(always: #"{"conclusion": "The rollout moved to 14 September.", "facts": []}"#)
        let (engine, _) = engine(model: model)

        await engine.ingest(speaker: "Others", start: 10,
                            text: "We moved the rollout to 14 September because of the freeze.")
        await engine.runPassNow()
        await engine.runPassNow()

        #expect(await engine.snapshot().filter { $0.kind == .conclusion }.count == 1)
    }

    /// The lane is a glance, not a log.
    @Test func theFactLaneKeepsOnlyTheMostRecentFewNewestFirst() async {
        var n = 0
        let model = StubModel { _, _ in
            n += 1
            return #"{"conclusion": "", "facts": ["Priya owns runbook number \#(n)"]}"#
        }
        // factInterval 0 so every pass reads the window; the clock is frozen, and
        // the default 20s floor would otherwise skip all but the first.
        let (engine, digest) = engine(model: model, options: .init(factInterval: 0))
        await engine.ingest(speaker: "Others", start: 10,
                            text: "Priya owns runbook number 1 and 2 and 3 and 4 and 5.")
        for _ in 0..<5 { await engine.runPassNow() }

        let facts = digest().facts
        #expect(facts.count == OverlayEngine.factLaneDepth)
        #expect(facts.first?.headline.contains("5") == true)   // newest first
    }

    @Test func ignoresBlankTurns() async {
        let (engine, digest) = engine(model: StubModel(always: #"{"facts": []}"#))
        await engine.ingest(speaker: "Me", start: 1, text: "   \n ")
        #expect(await engine.snapshot().isEmpty)
        #expect(digest().lastSpoken.isEmpty)
    }

    /// The pill must track the room, not the summarizer: the spoken line is
    /// published on ingest, before any model call happens.
    @Test func publishesTheSpokenLineImmediately() async {
        let model = StubModel(always: #"{"passage": 0, "answer": ""}"#)
        let (engine, digest) = engine(model: model, options: questionsOnly)
        await engine.ingest(speaker: "Others", start: 30, text: "Who signed the Helvetica lease renewal?")
        #expect(digest().lastSpoken == "Who signed the Helvetica lease renewal?")
        await engine.runPassNow()
        #expect(digest().lastQuestion?.source == .unsourced)
    }

    /// Replies chosen from the newest line of the window, not from a call
    /// counter. `ingest` schedules passes of its own, so a scripted stub
    /// desynchronises; keying on content makes every pass — scheduled or
    /// explicit — answer for the state it actually sees.
    fileprivate func reader(_ route: @escaping @Sendable (String) -> String) -> StubModel {
        StubModel { _, user in route(user.split(separator: "\n").last.map(String.init) ?? "") }
    }

    static let weatherThenPricing: @Sendable (String) -> String = { line in
        if line.contains("Snow") {
            return #"{"topic": "Weather", "conclusion": "", "facts": ["Snow expected on Tuesday"]}"#
        }
        if line.contains("14 September") {
            return #"{"topic": "Renewal pricing", "conclusion": "", "facts": ["Renewal decision due 14 September"]}"#
        }
        return #"{"topic": "Renewal pricing", "conclusion": "", "facts": ["Finance capped renewal at forty thousand"]}"#
    }

    /// Small talk at the top of the call, then the subject everyone joined for.
    /// The middle turn is read twice on purpose: a new topic has to survive two
    /// passes before it commits, which is the tangent guard doing its job.
    func weatherCall() async -> @Sendable () -> OverlayDigest {
        let (engine, digest) = engine(model: reader(Self.weatherThenPricing),
                                      options: .init(factInterval: 0))
        await engine.ingest(speaker: "Others", start: 10,
                            text: "Snow expected on Tuesday, they said, right through the weekend.")
        await engine.runPassNow()
        await engine.ingest(speaker: "Others", start: 60,
                            text: "On renewal pricing, finance capped renewal at forty thousand.")
        await engine.runPassNow()
        await engine.runPassNow()
        await engine.ingest(speaker: "Others", start: 120,
                            text: "So the renewal decision due 14 September, agreed.")
        await engine.runPassNow()
        return digest
    }

    /// The whole point of the feature. Ten minutes into the real conversation
    /// the lanes must not still be showing the weather from the opening.
    @Test func theOpeningSmallTalkLeavesTheLanesWhenTheTopicChanges() async {
        let digest = await weatherCall()
        let d = digest()
        #expect(d.currentTopic?.title == "Renewal pricing")
        #expect(!d.facts.map(\.headline).contains("Snow expected on Tuesday"))
        #expect(d.facts.map(\.headline).contains("Renewal decision due 14 September"))
    }

    /// And it is filed, not discarded — the weather is one page back.
    @Test func theEarlierTopicIsStillReachable() async {
        let d = await weatherCall()()
        #expect(d.topics.count == 2)
        #expect(d.topics[0].title == "Weather")
        #expect(d.topics[0].facts.map(\.headline).contains("Snow expected on Tuesday"))
        #expect(d.topics[1].isCurrent)
        #expect(d.currentTopicIndex == 1)
    }

    /// The boundary is committed where the new topic *started*, not where it was
    /// confirmed a pass later, so the cards from that gap move with it.
    @Test func theCardsFromTheConfirmingGapMoveWithTheBoundary() async {
        let d = await weatherCall()()
        #expect(d.topics[1].startedAt == 60)
        #expect(d.topics[1].facts.map(\.headline).contains("Finance capped renewal at forty thousand"))
    }

    /// Repeating a figure inside one topic is noise. Raising it again after the
    /// subject changed is the speaker saying it bears on this too, and hiding
    /// that would hide the point of the restatement.
    @Test func aFactRepeatsWhenItIsRaisedUnderANewTopic() async {
        let fact = "Finance capped renewal at forty thousand"
        let route: @Sendable (String) -> String = { line in
            let topic = line.contains("hiring") ? "Hiring plan" : "Renewal pricing"
            return #"{"topic": "\#(topic)", "conclusion": "", "facts": ["\#(fact)"]}"#
        }
        let (engine, _) = engine(model: reader(route), options: .init(factInterval: 0))

        await engine.ingest(speaker: "Others", start: 10,
                            text: "Finance capped renewal at forty thousand for the year.")
        await engine.runPassNow()
        await engine.runPassNow()
        await engine.ingest(speaker: "Others", start: 60,
                            text: "On the hiring plan, finance capped renewal at forty thousand there too.")
        await engine.runPassNow()
        await engine.runPassNow()
        await engine.runPassNow()

        let facts = await engine.snapshot().filter { $0.kind == .fact }
        #expect(facts.count == 2)                       // once per topic, not once per pass
        #expect(facts.allSatisfy { $0.headline == fact })
    }

    /// A model that never names a topic must not break the panel: one unnamed
    /// segment, lanes behaving exactly as they did before topics existed.
    @Test func aReplyWithNoTopicLeavesOneOpeningSegment() async {
        let model = StubModel(always: #"{"conclusion": "", "facts": ["Priya owns the runbook"]}"#)
        let (engine, digest) = engine(model: model, options: .init(factInterval: 0))
        await engine.ingest(speaker: "Others", start: 10, text: "Priya owns the runbook for this.")
        await engine.runPassNow()

        let d = digest()
        #expect(d.topics.count == 1)
        #expect(d.topics[0].title == "Opening")
        #expect(d.facts.map(\.headline) == ["Priya owns the runbook"])
    }
}

/// The segmenter decides where one subject ends and the next begins, with no
/// model involved — it is handed a name per pass and nothing else.
@Suite struct TopicSegmenterTests {
    func opened(_ titles: [(String, Double)]) -> TopicSegmenter {
        var s = TopicSegmenter()
        s.begin(at: 0)
        for (t, at) in titles { s.observe(title: t, at: at) }
        return s
    }

    /// A call starts before anyone knows what it is about, so the first name
    /// names the opening segment rather than splitting a second one off it.
    @Test func namesTheOpeningSegmentInsteadOfSplitting() {
        let s = opened([("Weather", 5)])
        #expect(s.segments.count == 1)
        #expect(s.current?.title == "Weather")
    }

    @Test func opensANewTopicOnceTheNameSticks() {
        let s = opened([("Weather", 5), ("Renewal pricing", 20), ("Renewal pricing", 35)])
        #expect(s.segments.count == 2)
        #expect(s.current?.title == "Renewal pricing")
    }

    @Test func holdsASingleSightingBack() {
        let s = opened([("Weather", 5), ("Renewal pricing", 20)])
        #expect(s.segments.count == 1)
    }

    @Test func forgetsACandidateThatDoesNotRecur() {
        let s = opened([("Weather", 5), ("Parking validation", 20), ("Weather", 35)])
        #expect(s.segments.count == 1)
        #expect(s.current?.title == "Weather")
    }

    /// Confirming costs a pass of latency. Committing at the first sighting
    /// hands it back, so the cards from that gap file under the new topic.
    @Test func theBoundaryLandsWhereTheNewTopicStarted() {
        let s = opened([("Weather", 5), ("Renewal pricing", 20), ("Renewal pricing", 35)])
        #expect(s.current?.startedAt == 20)
        #expect(s.segments[0].endedAt == 20)
    }

    /// The same subject named at two levels of detail is one subject.
    @Test func treatsARewordingAsTheSameTopic() {
        let s = opened([("Pricing", 5), ("Q3 pricing for enterprise", 20), ("Q3 pricing for enterprise", 35)])
        #expect(s.segments.count == 1)
    }

    /// Meetings circle back. "Pricing" twice in the pager is worse than not
    /// paging at all.
    @Test func reopensARecentTopicRatherThanListingItTwice() {
        let s = opened([("Weather", 5), ("Renewal pricing", 20), ("Renewal pricing", 35),
                        ("Weather", 50), ("Weather", 65)])
        #expect(s.segments.count == 2)
        #expect(s.current?.title == "Weather")
        #expect(s.current?.endedAt == nil)       // reopened, so cards land in it again
    }

    /// Without stripping filler words every "Discussion of X" title matches
    /// every other and the whole call collapses into one topic.
    @Test func doesNotMergeUnrelatedTitlesThatShareFillerWords() {
        #expect(TopicSegmenter.similarity("Discussion of the budget",
                                          "Discussion of the timeline") < TopicSegmenter.mergeThreshold)
    }

    @Test func matchesATitleAgainstItsLongerForm() {
        #expect(TopicSegmenter.similarity("Pricing",
                                          "Q3 pricing for enterprise") >= TopicSegmenter.mergeThreshold)
    }

    /// Cards are filed by when they were said, which is what lets a boundary
    /// land earlier than the pass that confirmed it.
    @Test func filesATimestampIntoTheRightSegment() {
        let s = opened([("Weather", 5), ("Renewal pricing", 20), ("Renewal pricing", 35)])
        #expect(s.segment(containing: 10)?.title == "Weather")
        #expect(s.segment(containing: 30)?.title == "Renewal pricing")
    }

    /// Returning to a topic must not swallow the one in between. A single range
    /// per topic cannot express that, which is why a topic holds spans.
    @Test func aReopenedTopicDoesNotSwallowTheOneInBetween() {
        let s = opened([("Weather", 5), ("Renewal pricing", 20), ("Renewal pricing", 35),
                        ("Weather", 50), ("Weather", 65)])
        #expect(s.segment(containing: 10)?.title == "Weather")
        #expect(s.segment(containing: 30)?.title == "Renewal pricing")
        #expect(s.segment(containing: 60)?.title == "Weather")
        #expect(s.current?.spans.count == 2)
    }

    /// An empty name is a model that had nothing to say, not a boundary.
    @Test func ignoresAnEmptyTitle() {
        let s = opened([("Weather", 5), ("", 20), ("", 35)])
        #expect(s.segments.count == 1)
        #expect(s.current?.title == "Weather")
    }
}


/// Restarting the app during a long recording must not cost you the recording.
/// These pin the decision that stands between an evening being picked back up
/// and being filed in halves.
@Suite struct RelaunchStateTests {
    func store() -> RelaunchState {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relaunch-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RelaunchState(directory: dir)
    }

    func marker(heartbeat: Date) -> RelaunchState.Marker {
        RelaunchState.Marker(startedAt: heartbeat, title: "D&D", isCall: false, heartbeatAt: heartbeat)
    }

    /// The rebuild case: the app was gone for seconds, the meeting is still on.
    @Test func aFreshMarkerResumes() {
        let s = store()
        let now = Date()
        s.writeMarker(marker(heartbeat: now.addingTimeInterval(-5)))
        #expect(s.resumableMarker(now: now)?.title == "D&D")
    }

    /// The Mac was closed and reopened another day. Resuming here would start
    /// recording out of nowhere, which is worse than filing.
    @Test func aStaleMarkerDoesNotResume() {
        let s = store()
        let now = Date()
        s.writeMarker(marker(heartbeat: now.addingTimeInterval(-RelaunchState.resumeWindow - 1)))
        #expect(s.resumableMarker(now: now) == nil)
    }

    /// And it is retired, so it cannot be reconsidered on the next launch.
    @Test func aStaleMarkerIsCleared() {
        let s = store()
        let now = Date()
        s.writeMarker(marker(heartbeat: now.addingTimeInterval(-RelaunchState.resumeWindow - 1)))
        _ = s.resumableMarker(now: now)
        #expect(s.loadMarker() == nil)
    }

    @Test func aDeliberateStopLeavesNothingToResume() {
        let s = store()
        s.writeMarker(marker(heartbeat: Date()))
        s.clearMarker()
        #expect(s.resumableMarker() == nil)
    }

    @Test func noMarkerMeansNothingToResume() {
        #expect(store().resumableMarker() == nil)
    }

    /// Fragments have to outlive the process — that is the whole point of
    /// writing them down.
    @Test func fragmentsRoundTrip() throws {
        let s = store()
        let audio = s.directory.appendingPathComponent("audio.caf")
        try Data("x".utf8).write(to: audio)
        let f = RelaunchState.Fragment(startedAt: Date(timeIntervalSince1970: 100),
                                       micAudioPath: audio.path,
                                       systemAudioPath: nil, systemAudioStartOffset: nil)
        s.saveFragments([f])
        #expect(s.loadFragments() == [f])
    }

    /// A fragment whose audio was pruned would fail assembly and take the good
    /// pieces down with it, so it is dropped on load.
    @Test func aFragmentWithNoAudioIsDropped() throws {
        let s = store()
        let real = s.directory.appendingPathComponent("audio.caf")
        try Data("x".utf8).write(to: real)
        s.saveFragments([
            .init(startedAt: Date(), micAudioPath: real.path, systemAudioPath: nil, systemAudioStartOffset: nil),
            .init(startedAt: Date(), micAudioPath: s.directory.appendingPathComponent("gone.caf").path,
                  systemAudioPath: nil, systemAudioStartOffset: nil),
        ])
        #expect(s.loadFragments().count == 1)
    }

    @Test func savingAnEmptyListClearsTheFile() throws {
        let s = store()
        let audio = s.directory.appendingPathComponent("audio.caf")
        try Data("x".utf8).write(to: audio)
        s.saveFragments([.init(startedAt: Date(), micAudioPath: audio.path,
                               systemAudioPath: nil, systemAudioStartOffset: nil)])
        s.saveFragments([])
        #expect(s.loadFragments().isEmpty)
    }

    /// A three-hour session must not age out mid-way.
    @Test func heartbeatKeepsALongSessionResumable() {
        let s = store()
        // Whole seconds: the marker is ISO-8601 on disk, so sub-second precision
        // does not survive the round trip.
        let started = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 10_000).rounded())
        s.writeMarker(marker(heartbeat: started))
        s.heartbeat()
        #expect(s.resumableMarker() != nil)
        // The original start time is preserved — only the heartbeat moves.
        #expect(s.loadMarker()?.startedAt == started)
    }
}

/// The overlay is draggable and remembers where it was put, which is exactly
/// what makes it possible to lose it for good. These pin the guard.
@Suite struct OverlayPlacementTests {
    let size = CGSize(width: 380, height: 44)
    /// One 1440×900 display with its origin at zero.
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func aPositionAlreadyOnScreenIsLeftAlone() {
        let wanted = CGPoint(x: 500, y: 880)
        #expect(OverlayPlacement.clamp(topLeft: wanted, size: size, screens: [main]) == wanted)
    }

    @Test func draggedOffTheRightEdgeComesBack() {
        let clamped = OverlayPlacement.clamp(topLeft: CGPoint(x: 1400, y: 880), size: size, screens: [main])
        #expect(clamped?.x == main.maxX - size.width)
    }

    @Test func draggedOffTheLeftEdgeComesBack() {
        #expect(OverlayPlacement.clamp(topLeft: CGPoint(x: -300, y: 880), size: size, screens: [main])?.x == 0)
    }

    @Test func draggedBelowTheBottomComesBack() {
        let clamped = OverlayPlacement.clamp(topLeft: CGPoint(x: 500, y: -50), size: size, screens: [main])
        #expect(clamped?.y == main.minY + size.height)
    }

    @Test func draggedAboveTheTopComesBack() {
        #expect(OverlayPlacement.clamp(topLeft: CGPoint(x: 500, y: 2000), size: size, screens: [main])?.y == main.maxY)
    }

    /// It should settle back onto the display it was already on, not jump to the
    /// primary one.
    @Test func staysOnTheScreenItMostlyOccupies() {
        let second = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let clamped = OverlayPlacement.clamp(topLeft: CGPoint(x: 2800, y: 880),
                                             size: size, screens: [main, second])
        #expect(clamped?.x == second.maxX - size.width)
    }

    /// The unplugged-monitor case: the remembered spot is nowhere, so it has to
    /// land somewhere reachable rather than stay lost.
    @Test func aPositionOnAVanishedDisplayLandsOnARealOne() {
        let clamped = OverlayPlacement.clamp(topLeft: CGPoint(x: 5000, y: 3000), size: size, screens: [main])
        #expect(clamped != nil)
        let rect = CGRect(x: clamped!.x, y: clamped!.y - size.height, width: size.width, height: size.height)
        #expect(main.contains(rect))
    }

    /// A screen smaller than the panel pins to its top-left corner rather than
    /// inverting the clamp and flinging it somewhere absurd. Top-left because
    /// that is where the readable end of the panel is.
    @Test func aScreenNarrowerThanThePanelPinsToTheCorner() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 200)
        let clamped = OverlayPlacement.clamp(topLeft: CGPoint(x: 900, y: 900), size: size, screens: [tiny])
        #expect(clamped == CGPoint(x: tiny.minX, y: tiny.maxY))
    }

    @Test func noScreensMeansNoPosition() {
        #expect(OverlayPlacement.clamp(topLeft: .zero, size: size, screens: []) == nil)
    }
}

/// Matching voices when one person has more than one of them — a player running
/// a character at a table, which is not an edge case in a game.
@Suite struct RoomVoiceMatchingTests {
    /// Two clearly different voiceprints for one person, plus a third person.
    let ownVoice: [Float] = [1, 0, 0, 0]
    let characterVoice: [Float] = [0, 1, 0, 0]
    let someoneElse: [Float] = [0, 0, 1, 0]

    /// The mean of two unlike voices matches neither. Taking the nearest sample
    /// is the whole point of keeping them separately.
    @Test func matchesTheNearestRememberedVoiceNotTheAverage() {
        let doug = SpeakerMatch.Profile(name: "Doug", embeddings: [ownVoice, characterVoice])
        #expect(doug.similarity(to: characterVoice) > 0.99)
        #expect(doug.similarity(to: ownVoice) > 0.99)

        // What the old averaged profile would have compared against.
        let averaged = SpeakerMatch.Profile(name: "Doug", embedding: VoiceMath.mean([ownVoice, characterVoice]))
        #expect(averaged.similarity(to: characterVoice) < 0.75)
    }

    /// A room: one person's normal voice and their character voice are two
    /// clusters, and both are them.
    @Test func aRoomLetsOnePersonOwnSeveralClusters() {
        let assignments = SpeakerMatch.assign(
            clusters: ["c1": ownVoice, "c2": characterVoice],
            profiles: [SpeakerMatch.Profile(name: "Doug", embeddings: [ownVoice, characterVoice])],
            threshold: 0.65, oneClusterPerPerson: false)
        #expect(assignments.allSatisfy { $0.name == "Doug" })
    }

    /// The call rule is untouched, and it is load-bearing: one voice after
    /// another claiming the same colleague is how a four-person call came out
    /// with seven people in it.
    @Test func aCallStillGivesEachPersonAtMostOneCluster() {
        let assignments = SpeakerMatch.assign(
            clusters: ["c1": ownVoice, "c2": characterVoice],
            profiles: [SpeakerMatch.Profile(name: "Doug", embeddings: [ownVoice, characterVoice])],
            threshold: 0.65)
        #expect(assignments.filter { $0.name == "Doug" }.count == 1)
        #expect(assignments.contains { $0.name == nil })
    }

    /// Loosening the rule must not start handing one person someone else's voice.
    @Test func aRoomStillRespectsTheThreshold() {
        let assignments = SpeakerMatch.assign(
            clusters: ["c1": ownVoice, "stranger": someoneElse],
            profiles: [SpeakerMatch.Profile(name: "Doug", embeddings: [ownVoice, characterVoice])],
            threshold: 0.65, oneClusterPerPerson: false)
        #expect(assignments.first { $0.cluster == "c1" }?.name == "Doug")
        #expect(assignments.first { $0.cluster == "stranger" }?.name == nil)
    }
}
