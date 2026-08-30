import AVFoundation
import SwiftUI

/// Playback for the audio a transcript was made from.
///
/// The reader could show you what the model heard and give you no way to hear
/// it, which is the gap on exactly the lines that need it most: a garbled
/// sentence is visibly wrong and unrecoverable without the tape. The phone has
/// had a transport since it had a reader. The Mac — which is where these
/// documents are written, and where the audio is filed next to them — did not.
///
/// Separate from `VoiceSnippetPlayer` on purpose. That one plays two-second
/// naming clips and only ever answers "who is this?", so it is a play/stop
/// toggle with nothing to scrub. This is an hour of meeting, and landing
/// somewhere in the middle of it is the whole point.
@MainActor
final class TranscriptAudio: NSObject, ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var duration: TimeInterval = 0
    /// Bound to the slider, so it is `var`: dragging writes here and `seek`
    /// pushes the value into the player.
    @Published var time: TimeInterval = 0
    @Published private(set) var failure: String?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// No audio session to claim or hand back — that is an iOS concept, and its
    /// absence is most of why this is shorter than the phone's `TakeAudio`.
    /// macOS also lets this coexist with a recording in progress, so there is no
    /// disabled state to carry either.
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
            // A file that exists but won't open is usually one still being
            // written, or a CAF the encode stage never finished replacing.
            failure = "This recording could not be opened."
            player = nil
            duration = 0
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
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
    }

    /// Called continuously while dragging, so it stays cheap.
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
    }
}

extension TranscriptAudio: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playing = false
            self.time = 0
            self.ticker?.invalidate(); self.ticker = nil
        }
    }
}

/// Transport for one audio file: play/pause, a scrubber, elapsed and remaining.
///
/// Deliberately the same shape as the phone's `AudioScrubber` — the same
/// controls in the same order — because the two readers are looking at the same
/// document and the muscle memory should carry between them.
struct TranscriptScrubber: View {
    let url: URL
    /// Set by clicking a timestamp in the transcript. Consumed and cleared here,
    /// so the player stays the only thing that owns playback state — the
    /// document just says where it would like to be.
    var seekTo: Binding<TimeInterval?> = .constant(nil)

    @StateObject private var audio = TranscriptAudio()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { audio.toggle() } label: {
                    Image(systemName: audio.playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(audio.failure != nil)
                .accessibilityLabel(audio.playing ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])

                VStack(spacing: 2) {
                    Slider(value: Binding(get: { audio.time },
                                          set: { audio.seek(to: $0) }),
                           in: 0...max(audio.duration, 0.01),
                           onEditingChanged: { editing in
                               // Pause on grab so the playhead does not fight
                               // the thumb, and leave it paused on release —
                               // scrubbing is usually looking, not listening.
                               if editing && audio.playing { audio.pause() }
                           })
                        .disabled(audio.duration == 0)

                    HStack {
                        Text(Self.clock(audio.time))
                        Spacer()
                        Text("−" + Self.clock(max(0, audio.duration - audio.time)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            if let failure = audio.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .task(id: url) { audio.load(url) }
        .onDisappear { audio.stop() }
        .onChange(of: seekTo.wrappedValue) { _, target in
            guard let target else { return }
            audio.seek(to: target)
            // Jumping to a moment is a request to hear it. Seeking silently and
            // making you find the play button would be the pedantic reading.
            audio.play()
            seekTo.wrappedValue = nil
        }
    }

    /// `mm:ss`, or `h:mm:ss` once there is an hour to show. The header card's
    /// `prettyDuration` says "51m 28s", which reads well as a fact about the
    /// meeting and badly as a playhead.
    static func clock(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
