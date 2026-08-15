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
    /// Pre-workspaces keys, read once to carry an existing setup forward.
    private static let legacyBookmarkKey = "transcripts.destination.bookmark"
    private static let legacyManagedKey = "transcripts.destination.managed"

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
    static func coordinatedWrite(at url: URL, _ body: (URL) throws -> Void) throws {
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
            return
        }
        // Carry a pre-workspaces setup forward rather than making the user pick
        // their folder again.
        if let legacy = defaults.data(forKey: Self.legacyBookmarkKey) {
            let managed = defaults.bool(forKey: Self.legacyManagedKey)
            let name = Self.resolve(legacy).map { Self.suggestedName(for: $0, existing: []) } ?? "Recordings"
            let migrated = Workspace(id: UUID(), name: name, bookmark: legacy, managed: managed)
            workspaces = [migrated]
            activeID = migrated.id
            save()
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        try? JSONEncoder().encode(workspaces).map { defaults.set($0, forKey: Self.listKey) }
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
