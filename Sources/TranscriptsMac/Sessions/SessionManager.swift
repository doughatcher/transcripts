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
    func start(profileID: String, label: String? = nil) -> Bool {
        guard let p = profiles().first(where: { $0.id == profileID }) else {
            Log.write("session: no profile '\(profileID)' in routing.json")
            return false
        }
        // Starting over the top of a running session ends the old one properly
        // rather than orphaning it — its hook still deserves to run.
        if active?.isRunning == true { end(reason: .explicit) }

        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = ActiveSession(profileID: p.id, startedAt: Date(),
                              label: (trimmed?.isEmpty == false) ? trimmed : nil)
        active = s
        profile = p
        try? store.save(s)
        startTicking()
        Log.write("session: started '\(p.id)'\(s.label.map { " — \($0)" } ?? "")")
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

    // MARK: - Sessions recorded elsewhere

    /// Completion keys already fired, so a run is never published twice.
    ///
    /// Kept in defaults rather than derived: the recordings that make up a run
    /// stay on disk indefinitely, so "have I already done this one" cannot be
    /// answered by their presence. Small and append-only — one short string per
    /// completed evening.
    private static let firedKey = "transcripts.sessions.completedRuns"
    private var firedRuns: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.firedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.firedKey) }
    }

    // MARK: - Recorded elsewhere

    /// Recordings another device tagged with a session, kept until the evening
    /// they belong to has completed.
    ///
    /// Persisted, where it used to live only in memory: an evening can arrive in
    /// the middle of the game and close hours later, and a relaunch in between
    /// forgot which session the recordings belonged to, so the hook never ran.
    private static let remoteKey = "transcripts.sessions.remoteItems"
    private var remoteItems: [RemoteSession.Item] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.remoteKey) else { return [] }
            return (try? JSONDecoder().decode([RemoteSession.Item].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.remoteKey) }
    }

    var hasPendingRemote: Bool { !remoteItems.isEmpty }

    /// Notes a recording that arrived tagged with a session.
    func rememberRemote(_ item: RemoteSession.Item) {
        var all = remoteItems.filter { $0.id != item.id }
        all.append(item)
        remoteItems = all
    }

    /// Where a tagged recording should be filed: its session's destination, the
    /// same as if the session had been running on this Mac. Nil for anything
    /// untagged, or a session that sets no destination.
    func remoteDestination(for recordID: UUID?) -> String? {
        guard let recordID, let item = remoteItems.first(where: { $0.id == recordID }) else { return nil }
        return profiles().first { $0.id == item.sessionID }?.destination
    }

    func isRemote(_ recordID: UUID) -> Bool { remoteItems.contains { $0.id == recordID } }

    /// Groups recordings tagged by another device and completes the runs that
    /// are finished.
    ///
    /// The Mac may not have been awake when any of this happened, which is the
    /// whole point: the evening is reconstructed from the recordings rather than
    /// watched as it occurs. Called after an import, whenever a tagged
    /// recording finishes processing, on a timer, and at launch — a run can
    /// close long after its last recording arrived, and nothing else would
    /// notice.
    ///
    /// `settled` says whether a recording has finished processing. A closed run
    /// waits for all of its recordings: completing the moment the files were
    /// imported handed the hook an evening with no transcripts in it yet, and
    /// then marked it done for good.
    func reconcileRemote(settled: (UUID) -> Bool,
                         complete: (RemoteSession.Run, SessionProfile) async -> Void) async {
        let items = remoteItems
        guard !items.isEmpty else { return }
        var finished: Set<UUID> = []
        let known = profiles()
        for profile in known {
            for run in RemoteSession.runs(from: items, profile: profile, now: Date()) {
                guard run.isClosed else { continue }          // may still be going
                let key = RemoteSession.key(for: run)
                if firedRuns.contains(key) {
                    finished.formUnion(run.items.map(\.id))
                    continue
                }
                guard run.items.allSatisfy({ settled($0.id) }) else { continue }
                // Recorded before running, not after: a crash mid-publish should
                // cost one evening's hook rather than re-fire it on every launch
                // for the rest of time. The log says what happened.
                firedRuns.insert(key)
                finished.formUnion(run.items.map(\.id))
                Log.write("session: '\(profile.id)' recorded elsewhere — \(run.items.count) recording(s), ended \(run.endedAt) (\(run.reason.rawValue))")
                await complete(run, profile)
            }
        }
        // A tag naming no profile can never complete; drop it rather than keep
        // it for ever.
        let ids = Set(known.map(\.id))
        remoteItems = remoteItems.filter { !finished.contains($0.id) && ids.contains($0.sessionID) }
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
