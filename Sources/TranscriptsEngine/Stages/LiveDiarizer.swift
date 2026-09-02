import AVFoundation
import FluidAudio
import Foundation
import TranscriptsCore

/// Names the voice behind each live turn on a shared microphone, while the
/// recording is still going.
///
/// The live transcript has only ever had two labels: "Me" for whatever the
/// microphone hears and "Others" for system audio. On a call that is right —
/// the two sides arrive on two tracks. In a room it is wrong by construction:
/// three people round a table, or a film playing into the room, all land on the
/// mic and all become "Me", and stay that way until the batch pass at the end
/// runs a proper diarization. This closes that gap for the duration of the
/// call, at lower fidelity than the batch pass and with no claim otherwise.
///
/// Not a rolling re-diarization. `performCompleteDiarization` is whole-file; run
/// every few seconds on everything so far it costs O(n²) over a call and moves
/// labels the user has already read. Instead each finalized turn is embedded
/// on its own — `extractSpeakerEmbedding` takes any slice — and handed to the
/// library's online `SpeakerManager`, which either matches it to a voice heard
/// earlier this call or opens a new one. Same distance threshold the batch pass
/// clusters with, so the "Telling voices apart" slider means one thing.
///
/// What it cannot do, stated plainly: a turn under a second has no usable
/// embedding and inherits the previous label; a voice that drifts (someone
/// leans back, gets tired) may open a second cluster with no way to merge it
/// later; and nothing here is ever revised. The batch pass remains the record.
public final class LiveDiarizer: @unchecked Sendable {
    public static let sampleRate = 16_000
    /// Below this a turn can join a voice but not start one. See `resolve`.
    static let minNewVoiceSeconds: Float = 1.5

    private let queue = DispatchQueue(label: "ltd.hatcher.transcripts.livediarize")
    private let converter = AudioConverter(sampleRate: Double(LiveDiarizer.sampleRate))
    private var diarizer: DiarizerManager?
    private let threshold: Float
    private let assignThreshold: Float
    private let matchThreshold: Float
    private let rememberVoices: Bool

    /// The last `capacity` samples of the mic, at 16 kHz mono. The analyzer
    /// finalizes a phrase seconds after the audio that carried it, so a couple
    /// of minutes is generous; the harness widens it so a file can be replayed
    /// faster than real time without the ring lapping the transcriber.
    private var ring: [Float]
    private let capacity: Int
    /// Total samples ever fed. Timeline seconds × 16 000 is an index into this
    /// count, and `written - capacity` is the oldest sample still in the ring.
    private var written = 0

    /// Diarizer ids → the labels the transcript uses ("Speaker 2", or an
    /// enrolled name), in order of first appearance — the same convention
    /// `SpeakerTurns.labelMap` applies to the batch result.
    private var labels: [String: String] = [:]
    private var nextAnonymous = 1
    private var lastLabel: String?
    private var profiles: [SpeakerMatch.Profile] = []

    public init(clusteringThreshold: Float? = nil, matchThreshold: Float = 0.65,
                rememberVoices: Bool = true, windowSeconds: Double = 120) {
        // Room defaults, deliberately: this only runs when the mic is a room.
        threshold = clusteringThreshold ?? FluidAudioDiarizer.roomClusteringThreshold
        // ×1.2 is not a tuning knob; it is what `DiarizerManager` does to the
        // same number before handing it to its own `SpeakerManager`, so the
        // slider means one thing in both passes. Passed raw, a 0.60 that gives
        // two voices in batch gave thirteen here, every split a near miss
        // between 0.60 and 0.72.
        assignThreshold = threshold * 1.2
        self.matchThreshold = matchThreshold
        self.rememberVoices = rememberVoices
        capacity = Int(windowSeconds * Double(Self.sampleRate))
        ring = [Float](repeating: 0, count: capacity)
    }

    /// Loads the models and seeds the operator's own voice. Returns false when
    /// diarization cannot run; every `label` then answers nil and the caller's
    /// fallback ("Me") is exactly what the live transcript did before.
    public func start() async -> Bool {
        do {
            // Same staging rule as the batch diarizer: a pre-fetched cache is
            // locked offline so a blocking proxy cannot purge it mid-load.
            let staged = DiarizerModels.defaultModelsDirectory()
                .appendingPathComponent(ModelNames.Diarizer.segmentationFile)
            if FileManager.default.fileExists(atPath: staged.path) {
                ModelHub.offlineMode = true
            }
            let models = try await DiarizerModels.downloadIfNeeded()
            var config = DiarizerConfig.default
            // A "yeah, do it" is about 0.6 s — the same floor the room batch uses.
            config.minSpeechDuration = 0.5
            config.clusteringThreshold = threshold
            let manager = DiarizerManager(config: config)
            manager.initialize(models: models)

            // Seed only the operator's own voice, exactly as the batch pass does,
            // so that when the operator does speak it says "Me" and not
            // "Speaker 3". Other remembered voices are matched by our own code
            // with a threshold we control — delegating that to the diarizer is
            // what once stamped seven colleagues onto a four-person call.
            if rememberVoices {
                let store = SpeakerProfileStore(url: FluidAudioDiarizer.profilesURL)
                if let me = store.selfProfile() {
                    manager.initializeKnownSpeakers(
                        [Speaker(id: FluidAudioDiarizer.selfName, name: FluidAudioDiarizer.selfName,
                                 currentEmbedding: me.embedding, isPermanent: true)])
                }
                profiles = store.profiles
                    .filter { !$0.isSelf }
                    .map { SpeakerMatch.Profile(name: $0.name, embeddings: $0.samples.map(\.embedding)) }
            }
            queue.sync { diarizer = manager }
            Log.write("livediarize: ready at sensitivity \(String(format: "%.2f", threshold)), \(profiles.count) remembered voice(s)")
            return true
        } catch {
            Log.write("livediarize: unavailable (\(error)) — live turns stay \"Me\"")
            return false
        }
    }

    /// Feeds one mic buffer. Cheap and non-blocking for the capture path: the
    /// resample and the ring write happen on this object's own queue.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let samples = try? converter.resampleBuffer(buffer), !samples.isEmpty else { return }
            for s in samples {
                ring[written % capacity] = s
                written += 1
            }
        }
    }

    /// The label for a finalized turn spanning `start`…`end` seconds on the
    /// transcriber's timeline. nil when no verdict is possible — models not
    /// ready, audio gone from the ring, turn too short or too quiet to embed —
    /// in which case the caller keeps whatever it would have said anyway.
    public func label(start: Double, end: Double) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: resolve(start: start, end: end))
            }
        }
    }

    private func resolve(start: Double, end: Double) -> String? {
        guard let diarizer else { return nil }
        let first = Int(start * Double(Self.sampleRate))
        let last = min(Int(end * Double(Self.sampleRate)), written)
        guard first >= max(0, written - capacity), last > first else {
            return refuse("ring", String(format: "%.1f–%.1fs asked, %.1fs fed, %.0fs held",
                                         start, end, Double(written) / Double(Self.sampleRate),
                                         Double(capacity) / Double(Self.sampleRate)))
        }
        var slice = [Float](repeating: 0, count: last - first)
        for i in 0..<slice.count { slice[i] = ring[(first + i) % capacity] }

        // The library refuses under a second, or under a whisper. Rather than
        // guess at a voice from nothing, a short interjection is taken to be the
        // person who was already talking — wrong sometimes, but wrong the way a
        // listener is wrong, not the way a random label is.
        let duration = Float(slice.count) / Float(Self.sampleRate)
        // Each refusal is named, because the failure mode of this whole feature
        // is silent: a turn that cannot be labeled quietly says "Me", which is
        // indistinguishable from the feature not existing. Rate-limited per
        // reason so a quiet room does not write a line per phrase.
        // Not the library's `validateAudio`. Its fixed RMS floor of 0.01 was
        // tuned for a voice close to a microphone; a film playing into the room,
        // or three people round a table, comes in well under it and every turn
        // was refused as "too quiet" — while the batch pass, which never gates
        // on level, named the same voices fine. The slice is a finalized phrase,
        // so it holds speech by construction: bring it up to a working level
        // and refuse only digital silence and the sub-second turns the model
        // has no view on.
        guard duration >= 1.0 else {
            return refuse("short", "\(String(format: "%.1f", duration))s")
        }
        let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        guard rms >= 1e-3 else {
            return refuse("silent", String(format: "%.1fs at rms %.4f", duration, rms))
        }
        let peak = slice.reduce(0) { max($0, abs($1)) }
        let gain = min(0.05 / rms, 0.95 / max(peak, 1e-6))
        if abs(gain - 1) > 0.01 { for i in slice.indices { slice[i] *= gain } }
        let embedding: [Float]
        do { embedding = try diarizer.extractSpeakerEmbedding(from: slice) } catch {
            return refuse("embed", "\(String(format: "%.1f", duration))s: \(error)")
        }
        guard diarizer.validateEmbedding(embedding) else {
            return refuse("embedding", "\(embedding.count) dims rejected")
        }
        // The raw distance to the nearest voice heard so far, before the
        // threshold is applied — the number that says whether a split was a
        // near miss or a different person. Logged for the first turns only.
        let nearest = diarizer.speakerManager.findSpeaker(with: embedding, speakerThreshold: 10)
        // The extractor pads every slice into a fixed ten-second window, so a
        // short turn is mostly zeros and its embedding is mostly noise: the two
        // wildest distances on record (0.87, 0.96) were both under 1.5 s. Such a
        // turn may still *match* a voice already heard — a "yeah" lands near its
        // owner — but it does not get to open a new one on that evidence.
        if duration < Self.minNewVoiceSeconds, nearest.distance > assignThreshold {
            return refuse("short-new", String(format: "%.1fs, nearest %.3f", duration, nearest.distance))
        }
        guard let speaker = diarizer.speakerManager.assignSpeaker(
            embedding, speechDuration: duration, speakerThreshold: assignThreshold)
        else { return refuse("assign", "\(String(format: "%.1f", duration))s, \(embedding.count) dims → nil") }
        decisions += 1
        if decisions <= 24 {
            Log.write(String(format: "livediarize: %.1fs → %@ (nearest %@ at %.3f, assign at %.2f)",
                             duration, speaker.id, nearest.id ?? "none", nearest.distance, assignThreshold))
        }
        // A voice's first embedding is its noisiest, so two clusters can open
        // for one person before there is enough of them to tell. Every few
        // turns, fold together any pair now within threshold of each other.
        // Earlier turns keep the name they were shown with; from here on the
        // voice has one.
        if decisions % 8 == 0 {
            for pair in diarizer.speakerManager.findMergeablePairs(speakerThreshold: assignThreshold) {
                diarizer.speakerManager.mergeSpeaker(pair.speakerToMerge, into: pair.destination)
                if let kept = labels[pair.destination] {
                    Log.write("livediarize: merged \(labels[pair.speakerToMerge] ?? pair.speakerToMerge) into \(kept)")
                    labels[pair.speakerToMerge] = kept
                }
            }
        }

        let label: String
        if speaker.isPermanent, speaker.name == FluidAudioDiarizer.selfName {
            label = FluidAudioDiarizer.selfName
        } else if let known = labels[speaker.id] {
            label = known
        } else {
            // First time this voice has been heard this call. Try the remembered
            // voices before minting a number; a room may map several clusters to
            // one person and that is allowed, as it is in the batch pass.
            var best: (name: String, score: Float)? = nil
            for p in profiles {
                let score = p.similarity(to: embedding)
                if score >= matchThreshold, score > (best?.score ?? 0) { best = (p.name, score) }
            }
            if let best {
                label = best.name
            } else {
                label = "Speaker \(nextAnonymous)"
                nextAnonymous += 1
            }
            labels[speaker.id] = label
        }
        lastLabel = label
        return label
    }

    private var refusals: [String: Int] = [:]
    private var decisions = 0
    /// Logs the first few refusals of each kind, then counts silently.
    private func refuse(_ reason: String, _ detail: String) -> String? {
        let n = (refusals[reason] ?? 0) + 1
        refusals[reason] = n
        if n <= 3 { Log.write("livediarize: no label (\(reason)) — \(detail)") }
        else if n == 4 { Log.write("livediarize: further \(reason) refusals not logged") }
        return lastLabel
    }
}
