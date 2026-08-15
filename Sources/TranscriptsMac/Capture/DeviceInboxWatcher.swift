import Foundation
import TranscriptsCore
import TranscriptsEngine

/// Watches the folder the phone/iPad drops captures into and reports ones ready
/// to import.
///
/// Polls rather than using FSEvents. Cloud providers materialize a file in
/// stages — the directory event fires when the placeholder appears, long before
/// the bytes land — so an event-driven watcher mostly fires on files it can't
/// read yet. A poll that re-checks readiness each pass is both simpler and more
/// honest about what's actually available.
@MainActor
final class DeviceInboxWatcher {
    /// Slow on purpose: a capture arriving a minute late costs nothing, and the
    /// folder lives on a network filesystem where aggressive scanning is rude.
    static let interval: TimeInterval = 30

    private var timer: Timer?
    private var seen: Set<UUID> = []
    private let onFound: ([DeviceInbox.Pending]) -> Void

    init(onFound: @escaping ([DeviceInbox.Pending]) -> Void) {
        self.onFound = onFound
    }

    /// Points the watcher at `root`, or stops it when nil. Safe to call on every
    /// config change — a no-op when the root hasn't moved.
    func retarget(to root: URL?) {
        timer?.invalidate()
        timer = nil
        guard let root else { return }
        // Sweep immediately so a capture waiting since last launch imports now
        // rather than after the first interval.
        scan(root)
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan(root) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Marks a capture as handled so a later sweep doesn't re-import it. Called
    /// once the pipeline owns the audio.
    func markHandled(_ id: UUID) { seen.insert(id) }

    private func scan(_ root: URL) {
        let pending: [DeviceInbox.Pending]
        do {
            pending = try DeviceInbox.pending(under: root)
        } catch {
            Log.write("device inbox: \(error)")
            return
        }
        let fresh = pending.filter { !seen.contains($0.capture.id) }
        guard !fresh.isEmpty else { return }
        Log.write("device inbox: \(fresh.count) new capture(s) from \(root.lastPathComponent)")
        onFound(fresh)
    }
}
