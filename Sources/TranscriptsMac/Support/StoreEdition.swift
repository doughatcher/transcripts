import AppKit
import TranscriptsCore
import TranscriptsEngine   // Log

/// What the Mac App Store build (the TranscriptsMacStore target, compiled with
/// APP_STORE) does differently from the direct download. Kept in one place so
/// the differences can be read in one sitting rather than hunted for.
///
/// The store build is sandboxed and cannot run other programs. So it has no
/// shell commands anywhere (sorting scripts, the handoff pipeline, script
/// stages, session "on complete" commands, a shell "open with"), does not
/// start Ollama for you, and does not update or install itself — the App
/// Store does that. Everything else is the same app.
///
/// Three layers, so a leftover setting can never reach a shell: the command
/// runner refuses; the config is cleaned when loaded; and Settings does not
/// show what cannot work.
enum StoreEdition {

    #if APP_STORE
    static let isStore = true
    #else
    static let isStore = false
    #endif

    // MARK: - Commands

    /// The runner the pipeline, sorting and sessions use. The store build gets
    /// one that refuses, whatever the config says.
    static func commandRunner() -> CommandRunner {
        #if APP_STORE
        return RefusingCommandRunner()
        #else
        return ProcessCommandRunner()
        #endif
    }

    /// Resets anything that would need a shell to its built-in equivalent.
    /// Returns true when something changed, so the caller can save.
    @discardableResult
    static func sanitize(_ config: inout AppConfig) -> Bool {
        guard isStore else { return false }
        var changed = false
        if config.pipeline.mode == .handoff {
            config.pipeline.mode = .bakedIn
            changed = true
        }
        if config.pipeline.handoffCommand != nil {
            config.pipeline.handoffCommand = nil
            changed = true
        }
        for i in config.pipeline.stages.indices {
            if case .externalCommand = config.pipeline.stages[i].provider {
                config.pipeline.stages[i].provider = .native
                changed = true
            }
        }
        // An "open with" that is a URL (obsidian://…) still works through
        // NSWorkspace; anything else was a shell command.
        if let open = config.openCommand, urlTemplate(in: open) == nil {
            config.openCommand = nil
            changed = true
        }
        return changed
    }

    @discardableResult
    static func sanitize(_ routing: inout RoutingConfig) -> Bool {
        guard isStore, routing.mode == .script else { return false }
        routing.mode = .automatic
        return true
    }

    /// The `scheme://…` part of an "open with" template, if it has one:
    /// `open "obsidian://open?path={path_encoded}"` → `obsidian://open?path={path_encoded}`.
    static func urlTemplate(in template: String) -> String? {
        guard let range = template.range(of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"']+"#,
                                         options: .regularExpression) else { return nil }
        return String(template[range])
    }

    // MARK: - First launch

    /// The part of first launch that needs no UI, run from the very top of
    /// AppController.init — before it loads the config, and before anything in
    /// it can save one. SwiftUI builds the Settings scene, and so the
    /// controller, ahead of applicationDidFinishLaunching; the first build of
    /// this edition set its defaults after that, so they were read too late
    /// and then saved over (found in its own first run, 2026-09-22).
    static func prepareConfig() {
        guard isStore else { return }
        FolderAccess.restoreAll()
        let store = ConfigStore()
        let firstRun = !FileManager.default.fileExists(atPath: store.url.path)
        var cfg = (try? store.load()) ?? .default
        var changed = sanitize(&cfg)
        // A store install is someone who has never heard of this app, not
        // someone who built it. Recording the moment a call opens the mic is
        // right for the author and wrong as a stranger's first experience —
        // and illegal in all-party-consent places. Start them on "ask first":
        // a call brings up a notification, and recording starts on their
        // say-so. One setting away from automatic, for whoever wants it.
        if firstRun {
            cfg.consentMode = .twoParty
            changed = true
        }
        if changed { try? store.save(cfg) }
    }

    /// Makes sure the library folder is one this build can open. Runs from
    /// the app delegate, because it may put up a dialog; returns true when it
    /// changed the config, so the caller can have the controller reload it.
    ///
    /// A fresh sandboxed install can reach no folder at all, so the default
    /// iCloud Drive path would open nothing and the app would look empty with
    /// no explanation. Ask once, starting in iCloud Drive: the folder chosen
    /// becomes both the library and the folder the iPhone and iPad send
    /// recordings to, which is the setup the phone app suggests too. Declining
    /// keeps a library inside the app's own container, so the app still works
    /// on this Mac alone and a folder can be chosen later in Settings.
    @MainActor
    static func prepareLibrary() -> Bool {
        guard isStore else { return false }
        let store = ConfigStore()
        var cfg = (try? store.load()) ?? .default
        let root = cfg.destinations.resolvedRoot.path
        if FolderAccess.canReach(root) || root.hasPrefix(NSHomeDirectory()) { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Where should Transcripts keep your recordings?"
        alert.informativeText = """
            Choose a folder in iCloud Drive to see your transcripts on your iPhone \
            and iPad too — pick the same “Transcripts” folder the iPhone app uses, \
            or create one. Recordings from your phone that land there are \
            transcribed on this Mac.

            You can change this later in Settings.
            """
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Keep on This Mac Only")

        var picked: String?
        if alert.runModal() == .alertFirstButtonReturn {
            let start = Locations.iCloudDrive()
                ?? URL(fileURLWithPath: Locations.userHome)
                    .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            let suggested = start.appendingPathComponent(Locations.folderName, isDirectory: true)
            picked = SettingsView.chooseFolder(
                title: "Choose your Transcripts folder",
                startingAt: FileManager.default.fileExists(atPath: suggested.path) ? suggested : start)
        }
        if let picked {
            cfg.destinations.knowledgeRoot = SettingsView.tildeify(picked)
            cfg.destinations.deviceInbox = SettingsView.tildeify(picked)
            Log.write("store: library set to \(picked)")
        } else {
            let local = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/\(Locations.folderName)", isDirectory: true)
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            cfg.destinations.knowledgeRoot = local.path
            cfg.destinations.deviceInbox = nil
            Log.write("store: library kept on this Mac at \(local.path)")
        }
        try? store.save(cfg)
        return true
    }
}

#if APP_STORE
/// Refuses every command. The store build is sandboxed, and App Review does
/// not allow an app to run arbitrary programs; `StoreEdition.sanitize` keeps
/// the config from asking, and this makes sure nothing slips through if it does.
struct RefusingCommandRunner: CommandRunner {
    func run(_ command: ExternalCommand, stdin: Data?) async throws -> CommandResult {
        Log.write("store: refused to run \(command.executable) — not available in the App Store edition")
        throw CommandRunnerError.launchFailed(
            "running other programs is not available in the App Store edition of Transcripts")
    }
}
#endif
