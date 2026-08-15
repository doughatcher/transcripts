import Foundation
import TranscriptsCore
import TranscriptsEngine

/// Drives a running session: absorbs recordings, decides when the evening is
/// over, and fires the completion command exactly once.
///
/// Kept apart from `AppController` because the lifecycle is genuinely its own
/// concern and because the interesting states — ended-but-not-completed,
/// relaunched-mid-session — are easier to reason about when they are not
/// tangled with capture.
@MainActor
final class SessionManager: ObservableObject {
    /// The session in progress, if any. Published so the menu can show it.
    @Published private(set) var active: ActiveSession?
    @Published private(set) var profile: SessionProfile?

    private let store: SessionStore
    private var ticker: Timer?
    /// Resolves profiles by id at the moment they are needed, rather than
    /// holding a copy — routing.json is hand-edited and may change mid-session.
    private let profiles: () -> [SessionProfile]
    /// Assigned after construction: the handler needs the controller, and the
    /// controller needs this. Optional rather than implicitly-unwrapped so a
    /// session started before wiring completes simply skips its hook instead of
    /// trapping.
    var onComplete: ((ActiveSession, SessionProfile) async -> Void)?

    init(directory: URL = HistoryStore.dir,
         profiles: @escaping () -> [SessionProfile]) {
        self.store = SessionStore(directory: directory)
        self.profiles = profiles
    }

    // MARK: - Lifecycle

    /// Picks up whatever the previous run left behind.
    ///
    /// Two distinct cases, and conflating them is how an evening gets published
    /// twice or not at all: a session still running (carry on) versus one that
    /// ended without its hook completing (fire it now, late but once).
    func restore() {
        guard let saved = store.load() else { return }
        guard let p = profiles().first(where: { $0.id == saved.profileID }) else {
            // The profile was renamed or deleted while a session was running.
            // Nothing sensible to complete against, so retire the marker rather
            // than leave it to be reconsidered on every launch.
            Log.write("session: profile '\(saved.profileID)' is gone — discarding stale marker")
            store.clear()
            return
        }
        active = saved
        profile = p

        if saved.needsCompletion {
            Log.write("session: '\(p.id)' ended while the app was away — completing now")
            Task { await complete() }
            return
        }
        Log.write("session: resumed '\(p.id)', started \(saved.startedAt)")
        startTicking()
        // The app may have been gone for hours; the session might already be
        // over by the rules, so evaluate immediately rather than at the next tick.
        evaluate()
    }

    @discardableResult
    func start(profileID: String) -> Bool {
        guard let p = profiles().first(where: { $0.id == profileID }) else {
            Log.write("session: no profile '\(profileID)' in routing.json")
            return false
        }
        // Starting over the top of a running session ends the old one properly
        // rather than orphaning it — its hook still deserves to run.
        if active?.isRunning == true { end(reason: .explicit) }

        let s = ActiveSession(profileID: p.id, startedAt: Date())
        active = s
        profile = p
        try? store.save(s)
        startTicking()
        Log.write("session: started '\(p.id)'")
        return true
    }

    func end(reason: ActiveSession.EndReason = .explicit) {
        guard var s = active, s.isRunning else { return }
        s.endedAt = Date()
        s.endReason = reason
        active = s
        try? store.save(s)
        stopTicking()
        Log.write("session: '\(s.profileID)' ended (\(reason.rawValue)) with \(s.recordingIDs.count) recording(s)")
        Task { await complete() }
    }

    /// Records that a recording belongs to this session, and keeps the idle
    /// clock alive. Called at both start and finish of a capture: a three-hour
    /// recording must not age out mid-take.
    func noteActivity(recordingID: UUID? = nil) {
        guard var s = active, s.isRunning else { return }
        s.lastActivityAt = Date()
        if let recordingID, !s.recordingIDs.contains(recordingID) {
            s.recordingIDs.append(recordingID)
        }
        active = s
        try? store.save(s)
    }

    /// The destination override for the session in progress, if it sets one.
    var destinationOverride: String? {
        guard active?.isRunning == true else { return nil }
        return profile?.destination
    }

    // MARK: - Completion

    private func complete() async {
        guard var s = active, s.needsCompletion, let p = profile else { return }
        await onComplete?(s, p)
        s.completedAt = Date()
        active = s
        // Persist the completion *before* clearing, so a crash in between
        // leaves a marker that says "already done" rather than one that
        // re-fires on next launch.
        try? store.save(s)
        store.clear()
        active = nil
        profile = nil
        Log.write("session: '\(p.id)' completed")
    }

    // MARK: - The clock

    /// A minute is plenty: every end condition is measured in tens of minutes,
    /// and a session should not keep a timer busy all evening for precision
    /// nobody can perceive.
    private func startTicking() {
        stopTicking()
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func evaluate() {
        guard let s = active, s.isRunning, let p = profile else { return }
        if let reason = SessionLifecycle.endReason(for: s, profile: p, now: Date()) {
            end(reason: reason)
        }
    }
}
