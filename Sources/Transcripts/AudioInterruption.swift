import AVFoundation
import Foundation

/// Notices that something else has taken the audio session.
///
/// A phone call is the case that matters most — iOS hands it the session
/// exclusively, and a capture running underneath is interrupted and, historically,
/// simply stopped producing audio while still claiming to record. Knowing it
/// happened lets the app stop cleanly, keep what it already has, and say why,
/// rather than leaving a take that looks forty minutes long and holds four.
///
/// This watched `CXCallObserver` from CallKit until 2026-09-15, which saw phone
/// calls and nothing else. `AVAudioSession.interruptionNotification` is a smaller
/// dependency and a wider net: Siri, an alarm and another app taking the session
/// exclusively all produce the same dead recording, and CallKit reported none of
/// them. Dropping the framework also drops an App Store review issue — MIIT
/// requires CallKit be deactivated in China, and an app that merely links it gets
/// flagged there whether or not it can place a call. This one never could.
@MainActor
final class AudioInterruption: ObservableObject {
    @Published private(set) var interrupted = false

    private let onInterrupted: @MainActor () -> Void
    private var token: (any NSObjectProtocol)?

    init(onInterrupted: @escaping @MainActor () -> Void) {
        self.onInterrupted = onInterrupted
        token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in self?.apply(type) }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    private func apply(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            // `.began` can repeat without an intervening `.ended`; only the
            // transition should stop a recording.
            guard !interrupted else { return }
            interrupted = true
            onInterrupted()
        case .ended:
            interrupted = false
        @unknown default:
            break
        }
    }
}
