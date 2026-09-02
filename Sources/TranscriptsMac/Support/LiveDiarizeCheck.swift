import AppKit
import AVFoundation
import TranscriptsCore
import TranscriptsEngine

/// Live-attribution replay — pushes an existing recording through the *live*
/// path (streaming transcriber plus `LiveDiarizer`, fed the same buffers in the
/// same order the capture tap would) and prints what the live transcript would
/// have shown, beside what the batch diarizer makes of the same file:
///
///   TRANSCRIPTS_LIVEDIARIZE=/path/to/mic.caf ~/Applications/Transcripts.app/Contents/MacOS/Transcripts
///
/// `TRANSCRIPTS_CLUSTER=0.6` sweeps the sensitivity, as for `DiarizeCheck`.
///
/// Exists because the honest question about live diarization is not "does it
/// run" but "does it beat saying Me": a live label that is confidently wrong is
/// worse than none. This answers that on a real recording with no call needed,
/// and it is the bar the feature is held to before it is wired into the app.
///
/// Exit codes: 0 = live produced labels · 1 = no such file · 2 = live path
/// unavailable on this macOS · 3 = diarizer unavailable (models?).
@MainActor
enum LiveDiarizeCheck {
    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_LIVEDIARIZE"]
    }

    static var clusteringThreshold: Float? {
        Float(ProcessInfo.processInfo.environment["TRANSCRIPTS_CLUSTER"] ?? "")
    }

    static func runAndExit(path: String) {
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            exit(await perform(path: path))
        }
    }

    /// Collected turns, appended from the transcriber's callbacks.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var turns: [(speaker: String, seg: TranscriptSegment)] = []
        private var pending = 0
        func add(_ speaker: String, _ seg: TranscriptSegment) {
            lock.lock(); turns.append((speaker, seg)); pending -= 1; lock.unlock()
        }
        func began() { lock.lock(); pending += 1; lock.unlock() }
        var inFlight: Int { lock.lock(); defer { lock.unlock() }; return pending }
        var sorted: [(speaker: String, seg: TranscriptSegment)] {
            lock.lock(); defer { lock.unlock() }; return turns.sorted { $0.seg.start < $1.seg.start }
        }
    }

    private static func perform(path: String) async -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        print("Transcripts live-diarize-check — \(url.lastPathComponent)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("✗ no such file"); return 1
        }
        guard #available(macOS 26, *) else {
            print("✗ the live path needs macOS 26"); return 2
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            print("✗ could not open audio"); return 1
        }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        print(String(format: "• %.0f s of audio, sensitivity %@", seconds,
                     clusteringThreshold.map { String(format: "%.2f", $0) } ?? "default"))

        // The ring must hold the whole file: replay outruns real time, and the
        // point is to test attribution, not the ring's length.
        // rememberVoices off: a probe must never touch the profile store.
        let diarizer = LiveDiarizer(clusteringThreshold: clusteringThreshold,
                                    rememberVoices: false, windowSeconds: seconds + 10)
        print("• loading diarizer …")
        guard await diarizer.start() else {
            print("✗ diarizer unavailable"); return 3
        }

        let collected = Collected()
        let mic = LiveTrackTranscriber { seg in
            collected.began()
            Task {
                let label = await diarizer.label(start: seg.start, end: seg.end) ?? "Me"
                collected.add(label, seg)
            }
        }
        guard await mic.start() else {
            print("✗ live transcriber would not start"); return 2
        }

        // Same buffers, same order, to both consumers — the capture tap's shape.
        print("• replaying through the live path …")
        let frames: AVAudioFrameCount = 4096
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                  (try? file.read(into: buffer, frameCount: frames)) != nil, buffer.frameLength > 0
            else { break }
            mic.feed(buffer)
            diarizer.feed(buffer)
        }
        await mic.finish()
        // The last labels are still resolving on the diarizer's queue.
        for _ in 0..<200 where collected.inFlight > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }

        let live = collected.sorted
        let turns = SpeakerTurns.turns(live.map {
            AttributedSegment(speaker: $0.speaker, start: $0.seg.start, text: $0.seg.text)
        })
        let liveVoices = SpeakerTurns.speakers(turns)
        print("✓ live: \(live.count) segment(s) → \(turns.count) turn(s), \(liveVoices.count) voice(s): \(liveVoices.joined(separator: ", "))")
        for turn in turns.prefix(14) {
            let text = turn.text.count > 88 ? String(turn.text.prefix(88)) + "…" : turn.text
            print("  \(SpeakerTurns.stamp(turn.start)) \(turn.speaker): \(text)")
        }
        if turns.count > 14 { print("  … \(turns.count - 14) more") }

        // The comparison that matters: the batch diarizer on the same file at the
        // same setting. Live should approach it, not be held to matching it.
        print("• batch on the same file, for comparison …")
        do {
            let outcome = try await FluidAudioDiarizer(rememberVoices: false,
                                                       clusteringThreshold: clusteringThreshold,
                                                       roomMode: true)
                .diarize(track: url, enrollSelfFrom: nil)
            let spans = SpeakerTurns.renumber(outcome.spans)
            let batchVoices = Set(spans.map(\.speaker)).sorted()
            print("✓ batch: \(spans.count) span(s), \(batchVoices.count) voice(s): \(batchVoices.joined(separator: ", "))")
            print("  live \(liveVoices.count) voice(s) vs batch \(batchVoices.count)")
        } catch {
            print("⚠ batch diarization unavailable: \(error)")
        }
        return live.isEmpty ? 3 : 0
    }
}
