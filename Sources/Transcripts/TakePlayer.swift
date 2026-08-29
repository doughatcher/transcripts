import AVFoundation
import SwiftUI

/// Playback for a finished take.
///
/// The app could read a recording and not hear it, which is a strange gap in a
/// recorder: when a take says "nothing was transcribed" you had no way to tell
/// whether the microphone was dead or the room was quiet, and when the
/// transcript garbled a sentence you could see it was wrong but not what was
/// actually said.
///
/// Owns its own `AVAudioPlayer` rather than reaching into `RecorderModel`,
/// because the two must never be live at once and keeping them apart makes that
/// obvious. Recording sets the session to `.record` deliberately — so it never
/// ducks whatever you were already listening to — and drops it on stop, so this
/// claims `.playback` for itself and hands it back when it finishes.
@MainActor
final class TakeAudio: NSObject, ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var duration: TimeInterval = 0
    /// Bound to the slider, so it is `var`: scrubbing writes here and `seek`
    /// pushes the value into the player.
    @Published var time: TimeInterval = 0
    @Published private(set) var failure: String?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func load(_ url: URL) {
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
            time = 0
            failure = nil
        } catch {
            failure = "This recording could not be opened."
            player = nil
            duration = 0
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { pause() } else { play() }
    }

    private func play() {
        guard let player else { return }
        do {
            // .spokenAudio is a playback mode — pairing it with .record throws
            // paramErr on device, which is why recording uses .default. Here it
            // is the right one: it is speech, and it routes to the speaker
            // rather than the earpiece.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            failure = "Couldn't start playback."
            return
        }
        player.play()
        playing = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.isPlaying else { return }
                self.time = p.currentTime
            }
        }
    }

    func pause() {
        player?.pause()
        playing = false
        ticker?.invalidate(); ticker = nil
        release()
    }

    /// Called continuously while dragging, so it does not touch the session.
    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, seconds), player.duration)
        player.currentTime = clamped
        time = clamped
    }

    func stop() {
        ticker?.invalidate(); ticker = nil
        player?.stop()
        player = nil
        playing = false
        time = 0
        duration = 0
        release()
    }

    /// Hands the session back so a recording started straight afterwards gets a
    /// clean `.record` activation rather than inheriting `.playback`.
    private func release() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension TakeAudio: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playing = false
            self.time = 0
            self.ticker?.invalidate(); self.ticker = nil
            self.release()
        }
    }
}

/// Transport for one audio file: play/pause, a scrubber, and elapsed/remaining.
/// Serves both a local take and a shared transcript's archived audio — by the
/// time it gets here, either one is just a playable URL.
struct AudioScrubber: View {
    let url: URL
    /// Recording and playback cannot share the audio session, so the transport
    /// goes flat rather than fighting for it.
    let disabled: Bool

    @StateObject private var audio = TakeAudio()
    @State private var scrubbing = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button { audio.toggle() } label: {
                    Image(systemName: audio.playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(disabled || audio.failure != nil)
                .accessibilityLabel(audio.playing ? "Pause" : "Play")

                VStack(spacing: 2) {
                    Slider(value: Binding(get: { audio.time },
                                          set: { audio.seek(to: $0) }),
                           in: 0...max(audio.duration, 0.01),
                           onEditingChanged: { editing in
                               // Pause on grab so the playhead does not fight
                               // the thumb, and leave it paused on release —
                               // scrubbing is usually looking, not listening.
                               scrubbing = editing
                               if editing && audio.playing { audio.pause() }
                           })
                        .disabled(disabled || audio.duration == 0)

                    HStack {
                        Text(Clock.human(audio.time))
                        Spacer()
                        Text("−" + Clock.human(max(0, audio.duration - audio.time)))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            if let failure = audio.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            } else if disabled {
                Text("Playback pauses while you are recording.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .task(id: url) { audio.load(url) }
        .onDisappear { audio.stop() }
        .onChange(of: disabled) { _, nowDisabled in
            if nowDisabled { audio.pause() }
        }
    }
}
