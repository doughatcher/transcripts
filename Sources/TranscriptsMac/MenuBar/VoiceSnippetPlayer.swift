import Foundation
import AVFoundation
import Combine
import TranscriptsEngine

/// Plays the short voice clips the naming grid uses to answer "who is this?".
/// One shared player so starting a new clip stops the previous one, and the UI
/// can show which card is currently sounding. Playing a clip that's already
/// playing toggles it off — a play/stop button.
@MainActor
final class VoiceSnippetPlayer: NSObject, ObservableObject {
    static let shared = VoiceSnippetPlayer()

    /// Path of the clip currently sounding, so a card can render a stop icon.
    @Published private(set) var playingPath: String?

    private var player: AVAudioPlayer?

    func toggle(path: String) {
        if playingPath == path { stop(); return }
        play(path: path)
    }

    func play(path: String) {
        stop()
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            playingPath = path
        } catch {
            Log.write("voices: clip playback failed (\(URL(fileURLWithPath: path).lastPathComponent)): \(error)")
            playingPath = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingPath = nil
    }
}

extension VoiceSnippetPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingPath = nil }
    }
}
