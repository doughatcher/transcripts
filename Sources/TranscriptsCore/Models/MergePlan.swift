import Foundation

/// Whether a set of recordings can be joined into one, and what the user should
/// be told before it happens.
///
/// The judgement this exists to make is not "are these the same meeting?" —
/// nothing can know that. It is which mistakes are cheap and which are not, and
/// they are not symmetric. Splitting one meeting in two leaves two notes that
/// already group together in the list. Merging two *different* meetings writes
/// one client's words into another's folder, quietly, and is unpleasant to
/// undo. So merging is always the user's explicit act, never inferred, and this
/// type's job is to make the doubtful cases visible before they commit to it.
public enum MergePlan {
    /// One recording being considered. `audioPath` is nil when the audio is gone
    /// — the caller checks the disk, because a path in the history is not proof.
    public struct Piece: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let startedAt: Date
        public let endedAt: Date?
        public let audioPath: String?
        /// Still recording or still processing. Its audio is not final yet.
        public let isBusy: Bool

        public init(id: UUID, title: String, startedAt: Date, endedAt: Date? = nil,
                    audioPath: String?, isBusy: Bool = false) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.audioPath = audioPath
            self.isBusy = isBusy
        }

        /// When this piece stopped occupying the timeline.
        public var finishedAt: Date { endedAt ?? startedAt }
    }

    /// A reason the merge cannot proceed at all.
    public enum Blocker: Equatable, Sendable {
        case needsTwo
        case stillRunning(String)
        case noAudio(String)

        public var message: String {
            switch self {
            case .needsTwo: return "Pick at least two recordings."
            case .stillRunning(let t): return "\"\(t)\" is still recording or processing."
            case .noAudio(let t): return "\"\(t)\" no longer has its audio."
            }
        }
    }

    /// A reason to look twice. Never blocks: a meeting really can change subject
    /// halfway through, and a real gap really can be a break rather than a
    /// different call. The user is the one who was in the room.
    public enum Caution: Equatable, Sendable {
        case differentSubjects([String])
        case longGap(minutes: Int)
        case spansDays

        public var message: String {
            switch self {
            case .differentSubjects(let titles):
                return "These do not look like the same meeting: \(titles.joined(separator: " · "))"
            case .longGap(let minutes):
                return "There is a \(minutes)-minute gap between two of these."
            case .spansDays:
                return "These were recorded on different days."
            }
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// Chronological, which is the order they will be laid on the timeline.
        public var ordered: [Piece]
        public var blockers: [Blocker]
        public var cautions: [Caution]

        public var isAllowed: Bool { blockers.isEmpty }
        /// Wall-clock span the merged recording will cover.
        public var span: TimeInterval {
            guard let first = ordered.first, let last = ordered.last else { return 0 }
            return last.finishedAt.timeIntervalSince(first.startedAt)
        }
    }

    /// Gap beyond which two pieces stop reading as one interrupted meeting.
    /// Deliberately the same window the recents list already uses to cluster
    /// back-to-back calls, so the two features cannot disagree about what
    /// "the same call" means.
    public static let suspiciousGap: TimeInterval = 25 * 60

    /// Title overlap at or above which two names are the same subject.
    public static let sameSubject = 0.6

    public static func plan(_ pieces: [Piece]) -> Outcome {
        let ordered = pieces.sorted { $0.startedAt < $1.startedAt }

        var blockers: [Blocker] = []
        if ordered.count < 2 { blockers.append(.needsTwo) }
        for p in ordered where p.isBusy { blockers.append(.stillRunning(p.title)) }
        for p in ordered where (p.audioPath ?? "").isEmpty { blockers.append(.noAudio(p.title)) }

        var cautions: [Caution] = []
        if ordered.count >= 2 {
            // Compared against the earliest title rather than pairwise: a meeting
            // that drifts subject reads as one chain of near-matches, and flagging
            // every adjacent pair would cry wolf on exactly that case.
            let anchor = ordered[0].title
            let strangers = ordered.dropFirst()
                .filter { TitleSimilarity.score(anchor, $0.title) < sameSubject }
                .map(\.title)
            if !strangers.isEmpty {
                cautions.append(.differentSubjects([anchor] + strangers))
            }

            let biggestGap = zip(ordered, ordered.dropFirst())
                .map { $1.startedAt.timeIntervalSince($0.finishedAt) }
                .max() ?? 0
            if biggestGap > suspiciousGap {
                cautions.append(.longGap(minutes: Int(biggestGap / 60)))
            }

            let cal = Calendar.current
            let days = Set(ordered.map { cal.startOfDay(for: $0.startedAt) })
            if days.count > 1 { cautions.append(.spansDays) }
        }

        return Outcome(ordered: ordered, blockers: blockers, cautions: cautions)
    }
}
