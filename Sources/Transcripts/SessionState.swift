import Foundation

/// The session this device is currently recording into.
///
/// Deliberately much thinner than the Mac's `SessionManager`, because iOS cannot
/// do most of what that one does. There is no timer here and no completion
/// action: between takes iOS suspends the app, so a clock cannot be trusted to
/// fire, and there is no `Process` in the sandbox to run a script with. Both of
/// those belong to whichever Mac picks the recordings up.
///
/// What this *can* do is the part only the device at the table can: know which
/// occasion a recording belongs to, and stamp it on the way out. Grouping and
/// publishing then happen wherever there is a machine capable of them, whenever
/// it next wakes.
@MainActor
final class SessionState: ObservableObject {
    @Published private(set) var id: String?
    @Published private(set) var label: String?
    @Published private(set) var startedAt: Date?

    private static let idKey = "transcripts.session.id"
    private static let labelKey = "transcripts.session.label"
    private static let startKey = "transcripts.session.startedAt"

    /// Sessions here run for hours across app suspensions, so the state lives in
    /// defaults rather than memory. A session is small and flat — three values —
    /// which is exactly what defaults are for.
    init() {
        let d = UserDefaults.standard
        id = d.string(forKey: Self.idKey)
        label = d.string(forKey: Self.labelKey)
        let t = d.double(forKey: Self.startKey)
        startedAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var isRunning: Bool { id != nil }

    func start(id: String, label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.label = (trimmed?.isEmpty == false) ? trimmed : nil
        self.startedAt = Date()
        let d = UserDefaults.standard
        d.set(id, forKey: Self.idKey)
        d.set(self.label, forKey: Self.labelKey)
        d.set(self.startedAt!.timeIntervalSince1970, forKey: Self.startKey)
    }

    func end() {
        id = nil; label = nil; startedAt = nil
        let d = UserDefaults.standard
        [Self.idKey, Self.labelKey, Self.startKey].forEach(d.removeObject(forKey:))
    }

    /// Session profiles, read from the routing config in the shared folder.
    ///
    /// The same `routing.json` the Mac writes — both sides point at one vault,
    /// so the phone can offer exactly the sessions the Mac knows about without
    /// a second place to configure them. Nil access (no folder chosen yet) gives
    /// an empty list rather than an error: an empty Shortcuts picker is a
    /// reasonable thing to see before setup.
    static func profiles(in destination: Destination) -> [SessionProfile] {
        guard let root = destination.root else { return [] }
        var found: [SessionProfile] = []
        try? destination.withAccess { _ in
            let url = root.appendingPathComponent(".transcripts/routing.json")
            guard let data = try? Data(contentsOf: url),
                  let cfg = try? JSONDecoder().decode(RoutingConfig.self, from: data)
            else { return }
            found = cfg.sessions
        }
        return found
    }
}
