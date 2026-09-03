import SwiftUI
import AppKit
import TranscriptsCore
import TranscriptsEngine
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var controller: AppController

    /// Pins the visible tab for offscreen doc-screenshot rendering (`DocCapture`).
    /// nil in normal use, so the tab bar stays interactive.
    var forcedTab: Int? = nil
    @State private var selection = 0
    /// Read once when the pane appears, not from the body: `known()` reads
    /// Obsidian's registry and stats every vault in it, and a body that does
    /// that re-runs the lot on each keystroke in the vault field.
    @State private var knownVaults: [URL] = []

    /// The same discipline for the audio devices and the login item, and here it
    /// was costing real time. `TabView` builds every tab's body, not just the
    /// visible one, so each click on the tab bar re-ran all of it — and this
    /// pane observes `AppController`, whose `inputLevel` and `tick` publish many
    /// times a second, so it also re-ran while nothing was being clicked at all.
    ///
    /// Per render it was: a CoreAudio device enumeration, a second CoreAudio
    /// call to resolve the chosen input, and an `SMAppService` status query.
    /// Worse, the enumeration went through `availableInputs()`, which caches
    /// device names into `config` — and `config`'s `didSet` writes the file to
    /// disk and republishes. A view body that writes to disk and invalidates
    /// itself is not a view body; it settles only because the names stop
    /// changing.
    @State private var connectedInputs: [AudioInputDevice] = []
    @State private var resolvedInput: AudioInputDevice?
    @State private var launchAtLogin = false

    /// Off the render path deliberately — this is the call that may write config.
    private func refreshDeviceState() {
        connectedInputs = controller.availableInputs()
        resolvedInput = controller.resolvedInput
        launchAtLogin = controller.launchAtLoginEnabled
    }

    var body: some View {
        TabView(selection: Binding(get: { forcedTab ?? selection },
                                   set: { selection = $0 })) {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            voicesTab.tabItem { Label("Voices", systemImage: "person.wave.2") }.tag(1)
            sortingTab.tabItem { Label("Sorting", systemImage: "tray.and.arrow.down") }.tag(2)
            pipelineTab.tabItem { Label("Pipeline", systemImage: "arrow.triangle.branch") }.tag(3)
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag(4)
        }
        .frame(width: 580, height: 520)
        .padding()
        .onAppear {
            // Accessory apps open Settings behind other windows; bring it forward.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { NSApp.keyWindow?.orderFrontRegardless() }
            refreshDeviceState()
        }
        // A mic plugged in while Settings is open should still appear, so the
        // list refreshes when the window comes forward rather than never.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refreshDeviceState() }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Microphone") {
                inputDevicePicker
            }
            Section("Recording") {
                Toggle("Auto-record when the mic goes live", isOn: binding(\.autoRecordOnMicActivation))
                Toggle("Capture system audio (the other side of calls)", isOn: binding(\.captureSystemAudio))
                Picker("Consent mode", selection: binding(\.consentMode)) {
                    Text("One-party — auto-record calls").tag(ConsentMode.oneParty)
                    Text("Two-party — announce & confirm first").tag(ConsentMode.twoParty)
                }
                Text(controller.config.consentMode == .twoParty
                     ? "When a call is detected, Transcripts notifies you to announce recording; it starts only when you confirm."
                     : "Records automatically when a call is detected. Use only where one-party consent is lawful.")
                    .font(.caption2).foregroundStyle(.secondary)
                TextField("Archive codec", text: binding(\.archiveCodec))
                NotificationStatusRow()
            }
            Section("Overlay") {
                Toggle("Show the overlay during calls", isOn: binding(\.overlay.enabled))
                Text("A small floating panel showing key facts, and answers to questions raised — drawn only from what was said in the call and from your notes. It never answers from the model's own knowledge, and always says where an answer came from.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Search my notes for answers", isOn: binding(\.overlay.searchNotes))
                    .disabled(!controller.config.overlay.enabled)
                Text(controller.config.overlay.searchNotes
                     ? "Reads the Markdown notes under your transcripts folder to answer questions. Everything stays on this Mac."
                     : "Answers come only from earlier in the same call.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Launch Transcripts at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { controller.setLaunchAtLogin($0); launchAtLogin = $0 }
                ))
                Picker("Menu bar icon", selection: binding(\.menuBarIcon)) {
                    Text("Transport (stop · standby · record)").tag(MenuBarIconStyle.transport)
                    Text("Transcripts mark").tag(MenuBarIconStyle.mark)
                    Text("Waveform").tag(MenuBarIconStyle.waveform)
                    Text("Microphone").tag(MenuBarIconStyle.microphone)
                }
                HStack {
                    ColorPicker("Recording color", selection: recordingColorBinding, supportsOpacity: false)
                    if controller.config.recordingColorHex.caseInsensitiveCompare(HexColor.violet) != .orderedSame {
                        Button("Violet") { controller.config.recordingColorHex = HexColor.violet }
                            .controlSize(.small)
                    }
                    if controller.config.recordingColorHex.caseInsensitiveCompare(HexColor.azure) != .orderedSame {
                        Button("Azure") { controller.config.recordingColorHex = HexColor.azure }
                            .controlSize(.small)
                    }
                    if controller.config.recordingColorHex.caseInsensitiveCompare(HexColor.recordingRed) != .orderedSame {
                        Button("Red") { controller.config.recordingColorHex = HexColor.recordingRed }
                            .controlSize(.small)
                    }
                }
                Text("The pulsing menu-bar icon and the popover's recording marks.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper("Recent in menu: \(controller.config.recentsLimit)",
                        value: binding(\.recentsLimit), in: 5...50)
            }
            Section("Backups") {
                Stepper(controller.config.backupRetentionDays == 0
                        ? "Keep backups: forever"
                        : "Keep backups: \(controller.config.backupRetentionDays) days",
                        value: binding(\.backupRetentionDays), in: 0...365, step: 5)
                HStack {
                    Text("Audio + transcript per recording, auto-pruned.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal…") { controller.revealBackups() }
                }
            }
            Section("Opening") {
                TextField("Open with", text: openCommandBinding,
                          prompt: Text(#"open "obsidian://open?path={path_encoded}""#))
                    .textFieldStyle(.roundedBorder)
                Text("Optional. Opens a recording's document with this command. **{path}** is the file path (for `open -a \"App\" \"{path}\"`); **{path_encoded}** is URL-encoded (for URIs like `obsidian://`). Blank = Transcripts's built-in viewer.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Use Obsidian") { controller.config.openCommand = #"open "obsidian://open?path={path_encoded}""# }
                    if controller.canOpenExternally {
                        Button("Clear") { controller.config.openCommand = nil }
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Voices

    private var voicesTab: some View {
        Form {
            Section("In-person recordings") {
                Toggle("My microphone records a room", isOn: binding(\.micRecordsARoom))
                Text("For meetings, games or interviews where several people share one microphone. Transcripts splits the microphone track by voice instead of treating all of it as you. Detected calls are unaffected — there the other side is captured separately, which is better evidence than any clustering.")
                    .font(.caption2).foregroundStyle(.secondary)
                Slider(value: binding(\.roomVoiceSensitivity), in: 0.55...0.80, step: 0.01) {
                    Text("Telling voices apart")
                } minimumValueLabel: {
                    Text("Split").font(.caption2)
                } maximumValueLabel: {
                    Text("Merge").font(.caption2)
                }
                .disabled(!controller.config.micRecordsARoom)
                Text(controller.config.roomVoiceSensitivity > 0
                     ? "At \(String(format: "%.2f", controller.config.roomVoiceSensitivity)) — small changes matter a lot here."
                     : "Using the default (\(String(format: "%.2f", FluidAudioDiarizer.roomClusteringThreshold))), which leans towards splitting.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("More voices than people is normal and fine: someone doing a character genuinely sounds like someone else, and you can name several voices as the same person. Two people merged into one voice cannot be separated afterwards, so err towards splitting.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Speaker names") {
                Toggle("Name speakers automatically (best-effort)", isOn: binding(\.rememberVoices))
                Text("Off by default, transcripts label your voice **Me** and everyone else **Others** - always correct. Turn this on and Transcripts splits the other side into individual people and learns their voices to name them on future calls.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("**It's guessing from voice alone** - about as accurate as commercial meeting tools, but it will put the wrong name on someone now and then. **Review & fix attributions** below is how you catch and correct that, and each fix retrains the voice. Enable this only if you're willing to manage the occasional correction.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.config.rememberVoices {
                    Text("Voice profiles are stored only on this Mac. Your own voice is learned from the mic; anyone else is remembered only after you confirm. A few seconds of each voice is kept so you can play it back here.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Only name when sure")
                        Slider(value: binding(\.nameMatchConfidence), in: 0.45...0.9)
                        Text("\(Int(controller.config.nameMatchConfidence * 100))%")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    Text("How confident a voice match must be to put a name on it. Higher keeps more speakers as **Me / Others** rather than risk a wrong name. Below the bar, a voice stays anonymous.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Your organization", text: binding(\.homeOrganization))
                        .textFieldStyle(.roundedBorder)
                    Text("The default affiliation for colleagues. Voices from a call sorted into a **Cases/<Client>/** folder are tagged with that client instead; you can edit any below.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if controller.config.rememberVoices {
                Section {
                    VoicesGrid()
                }
                Section("Review & fix attributions") {
                    Text("Hear each speaker from a meeting and correct anyone matched to the wrong person. A fix retrains the voice and rewrites that transcript.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MeetingReview()
                }
                Section("Maintain with an agent") {
                    Text("Voice profiles live in a plain JSON file — names, affiliations, and per-voice metadata (the biometric embeddings are just numbers, and never leave this Mac). Point a coding agent (GitHub Copilot, Claude) at it to bulk-fill affiliations, reconcile names against your meeting invites, or enrich from your knowledge base. Each pending voice records the meeting name + date, so an agent can look up who was on the call.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(controller.voicesFileURL.path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Copy path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(controller.voicesFileURL.path, forType: .string)
                        }.controlSize(.small)
                        Button("Reveal…") { controller.revealVoicesFile() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Bridges the stored `#RRGGBB` to the ColorPicker's `Color`. Writes back a
    /// canonical sRGB hex so config stays diff-clean and the menu-bar renderer
    /// (which keys its cache on hex) sees a stable value.
    private var recordingColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: .fromHex(controller.config.recordingColorHex)) },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .fromHex(HexColor.recordingRed)
                controller.config.recordingColorHex = HexColor.string(
                    r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
            }
        )
    }

    private var openCommandBinding: Binding<String> {
        Binding(
            get: { controller.config.openCommand ?? "" },
            set: { controller.config.openCommand = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Sorting

    private var sortingTab: some View {
        Form {
            Section("Destination") {
                HStack {
                    TextField("Knowledge root", text: binding(\.destinations.knowledgeRoot))
                    Button("Choose…") {
                        if let picked = Self.chooseFolder(title: "Choose the knowledge root") {
                            controller.config.destinations.knowledgeRoot = Self.tildeify(picked)
                        }
                    }
                }
            }

            Section("Obsidian") {
                HStack {
                    TextField("Vault", text: binding(\.destinations.vaultMirror, default: ""))
                    Button("Choose…") {
                        if let picked = Self.chooseFolder(title: "Choose your Obsidian vault") {
                            controller.config.destinations.vaultMirror = Self.tildeify(picked)
                        }
                    }
                    if controller.config.destinations.vaultMirror?.isEmpty == false {
                        Button("Clear") { controller.config.destinations.vaultMirror = nil }
                    }
                }
                // Offered rather than assumed for a vault other than the one
                // detected — with several vaults, which one the notes belong in
                // is the user's call.
                ForEach(knownVaults.prefix(3), id: \.self) { vault in
                    if controller.config.destinations.vaultMirror.map({ (($0 as NSString).expandingTildeInPath) })
                        != vault.path {
                        Button("Use “\(vault.lastPathComponent)”") {
                            controller.config.destinations.vaultMirror = Self.tildeify(vault.path)
                        }
                    }
                }
                Text("A copy of each finished transcript is filed into your vault, in the same folder Sorting routed it to. The audio is not copied — it stays in the knowledge root, so a vault carried by Obsidian Sync doesn't fill up with recordings. Blank = off.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Devices") {
                HStack {
                    TextField("Device inbox (iPhone / iPad)",
                              text: binding(\.destinations.deviceInbox, default: ""))
                    Button("Choose…") {
                        if let picked = Self.chooseFolder(title: "Choose the folder your devices sync to") {
                            controller.config.destinations.deviceInbox = Self.tildeify(picked)
                            controller.startDeviceWatcher()
                        }
                    }
                    if controller.config.destinations.deviceInbox?.isEmpty == false {
                        Button("Clear") {
                            controller.config.destinations.deviceInbox = nil
                            controller.startDeviceWatcher()
                        }
                    }
                }
                if Locations.isICloudAvailable,
                   controller.config.destinations.deviceInbox != Locations.defaultDeviceInbox() {
                    Button("Use iCloud Drive") {
                        controller.config.destinations.deviceInbox = Locations.defaultDeviceInbox()
                        controller.startDeviceWatcher()
                    }
                }
                Text("Pick the same folder the Transcripts app on your iPhone or iPad sends to — its iCloud Drive or OneDrive folder shows up here as an ordinary directory. Recordings dropped there are imported and run through the full pipeline. Blank = off.")
                    .font(.caption2).foregroundStyle(.secondary)
                // Named rather than detected: whether a Mac is MDM-enrolled says
                // nothing reliable about whether client data belongs in a personal
                // iCloud account, and that call isn't one a heuristic should make.
                Text("On a work machine, check your organisation's policy before syncing meeting recordings through a personal cloud account.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Sorting") {
                Picker("File recordings", selection: routingBinding(\.mode)) {
                    Text("Automatic (on-device)").tag(RoutingConfig.Mode.automatic)
                    Text("Custom script").tag(RoutingConfig.Mode.script)
                    Text("Off — fixed folder").tag(RoutingConfig.Mode.off)
                }
                TextField("Default / fallback folder", text: routingBinding(\.fallback))

                if controller.routing.mode == .automatic {
                    HStack {
                        Text("Match confidence")
                        Slider(value: routingBinding(\.confidenceThreshold), in: 0.2...0.9)
                        Text("\(Int(controller.routing.confidenceThreshold * 100))%")
                            .monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    Text("Auto-discovers every */transcripts/ folder; matches on keywords then the on-device model, else the fallback.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if controller.routing.mode == .script {
                    TextField("Script executable", text: scriptExecBinding)
                    TextField("Arguments (${transcriptURL} ${audioURL} ${title})", text: scriptArgsBinding)
                    Text("Runs when a recording is done; print a vault-relative destination (or JSON {\"destination\":\"…\"}).")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                HStack {
                    Text("Advanced rules: .transcripts/routing.json").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal…") { controller.revealRoutingConfig() }
                }
                Button("Re-sort existing recordings…") { controller.resortAll() }
                    .help("Re-run the current rules over every recording and move any that changed.")
            }

            // Sessions were configurable from the day they shipped and settable
            // only by hand-editing routing.json, which meant that for anyone who
            // had not read the guide they did not exist. The Shortcuts action
            // has always been able to start one; it just offered an empty picker.
            Section("Sessions") {
                ForEach($controller.routing.sessions) { $session in
                    DisclosureGroup {
                        TextField("Name", text: $session.name)

                        HStack {
                            TextField("Files go to", text: Binding(
                                get: { session.destination ?? "" },
                                set: { session.destination = $0.isEmpty ? nil : $0 }))
                            Button("Choose…") {
                                if let picked = Self.chooseSessionFolder(under: controller) {
                                    session.destination = picked
                                }
                            }
                        }

                        Picker("Ends after", selection: $session.idleTimeout) {
                            Text("30 minutes idle").tag(TimeInterval(1_800))
                            Text("1 hour idle").tag(TimeInterval(3_600))
                            Text("2 hours idle").tag(TimeInterval(7_200))
                            Text("3 hours idle").tag(TimeInterval(10_800))
                            Text("Never (end it yourself)").tag(TimeInterval(0))
                        }

                        HStack {
                            TextField("…or at (HH:mm)", text: Binding(
                                get: { session.hardStop ?? "" },
                                set: { session.hardStop = $0.isEmpty ? nil : $0 }))
                            if session.hardStop?.isEmpty == false && session.hardStopComponents == nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Not a time — use 24-hour HH:mm, e.g. 23:30. Left as is, there is no backstop.")
                            }
                        }

                        TextField("When it ends, run", text: Binding(
                            get: { Self.commandText(session.onComplete) },
                            set: { session.onComplete = Self.command(from: $0) }))
                        Text("Runs once, when the whole session is over. ${sessionLabel}, ${sessionName} and the session's files are substituted in.")
                            .font(.caption2).foregroundStyle(.secondary)

                        Button("Remove “\(session.name)”", role: .destructive) {
                            controller.routing.sessions.removeAll { $0.id == session.id }
                        }
                    } label: {
                        HStack {
                            Text(session.name)
                            Spacer()
                            Text(session.destination ?? "filed normally")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Button("Add a session…") {
                    controller.routing.sessions.append(
                        SessionProfile(id: Self.freshSessionID(in: controller.routing.sessions),
                                       name: "New session"))
                }
                Text("A session groups an evening's recordings under one name — a game night, a workshop, a day of interviews — and runs its action once at the end rather than after every recording. Start and end one from Shortcuts, so a weekly game can record itself.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Summarization") {
                Picker("Engine", selection: binding(\.llmProvider)) {
                    Text("Automatic (on-device, self-contained)").tag(LLMProvider.appleOnDevice)
                    Text("Ollama (local server)").tag(LLMProvider.ollama)
                }
                Text("Active: \(controller.llmStatus)")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.config.llmProvider == .ollama {
                    TextField("Ollama URL", text: binding(\.ollama.url))
                    TextField("Ollama model", text: binding(\.ollama.model))
                }
                Text("Transcription is always on-device (Apple Speech). No Whisper or model download needed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { knownVaults = ObsidianVault.known() }
    }

    private func routingBinding<T>(_ keyPath: WritableKeyPath<RoutingConfig, T>) -> Binding<T> {
        Binding(
            get: { controller.routing[keyPath: keyPath] },
            set: { controller.routing[keyPath: keyPath] = $0 }
        )
    }

    private var scriptExecBinding: Binding<String> {
        Binding(
            get: { controller.routing.script?.executable ?? "" },
            set: { newValue in
                var cmd = controller.routing.script ?? ExternalCommand(executable: newValue)
                cmd.executable = newValue
                controller.routing.script = cmd
            }
        )
    }

    private var scriptArgsBinding: Binding<String> {
        Binding(
            get: { (controller.routing.script?.arguments ?? []).joined(separator: " ") },
            set: { newValue in
                var cmd = controller.routing.script ?? ExternalCommand(executable: "/bin/bash")
                cmd.arguments = newValue.split(separator: " ").map(String.init)
                controller.routing.script = cmd
            }
        )
    }

    @ViewBuilder
    private var inputDevicePicker: some View {
        let favoriteInputs = controller.favoriteInputs(connectedDevices: connectedInputs)
        let favoriteUIDs = Set(favoriteInputs.map(\.uid))
        let otherInputs = connectedInputs.filter { !favoriteUIDs.contains($0.uid) }

        HStack(spacing: 6) {
            Image(systemName: "mic")
            Text("Recording from:")
            if let r = resolvedInput {
                Text(r.name).foregroundStyle(.secondary)
            } else {
                Text("no input found").foregroundStyle(.orange)
            }
        }
        .font(.caption)

        if !favoriteInputs.isEmpty {
            Text("Favorites (top = highest priority)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(favoriteInputs.enumerated()), id: \.element.id) { index, favorite in
                favoriteInputRow(favorite, index: index, count: favoriteInputs.count)
            }
        }

        if !favoriteInputs.isEmpty && !otherInputs.isEmpty {
            Divider()
        }

        if !otherInputs.isEmpty {
            Text("Other connected microphones")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(otherInputs) { dev in
                availableInputRow(dev)
            }
        }

        if favoriteInputs.isEmpty && otherInputs.isEmpty {
            Text("No microphone inputs found.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }

        if controller.hasInputOverride {
            Button("Use favorites (clear override)") { controller.setInputOverride(nil) }
                .font(.caption)
        }

        Text("★ favorites are always listed here, even when unplugged. Transcripts records from the highest-priority favorite that's connected, top to bottom. Click a connected mic to force it for now; that beats favorites.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func favoriteInputRow(_ favorite: AppController.FavoriteInputChoice, index: Int, count: Int) -> some View {
        let inUse = resolvedInput?.uid == favorite.uid
        let forced = controller.config.overrideInputUID == favorite.uid

        HStack(spacing: 8) {
            Button {
                controller.toggleFavoriteInput(favorite.uid)
            } label: {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .help("Remove favorite")

            if favorite.isConnected {
                Button {
                    controller.setInputOverride(forced ? nil : favorite.uid)
                } label: {
                    HStack(spacing: 6) {
                        Text(favorite.name).fontWeight(inUse ? .semibold : .regular)
                        Spacer()
                        if forced { Text("forced").font(.caption2).foregroundStyle(.secondary) }
                        if inUse { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    Text(favorite.name)
                    Spacer()
                    Text("not connected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Button {
                    controller.moveFavoriteInput(uid: favorite.uid, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button {
                    controller.moveFavoriteInput(uid: favorite.uid, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(index == count - 1)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func availableInputRow(_ dev: AudioInputDevice) -> some View {
        let inUse = resolvedInput?.uid == dev.uid
        let forced = controller.config.overrideInputUID == dev.uid

        HStack(spacing: 8) {
            Button {
                controller.toggleFavoriteInput(dev.uid)
            } label: {
                Image(systemName: "star")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Make favorite")

            Button {
                controller.setInputOverride(forced ? nil : dev.uid)
            } label: {
                HStack(spacing: 6) {
                    Text(dev.name).fontWeight(inUse ? .semibold : .regular)
                    Spacer()
                    if forced { Text("forced").font(.caption2).foregroundStyle(.secondary) }
                    if inUse { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pipeline

    private var pipelineTab: some View {
        Form {
            Picker("Mode", selection: binding(\.pipeline.mode)) {
                Text("Baked-in (native stages)").tag(PipelineMode.bakedIn)
                Text("Handoff (one external script)").tag(PipelineMode.handoff)
            }
            .pickerStyle(.radioGroup)

            if controller.config.pipeline.mode == .handoff {
                handoffEditor
            } else {
                Section("Stages") {
                    ForEach(Array(controller.config.pipeline.stages.enumerated()), id: \.offset) { index, stage in
                        StageRow(index: index)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var handoffEditor: some View {
        Section("Handoff command") {
            Text("Receives ${audioURL} and the full context JSON on stdin / $TRANSCRIPTS_CONTEXT_JSON.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Executable", text: Binding(
                get: { controller.config.pipeline.handoffCommand?.executable ?? "/bin/bash" },
                set: { newValue in
                    var cmd = controller.config.pipeline.handoffCommand ?? ExternalCommand(executable: newValue)
                    cmd.executable = newValue
                    controller.config.pipeline.handoffCommand = cmd
                }
            ))
            TextField("Arguments (space-separated)", text: Binding(
                get: { (controller.config.pipeline.handoffCommand?.arguments ?? []).joined(separator: " ") },
                set: { newValue in
                    var cmd = controller.config.pipeline.handoffCommand ?? ExternalCommand(executable: "/bin/bash")
                    cmd.arguments = newValue.split(separator: " ").map(String.init)
                    controller.config.pipeline.handoffCommand = cmd
                }
            ))
        }
    }

    // MARK: - Bindings

    private func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { controller.config[keyPath: keyPath] },
            set: { controller.config[keyPath: keyPath] = $0 }
        )
    }

    /// Optional-backed field: an empty field means "unset", not an empty string,
    /// so clearing the box actually switches the feature off.
    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<AppConfig, T?>,
                                       default fallback: T) -> Binding<T> {
        Binding(
            get: { controller.config[keyPath: keyPath] ?? fallback },
            set: { controller.config[keyPath: keyPath] = ($0 == fallback) ? nil : $0 }
        )
    }

    /// Directory picker. A text field alone can't reach
    /// `~/Library/CloudStorage/…` or `~/Library/Mobile Documents/…` comfortably —
    /// both are hidden from Finder's sidebar by default — and those are exactly
    /// where a device inbox lives.
    static func chooseFolder(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    /// Stores paths under the home directory as `~/…` so a config stays readable
    /// and portable between accounts.
    static func tildeify(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Sessions

    /// Says no out loud. A picker that closes and leaves the field unchanged
    /// reads as a bug in the picker.
    private static func warn(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// A session destination is a folder *inside* the knowledge root, stored
    /// relative to it — the same shape the routing table uses. Picking an
    /// absolute path elsewhere would file the evening outside the library
    /// entirely, so anything outside the root is refused rather than silently
    /// stored as something that will not route.
    static func chooseSessionFolder(under controller: AppController) -> String? {
        guard let picked = chooseFolder(title: "Choose where this session's recordings go") else { return nil }
        let root = controller.config.destinations.resolvedRoot.standardizedFileURL.path
        guard picked.hasPrefix(root) else {
            warn("That folder is outside your knowledge root",
                 "A session files into a folder inside \(root). Pick one there, or move your knowledge root first.")
            return nil
        }
        let relative = String(picked.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "" : relative + "/"
    }

    /// An id that is not already taken. Ids are referenced by the Shortcuts
    /// action and by a session that is currently running, so one is minted once
    /// here and never derived from the name again — renaming "D&D" to "Curse of
    /// Strahd" must not orphan the evening already in progress.
    static func freshSessionID(in existing: [SessionProfile]) -> String {
        let taken = Set(existing.map(\.id))
        var n = 1
        while taken.contains("session-\(n)") { n += 1 }
        return "session-\(n)"
    }

    /// The completion command as one editable line, matching how the routing
    /// script is edited above. First word is the executable, the rest arguments.
    static func commandText(_ command: ExternalCommand?) -> String {
        guard let command else { return "" }
        return ([command.executable] + command.arguments).joined(separator: " ")
    }

    static func command(from text: String) -> ExternalCommand? {
        let parts = text.split(separator: " ").map(String.init)
        guard let executable = parts.first else { return nil }
        return ExternalCommand(executable: executable, arguments: Array(parts.dropFirst()))
    }

}

/// About / security / consent information.
struct AboutTab: View {
    @EnvironmentObject private var controller: AppController

    private static let siteURL = URL(string: "https://transcripts.doughatcher.com")!
    private static let guideURL = URL(string: "https://transcripts.doughatcher.com/guide")!
    private static let supportURL = URL(string: "mailto:support@hatcher.ltd?subject=Transcripts")!
    /// An app whose whole claim is that nothing leaves the device should let you
    /// go and check that for yourself. It sits outside the row of links below
    /// because a fifth Label does not fit in a 580pt window.
    private static let sourceURL = URL(string: "https://github.com/doughatcher/transcripts")!
    /// Reports still land in the support repository rather than alongside the
    /// code: that is where the existing threads and the people subscribed to
    /// them already are, and splitting them costs more than the tidiness gains.
    private static let issuesURL = URL(string: "https://github.com/doughatcher/transcripts-support/issues")!

    private static let author = "Doug Hatcher"

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill").font(.largeTitle).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("Transcripts").font(.title2.bold())
                        Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates…") { controller.checkForUpdatesInteractive() }
                }

                Toggle("Ride the beta train — offer pre-release builds", isOn: Binding(
                    get: { controller.config.includePrereleases },
                    set: { controller.config.includePrereleases = $0 }))
                Text("Update checks will include pre-releases (e.g. 0.8.1-beta.1) before they're blessed as stable. Betas are field-tested first, but expect rough edges.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Recording consent", systemImage: "exclamationmark.shield")
                            .font(.headline)
                        Text("Only record where you are legally permitted. Use Transcripts **only in one-party-consent jurisdictions**, or where **all participants have consented**. Recording laws vary by state and country — when in doubt, get explicit consent from everyone on the call. You are responsible for lawful use.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Privacy & security", systemImage: "lock.shield")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            bullet("Fully on-device: transcription (Apple Speech) and summaries (Apple Intelligence, with a built-in fallback) run locally. No audio or transcript is sent to any cloud service.")
                            bullet("A local Ollama server is used for summaries only if you explicitly run one.")
                            bullet("Recordings and transcripts are stored locally — in your knowledge vault and under ~/Library/Application Support/Transcripts. Nothing leaves your Mac unless you move it.")
                            bullet("Microphone and Screen Recording access are granted by you via macOS; Transcripts never bypasses those prompts.")
                            bullet("No accounts, no analytics, no telemetry. The only network request Transcripts makes on its own is the update check.")
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("About", systemImage: "info.circle")
                            .font(.headline)
                        Text("Transcripts is made by \(Self.author).")
                            .font(.callout)
                        Link(destination: Self.sourceURL) {
                            Label("Source on GitHub — MIT licensed", systemImage: "curlybraces")
                        }
                        .font(.callout)
                        HStack(spacing: 18) {
                            Link(destination: Self.siteURL) {
                                Label("Website", systemImage: "globe")
                            }
                            Link(destination: Self.guideURL) {
                                Label("User guide", systemImage: "book")
                            }
                            Link(destination: Self.issuesURL) {
                                Label("Report an issue", systemImage: "ladybug")
                            }
                            Link(destination: Self.supportURL) {
                                Label("Support", systemImage: "envelope")
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Updates", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        Text("Transcripts checks its public releases on launch and installs new versions to ~/Applications. Installed with Homebrew? Use `brew upgrade --cask transcripts` instead, so Homebrew's records stay accurate.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Check now") { controller.checkForUpdatesInteractive() }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(s).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// One row per stage with a native / external / disabled selector.
private struct StageRow: View {
    @EnvironmentObject private var controller: AppController
    let index: Int

    private enum Kind: String, CaseIterable { case native, external, disabled }

    var body: some View {
        let stage = controller.config.pipeline.stages[index]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stage.id.rawValue.capitalized).frame(width: 90, alignment: .leading)
                Picker("", selection: kindBinding) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if case .externalCommand = stage.provider {
                TextField("Executable", text: execBinding)
                TextField("Arguments (space-separated)", text: argsBinding)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var kindBinding: Binding<Kind> {
        Binding(
            get: {
                switch controller.config.pipeline.stages[index].provider {
                case .native: return .native
                case .externalCommand: return .external
                case .disabled: return .disabled
                }
            },
            set: { kind in
                switch kind {
                case .native: controller.config.pipeline.stages[index].provider = .native
                case .disabled: controller.config.pipeline.stages[index].provider = .disabled
                case .external:
                    if case .externalCommand = controller.config.pipeline.stages[index].provider { break }
                    controller.config.pipeline.stages[index].provider =
                        .externalCommand(ExternalCommand(executable: "/bin/bash", arguments: ["-c", "echo ${transcriptURL}"]))
                }
            }
        )
    }

    private var execBinding: Binding<String> {
        Binding(
            get: {
                if case .externalCommand(let c) = controller.config.pipeline.stages[index].provider { return c.executable }
                return ""
            },
            set: { newValue in
                if case .externalCommand(var c) = controller.config.pipeline.stages[index].provider {
                    c.executable = newValue
                    controller.config.pipeline.stages[index].provider = .externalCommand(c)
                }
            }
        )
    }

    private var argsBinding: Binding<String> {
        Binding(
            get: {
                if case .externalCommand(let c) = controller.config.pipeline.stages[index].provider { return c.arguments.joined(separator: " ") }
                return ""
            },
            set: { newValue in
                if case .externalCommand(var c) = controller.config.pipeline.stages[index].provider {
                    c.arguments = newValue.split(separator: " ").map(String.init)
                    controller.config.pipeline.stages[index].provider = .externalCommand(c)
                }
            }
        )
    }
}

/// Notification authorization state + remedies (#8). Call-consent
/// announcements and dead-mic banners silently vanish while denied — this row
/// is the only place that says so.
private struct NotificationStatusRow: View {
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .authorized, .provisional:
                Label("Notifications enabled", systemImage: "bell")
                    .foregroundStyle(.secondary)
            case .denied:
                Label("Notifications are off — call-consent and mic alerts won't show",
                      systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open System Settings") { Notifier.openSystemSettings() }
            case .notDetermined:
                Label("Notifications not yet allowed", systemImage: "bell.badge")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enable") {
                    Notifier.shared.requestAuthorization()
                    Task { try? await Task.sleep(for: .seconds(2)); await refresh() }
                }
            default:
                Label("Checking notification access…", systemImage: "bell")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .task { await refresh() }
    }

    private func refresh() async {
        status = await Notifier.shared.authorizationStatus()
    }
}
