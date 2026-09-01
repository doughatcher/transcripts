import Foundation
import FluidAudio
import TranscriptsCore

/// On-device speaker diarization of the system-audio track via FluidAudio's
/// Core ML (pyannote-style) models, plus the voice-profile hooks (#6 Tier B):
///
/// - Enrolled profiles are handed to the diarizer up front, so a known voice's
///   cluster is born already named ("Tracy") instead of anonymous.
/// - The operator's own embedding is auto-refreshed from the mic track every
///   call (the one speaker Transcripts knows by construction) and enrolled as the
///   "Me" profile — which also makes own-voice bleed in the system track land
///   on "Me" instead of minting a phantom Speaker N.
/// - Every anonymous cluster's embedding is returned so a later confirm can
///   turn it into a profile without re-processing audio.
///
/// The models download once (or are staged by scripts/fetch-diarizer-models.sh
/// behind blocking proxies). Any failure throws — the caller degrades to
/// labeling the other side as a single voice; diarization never costs a recording.
public struct FluidAudioDiarizer: Diarizer {
    /// The profile name for the operator's own voice. TranscribeStage maps
    /// spans with this label onto the mic-track speaker ("Me").
    public static let selfName = "Me"

    public static var profilesURL: URL {
        HistoryStore.dir.appendingPathComponent("speakers.json")
    }

    public let rememberVoices: Bool
    /// Minimum cosine similarity to accept a name match; below it a voice stays
    /// anonymous (Me/Others). Higher = more conservative.
    public let matchThreshold: Float
    /// How readily two similar voices are treated as different people
    /// (FluidAudio's clustering threshold; lower = more speakers). Nil keeps the
    /// library default of 0.7.
    ///
    /// This is the only lever that actually moves the speaker count.
    /// `DiarizerConfig.numClusters` looks like the obvious one — "there are five
    /// of us" — but nothing in the library reads it; it is wired only through
    /// FluidAudio's own CLI. Setting it does nothing at all, which is worse than
    /// not having it.
    public let clusteringThreshold: Float?
    /// Loosen the gates for a room recording. The defaults are tuned for a call,
    /// where every participant talks at length; round a table someone may say
    /// two things all evening, and the stock one-second floor throws exactly
    /// those away.
    public let roomMode: Bool

    public init(rememberVoices: Bool = true, matchThreshold: Float = 0.65,
                clusteringThreshold: Float? = nil, roomMode: Bool = false) {
        self.rememberVoices = rememberVoices
        self.matchThreshold = matchThreshold
        self.clusteringThreshold = clusteringThreshold
        self.roomMode = roomMode
    }

    /// Diarizer settings for this run.
    ///
    /// Two things move, and only for a room. The minimum speech duration drops,
    /// because the one-second default is tuned for a call where everyone talks
    /// at length and it discards the person who said two things all evening.
    /// And the clustering threshold is exposed, because it is the only setting
    /// that changes how many people come out the other end.
    var diarizerConfig: DiarizerConfig {
        var config = DiarizerConfig.default
        if roomMode {
            // A "yeah, do it" is about 0.6s. One second discards it, and with it
            // the only evidence that person was ever in the room.
            config.minSpeechDuration = 0.5
            config.clusteringThreshold = Self.roomClusteringThreshold
        }
        if let clusteringThreshold {
            config.clusteringThreshold = clusteringThreshold
        }
        return config
    }

    /// Room recordings lean towards splitting rather than merging.
    ///
    /// The two errors are not symmetrical. Two people merged into one cluster
    /// cannot be pulled apart afterwards by any amount of naming — the evidence
    /// is gone. One person split across two clusters is fully recoverable: both
    /// clusters get named, and `SpeakerMatch` lets several of them belong to the
    /// same person. So when in doubt, split.
    ///
    /// That reasoning has a limit, and it was found empirically. At 0.65 a
    /// twelve-minute sample resolved into a sensible eight voices, but the same
    /// setting over a two-and-a-half-hour session produced **thirty-three** for a
    /// table of five: across an evening people lean in and back, get louder,
    /// tire, and a threshold tuned on a few minutes accumulates a new cluster
    /// for every one of those. Thirty voices is not a list anybody will sit down
    /// and name, so in practice it is no better than none.
    ///
    /// Measured on thirty minutes of real play at a five-person table:
    /// 0.65 → 11 voices, 0.70 → 8, **0.75 → 6**, 0.80 → 3. Six is the count that
    /// matches the room with a little room for character voices, so 0.75 it is —
    /// still on the splitting side of the library's 0.7 default, just not
    /// recklessly so.
    public static let roomClusteringThreshold: Float = 0.75

    public func diarize(track: URL, enrollSelfFrom: URL?) async throws -> DiarizationOutcome {
        // Pre-staged models (scripts/fetch-diarizer-models.sh, for machines whose
        // proxies block Hugging Face): lock FluidAudio to the cache. Offline mode
        // both skips the doomed network fetch and — critically — prevents the
        // "first load failed → purge cache → re-download" path from destroying a
        // valid staged cache behind a blocking proxy.
        let staged = DiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(ModelNames.Diarizer.segmentationFile)
        if FileManager.default.fileExists(atPath: staged.path) {
            ModelHub.offlineMode = true
        }
        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager(config: diarizerConfig)
        diarizer.initialize(models: models)
        let converter = AudioConverter()

        // We seed ONLY the operator's own voice. Own-voice bleed in the system
        // track then folds into the "Me" cluster (what FluidAudio's known-speaker
        // handling is good at). We deliberately do NOT seed other profiles: naming
        // the other participants is done in our own code below, from the real
        // per-segment embeddings, with a threshold we control — because delegating
        // it to the diarizer with no controllable gate is what stamped seven
        // colleagues onto a four-person call.
        var profiles: [SpeakerMatch.Profile] = []
        var affiliationByName: [String: String] = [:]
        if rememberVoices {
            let store = SpeakerProfileStore(url: Self.profilesURL)
            // Only from a track that is the operator alone. In a room the middle
            // minute of the microphone is whoever happened to be talking, and
            // enrolling it as "Me" would put the user's name on a friend's voice
            // — and then keep doing so on every future recording.
            if let micAudio = enrollSelfFrom, let samples = try? converter.resampleAudioFile(micAudio) {
                let window = 16_000 * 60
                let start = max(0, (samples.count - window) / 2)
                let slice = samples[start..<min(samples.count, start + window)]
                if slice.count >= 16_000 * 5,
                   let embedding = try? diarizer.extractSpeakerEmbedding(from: slice) {
                    store.enroll(name: Self.selfName, embedding: embedding, isSelf: true)
                }
            }
            if let me = store.selfProfile() {
                diarizer.initializeKnownSpeakers(
                    [Speaker(id: Self.selfName, name: Self.selfName,
                             currentEmbedding: me.embedding, isPermanent: true)])
            }
            // The candidates for our own matching: everyone but self.
            // Every remembered sample, not the profile's mean: see
            // SpeakerMatch.Profile — a person who does voices has more than one.
            profiles = store.profiles
                .filter { !$0.isSelf }
                .map { SpeakerMatch.Profile(name: $0.name, embeddings: $0.samples.map(\.embedding)) }
            for p in store.profiles where p.affiliation?.isEmpty == false {
                affiliationByName[p.name] = p.affiliation
            }
        }

        let samples = try converter.resampleAudioFile(track)
        let result = try diarizer.performCompleteDiarization(samples)

        // Real per-cluster voiceprints: the mean of each cluster's *segment*
        // embeddings (the voice actually heard this call), not a seeded profile.
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for seg in result.segments {
            guard !seg.embedding.isEmpty else { continue }
            if sums[seg.speakerId] == nil { sums[seg.speakerId] = [Float](repeating: 0, count: seg.embedding.count) }
            for i in seg.embedding.indices { sums[seg.speakerId]![i] += seg.embedding[i] }
            counts[seg.speakerId, default: 0] += 1
        }
        var embeddings: [String: [Float]] = [:]
        for (id, sum) in sums { embeddings[id] = sum.map { $0 / Float(counts[id] ?? 1) } }

        // Match the anonymous clusters (everything except the self cluster) to
        // enrolled voices ourselves — one-to-one, gated by `matchThreshold`.
        let anonymous = embeddings.filter { $0.key != Self.selfName }
        let assignments = SpeakerMatch.assign(clusters: anonymous, profiles: profiles,
                                              threshold: matchThreshold,
                                              oneClusterPerPerson: !roomMode)
        var rename: [String: String] = [:]          // cluster id → matched name
        var confidence: [String: Float] = [:]       // final label → confidence
        var affiliations: [String: String] = [:]    // final label → affiliation
        for a in assignments {
            guard let name = a.name else { continue }
            rename[a.cluster] = name
            // Several clusters can carry one name in a room; keep the best score
            // rather than whichever happened to be assigned last.
            confidence[name] = max(confidence[name] ?? 0, a.confidence)
            if let aff = affiliationByName[name] { affiliations[name] = aff }
        }
        if roomMode {
            Log.write("diarize: room mode found \(embeddings.count) voice(s) at sensitivity "
                      + String(format: "%.2f", diarizerConfig.clusteringThreshold)
                      + ", named \(rename.count) against \(profiles.count) profile(s)")
        } else if !profiles.isEmpty {
            Log.write("diarize: \(anonymous.count) other voice(s), named \(rename.count) at ≥\(String(format: "%.2f", matchThreshold)) against \(profiles.count) profile(s)")
        }

        let spans = result.segments.map {
            SpeakerSpan(speaker: rename[$0.speakerId] ?? $0.speakerId,
                        start: Double($0.startTimeSeconds),
                        end: Double($0.endTimeSeconds))
        }
        // Re-key embeddings to the final labels so downstream (suggestions,
        // attributions) sees named voices under their names.
        var finalEmbeddings: [String: [Float]] = [:]
        for (id, emb) in embeddings { finalEmbeddings[rename[id] ?? id] = emb }
        return DiarizationOutcome(spans: spans, embeddings: finalEmbeddings,
                                  confidence: confidence, affiliations: affiliations)
    }
}
