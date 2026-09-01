import Foundation

/// Matching diarized voice clusters to enrolled profiles — in our own code, with a
/// threshold we control, rather than trusting the diarizer's built-in naming.
///
/// This is the fix for the over-match that shipped: seven enrolled colleagues got
/// stamped onto a four-person call none of them were on. Two rules prevent it:
///
/// 1. **One-to-one.** Each cluster gets at most one name, and each profile is
///    claimed at most once — a real person can't be two speakers in one meeting.
///    This alone caps names at the number of clusters and makes "seven names on a
///    four-person call" impossible.
/// 2. **Confidence gate.** A pairing is accepted only when cosine similarity meets
///    `threshold`; below it the cluster stays anonymous (`Speaker N` / `Others`).
///    A high threshold means "name only when sure, otherwise leave it Me/Others."
///
/// The confidence is carried through so downstream (transcript frontmatter, the
/// review UI) can tell how sure each name was.
public enum SpeakerMatch {

    public struct Assignment: Equatable, Sendable {
        /// The diarizer's cluster id this assignment is for.
        public let cluster: String
        /// The matched profile name, or nil when the cluster stays anonymous.
        public let name: String?
        /// Cosine similarity to the matched profile (0 when unmatched).
        public let confidence: Float

        public init(cluster: String, name: String?, confidence: Float) {
            self.cluster = cluster
            self.name = name
            self.confidence = confidence
        }
    }

    public struct Profile: Equatable, Sendable {
        public let name: String
        /// Every remembered voiceprint for this person, matched individually.
        ///
        /// Individually, not averaged, because one person does not necessarily
        /// have one voice. A player running a character at a table speaks in a
        /// register nothing like their own, and the mean of the two is a voice
        /// that matches neither of them.
        public let embeddings: [[Float]]

        public init(name: String, embeddings: [[Float]]) {
            self.name = name
            self.embeddings = embeddings
        }

        public init(name: String, embedding: [Float]) {
            self.init(name: name, embeddings: [embedding])
        }

        /// Closeness to the nearest remembered voice, not the average one.
        public func similarity(to embedding: [Float]) -> Float {
            embeddings.map { VoiceMath.cosine(embedding, $0) }.max() ?? 0
        }
    }

    /// Assigns clusters to profiles greedily by descending similarity: the single
    /// most-confident pairing is claimed first, then the next among still-free
    /// clusters and profiles, and so on, stopping below `threshold`. Clusters left
    /// over stay anonymous (`name == nil`).
    ///
    /// Greedy-by-best is the right heuristic here: the strongest match should win
    /// its profile outright, and because each profile is single-use, a loosely
    /// similar second cluster can't also claim it. Determinism (ties broken by
    /// cluster then name) keeps the output stable across runs.
    ///
    /// `oneClusterPerPerson` is that single-use rule, and it is the default
    /// because on a call it is true and load-bearing — without it one loosely
    /// similar voice after another claims the same colleague, which is how a
    /// four-person call once came out with seven people in it.
    ///
    /// A room recording turns it off. When somebody runs three characters in an
    /// evening the diarizer quite correctly reports three voices, and all three
    /// of them are that person; refusing to name more than one of them leaves
    /// the rest as anonymous Speaker numbers forever.
    public static func assign(clusters: [String: [Float]],
                              profiles: [Profile],
                              threshold: Float,
                              oneClusterPerPerson: Bool = true) -> [Assignment] {
        var pairs: [(cluster: String, name: String, sim: Float)] = []
        for (cluster, emb) in clusters {
            for profile in profiles {
                pairs.append((cluster, profile.name, profile.similarity(to: emb)))
            }
        }
        pairs.sort {
            if $0.sim != $1.sim { return $0.sim > $1.sim }
            if $0.cluster != $1.cluster { return $0.cluster < $1.cluster }
            return $0.name < $1.name
        }

        var takenClusters = Set<String>()
        var takenProfiles = Set<String>()
        var byCluster: [String: Assignment] = [:]
        for p in pairs where p.sim >= threshold {
            guard !takenClusters.contains(p.cluster) else { continue }
            if oneClusterPerPerson, takenProfiles.contains(p.name) { continue }
            takenClusters.insert(p.cluster)
            takenProfiles.insert(p.name)
            byCluster[p.cluster] = Assignment(cluster: p.cluster, name: p.name, confidence: p.sim)
        }

        return clusters.keys.sorted().map {
            byCluster[$0] ?? Assignment(cluster: $0, name: nil, confidence: 0)
        }
    }

    /// A coarse label for a confidence value, for the transcript frontmatter — so a
    /// downstream reader can weight a name without knowing the raw cosine scale.
    public static func band(_ confidence: Float, threshold: Float) -> String {
        if confidence <= 0 { return "none" }
        if confidence >= max(threshold, 0.8) { return "high" }
        if confidence >= threshold { return "medium" }
        return "low"
    }
}
