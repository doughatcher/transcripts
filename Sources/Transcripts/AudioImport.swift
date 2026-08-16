import AVFoundation
import Foundation

/// Brings audio recorded by something else into the library.
///
/// The case that prompted it: iOS gives no third-party app access to telephony
/// audio — `CXCall` exposes only whether a call is connected, and no
/// `AVAudioSession` category routes call audio anywhere an app can reach. So a
/// call cannot be *recorded* here. It can, however, be recorded by the Phone app
/// and then handed over, and once it is, everything downstream — transcription,
/// speaker attribution on the Mac, routing, session tagging — applies exactly as
/// it would to a recording made here.
///
/// Reached through `CFBundleDocumentTypes` rather than a share extension. An
/// extension would need its own bundle identifier, which on free provisioning
/// means spending one of three app-id slots, and would then need an App Group to
/// reach the destination bookmark that lives in the app's defaults. Declaring
/// the document type gets Transcripts into the share sheet and hands the file to
/// the running app, with no second process and no shared container.
enum AudioImport {
    enum Failure: LocalizedError {
        case unreadable
        case notAudio
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file couldn't be read."
            case .notAudio:   return "That doesn't look like an audio file."
            case .empty:      return "That recording appears to be empty."
            }
        }
    }

    /// Copies `url` into the captures directory and returns where it landed,
    /// along with what the file itself says about its length and age.
    ///
    /// Copied rather than referenced: the source may be a temporary URL the
    /// system reclaims, or a document the user deletes an hour later. A library
    /// entry pointing at either is a broken row waiting to happen.
    static func stage(_ url: URL, into directory: URL, id: UUID) async throws
        -> (audio: URL, duration: TimeInterval, recordedAt: Date) {

        // A URL arriving from the share sheet is usually security-scoped, and
        // reading it without asking silently yields nothing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let dest = directory.appendingPathComponent("\(id.uuidString).\(ext)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            throw Failure.unreadable
        }

        let asset = AVURLAsset(url: dest)
        guard let loaded = try? await asset.load(.duration) else {
            try? FileManager.default.removeItem(at: dest)
            throw Failure.notAudio
        }
        let seconds = loaded.seconds
        guard seconds.isFinite, seconds > 0.5 else {
            try? FileManager.default.removeItem(at: dest)
            throw Failure.empty
        }

        // When the recording was made, not when it was imported. A call
        // recorded this morning and shared tonight belongs this morning — and
        // on the Mac side that timestamp is what groups it into a session.
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? (try? dest.resourceValues(forKeys: [.creationDateKey]).creationDate)
        let recordedAt = created ?? Date().addingTimeInterval(-seconds)

        return (dest, seconds, recordedAt)
    }
}
