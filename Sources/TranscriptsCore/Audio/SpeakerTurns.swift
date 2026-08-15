import Foundation

/// A transcribed span of one audio track, in seconds relative to that track's start.
public struct TranscriptSegment: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A span of one speaker's audio as found by diarization, in seconds relative to
/// the diarized track's start.
public struct SpeakerSpan: Equatable, Sendable {
    public let speaker: String
    public let start: Double
    public let end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// One speaker-labeled utterance placed on the recording's common timeline.
public struct AttributedSegment: Equatable, Sendable {
    public let speaker: String
    public let start: Double
    public let text: String

    public init(speaker: String, start: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.text = text
    }
}

/// What a diarization pass yields: per-speaker time spans plus the voice
/// embedding behind each label — the raw material for voice profiles (#6).
public struct DiarizationOutcome: Sendable {
    public var spans: [SpeakerSpan]
    /// Final label → the **real** per-call voice embedding heard for that speaker
    /// (aggregated from the diarizer's segment embeddings, not a seeded profile).
    public var embeddings: [String: [Float]]
    /// Final label → match confidence, for the labels that were named by matching
    /// an enrolled voice (cosine similarity). Absent for `Me`, anonymous speakers,
    /// and transcript-evidence names.
    public var confidence: [String: Float]
    /// Named label → the matched profile's affiliation ("Org / Group"), so the
    /// transcript can record which orgs/groups were in the room.
    public var affiliations: [String: String]

    public init(spans: [SpeakerSpan], embeddings: [String: [Float]] = [:],
                confidence: [String: Float] = [:], affiliations: [String: String] = [:]) {
        self.spans = spans
        self.embeddings = embeddings
        self.confidence = confidence
        self.affiliations = affiliations
    }
}

/// Pure attribution logic: Transcripts records a call as two tracks (your mic, and the
/// system audio carrying the other participants), so "who said what" starts as a
/// certainty — mic = you — plus an optional diarization pass that splits the other
/// side into distinct voices. These helpers label, interleave, and render that.
public enum SpeakerTurns {
    /// True for diarizer-generated anonymous ids ("1", "SPEAKER_01") as opposed
    /// to enrolled-profile names ("Tracy", "Me"), which must pass through.
    public static func isAnonymousLabel(_ label: String) -> Bool {
        if Int(label) != nil { return true }
        return label.uppercased().hasPrefix("SPEAKER")
    }

    /// Maps anonymous diarizer ids to stable human labels ("Speaker 1", …) by
    /// order of first appearance; enrolled-profile names are kept as-is.
    public static func labelMap(_ spans: [SpeakerSpan]) -> [String: String] {
        var map: [String: String] = [:]
        var counter = 0
        for span in spans.sorted(by: { $0.start < $1.start }) where map[span.speaker] == nil {
            if isAnonymousLabel(span.speaker) {
                counter += 1
                map[span.speaker] = "Speaker \(counter)"
            } else {
                map[span.speaker] = span.speaker
            }
        }
        return map
    }

    public static func renumber(_ spans: [SpeakerSpan]) -> [SpeakerSpan] {
        let map = labelMap(spans)
        return spans.sorted { $0.start < $1.start }.map { span in
            SpeakerSpan(speaker: map[span.speaker] ?? span.speaker, start: span.start, end: span.end)
        }
    }

    /// Where to cut a "hear this voice" sample from the diarized track, per
    /// speaker. Picks each speaker's **longest** span — the cleanest stretch of
    /// them talking uninterrupted — and takes up to `maxSeconds` of it, nudged a
    /// beat past the onset so the clip opens on speech rather than the join. A
    /// speaker whose longest span is under `minSeconds` yields nothing: too short
    /// to recognize, better no sample than a syllable.
    ///
    /// Keyed by whatever labels the spans carry, so call it after `renumber` to
    /// get "Speaker 1" rather than a raw diarizer id.
    public static func sampleWindows(_ spans: [SpeakerSpan],
                                     maxSeconds: Double = 6,
                                     minSeconds: Double = 1.5,
                                     onsetSkip: Double = 0.25)
    -> [String: (start: Double, seconds: Double)] {
        var longest: [String: SpeakerSpan] = [:]
        for span in spans {
            let dur = span.end - span.start
            guard dur > 0 else { continue }
            if let cur = longest[span.speaker], (cur.end - cur.start) >= dur { continue }
            longest[span.speaker] = span
        }
        var windows: [String: (start: Double, seconds: Double)] = [:]
        for (speaker, span) in longest {
            let dur = span.end - span.start
            guard dur >= minSeconds else { continue }
            // Only skip the onset when there's room to spare beyond the minimum.
            let skip = dur - onsetSkip >= minSeconds ? onsetSkip : 0
            windows[speaker] = (start: span.start + skip,
                                seconds: min(maxSeconds, dur - skip))
        }
        return windows
    }

    /// Labels each transcribed segment with the diarized speaker whose span
    /// overlaps it the most; `fallback` when nothing overlaps (or no spans at all).
    public static func assign(
        _ segments: [TranscriptSegment], spans: [SpeakerSpan], fallback: String
    ) -> [AttributedSegment] {
        segments.map { seg in
            var best: (speaker: String, overlap: Double)? = nil
            for span in spans {
                let overlap = min(seg.end, span.end) - max(seg.start, span.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (span.speaker, overlap)
                }
            }
            return AttributedSegment(speaker: best?.speaker ?? fallback, start: seg.start, text: seg.text)
        }
    }

    /// Interleaves labeled segments from any number of tracks (already shifted onto
    /// one timeline) into ordered turns, coalescing consecutive same-speaker
    /// segments into a single turn.
    public static func turns(_ segments: [AttributedSegment]) -> [(speaker: String, text: String)] {
        let ordered = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var out: [(speaker: String, text: String)] = []
        for seg in ordered {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = out.last, last.speaker == seg.speaker {
                out[out.count - 1].text += " " + text
            } else {
                out.append((seg.speaker, text))
            }
        }
        return out
    }

    /// Renders turns as markdown paragraphs: `**Me:** …`.
    public static func markdown(_ turns: [(speaker: String, text: String)]) -> String {
        turns.map { "**\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
    }

    /// Rewrites a stored transcript so a speaker's turns carry a corrected name —
    /// the document half of fixing a misattribution. Replaces the `**Old:**` turn
    /// prefixes and the name's entry in the `speakers:` frontmatter list, leaving
    /// body prose untouched (only the exact quoted token on the speakers line is
    /// swapped). Within one transcript a name maps to a single diarized cluster, so
    /// this is unambiguous.
    public static func renameSpeaker(in text: String, from oldName: String, to newName: String) -> String {
        let old = oldName.trimmingCharacters(in: .whitespaces)
        let new = newName.trimmingCharacters(in: .whitespaces)
        guard !old.isEmpty, !new.isEmpty, old != new else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = String(line)
            // Turn prefixes anywhere they appear.
            s = s.replacingOccurrences(of: "**\(old):**", with: "**\(new):**")
            // Only the speakers frontmatter list gets the quoted-token swap.
            if s.hasPrefix("speakers:") {
                s = s.replacingOccurrences(of: "\"\(old)\"", with: "\"\(new)\"")
            }
            return s
        }.joined(separator: "\n")
    }

    /// The distinct speakers in speaking order (for the document frontmatter).
    public static func speakers(_ turns: [(speaker: String, text: String)]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for t in turns where !seen.contains(t.speaker) {
            seen.insert(t.speaker)
            out.append(t.speaker)
        }
        return out
    }
}
