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

    public init(rememberVoices: Bool = true, matchThreshold: Float = 0.65) {
        self.rememberVoices = rememberVoices
        self.matchThreshold = matchThreshold
    }

    public func diarize(systemAudio: URL, micAudio: URL?) async throws -> DiarizationOutcome {
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
        let diarizer = DiarizerManager()
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
            if let micAudio, let samples = try? converter.resampleAudioFile(micAudio) {
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
            profiles = store.profiles
                .filter { !$0.isSelf }
                .map { SpeakerMatch.Profile(name: $0.name, embedding: $0.embedding) }
            for p in store.profiles where p.affiliation?.isEmpty == false {
                affiliationByName[p.name] = p.affiliation
            }
        }

        let samples = try converter.resampleAudioFile(systemAudio)
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
                                              threshold: matchThreshold)
        var rename: [String: String] = [:]          // cluster id → matched name
        var confidence: [String: Float] = [:]       // final label → confidence
        var affiliations: [String: String] = [:]    // final label → affiliation
        for a in assignments {
            guard let name = a.name else { continue }
            rename[a.cluster] = name
            confidence[name] = a.confidence
            if let aff = affiliationByName[name] { affiliations[name] = aff }
        }
        if !profiles.isEmpty {
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
