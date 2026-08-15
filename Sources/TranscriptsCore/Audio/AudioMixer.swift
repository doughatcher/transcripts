import Foundation
import AVFoundation

/// Mixes several audio files into one `.m4a` by layering them as parallel tracks in
/// a composition and exporting — the export sums the tracks. Used to combine the
/// mic (you) and system audio (the other participants) into a single file for
/// transcription. Offline (post-recording) so there's no live-mixing feedback risk.
///
/// Inputs that can't be read (missing file, no audio track, zero duration) are
/// skipped rather than failing the mix — losing one side of a call is better than
/// losing the recording. Lives in TranscriptsCore so the mix behavior is testable.
public enum AudioMixer {

    /// One source file placed at an absolute position on the output timeline.
    public struct Placement: Sendable {
        public let url: URL
        /// Seconds from the start of the assembled timeline.
        public let at: TimeInterval
        public init(url: URL, at: TimeInterval) {
            self.url = url
            self.at = at
        }
    }

    /// Lays several files end to end on a single timeline at explicit offsets,
    /// leaving silence in the gaps. Used to stitch the fragments of one meeting
    /// back together after a mid-call mic recovery restarted the capture: each
    /// fragment goes back at the position it actually occupied, so a 40-second
    /// switchover reads as 40 seconds of quiet rather than shifting everything
    /// after it out of sync.
    ///
    /// Assembling each side separately (mic fragments on one timeline, system
    /// fragments on another) preserves the two-track separation that speaker
    /// attribution needs — the alternative, concatenating the per-fragment
    /// *mixes*, would collapse "you" and "them" into one track.
    public static func assemble(_ placements: [Placement], into output: URL,
                                log: @Sendable (String) -> Void = { _ in }) async -> URL? {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var added = 0

        for placement in placements.sorted(by: { $0.at < $1.at }) {
            let asset = AVURLAsset(url: placement.url)
            guard
                let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                duration.seconds > 0
            else { continue }
            let at = CMTime(seconds: max(0, placement.at), preferredTimescale: 600)
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                          of: sourceTrack, at: at)
                added += 1
            } catch {
                log("mixer: failed to place \(placement.url.lastPathComponent) at \(placement.at)s: \(error)")
            }
        }

        guard added > 0 else {
            log("mixer: nothing to assemble")
            return nil
        }
        return await export(composition, to: output, label: "assembled \(added) segment(s)", log: log)
    }

    /// Cuts a short clip out of `source` — `seconds` starting at `from` — and
    /// exports it as a standalone `.m4a`. Used to grab a few seconds of one
    /// speaker's voice for the "hear this to name it" grid (#6). A clip past the
    /// end of the source is clamped to what exists; an empty result returns nil.
    public static func clip(_ source: URL, from: TimeInterval, seconds: TimeInterval,
                            into output: URL, log: @Sendable (String) -> Void = { _ in }) async -> URL? {
        let asset = AVURLAsset(url: source)
        guard
            let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
            let total = try? await asset.load(.duration),
            total.seconds > 0
        else {
            log("mixer: clip source unreadable \(source.lastPathComponent)")
            return nil
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        let start = max(0, min(from, total.seconds))
        let length = max(0, min(seconds, total.seconds - start))
        guard length > 0 else { log("mixer: clip is empty (\(source.lastPathComponent))"); return nil }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: length, preferredTimescale: 600))
        do {
            try track.insertTimeRange(range, of: sourceTrack, at: .zero)
        } catch {
            log("mixer: clip failed (\(source.lastPathComponent)): \(error)")
            return nil
        }
        return await export(composition, to: output,
                            label: "clipped \(String(format: "%.1f", length))s", log: log)
    }

    /// Returns the mixed output URL, or nil on failure.
    public static func mix(_ inputs: [URL], into output: URL,
                           log: @Sendable (String) -> Void = { _ in }) async -> URL? {
        let composition = AVMutableComposition()
        var added = 0

        for url in inputs {
            let asset = AVURLAsset(url: url)
            guard
                let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                duration.seconds > 0,
                let compTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            do {
                try compTrack.insertTimeRange(range, of: sourceTrack, at: .zero)
                added += 1
            } catch {
                log("mixer: failed to add track from \(url.lastPathComponent): \(error)")
            }
        }

        guard added > 0 else {
            log("mixer: nothing to mix (added=\(added))")
            return nil
        }
        return await export(composition, to: output, label: "mixed \(added) tracks", log: log)
    }

    private static func export(_ composition: AVMutableComposition, to output: URL,
                               label: String, log: @Sendable (String) -> Void) async -> URL? {
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            log("mixer: could not create an export session")
            return nil
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }

        if export.status == .completed {
            log("mixer: \(label) → \(output.lastPathComponent)")
            return output
        }
        log("mixer: export failed (\(export.status.rawValue)) \(export.error?.localizedDescription ?? "")")
        return nil
    }
}
