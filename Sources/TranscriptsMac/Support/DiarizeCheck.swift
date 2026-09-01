import AppKit
import TranscriptsCore
import TranscriptsEngine

/// Attribution smoke test — runs the real diarizer (and, on macOS 26, the real
/// timestamped transcriber) against an existing audio file and prints the
/// speaker spans/turns. Verifies the FluidAudio model download works on this
/// machine and shows what attribution would produce, without needing a live call:
///
///   TRANSCRIPTS_DIARIZE=/path/to/call.m4a ~/Applications/Transcripts.app/Contents/MacOS/Transcripts
///
/// For a room recording — one microphone, several people — set `TRANSCRIPTS_ROOM=1`
/// to loosen the short-speech gate, and `TRANSCRIPTS_CLUSTER=0.65` to sweep the
/// sensitivity. This is the way to find out how many voices a real recording
/// actually resolves into, rather than guessing at a setting.
///
/// Exit codes: 0 = diarization produced speaker spans · 1 = no such file ·
/// 3 = diarization unavailable (model download blocked?) — timestamped
/// transcription is still exercised so Tier 1 attribution stays verifiable.
@MainActor
enum DiarizeCheck {
    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_DIARIZE"]
    }

    /// One microphone with a room in front of it.
    static var roomMode: Bool {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_ROOM"] == "1"
    }

    /// Clustering sensitivity override (lower = more speakers); nil = default.
    static var clusteringThreshold: Float? {
        Float(ProcessInfo.processInfo.environment["TRANSCRIPTS_CLUSTER"] ?? "")
    }

    static func runAndExit(path: String) {
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            exit(await perform(path: path))
        }
    }

    private static func perform(path: String) async -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        print("Transcripts diarize-check — \(url.lastPathComponent)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("✗ no such file")
            return 1
        }

        var spans: [SpeakerSpan] = []
        var diarizationOK = false
        do {
            print("• diarizing (first run downloads the Core ML models) …")
            if roomMode {
                print("• room mode, sensitivity \(clusteringThreshold.map { String(format: "%.2f", $0) } ?? "default")")
            }
            // rememberVoices off: a probe must never write to the profile store.
            let outcome = try await FluidAudioDiarizer(rememberVoices: false,
                                                       clusteringThreshold: clusteringThreshold,
                                                       roomMode: roomMode)
                .diarize(track: url, enrollSelfFrom: nil)
            spans = SpeakerTurns.renumber(outcome.spans)
            diarizationOK = true
            let speakers = Set(spans.map(\.speaker)).sorted()
            print("✓ \(spans.count) span(s), \(speakers.count) speaker(s): \(speakers.joined(separator: ", "))")
            for span in spans.prefix(12) {
                print(String(format: "  %7.1fs – %7.1fs  %@", span.start, span.end, span.speaker))
            }
            if spans.count > 12 { print("  … \(spans.count - 12) more") }
        } catch {
            print("⚠ diarization unavailable: \(error)")
            print("  (attribution degrades to a single 'Others' voice until the models download)")
        }

        if #available(macOS 26, *) {
            print("• transcribing with timestamps …")
            do {
                let segments = try await SpeechTranscriberEngine()
                    .transcribeSegments(audioURL: url, model: "")
                let turns = SpeakerTurns.turns(
                    SpeakerTurns.assign(segments, spans: spans, fallback: "Others"))
                print("✓ \(segments.count) segment(s) → \(turns.count) attributed turn(s):")
                for turn in turns.prefix(8) {
                    let text = turn.text.count > 90 ? String(turn.text.prefix(90)) + "…" : turn.text
                    print("  \(turn.speaker): \(text)")
                }
            } catch {
                print("⚠ transcription failed (\(error))")
            }
        }
        return diarizationOK ? 0 : 3
    }
}
