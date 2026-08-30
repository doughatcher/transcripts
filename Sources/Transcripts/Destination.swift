import Foundation

/// A named place recordings go, and the library that lives there.
///
/// More than one, because the folders people record into aren't
/// interchangeable: a personal iCloud Drive and a work OneDrive are different
/// audiences, different retention, different rules about what may be in them.
/// Naming them ("Personal", "Work") and switching between them is what keeps a
/// client meeting out of a personal account by accident.
struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Security-scoped bookmark. The raw path is useless on its own — only this
    /// can reopen the folder after a relaunch.
    var bookmark: Data
    /// True when the user picked a parent and we own a `Transcripts/` folder inside.
    var managed: Bool
}

/// Holds the workspaces and which one is current.
///
/// The user grants access once per workspace through the document picker.
/// Because the picker lists every File Provider, this works identically for
/// OneDrive, SharePoint libraries, iCloud Drive, Dropbox or on-device storage —
/// which keeps the transport a user setting rather than a code dependency, and
/// sidesteps Graph OAuth and tenant app registrations on managed devices.
@MainActor
final class Destination: ObservableObject {
    private static let listKey = "transcripts.workspaces"
    private static let activeKey = "transcripts.workspace.active"

    /// Folder name created inside the picked root in "set up for me" mode.
    static let managedFolderName = "Transcripts"

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var problem: String?

    var active: Workspace? { workspaces.first { $0.id == activeID } }
    var managed: Bool { active?.managed ?? false }

    /// The granted folder itself. Security scope belongs to this, not to the
    /// subfolder we actually write into.
    var url: URL? { active.flatMap { Self.resolve($0.bookmark) } }

    /// Where captures and the library actually live.
    var root: URL? {
        guard let url else { return nil }
        return managed ? url.appendingPathComponent(Self.managedFolderName, isDirectory: true) : url
    }

    var displayName: String? { active?.name }

    init() { load() }

    // MARK: - Managing workspaces

    /// Suggests a name from the folder, so the common cases are already right
    /// and the user is confirming rather than composing.
    static func suggestedName(for url: URL, existing: [Workspace]) -> String {
        let component = url.lastPathComponent
        let base: String
        switch true {
        case component == "com~apple~CloudDocs", component.localizedCaseInsensitiveContains("icloud"):
            base = "Personal"
        case component.localizedCaseInsensitiveContains("onedrive"),
             component.localizedCaseInsensitiveContains("sharepoint"):
            base = "Work"
        // What the picker calls "On My iPhone" is really the app group's
        // "File Provider Storage" on disk. Showing that raw is how a perfectly
        // ordinary choice — keep it on the phone — ends up labelled with an
        // implementation detail.
        case component == "File Provider Storage":
            base = "This Device"
        default:
            base = component
        }
        guard existing.contains(where: { $0.name == base }) else { return base }
        var n = 2
        while existing.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }

    func add(_ picked: URL, name: String? = nil, managed: Bool = false) {
        // The picker hands back a security-scoped URL; the scope must be open
        // while the bookmark is created or the data is worthless on relaunch.
        let opened = picked.startAccessingSecurityScopedResource()
        defer { if opened { picked.stopAccessingSecurityScopedResource() } }
        do {
            let data = try picked.bookmarkData()
            if managed {
                let folder = picked.appendingPathComponent(Self.managedFolderName, isDirectory: true)
                try Self.coordinatedWrite(at: picked) { _ in
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                // Confirm rather than assume: an uncoordinated create against a
                // File Provider can "succeed" into a local shadow that never
                // syncs, which looks exactly like nothing happening (2026-08-03).
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    problem = "Couldn't create the \(Self.managedFolderName) folder in \(picked.lastPathComponent)."
                    return
                }
            }
            let workspace = Workspace(
                id: UUID(),
                name: name ?? Self.suggestedName(for: picked, existing: workspaces),
                bookmark: data,
                managed: managed)
            workspaces.append(workspace)
            activeID = workspace.id
            save()
            problem = nil
        } catch {
            problem = "Couldn't use that folder: \(error.localizedDescription)"
        }
    }

    func select(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = trimmed
        save()
    }

    /// Forgets a workspace. Only the grant — the folder and everything in it is
    /// untouched, and re-adding it brings the library straight back.
    func remove(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if activeID == id { activeID = workspaces.first?.id }
        save()
    }

    // MARK: - Access

    /// Runs `body` with the active workspace's security scope open, handing it
    /// the effective root. Every write into a File Provider folder must happen
    /// inside this.
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url, let root else { throw ExportError.noDestination }
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        var result: T?
        try Self.coordinatedWrite(at: url) { _ in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            result = try body(root)
        }
        guard let result else { throw ExportError.noDestination }
        return result
    }

    /// Scope for reads that happen off the main actor (the library scan). The
    /// bookmark is passed in because resolving it needs no actor isolation.
    nonisolated static func withScope<T>(bookmark: Data, _ body: () throws -> T) rethrows -> T {
        let granted = resolve(bookmark)
        let opened = granted?.startAccessingSecurityScopedResource() ?? false
        defer { if opened { granted?.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    nonisolated static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    }

    /// Wraps a write in `NSFileCoordinator`. iCloud Drive and OneDrive are File
    /// Providers: an uncoordinated write races the sync daemon, and the provider
    /// is free to ignore or clobber it. Coordination is what makes the change one
    /// the provider agrees to upload.
    /// `nonisolated` alongside `withScope` above, and for the same reason: the
    /// library's edits run off the main actor so a File Provider taking its time
    /// over a write doesn't stall the recorder's meters. It touches no instance
    /// state, so there is nothing here for the actor to protect.
    nonisolated static func coordinatedWrite(at url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { actual in
            do { try body(actual) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        if let coordinationError { throw coordinationError }
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([Workspace].self, from: data), !list.isEmpty {
            workspaces = list
            activeID = defaults.string(forKey: Self.activeKey).flatMap(UUID.init)
                ?? list.first?.id
        }
        #if DEBUG
        seedWorkspaceIfAsked()
        #endif
    }

    #if DEBUG
    /// Gives a simulator a workspace on launch, for `scripts/seed-simulator.sh`.
    ///
    /// The seeded library is invisible without one: with no destination the
    /// detail pane is the "where should recordings go?" setup, so a screenshot
    /// of a well-stocked app is a screenshot of its first-run wizard. The
    /// bookmark has to be minted in-process — one made anywhere else resolves
    /// to nothing inside this sandbox — which is why this cannot live in the
    /// shell script with the rest of the seeding.
    ///
    /// DEBUG-only, and the App Store build is Release, so this is compiled out
    /// of anything a user can install.
    private func seedWorkspaceIfAsked() {
        guard CommandLine.arguments.contains("--seed-workspace"), workspaces.isEmpty else { return }
        let root = URL.documentsDirectory.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        add(root, name: "Personal", managed: false)
    }
    #endif

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(workspaces) {
            defaults.set(data, forKey: Self.listKey)
        }
        defaults.set(activeID?.uuidString, forKey: Self.activeKey)
    }
}

enum ExportError: Error, LocalizedError {
    case noDestination

    var errorDescription: String? {
        switch self {
        case .noDestination:
            return "Choose a folder to send recordings to first."
        }
    }
}
