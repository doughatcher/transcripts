import Foundation

/// Vector math for voiceprints, kept pure and testable.
public enum VoiceMath {
    /// The elementwise mean of several embeddings — a profile's effective
    /// voiceprint is the mean of its per-meeting samples, so dropping a bad
    /// sample and re-deriving is exact (unlike a one-way running average).
    public static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        var n: Float = 0
        for v in vectors where v.count == acc.count {
            for i in 0..<acc.count { acc[i] += v[i] }
            n += 1
        }
        guard n > 0 else { return first }
        return acc.map { $0 / n }
    }

    /// Cosine similarity in −1…1; the diarizer's match confidence uses the same
    /// shape, so this is how the review UI can show "how sure."
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// One meeting's contribution to a voice profile — the embedding heard that call,
/// tagged with which recording it came from so a later correction can remove or
/// move exactly this sample. Storing samples (not a rolled-up average) is what
/// lets a misattribution be undone cleanly: drop the wrong sample, the voiceprint
/// re-derives without it.
public struct VoiceSample: Codable, Equatable, Sendable {
    /// The recording this sample was heard in (nil for legacy/rolled-up samples).
    public var meetingID: String?
    public var embedding: [Float]
    public var date: Date

    public init(meetingID: String? = nil, embedding: [Float], date: Date = Date()) {
        self.meetingID = meetingID
        self.embedding = embedding
        self.date = date
    }
}

/// One remembered voice: a set of per-meeting embedding **samples** (each a
/// biometric template — it can't reconstruct speech, but it identifies the
/// person) plus the name it was confirmed under. The effective voiceprint is the
/// mean of the samples, so correcting a bad attribution just removes that sample.
/// Local-only by design (#6 Tier B): profiles never leave the machine.
public struct SpeakerProfile: Codable, Equatable, Sendable {
    public var name: String
    /// Per-meeting samples; the voiceprint is their mean.
    public var samples: [VoiceSample]
    /// The operator's own voice (auto-enrolled from the mic track — the one
    /// speaker Transcripts knows by construction).
    public var isSelf: Bool
    public var updatedAt: Date
    /// A few seconds of this person's voice, kept so the Voices grid can play
    /// "who is this?" back. Recognizable audio, unlike the embedding — retained
    /// by explicit choice (#6); absent for self and pre-snippet profiles.
    public var sampleAudioPath: String?
    /// Who this person is with — the operator's home org for colleagues, a client
    /// or case name for external voices. Prefilled from the call's routing when
    /// enrolled, editable in the grid, and maintainable from the knowledge vault.
    public var affiliation: String?

    /// The effective voiceprint used for matching — the mean of all samples.
    public var embedding: [Float] { VoiceMath.mean(samples.map(\.embedding)) }
    /// How many meetings this voice has been heard in.
    public var meetings: Int { samples.count }

    public init(name: String, samples: [VoiceSample], isSelf: Bool = false,
                updatedAt: Date = Date(), sampleAudioPath: String? = nil,
                affiliation: String? = nil) {
        self.name = name
        self.samples = samples
        self.isSelf = isSelf
        self.updatedAt = updatedAt
        self.sampleAudioPath = sampleAudioPath
        self.affiliation = affiliation
    }

    /// Convenience for a single-embedding profile (tests, one-shot enroll).
    public init(name: String, embedding: [Float], meetings: Int = 1,
                isSelf: Bool = false, updatedAt: Date = Date(),
                sampleAudioPath: String? = nil, affiliation: String? = nil) {
        self.init(name: name, samples: [VoiceSample(embedding: embedding, date: updatedAt)],
                  isSelf: isSelf, updatedAt: updatedAt,
                  sampleAudioPath: sampleAudioPath, affiliation: affiliation)
    }

    private enum CodingKeys: String, CodingKey {
        case name, samples, isSelf, updatedAt, sampleAudioPath, affiliation
        case embedding, meetings   // legacy — a pre-samples profile
    }

    /// Tolerant decode with migration: a profile written before per-sample storage
    /// carried a single rolled-up `embedding` and a `meetings` count. Seed that as
    /// one sample so old stores keep working and the voiceprint is unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
        sampleAudioPath = try? c.decode(String.self, forKey: .sampleAudioPath)
        affiliation = try? c.decode(String.self, forKey: .affiliation)
        if let samples = try? c.decode([VoiceSample].self, forKey: .samples), !samples.isEmpty {
            self.samples = samples
        } else if let legacy = try? c.decode([Float].self, forKey: .embedding) {
            self.samples = [VoiceSample(embedding: legacy, date: updatedAt)]
        } else {
            self.samples = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(samples, forKey: .samples)
        try c.encode(isSelf, forKey: .isSelf)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(sampleAudioPath, forKey: .sampleAudioPath)
        try c.encodeIfPresent(affiliation, forKey: .affiliation)
    }
}

/// Deriving a speaker's likely affiliation from the meeting's routing. Pure so the
/// prefill logic is testable without the app.
public enum Affiliation {
    /// A call sorted into `Cases/<Client>/…` puts its outside voices with that
    /// client; anything else defaults to the operator's home org. The user always
    /// confirms, so this only has to be right often, not always.
    public static func suggested(destination: String?, homeOrg: String) -> String {
        guard let destination else { return homeOrg }
        let parts = destination.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0.caseInsensitiveCompare("Cases") == .orderedSame }),
           i + 1 < parts.count, !parts[i + 1].isEmpty {
            return parts[i + 1]
        }
        return homeOrg
    }

    /// Affiliations are a path: `Org / Group` (e.g. "Blue Acorn iCi / USP Project
    /// Team"). The top segment is the organization; the rest is the internal group,
    /// so a big org like Blue Acorn breaks into teams rather than one bucket. A
    /// plain string with no separator is just an org. Separator is " / ".
    public static let separator = " / "

    /// The organization — the first path segment.
    public static func org(of affiliation: String) -> String {
        affiliation.components(separatedBy: separator).first?
            .trimmingCharacters(in: .whitespaces) ?? affiliation
    }

    /// The group within the org (everything after the first segment), or nil for a
    /// bare org.
    public static func group(of affiliation: String) -> String? {
        let parts = affiliation.components(separatedBy: separator)
        guard parts.count > 1 else { return nil }
        let g = parts.dropFirst().joined(separator: separator).trimmingCharacters(in: .whitespaces)
        return g.isEmpty ? nil : g
    }

    /// The distinct organizations present among a set of affiliations, in first-seen
    /// order — what the transcript frontmatter records as "who was in the room."
    public static func orgs(in affiliations: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in affiliations {
            let o = org(of: a)
            guard !o.isEmpty, seen.insert(o.lowercased()).inserted else { continue }
            out.append(o)
        }
        return out
    }
}

/// A voice waiting for the user's confirm: Tier A's transcript evidence said
/// "Speaker 2 is Tracy" and diarization captured her embedding — but nothing
/// is remembered until the user says yes. Suggest-and-confirm IS the consent
/// gate for voices other than the operator's own.
public struct SpeakerSuggestion: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The transcript's guessed name, or empty for a voice we heard but couldn't
    /// name — the grid lets you listen and type who it is.
    public var name: String
    /// The diarizer's per-call display label ("Speaker 2"), so multiple unnamed
    /// cards from one meeting stay distinguishable.
    public var label: String
    public var embedding: [Float]
    public var sourceTitle: String
    public var suggestedAt: Date
    /// A few seconds of this voice, so naming is "listen, then name" rather than
    /// trusting a guess. nil when the cluster had no span long enough to sample.
    public var sampleAudioPath: String?
    /// Prefilled affiliation from the call's routing (home org or client/case);
    /// the user can override it before confirming.
    public var affiliation: String?
    /// The calendar meeting this voice was heard in — the *window* title Transcripts
    /// captured ("TE Ballpark Review"), not the summary title. With `meetingDate`
    /// this lets a maintenance skill match the meeting to its Outlook invite and
    /// pull the attendee list to propose names/affiliations.
    public var meetingName: String?
    /// When the meeting was recorded — the invite lookup key alongside the title.
    public var meetingDate: Date?
    /// The recording this voice came from — the key that tags the enrolled sample,
    /// so a later correction can find and move exactly this meeting's contribution.
    public var recordingID: String?

    /// True when the transcript actually named this voice (drives the high-signal
    /// menu banner; unnamed voices live in the grid only, never nag).
    public var isNamed: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    public init(id: UUID = UUID(), name: String, label: String = "",
                embedding: [Float], sourceTitle: String,
                suggestedAt: Date = Date(), sampleAudioPath: String? = nil,
                affiliation: String? = nil, meetingName: String? = nil,
                meetingDate: Date? = nil, recordingID: String? = nil) {
        self.id = id
        self.name = name
        self.label = label
        self.embedding = embedding
        self.sourceTitle = sourceTitle
        self.suggestedAt = suggestedAt
        self.sampleAudioPath = sampleAudioPath
        self.affiliation = affiliation
        self.meetingName = meetingName
        self.meetingDate = meetingDate
        self.recordingID = recordingID
    }
}

/// JSON-file store for voice profiles + pending suggestions + declined names.
/// Small, atomic, human-inspectable — same durability posture as history.json.
public final class SpeakerProfileStore {
    private struct FileShape: Codable {
        var profiles: [SpeakerProfile] = []
        var suggestions: [SpeakerSuggestion] = []
        var declinedNames: [String] = []
        /// Voiceprints of declined suggestions — "ignore" means ignore, not
        /// "ask again next meeting." A new anonymous cluster acoustically close to
        /// one of these is suppressed before it ever becomes a pending card.
        var declinedEmbeddings: [[Float]] = []

        init() {}

        // Tolerant decoding, same reason as everywhere else in this file: a struct
        // with default values still requires every key on decode UNLESS told
        // otherwise — an older speakers.json missing `declinedEmbeddings` would
        // otherwise fail to decode entirely and silently reset to empty, wiping the
        // user's whole voice store on the next save.
        private enum CodingKeys: String, CodingKey {
            case profiles, suggestions, declinedNames, declinedEmbeddings
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            profiles = (try? c.decode([SpeakerProfile].self, forKey: .profiles)) ?? []
            suggestions = (try? c.decode([SpeakerSuggestion].self, forKey: .suggestions)) ?? []
            declinedNames = (try? c.decode([String].self, forKey: .declinedNames)) ?? []
            declinedEmbeddings = (try? c.decode([[Float]].self, forKey: .declinedEmbeddings)) ?? []
        }
    }

    private let url: URL
    private var shape = FileShape()

    public private(set) var profiles: [SpeakerProfile] {
        get { shape.profiles }
        set { shape.profiles = newValue }
    }
    public var suggestions: [SpeakerSuggestion] { shape.suggestions }

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(FileShape.self, from: data) {
            shape = decoded
        }
    }

    public func profile(named name: String) -> SpeakerProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func suggestion(named name: String) -> SpeakerSuggestion? {
        shape.suggestions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func suggestion(id: UUID) -> SpeakerSuggestion? {
        shape.suggestions.first { $0.id == id }
    }

    /// Most pending voices to keep at once, so unnamed voices you never get around
    /// to naming can't grow without bound. Oldest drop off first.
    public static let maxPendingSuggestions = 24

    /// Cosine similarity above which a new voice is treated as "the same one
    /// already ignored" rather than a fresh stranger.
    public static let declinedSimilarityThreshold: Float = 0.75
    /// Bounds the ignore list the same way profile samples are bounded — oldest
    /// declines age out rather than growing the file forever.
    public static let maxDeclinedEmbeddings = 100

    public func selfProfile() -> SpeakerProfile? {
        profiles.first { $0.isSelf }
    }

    /// Most per-meeting samples to keep per profile — enough that the mean is
    /// stable and fresh, bounded so a daily-standup regular can't grow the file
    /// forever. Oldest samples drop off first.
    public static let maxSamplesPerProfile = 20

    /// Adds this meeting's sample to a voice's profile (creating it if new). The
    /// voiceprint is the mean of the samples, so a later correction can drop a bad
    /// one exactly. Re-enrolling from the *same* meeting replaces that meeting's
    /// sample rather than double-counting. A new `sampleAudioPath` replaces the old
    /// one (freshest clip wins); pass nil to keep whatever's there.
    public func enroll(name: String, embedding: [Float], isSelf: Bool = false,
                       sampleAudioPath: String? = nil, affiliation: String? = nil,
                       meetingID: String? = nil) {
        let sample = VoiceSample(meetingID: meetingID, embedding: embedding, date: Date())
        if let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            var p = profiles[i]
            if let meetingID, let si = p.samples.firstIndex(where: { $0.meetingID == meetingID }) {
                p.samples[si] = sample                    // same meeting → replace
            } else {
                p.samples.append(sample)
            }
            if p.samples.count > Self.maxSamplesPerProfile {
                p.samples.removeFirst(p.samples.count - Self.maxSamplesPerProfile)
            }
            p.updatedAt = Date()
            if let sampleAudioPath { p.sampleAudioPath = sampleAudioPath }
            if let affiliation { p.affiliation = affiliation }
            profiles[i] = p
        } else {
            profiles.append(SpeakerProfile(name: name, samples: [sample], isSelf: isSelf,
                                           sampleAudioPath: sampleAudioPath, affiliation: affiliation))
        }
        shape.declinedNames.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        save()
    }

    /// Removes the sample a given meeting contributed to a profile — the surgical
    /// half of fixing a misattribution. If it was the profile's last sample the
    /// profile is removed entirely. Returns the removed sample (to move elsewhere),
    /// or nil when this meeting never contributed to that profile (a match-only
    /// mislabel, where the transcript was wrong but the voiceprint stayed clean).
    @discardableResult
    public func removeSample(fromProfileNamed name: String, meetingID: String) -> VoiceSample? {
        guard let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              let si = profiles[i].samples.firstIndex(where: { $0.meetingID == meetingID })
        else { return nil }
        let removed = profiles[i].samples.remove(at: si)
        if profiles[i].samples.isEmpty {
            profiles.remove(at: i)
        } else {
            profiles[i].updatedAt = Date()
        }
        save()
        return removed
    }

    /// Update just the affiliation of an enrolled profile (grid edit, or a future
    /// vault-maintenance pass). Empty string clears it.
    public func setAffiliation(name: String, to affiliation: String) {
        guard let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        let trimmed = affiliation.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[i].affiliation = trimmed.isEmpty ? nil : trimmed
        profiles[i].updatedAt = Date()
        save()
    }

    /// Removes a profile and returns it, so the caller can clean up the snippet
    /// file the JSON only referenced.
    @discardableResult
    public func remove(name: String) -> SpeakerProfile? {
        guard let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        let removed = profiles.remove(at: i)
        save()
        return removed
    }

    /// Queues a voice for naming. A **named** guess (transcript evidence) is
    /// deduped: skipped if that name is already enrolled, already pending, or was
    /// declined, so it never re-nags. An **unnamed** voice (empty name) — one we
    /// heard but couldn't identify — is always queued so it can be named by ear;
    /// the pending list is capped so these can't pile up forever.
    /// Returns the queued suggestion's id, or nil when a named guess was deduped.
    @discardableResult
    public func suggest(name: String, label: String = "", embedding: [Float],
                        sourceTitle: String, sampleAudioPath: String? = nil,
                        affiliation: String? = nil, meetingName: String? = nil,
                        meetingDate: Date? = nil, recordingID: String? = nil) -> UUID? {
        let named = !name.trimmingCharacters(in: .whitespaces).isEmpty
        if named {
            guard profile(named: name) == nil,
                  !shape.suggestions.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  !shape.declinedNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { return nil }
        }
        // "Ignore" means ignore: a voice acoustically close to one already
        // declined doesn't get a fresh pending card next meeting.
        if shape.declinedEmbeddings.contains(where: { VoiceMath.cosine($0, embedding) >= Self.declinedSimilarityThreshold }) {
            return nil
        }
        let suggestion = SpeakerSuggestion(name: name, label: label, embedding: embedding,
                                           sourceTitle: sourceTitle, sampleAudioPath: sampleAudioPath,
                                           affiliation: affiliation, meetingName: meetingName,
                                           meetingDate: meetingDate, recordingID: recordingID)
        shape.suggestions.append(suggestion)
        // Cap: drop the oldest, preferring to evict still-unnamed voices so a
        // transcript-named guess isn't lost to a pile of anonymous ones.
        if shape.suggestions.count > Self.maxPendingSuggestions {
            if let i = shape.suggestions.firstIndex(where: { !$0.isNamed }) {
                dropSuggestion(at: i)
            } else {
                dropSuggestion(at: 0)
            }
        }
        save()
        return suggestion.id
    }

    /// Removes a suggestion by index, deleting its pending clip so evicted voices
    /// don't leave orphan audio behind.
    private func dropSuggestion(at index: Int) {
        let s = shape.suggestions.remove(at: index)
        s.sampleAudioPath.map { try? FileManager.default.removeItem(atPath: $0) }
    }

    /// Confirm → enrolled profile; decline → remembered so it isn't re-asked.
    /// Returns the resolved suggestion (with its snippet path) so the caller can
    /// move the clip into durable storage on accept, or delete it on decline.
    /// `enrolledSamplePath` overrides the stored path when the caller has already
    /// relocated the clip to its permanent home.
    @discardableResult
    public func resolveSuggestion(name: String, accept: Bool,
                                  enrolledSamplePath: String? = nil) -> SpeakerSuggestion? {
        guard let i = shape.suggestions.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        let s = shape.suggestions.remove(at: i)
        if accept {
            enroll(name: s.name, embedding: s.embedding,
                   sampleAudioPath: enrolledSamplePath ?? s.sampleAudioPath)
        } else {
            shape.declinedNames.append(s.name)
            if !s.embedding.isEmpty { shape.declinedEmbeddings.append(s.embedding) }
            save()
        }
        return s
    }

    /// Confirm a suggestion under a possibly-corrected name — the grid lets the
    /// user fix the transcript's guess before enrolling. Removes the pending entry
    /// (without declining, so a corrected name doesn't blacklist the original) and
    /// enrolls under `finalName`. Returns the resolved suggestion.
    @discardableResult
    public func confirmSuggestion(originalName: String, as finalName: String,
                                  enrolledSamplePath: String? = nil) -> SpeakerSuggestion? {
        guard let i = shape.suggestions.firstIndex(where: {
            $0.name.caseInsensitiveCompare(originalName) == .orderedSame
        }) else { return nil }
        return confirm(at: i, as: finalName, enrolledSamplePath: enrolledSamplePath)
    }

    /// Confirm a specific suggestion by id — the grid's path, since unnamed voices
    /// share no distinguishing name. `finalName` is the name the user typed;
    /// `affiliation` overrides the prefilled guess when the user edited it.
    @discardableResult
    public func confirmSuggestion(id: UUID, as finalName: String,
                                  affiliation: String? = nil,
                                  enrolledSamplePath: String? = nil) -> SpeakerSuggestion? {
        guard let i = shape.suggestions.firstIndex(where: { $0.id == id }) else { return nil }
        return confirm(at: i, as: finalName, affiliation: affiliation,
                       enrolledSamplePath: enrolledSamplePath)
    }

    private func confirm(at i: Int, as finalName: String, affiliation: String? = nil,
                         enrolledSamplePath: String?) -> SpeakerSuggestion {
        let s = shape.suggestions.remove(at: i)
        let name = finalName.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = (affiliation ?? s.affiliation)?.trimmingCharacters(in: .whitespacesAndNewlines)
        enroll(name: name.isEmpty ? s.name : name, embedding: s.embedding,
               sampleAudioPath: enrolledSamplePath ?? s.sampleAudioPath,
               affiliation: (org?.isEmpty ?? true) ? nil : org,
               meetingID: s.recordingID)
        return s
    }

    /// Decline a specific suggestion by id — this both removes it now and keeps it
    /// from resurfacing: a named guess is remembered by name (won't re-suggest that
    /// name), and its voiceprint is banked so a future occurrence of the same voice
    /// — named or not — is suppressed before it becomes a new card.
    @discardableResult
    public func declineSuggestion(id: UUID) -> SpeakerSuggestion? {
        guard let i = shape.suggestions.firstIndex(where: { $0.id == id }) else { return nil }
        let s = shape.suggestions.remove(at: i)
        if s.isNamed { shape.declinedNames.append(s.name) }
        if !s.embedding.isEmpty {
            shape.declinedEmbeddings.append(s.embedding)
            if shape.declinedEmbeddings.count > Self.maxDeclinedEmbeddings {
                shape.declinedEmbeddings.removeFirst(shape.declinedEmbeddings.count - Self.maxDeclinedEmbeddings)
            }
        }
        save()
        return s
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(shape) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
