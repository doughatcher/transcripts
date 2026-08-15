import Foundation

/// One speaker as attributed in a specific meeting — the label that appears in
/// that transcript ("Tracy", "Speaker 1", "Me"), the embedding of their cluster,
/// and a clip to play back. This is the unit the review UI shows and a correction
/// reassigns: it links a transcript's speaker to the voiceprint behind it.
public struct MeetingSpeaker: Codable, Equatable, Sendable, Identifiable {
    /// The name as written in the transcript for this meeting. An enrolled match
    /// shows the profile name; an unknown voice shows "Speaker N".
    public var label: String
    /// The cluster's voiceprint this meeting — the sample a correction moves.
    public var embedding: [Float]
    /// A few seconds of this voice, kept per meeting so the review can play it.
    public var clipPath: String?
    /// The operator's own voice (not reassignable — it's you).
    public var isSelf: Bool

    public var id: String { label }

    public init(label: String, embedding: [Float], clipPath: String? = nil, isSelf: Bool = false) {
        self.label = label
        self.embedding = embedding
        self.clipPath = clipPath
        self.isSelf = isSelf
    }
}

/// The speaker attribution for one recording — everything needed to review and
/// correct who-said-what after the fact: the meeting's identity, its transcript,
/// and each detected speaker.
public struct MeetingAttribution: Codable, Equatable, Sendable, Identifiable {
    public var recordingID: String
    public var meetingName: String?
    public var meetingDate: Date
    /// The transcript document, so a reassignment can rewrite its speaker labels.
    public var transcriptPath: String?
    public var speakers: [MeetingSpeaker]

    public var id: String { recordingID }

    public init(recordingID: String, meetingName: String? = nil, meetingDate: Date,
                transcriptPath: String? = nil, speakers: [MeetingSpeaker]) {
        self.recordingID = recordingID
        self.meetingName = meetingName
        self.meetingDate = meetingDate
        self.transcriptPath = transcriptPath
        self.speakers = speakers
    }
}

/// JSON-file store of per-meeting attributions, newest first. Same durable,
/// human-inspectable posture as history.json and speakers.json.
public final class AttributionStore {
    private let url: URL
    private var records: [MeetingAttribution] = []
    /// Keep the file bounded — enough history to review recent misattributions,
    /// not unbounded. Oldest drop off (their per-meeting clips are pruned by the
    /// app's normal backup retention).
    public static let maxRecords = 200

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([MeetingAttribution].self, from: data) {
            records = decoded
        }
    }

    public var all: [MeetingAttribution] { records }

    public func attribution(recordingID: String) -> MeetingAttribution? {
        records.first { $0.recordingID == recordingID }
    }

    /// Upsert one meeting's attribution (replaces any prior record for the same
    /// recording — a reprocess supersedes the old attribution).
    public func record(_ attribution: MeetingAttribution) {
        records.removeAll { $0.recordingID == attribution.recordingID }
        records.insert(attribution, at: 0)
        if records.count > Self.maxRecords { records.removeLast(records.count - Self.maxRecords) }
        save()
    }

    /// Edit a stored attribution in place (e.g. after a reassignment).
    public func update(recordingID: String, _ mutate: (inout MeetingAttribution) -> Void) {
        guard let i = records.firstIndex(where: { $0.recordingID == recordingID }) else { return }
        mutate(&records[i])
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
