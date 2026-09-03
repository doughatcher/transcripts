import Foundation
import SwiftUI
import AppKit
import TranscriptsCore
import TranscriptsEngine

/// App-wide state and orchestration. Owns the config, the mic-activity watcher,
/// the recorder, and the pipeline engine. Drives the menu-bar UI.
@MainActor
final class AppController: ObservableObject {
    /// Shared instance so the AppKit status-bar controller (which owns the live
    /// menu-bar icon) and the SwiftUI Settings scene drive the same state.
    static let shared = AppController()

    enum State: Equatable {
        case idle          // auto-record off
        case armed         // waiting for the mic to go live
        case recording(since: Date)
        case processing
    }

    @Published private(set) var state: State = .idle
    /// Capped list for the menu (see config.recentsLimit).
    @Published private(set) var recents: [RecentItem] = []
    /// Full history for the Recordings browser window.
    @Published private(set) var allRecents: [RecentItem] = []
    /// Selection driving the Recordings window's detail pane.
    @Published var selectedRecordID: UUID?
    /// Live 0…1 mic input level, updated ~14×/sec while recording. Drives the EQ.
    @Published private(set) var inputLevel: Float = 0
    /// Short rolling history of input levels for the multi-bar EQ (oldest → newest).
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 14)
    /// Ticks every second while recording so the elapsed clock advances.
    @Published private(set) var tick: Int = 0
    @Published var config: AppConfig {
        didSet { persistConfig(); refreshRecents() }
    }
    /// Sorting rules, persisted to `<vault>/.transcripts/routing.json`.
    @Published var routing: RoutingConfig {
        didSet { try? makeRoutingStore().save(routing) }
    }
    @Published private(set) var lastError: String?

    struct RecentItem: Identifiable {
        let id: UUID              // the history record id
        let title: String
        let destination: String?
        let when: Date
        let status: RecordingRecord.Status
        /// The persisted `.md` document, so the menu can open it in the viewer.
        let path: URL?
        /// A failed item whose audio still exists can be reprocessed.
        let retryable: Bool
        /// Auto-started by call detection — used for grouping legacy fragments.
        let isCall: Bool
        /// Stable call identity (meeting name + day); fragments of one call share it.
        let callKey: String?
        /// Captured no usable audio — shown greyed as "No audio captured".
        let isEmpty: Bool
    }

    struct FavoriteInputChoice: Identifiable {
        let uid: String
        let name: String
        let device: AudioInputDevice?

        var id: String { uid }
        var isConnected: Bool { device != nil }
    }

    private let configStore: ConfigStore
    private let history = HistoryStore()
    private let watcher = MicActivityWatcher()
    private let callDetector = CallDetector()
    private var recorder: Recorder?
    private var systemCapturer: SystemAudioCapturer?
    private var levelTimer: Timer?
    /// Inputs that produced pure silence while recording this session — excluded
    /// from device selection so a dead-mic recovery can't re-pick them.
    private var deadInputUIDs: Set<String> = []
    /// A specific device to bind on the next recovery restart, bypassing the
    /// resolver. Set when we've identified the exact input carrying the signal —
    /// e.g. the Voice-Processing aggregate that swallowed the built-in mic — which
    /// the normal favorites/override rules wouldn't pick. Consumed once.
    private var pendingRecoveryDevice: AudioInputDevice?

    /// A slice of the current meeting that a mic recovery cut short. Its audio is
    /// held here and stitched back on when the meeting really ends, so switching
    /// mics mid-call produces one note instead of two.
    private struct CarriedFragment {
        let startedAt: Date
        let micAudioURL: URL
        let systemAudioURL: URL?
        let systemAudioStartOffset: Double?

        var persisted: RelaunchState.Fragment {
            RelaunchState.Fragment(startedAt: startedAt,
                                   micAudioPath: micAudioURL.path,
                                   systemAudioPath: systemAudioURL?.path,
                                   systemAudioStartOffset: systemAudioStartOffset)
        }

        init(startedAt: Date, micAudioURL: URL, systemAudioURL: URL?, systemAudioStartOffset: Double?) {
            self.startedAt = startedAt
            self.micAudioURL = micAudioURL
            self.systemAudioURL = systemAudioURL
            self.systemAudioStartOffset = systemAudioStartOffset
        }

        init(_ f: RelaunchState.Fragment) {
            startedAt = f.startedAt
            micAudioURL = URL(fileURLWithPath: f.micAudioPath)
            systemAudioURL = f.systemAudioPath.map { URL(fileURLWithPath: $0) }
            systemAudioStartOffset = f.systemAudioStartOffset
        }
    }

    /// Fragments awaiting stitching. Cleared when a recording starts fresh, so a
    /// crash or a new meeting can't graft yesterday's audio onto today's.
    ///
    /// Mirrored to disk on every change: these used to live only in memory, which
    /// meant restarting the app during a meeting lost the pieces it had already
    /// set aside. Persisting them is what lets one evening survive several
    /// rebuilds and still come out as a single recording.
    private var carriedFragments: [CarriedFragment] = [] {
        didSet { relaunch.saveFragments(carriedFragments.map(\.persisted)) }
    }
    /// Voice profiles (#6 Tier B): pending "remember this voice?" suggestions
    /// surfaced as menu banners. Note the pipeline's diarizer writes the same
    /// speakers.json via its own store instance; both sides do load-modify-save
    /// of a small file, and writes are rare enough that last-writer-wins is fine.
    @Published private(set) var voiceSuggestions: [SpeakerSuggestion] = []
    private lazy var speakerStore = SpeakerProfileStore(url: FluidAudioDiarizer.profilesURL)
    /// Per-meeting speaker attributions — what the review-and-correct UI reads.
    private lazy var attributionStore = AttributionStore(
        url: HistoryStore.dir.appendingPathComponent("attributions.json"))

    /// Live streaming transcript (macOS 26). `Any`-typed because stored
    /// properties can't be availability-gated; cast at use.
    private var liveTranscript: LiveTranscript?
    private var liveMicTranscriber: Any?
    private var liveSystemTranscriber: Any?
    /// Names the voice behind each mic turn while a room is recording. nil on
    /// a call, where the two tracks are better evidence than any clustering.
    private var liveDiarizer: LiveDiarizer?
    /// The overlay's engine and panel. `Any`-typed for the same reason the
    /// transcribers are: the overlay only has turns to work with on macOS 26.
    private var overlayEngine: Any?
    private let overlayPanel = OverlayPanel()
    /// Marker + fragment store that lets a relaunch pick a meeting back up.
    private let relaunch = RelaunchState(directory: HistoryStore.dir)
    /// Timer that lets a call with no questions still accrue facts.
    private var overlayTimer: Timer?
    /// True while the overlay is showing. Published so the menu's toggle and the
    /// panel's own close button can never disagree about the state.
    @Published private(set) var overlayVisible = false
    /// Fragments carried into the current recording by a relaunch — surfaced in
    /// the menu so a resumed meeting is visible rather than merely logged.
    @Published private(set) var resumedFragmentCount = 0
    /// The history record for the in-flight recording.
    private var currentRecordID: UUID?
    /// True while the current recording was auto-started by call detection, so we
    /// know to auto-stop it when the call ends.
    private var recordingIsCall = false
    /// In two-party mode, the app of a detected call awaiting the user's confirmation
    /// to start recording (drives the "announce & record" banner).
    @Published private(set) var pendingCallApp: String?

    private var deviceWatcher: DeviceInboxWatcher?

    init() {
        let store = ConfigStore()
        self.configStore = store
        let cfg = (try? store.load()) ?? .default
        self.config = cfg
        self.routing = RoutingStore(knowledgeRoot: cfg.destinations.resolvedRoot).loadOrSeed()
        self.sessions = SessionManager(
            // Read through to the live config each time: routing.json is
            // hand-edited, and a profile may be added or retimed mid-evening.
            // Re-read from disk each time rather than closing over a snapshot:
            // routing.json is hand-edited, and a profile may be added or retimed
            // in the middle of an evening.
            profiles: {
                let root = ((try? store.load()) ?? cfg).destinations.resolvedRoot
                return RoutingStore(knowledgeRoot: root).loadOrSeed().sessions
            })
        migrateInputPrefs()
        backfillFavoriteInputNames()
        migrateOpenCommand()
        detectVaultMirror()
        configureWatcher()
        applyArmState()
        refreshRecents()
        recoverInterrupted()
        sessions.onComplete = { [weak self] session, profile in
            await self?.runSessionCompletion(session, profile)
        }
        // After recoverInterrupted: a session may have ended while the app was
        // away, and completing it wants the recordings already back in history.
        sessions.restore()
        startDeviceWatcher()
        pruneBackups()
        checkForUpdatesQuietly()
        Notifier.shared.onStartRecording = { [weak self] in
            Task { @MainActor in self?.startPendingCallRecording() }
        }
        Notifier.shared.configure()
    }

    // MARK: - Arming / auto-record

    func setAutoRecord(_ on: Bool) {
        config.autoRecordOnMicActivation = on
        applyArmState()
    }

    private func applyArmState() {
        if config.autoRecordOnMicActivation {
            watcher.start()
            callDetector.start()
            if case .recording = state {} else { state = .armed }
        } else {
            watcher.stop()
            callDetector.stop()
            if case .recording = state {} else { state = .idle }
        }
    }

    private func configureWatcher() {
        watcher.onActivation = { [weak self] in
            Task { @MainActor in self?.handleMicActivation() }
        }
        watcher.onDeactivation = { [weak self] in
            Task { @MainActor in self?.handleMicDeactivation() }
        }
        // Precise call detection: fires when a meeting app starts/stops using the
        // mic, independent of Transcripts's own capture.
        callDetector.onCallStarted = { [weak self] app in
            Task { @MainActor in self?.handleCallStarted(app) }
        }
        callDetector.onCallEnded = { [weak self] in
            Task { @MainActor in self?.handleCallEnded() }
        }
    }

    private func handleCallStarted(_ app: String) {
        guard config.autoRecordOnMicActivation else { return }
        if case .recording = state { return }
        switch config.consentMode {
        case .oneParty:
            Log.write("call detected: \(app) → auto-recording (one-party consent)")
            recordingIsCall = true
            startRecording()
        case .twoParty:
            // Announce first — don't record until the user confirms.
            Log.write("call detected: \(app) → announcing for consent (two-party)")
            pendingCallApp = app
            Notifier.shared.announceCall(app: app)
        }
    }

    private func handleCallEnded() {
        if pendingCallApp != nil {
            Log.write("call ended before recording was confirmed")
            pendingCallApp = nil
        }
        guard recordingIsCall, case .recording = state else { return }
        Log.write("call ended → stopping recording")
        recordingIsCall = false
        stopRecordingAndProcess()
    }

    /// Confirms a pending two-party call and starts recording (from the notification
    /// action or the dropdown banner).
    func startPendingCallRecording() {
        guard pendingCallApp != nil else { return }
        pendingCallApp = nil
        if case .recording = state { return }
        recordingIsCall = true
        startRecording()
    }

    func dismissPendingCall() { pendingCallApp = nil }

    private func handleMicActivation() {
        guard config.autoRecordOnMicActivation else { return }
        if case .recording = state { return }
        // Meetings are handled precisely by CallDetector; skip them here so we don't
        // double-trigger. This path is for generic (non-meeting) mic auto-record.
        if MeetingDetector.isMeetingAppRunning { return }
        if !config.autoRecordAppAllowlist.isEmpty {
            let active = ActiveAppProvider.current()
            guard let bid = active.bundleID, config.autoRecordAppAllowlist.contains(bid) else { return }
        }
        startRecording()
    }

    private func handleMicDeactivation() {
        // Only auto-stop generic (non-call) recordings here; calls stop via
        // CallDetector, which can see the meeting app release the mic even while
        // Transcripts is still capturing.
        guard !recordingIsCall, case .recording = state else { return }
        stopRecordingAndProcess()
    }

    // MARK: - Manual controls

    /// `isRecovery` marks a dead-mic auto-restart: the session's dead-device list
    /// is kept (so the silent mic can't be re-picked) instead of reset.
    /// `continuing` marks a resume after the app was restarted mid-meeting: like
    /// `isRecovery` it keeps the fragments already set aside, because the whole
    /// point is that this is the same meeting.
    func startRecording(isRecovery: Bool = false, continuing: Bool = false) {
        guard recorder == nil else { return }
        if !isRecovery && !continuing {
            deadInputUIDs.removeAll(); pendingRecoveryDevice = nil; carriedFragments.removeAll()
        }
        deadAirSnoozeUntil = nil
        lastLiveTurnAt = nil
        liveStallWarned = false
        Task { @MainActor in
            // Resolve microphone permission BEFORE capturing, so the first real
            // recording already has access. Recording before the grant settles is
            // exactly what produced silent audio.
            guard await Recorder.ensureMicAccess() else {
                self.lastError = "Microphone access is off. Enable Transcripts in System Settings ▸ Privacy & Security ▸ Microphone."
                Log.write("startRecording: mic not granted (\(Recorder.micAuthDescription))")
                self.applyArmState()
                return
            }
            guard self.recorder == nil else { return }
            // Only treat this as a meeting when a meeting app is *actively* using the
            // mic right now — not merely running. Teams/Slack are always open, so
            // without this a manual voice note gets named/routed from a stray Slack
            // window instead of from what was actually said.
            let inMeeting = CallDetector.meetingAppUsingInput() != nil
            // During a call, the device the meeting app is capturing from is where
            // the conversation is — follow it even when it isn't a favorite.
            let callUIDs = inMeeting ? CallDetector.meetingAppDeviceUIDs() : []
            // A recovery restart may target a specific device we already proved is
            // the one carrying the signal (e.g. the aggregate that swallowed the
            // built-in mic). Bind it directly, bypassing the resolver — but only
            // while it's still present.
            let recoveryDevice = self.pendingRecoveryDevice
            self.pendingRecoveryDevice = nil
            let device: AudioInputDevice
            if isRecovery, let recoveryDevice,
               AudioInputDevices.all().contains(where: { $0.uid == recoveryDevice.uid }) {
                device = recoveryDevice
                Log.write("startRecording: recovery binding directly to '\(recoveryDevice.name)'")
            } else if let resolved = AudioInputDevices.resolve(favorites: self.config.favoriteInputUIDs,
                                                               override: self.config.overrideInputUID,
                                                               callDeviceUIDs: callUIDs,
                                                               excluding: self.deadInputUIDs) {
                device = resolved
                if callUIDs.contains(device.uid) {
                    Log.write("startRecording: following the call's input '\(device.name)'")
                }
            } else {
                self.lastError = "No microphone input device found."
                Log.write("startRecording: no input device")
                self.applyArmState()
                return
            }
            let rec = Recorder(device: device, captureSystemAudio: self.config.captureSystemAudio,
                               captureWindowTitles: inMeeting)
            // Durable capture location (Application Support) so a crash or OS temp
            // cleanup can't lose an in-flight recording.
            let recordID = UUID()
            let dir = HistoryStore.capturesDir.appendingPathComponent(recordID.uuidString, isDirectory: true)
            do {
                try rec.start(into: dir)
                self.recorder = rec
                self.currentRecordID = recordID
                // Joins the running session, and keeps its idle clock alive:
                // a three-hour take must not age out mid-recording.
                self.sessions.noteActivity(recordingID: recordID)
                self.state = .recording(since: Date())
                self.lastError = nil
                self.startLevelTimer()
                let app = ActiveAppProvider.current().appName
                let now = Date()
                // Only in an active meeting do we name from the window (e.g. "Rollout
                // Weekly Leadership Status with BAiCi") and lock that name. Otherwise
                // leave a neutral placeholder and let the summary title it from what was
                // actually said — never from an incidental Teams/Slack window.
                let meetingName = inMeeting ? WindowTitleProvider.currentMeetingName() : nil
                let title: String
                if let meetingName { title = meetingName }
                else if self.recordingIsCall { title = "\(app ?? "Meeting") call" }
                else { title = app.map { "\($0) recording" } ?? "Recording" }
                let callKey = meetingName.map { Self.callKey(name: $0, at: now) }
                self.history.upsert(RecordingRecord(
                    id: recordID,
                    title: title,
                    recordedAt: now, endedAt: nil, activeApp: app, isCall: self.recordingIsCall,
                    status: .recording, captureDir: dir.path,
                    audioPath: dir.appendingPathComponent("audio.caf").path,
                    documentPath: nil, destination: nil, errorText: nil,
                    callKey: callKey, namedFromWindow: meetingName != nil, renamedByUser: nil,
                    silent: nil))
                self.refreshRecents()
                // The marker is what tells the next launch this meeting was still
                // going. Deleted only by a deliberate stop.
                relaunch.writeMarker(RelaunchState.Marker(
                    startedAt: now, title: title, isCall: self.recordingIsCall, heartbeatAt: now))
                Log.write("startRecording: capturing into \(dir.path)")
                if #available(macOS 26, *) {
                    self.startLiveTranscript(recorder: rec, title: title, startedAt: now,
                                             windowTitles: inMeeting ? WindowTitleProvider.meetingWindowTitles() : [])
                }
                self.maybeStartSystemAudio(scratchDir: dir)
            } catch {
                self.lastError = "Recording could not start: \(Self.shortError(error))"
                Log.write("startRecording: FAILED — \(error)")
                self.applyArmState()
            }
        }
    }

    /// Ends the capture and files it. `carryForward` is the mic-recovery case: the
    /// meeting is still going, so instead of running the pipeline we set this slice
    /// aside and let the fragment that finally ends the meeting absorb it.
    func stopRecordingAndProcess(carryForward: Bool = false) {
        guard let rec = recorder else { return }
        stopLevelTimer()
        DeadAirPanel.shared.dismiss()
        recordingIsCall = false
        let capturer = systemCapturer
        systemCapturer = nil
        let recordID = currentRecordID
        currentRecordID = nil
        // A carry-forward stop is a pause in one meeting, so the marker stays and
        // the next launch resumes. Only a deliberate stop retires it.
        if !carryForward { relaunch.clearMarker(); resumedFragmentCount = 0 }
        finishLiveTranscript()
        do {
            var recording = try rec.stop()
            recorder = nil
            state = .processing
            // Near-zero peak = the mic captured nothing (dead/muted). Mark it so the UI
            // shows it as empty instead of a hallucinated title from a blank transcript.
            let silent = AudioLevel.isSilent(peak: recording.peakLevel ?? 1)
            updateRecord(recordID) { $0.status = .processing; $0.endedAt = recording.endedAt; $0.silent = silent }
            Task { @MainActor in
                // If we were also capturing the other participants, finalize it and
                // mix both sides into one file for transcription.
                let sysURL = await capturer?.stop()
                if let sysURL {
                    // Keep both sides for speaker attribution: mic = you, system
                    // audio = the other participants. The mix below is the archive
                    // (and the transcription fallback when attribution can't run).
                    recording.micAudioURL = recording.audioURL
                    recording.systemAudioURL = sysURL
                    recording.systemAudioStartOffset =
                        capturer?.firstSampleAt?.timeIntervalSince(recording.startedAt)
                }

                if carryForward {
                    // Hold this slice — no pipeline, no note, no history row. The
                    // recording that ends the meeting stitches it back in.
                    self.carriedFragments.append(CarriedFragment(
                        startedAt: recording.startedAt,
                        micAudioURL: recording.micAudioURL ?? recording.audioURL,
                        systemAudioURL: recording.systemAudioURL,
                        systemAudioStartOffset: recording.systemAudioStartOffset))
                    if let recordID { self.history.remove(recordID) }
                    self.refreshRecents()
                    let secs = Int(recording.endedAt?.timeIntervalSince(recording.startedAt) ?? 0)
                    Log.write("recovery: holding \(secs)s fragment to stitch into this meeting (\(self.carriedFragments.count) held)")
                    return
                }

                if !self.carriedFragments.isEmpty {
                    await self.stitchCarriedFragments(into: &recording, recordID: recordID)
                }

                if let sysURL, let micURL = recording.micAudioURL {
                    let mixed = micURL.deletingLastPathComponent().appendingPathComponent("call-mixed.m4a")
                    if let mixedURL = await AudioMixer.mix([micURL, recording.systemAudioURL ?? sysURL],
                                                           into: mixed, log: { Log.write($0) }) {
                        recording.audioURL = mixedURL
                        self.updateRecord(recordID) { $0.audioPath = mixedURL.path }
                        Log.write("call: mixed your mic + the other participants for transcription")
                    }
                }
                self.runPipeline(for: recording, recordID: recordID)
            }
        } catch {
            lastError = "Recording could not be saved: \(Self.shortError(error))"
            recorder = nil
            updateRecord(recordID) { $0.status = .failed; $0.errorText = "stop failed: \(error)" }
            refreshRecents()
            Task { _ = await capturer?.stop() }
            applyArmState()
        }
    }

    /// Rebuilds one continuous meeting from the fragments a mic recovery split it
    /// into. Each side is reassembled on its own timeline at the wall-clock offset
    /// the fragment actually occupied, so the switchover reads as a short gap and
    /// everything after it stays in sync. Speaker attribution keeps working because
    /// mic and system stay separate tracks.
    ///
    /// Best-effort: if assembly fails we fall through with the final fragment
    /// alone, which is exactly the old behavior minus the spurious second note.
    private func stitchCarriedFragments(into recording: inout Recording, recordID: UUID?) async {
        let fragments = carriedFragments
        carriedFragments.removeAll()
        guard let base = fragments.map(\.startedAt).min() else { return }
        let dir = recording.audioURL.deletingLastPathComponent()

        var micPlacements = fragments.map {
            AudioMixer.Placement(url: $0.micAudioURL, at: $0.startedAt.timeIntervalSince(base))
        }
        micPlacements.append(AudioMixer.Placement(url: recording.micAudioURL ?? recording.audioURL,
                                                  at: recording.startedAt.timeIntervalSince(base)))

        var systemPlacements = fragments.compactMap { f -> AudioMixer.Placement? in
            guard let url = f.systemAudioURL else { return nil }
            return AudioMixer.Placement(url: url,
                                        at: f.startedAt.timeIntervalSince(base) + (f.systemAudioStartOffset ?? 0))
        }
        if let url = recording.systemAudioURL {
            systemPlacements.append(AudioMixer.Placement(
                url: url,
                at: recording.startedAt.timeIntervalSince(base) + (recording.systemAudioStartOffset ?? 0)))
        }

        let span = Int(Date().timeIntervalSince(base))
        Log.write("recovery: stitching \(fragments.count + 1) fragment(s) spanning \(span)s into one meeting")

        guard let micURL = await AudioMixer.assemble(micPlacements,
                                                     into: dir.appendingPathComponent("meeting-mic.m4a"),
                                                     log: { Log.write($0) }) else {
            Log.write("recovery: mic assembly failed — filing the final fragment alone")
            return
        }
        recording.micAudioURL = micURL
        recording.audioURL = micURL
        if !systemPlacements.isEmpty,
           let sysURL = await AudioMixer.assemble(systemPlacements,
                                                  into: dir.appendingPathComponent("meeting-system.m4a"),
                                                  log: { Log.write($0) }) {
            recording.systemAudioURL = sysURL
        }
        // The offsets are baked into the assembled system timeline now.
        recording.systemAudioStartOffset = 0
        // The meeting began when its first fragment did — that drives the note's
        // filename stamp and frontmatter.
        recording.startedAt = base
        updateRecord(recordID) { $0.recordedAt = base }
    }

    /// Starts system-audio capture alongside the mic when we're in a call (a meeting
    /// app is running) and the user hasn't disabled it — so a recorded call includes
    /// the other participants, not just your side.
    private func maybeStartSystemAudio(scratchDir: URL) {
        guard config.captureSystemAudio, MeetingDetector.isMeetingAppRunning else { return }
        guard explainSystemAudioPermissionIfNeeded() else { return }
        let capturer = SystemAudioCapturer()
        systemCapturer = capturer
        let sysURL = scratchDir.appendingPathComponent("system.caf")
        Task { @MainActor in
            let ok = await capturer.start(into: sysURL)
            if !ok { self.systemCapturer = nil; return }
            if #available(macOS 26, *) { self.attachLiveSystemTranscriber(to: capturer) }
        }
    }

    /// One-time context shown before the system-audio permission dialog can
    /// appear, so the OS prompt never lands cold: the user hears first that saying
    /// no costs only the remote side of calls, not the recording. Skipped entirely
    /// when the Screen Recording grant already exists (nothing will be asked) and
    /// after the first showing (context given; later recordings go straight to the
    /// OS dialog). Returns false when the user chose mic-only for this recording.
    private func explainSystemAudioPermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let explainedKey = "systemAudioPermissionExplained"
        if UserDefaults.standard.bool(forKey: explainedKey) { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Capture the other side of calls?"
        alert.informativeText = """
        To include what other participants say, macOS will ask permission to record this Mac's audio — a normal Allow/Don't Allow dialog. No administrator access is needed.

        This is optional. Without it, recordings still capture your microphone (you, and the room); only the remote side of calls is left out.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Mic-Only for Now")
        UserDefaults.standard.set(true, forKey: explainedKey)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Live transcript (streaming, macOS 26)

    /// Streams the mic track into the live transcript as "Me". Failure leaves the
    /// recording untouched — live transcription is an observer, never a dependency.
    @available(macOS 26, *)
    private func startLiveTranscript(recorder rec: Recorder, title: String,
                                     startedAt: Date, windowTitles: [String]) {
        let live = LiveTranscript(vaultRoot: config.destinations.resolvedRoot)
        live.begin(title: title, startedAt: startedAt, windowTitles: windowTitles)
        liveTranscript = live

        // A room's microphone carries several people; a call's carries one.
        // Only the room gets a live diarizer, and its models load in the
        // background — until they are ready every turn is "Me", which is what
        // the live transcript always said.
        var diarizer: LiveDiarizer? = nil
        // The same gate the batch pass uses (`nativeStages(roomMode:)`): a
        // detected call's other side arrives on its own track, and clustering
        // the mic then would only split one person into several.
        if config.micRecordsARoom, !recordingIsCall {
            let d = LiveDiarizer(
                clusteringThreshold: config.roomVoiceSensitivity > 0 ? Float(config.roomVoiceSensitivity) : nil,
                matchThreshold: Float(config.nameMatchConfidence),
                rememberVoices: config.rememberVoices)
            diarizer = d
            liveDiarizer = d
            Task.detached { _ = await d.start() }
        }

        let mic = LiveTrackTranscriber { [weak self, weak diarizer] seg in
            Task { @MainActor in
                // Waited for rather than patched in afterwards: an embedding of
                // a few seconds of audio resolves in well under the partial
                // flush interval, and a transcript whose labels change under
                // the reader is worse than one that arrives a beat later.
                let speaker = await diarizer?.label(start: seg.start, end: seg.end) ?? "Me"
                self?.appendLiveTurn(speaker: speaker, start: seg.start, text: seg.text)
            }
        } onPartial: { [weak self] text in
            Task { @MainActor in self?.showLivePartial(speaker: "Me", text: text) }
        }
        liveMicTranscriber = mic
        startOverlay()
        Task { @MainActor in
            if await mic.start() {
                // One tap, two consumers, same buffers in the same order — the
                // diarizer's ring and the transcriber's timeline stay aligned
                // only because they start on the same buffer.
                rec.onBuffer = { [weak mic, weak diarizer] buffer in
                    mic?.feed(buffer)
                    diarizer?.feed(buffer)
                }
                Log.write("live: mic track streaming to live.md\(diarizer != nil ? " (room: naming voices live)" : "")")
            } else {
                self.liveMicTranscriber = nil
                self.liveDiarizer = nil
            }
        }
    }

    /// Streams the system-audio track (the other participants) as "Others",
    /// shifted onto the mic timeline by the capture-start offset.
    @available(macOS 26, *)
    private func attachLiveSystemTranscriber(to capturer: SystemAudioCapturer) {
        let sys = LiveTrackTranscriber { [weak self, weak capturer] seg in
            Task { @MainActor in
                guard let self else { return }
                var start = seg.start
                if case .recording(let since) = self.state, let first = capturer?.firstSampleAt {
                    start += first.timeIntervalSince(since)
                }
                self.appendLiveTurn(speaker: "Others", start: start, text: seg.text)
            }
        } onPartial: { [weak self] text in
            Task { @MainActor in self?.showLivePartial(speaker: "Others", text: text) }
        }
        liveSystemTranscriber = sys
        Task { @MainActor in
            if await sys.start() {
                capturer.onSampleBuffer = { [weak sys] sampleBuffer in
                    if let pcm = pcmBuffer(from: sampleBuffer) { sys?.feed(pcm) }
                }
                Log.write("live: system track streaming to live.md")
            } else {
                self.liveSystemTranscriber = nil
            }
        }
    }

    /// Everything that happens when a live engine finalizes a turn, in one
    /// place: the file both readers watch, and the overlay. The two tracks used
    /// to do this separately and had already drifted apart once.
    private func appendLiveTurn(speaker: String, start: Double, text: String) {
        lastLiveTurnAt = Date()
        liveTranscript?.append(speaker: speaker, start: start, text: text)
        if let engine = overlayEngine as? OverlayEngine {
            Task { await engine.ingest(speaker: speaker, start: start, text: text) }
        }
    }

    /// The live edge: text still being revised, which reaches the screen seconds
    /// before the analyzer is willing to call the phrase finished. It goes to
    /// the overlay's pill and to a clearly-marked section of the live file, and
    /// never into the transcript itself.
    private func showLivePartial(speaker: String, text: String) {
        liveTranscript?.setPartial(speaker: speaker, text: text)
        if overlayVisible { overlayPanel.showPartial(text) }
    }

    // MARK: - Overlay

    /// Builds the overlay for this call and shows its panel.
    ///
    /// The vault index is built off the main actor before the engine starts: on
    /// a large vault it is seconds of file reading, and it must not be seconds
    /// the recorder spends not recording. Until it lands the overlay answers
    /// from the call alone, which is the same behaviour as having no notes.
    private func startOverlay() {
        guard config.overlay.enabled else { return }
        let cfg = config
        let model = Self.makeChatModel(for: cfg)
        var options = OverlayEngine.Options()
        // No language model in the chain means nothing can phrase an answer;
        // the engine quotes and attributes the best passage instead of asking
        // ExtractiveChatModel for JSON it does not produce. See OverlayEngine.
        options.retrievalOnly = !Self.hasLanguageModel(for: cfg)

        // Which lanes can actually fill is decided here, so say so once rather
        // than leaving "why is Facts always empty" to be guessed at.
        Log.write("overlay: \(llmStatus)\(options.retrievalOnly ? " — retrieval only, no conclusion/facts lanes" : "")")
        let engine = OverlayEngine(model: model, vault: nil, options: options) { [weak self] cards in
            Task { @MainActor in self?.overlayPanel.update(cards) }
        }
        overlayEngine = engine

        if cfg.overlay.searchNotes {
            let root = cfg.destinations.resolvedRoot
            Task.detached(priority: .utility) {
                let index = PassageIndex.vault(root: root)
                Log.write("overlay: indexed \(index.count) passages from \(root.path)")
                await engine.attach(vault: index)
            }
        }

        overlayPanel.onClose = { [weak self] in self?.hideOverlay() }
        // Persisted when the drag settles, so a dragged position survives a crash
        // rather than only a clean quit. `config`'s didSet writes it.
        overlayPanel.onMoved = { [weak self] origin in
            guard let self else { return }
            self.config.overlay.originX = origin.x
            self.config.overlay.originY = origin.y
        }
        let origin = cfg.overlay.originX.flatMap { x in
            cfg.overlay.originY.map { CGPoint(x: x, y: $0) }
        }
        overlayPanel.show(origin: origin)
        overlayVisible = true

        // A quiet stretch still deserves the facts from the stretch before it.
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let engine = self?.overlayEngine as? OverlayEngine else { return }
                await engine.tick()
            }
        }
    }

    /// Tears the overlay down. Safe to call when it was never started.
    private func stopOverlay() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        overlayEngine = nil
        hideOverlay()
    }

    /// Hides the panel for the rest of this call without discarding what the
    /// engine has gathered — showing it again brings the cards back.
    func hideOverlay() {
        // Remember where it was dragged to. Assigning to `config` persists it
        // (see its `didSet`), which is why this is done once here rather than
        // on every frame of a drag.
        if let origin = overlayPanel.currentOrigin,
           origin.x != config.overlay.originX || origin.y != config.overlay.originY {
            config.overlay.originX = origin.x
            config.overlay.originY = origin.y
        }
        overlayPanel.hide()
        overlayVisible = false
    }

    /// Menu action. Only meaningful while a recording with an engine is running.
    func toggleOverlay() {
        guard overlayEngine != nil else { return }
        if overlayVisible {
            hideOverlay()
        } else {
            let origin = config.overlay.originX.flatMap { x in
                config.overlay.originY.map { CGPoint(x: x, y: $0) }
            }
            overlayPanel.show(origin: origin)
            overlayVisible = true
            // Bring back what the engine already has, rather than an empty panel
            // waiting on the next turn.
            if let engine = overlayEngine as? OverlayEngine {
                Task { @MainActor in
                    let digest = await engine.digest()
                    self.overlayPanel.update(digest)
                }
            }
        }
    }

    /// Whether the resolved chain has anything that can actually write a
    /// sentence. Mirrors `makeChatModel`'s ordering.
    static func hasLanguageModel(for cfg: AppConfig) -> Bool {
        if cfg.llmProvider == .ollama { return true }
        #if canImport(FoundationModels)
        if FoundationModelsChatModel.isAvailable { return true }
        #endif
        #if arch(arm64)
        if MLXChatModel.isAvailable { return true }
        #endif
        return false
    }

    /// Finalizes both live engines and stamps the live doc "ended". The batch
    /// pipeline (running next) produces the authoritative vault document.
    private func finishLiveTranscript() {
        stopOverlay()
        guard #available(macOS 26, *) else { return }
        let mic = liveMicTranscriber as? LiveTrackTranscriber
        let sys = liveSystemTranscriber as? LiveTrackTranscriber
        let live = liveTranscript
        liveMicTranscriber = nil
        liveSystemTranscriber = nil
        liveDiarizer = nil
        liveTranscript = nil
        guard mic != nil || sys != nil || live != nil else { return }
        Task { @MainActor in
            await mic?.finish()
            await sys?.finish()
            live?.end()
        }
    }

    // MARK: - Live metering

    /// Seconds of pure silence after which a recording's mic is declared dead and
    /// recovery kicks in. Long enough to ride out joining muted-and-quiet; short
    /// enough that a 30-minute meeting isn't lost to a clamshell built-in mic.
    private static let deadMicSeconds: TimeInterval = 20

    /// The same trip wire, but for a capture we already switched to. Deliberately
    /// much longer: a noise-gated mic reads digital zero until it's spoken into, so
    /// the fast window would condemn a working device just because its owner is
    /// listening. Nothing is lost by waiting — we've stopped switching by then, and
    /// the only thing riding on it is the wording of a notice.
    private static let deadMicRecheckSeconds: TimeInterval = 90

    /// The window to apply right now: fast on first look, patient once we've
    /// already moved off one device.
    private var deadMicWindow: TimeInterval {
        deadInputUIDs.isEmpty ? Self.deadMicSeconds : Self.deadMicRecheckSeconds
    }

    /// Minutes of silence on BOTH sides (your mic and the other participants)
    /// after which we ask whether the meeting is over — catches recording long
    /// past the call's end, or capturing the wrong output entirely.
    private static let deadAirSeconds: TimeInterval = 300

    /// Suppresses re-prompting after "Keep Recording" (and while a dead-air
    /// prompt is up). Reset on each recording start.
    private var deadAirSnoozeUntil: Date?

    /// When the live transcript last appended a turn — the health signal users
    /// actually care about during a call ("is it flowing?"), independent of mic
    /// levels. Reset on each recording start.
    private var lastLiveTurnAt: Date?
    private var liveStallWarned = false

    private func startLevelTimer() {
        levelTimer?.invalidate()
        var secondAccumulator: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var deadMicFired = false
        var lastMicActivityAt: Date?
        let interval: TimeInterval = 0.07
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rec = self.recorder, case .recording(let since) = self.state else { return }
                let micLvl = rec.sampleLevel()
                // The icon/EQ show that *capture* is flowing, not just your mic —
                // on a call you're usually muted, but the other side pulses the
                // one mark. Dead-mic/dead-air logic still reads each side separately.
                let lvl = max(micLvl, self.systemCapturer?.sampleLevel() ?? 0)
                self.inputLevel = lvl
                self.levels.removeFirst()
                self.levels.append(lvl)
                if micLvl >= AudioLevel.silencePeakThreshold { lastMicActivityAt = Date() }
                secondAccumulator += interval
                if secondAccumulator >= 1 {
                    secondAccumulator = 0
                    self.tick &+= 1
                    self.checkDeadAir(since: since, lastMicActivity: lastMicActivityAt)
                    self.checkLiveFlow(since: since)
                    // Window titles improve mid-call (join screen → the real
                    // meeting window) — re-sample every ~15s and upgrade.
                    if self.tick % 15 == 0 { self.refreshMeetingContext() }
                    // Keeps the relaunch marker fresh, so a three-hour session
                    // stays resumable rather than ageing out of the window.
                    if self.tick % 30 == 0 { self.relaunch.heartbeat() }
                }
                // Dead-mic trip wire: fires only on *digital* silence (a dead or
                // hardware-muted device). A healthy mic in a quiet room shows
                // ambient noise and must never trigger a device switch.
                elapsed += interval
                if !deadMicFired, elapsed >= self.deadMicWindow,
                   AudioLevel.isDigitallyDead(peak: rec.samplePeak()) {
                    deadMicFired = true
                    self.handleDeadMicWhileRecording()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    /// Re-samples meeting window titles mid-recording and upgrades the record's
    /// provisional title when a better meeting name appears. The Teams join
    /// screen titles the first sample "Meeting join"; the real meeting window
    /// ("Claude Enterprise Evaluation Program Touchpoint") only exists once
    /// you're actually in the call. A manual rename always stands.
    private func refreshMeetingContext() {
        guard recordingIsCall, let rec = recorder, let id = currentRecordID else { return }
        let titles = WindowTitleProvider.meetingWindowTitles()
        guard !titles.isEmpty else { return }
        rec.mergeWindowTitles(titles)   // flows into routing + frontmatter at stop
        guard let name = WindowTitleProvider.meetingName(from: titles),
              let r = history.record(id),
              r.renamedByUser != true, r.title != name else { return }
        // Stickiness: a real window-derived name only changes when it's gone
        // from the screen (meeting renamed/left) — transient windows (share
        // sheets, popped-out panes) must not flap the title mid-call.
        if r.namedFromWindow == true,
           titles.contains(where: { $0.localizedCaseInsensitiveContains(r.title) }) { return }
        Log.write("call: meeting name improved '\(r.title)' → '\(name)'")
        let key = Self.callKey(name: name, at: r.recordedAt)
        updateRecord(id) { $0.title = name; $0.namedFromWindow = true; $0.callKey = key }
        liveTranscript?.retitle(name)
        refreshRecents()
    }

    /// The alert that matters during a call: the other side is AUDIBLE but the
    /// live transcript hasn't produced a turn in minutes — the transcription
    /// pipeline is stalled. (Mic-level silence is meaningless in comparison:
    /// muted-for-90-minutes is normal posture.) The batch pass at stop still
    /// transcribes everything regardless, and the panel says so.
    private func checkLiveFlow(since: Date) {
        guard !liveStallWarned, recordingIsCall,
              liveSystemTranscriber != nil,
              Date().timeIntervalSince(since) > 180 else { return }
        guard let audible = systemCapturer?.lastAudible(),
              Date().timeIntervalSince(audible) < 60 else { return }
        let lastTurn = lastLiveTurnAt ?? since
        guard Date().timeIntervalSince(lastTurn) > 180 else { return }
        liveStallWarned = true
        Log.write("live: STALLED — call audible but no transcript turn for 3+ min")
        DeadAirPanel.shared.show(
            title: "Live transcript stalled",
            body: "The call is audible but nothing has transcribed for a few minutes. The audio is still recording and will fully transcribe when the call ends.",
            secondary: ("Open Live Transcript", { [weak self] in self?.openLiveTranscript() }),
            autoDismissAfter: 20)
    }

    /// Both sides quiet for `deadAirSeconds` → float a "still recording — stop?"
    /// prompt. Never auto-stops: silence can be legitimate (someone screensharing
    /// a video with the sound off, a pause before Q&A), so the user decides.
    private func checkDeadAir(since: Date, lastMicActivity: Date?) {
        if let snooze = deadAirSnoozeUntil, Date() < snooze { return }
        let lastMic = lastMicActivity ?? since
        let lastSys = systemCapturer?.lastAudible() ?? since
        let lastActivity = max(max(lastMic, lastSys), since)
        let quiet = Date().timeIntervalSince(lastActivity)
        guard quiet >= Self.deadAirSeconds else { return }

        deadAirSnoozeUntil = Date().addingTimeInterval(600)   // don't re-prompt under the panel
        let minutes = Int(quiet / 60)
        Log.write("deadair: \(minutes) min of silence on both sides — prompting")
        DeadAirPanel.shared.show(
            title: "Still recording — \(minutes) min of silence",
            body: "Nobody has said anything for a while. If the meeting is over, stop and process what was captured.",
            primary: ("Stop & Process", { [weak self] in self?.stopRecordingAndProcess() }),
            secondary: ("Keep Recording", { [weak self] in
                self?.deadAirSnoozeUntil = Date().addingTimeInterval(600)
            }))
    }

    /// The mic has produced nothing since the recording started. Flag it, tell the
    /// user, and — unless they explicitly forced a device that is genuinely capable
    /// of producing signal — restart the capture on the next viable input (the
    /// call's own device outranks favorites). The interrupted slice is held and
    /// stitched back on at the end, so the meeting still files as one note.
    private func handleDeadMicWhileRecording() {
        guard let rec = recorder else { return }
        let dead = rec.device
        let signalPath = AudioInputDevices.describeSignalPath(dead)

        // System-level mute (AirPods stem press, the menu-bar mic mute Teams
        // integrates with) zeroes EVERY input for EVERY app — being muted for
        // 90 minutes is normal meeting posture, not a broken device, and
        // switching mics under it just records zeros from somewhere else.
        if AudioInputDevices.isInputMuted(dead) == true {
            Log.write("deadmic: '\(dead.name)' reports muted — normal posture, standing down")
            return
        }

        // We already switched once and the replacement is quiet too. Do NOT read
        // that as a system mute: a noise-gated mic (the MX Brio does this) sits at
        // digital zero until someone actually speaks into it, so on 2026-07-21 a
        // perfectly healthy Brio was declared muted 111s into a call it went on to
        // record fine. Stop switching — one flap is enough — but only report what
        // we actually know.
        if !deadInputUIDs.isEmpty {
            Log.write("deadmic: replacement '\(dead.name)' still silent after \(Int(deadMicWindow))s (\(signalPath)) — no further switching")
            DeadAirPanel.shared.show(
                title: "Still not hearing you",
                body: "'\(dead.name)' hasn't picked up any sound yet. If you're muted, that's expected — the other side of the call is being recorded either way.",
                secondary: ("Mic Settings…", { [weak self] in self?.openSettings() }),
                autoDismissAfter: 15)
            return
        }

        deadInputUIDs.insert(dead.uid)
        Log.write("deadmic: '\(dead.name)' captured nothing for \(Int(deadMicWindow))s (\(signalPath))")

        // A call app running echo cancellation takes over the mic's hardware
        // stream; our plain read of the raw device then gets pure silence while the
        // live signal sits inside the call app's voice-processing path. Two ways to
        // see it: macOS published an aggregate that owns the device, or the device
        // has been forced down to a voice sample rate (the only visible sign when
        // the aggregate is private — GH #12, and the MX Brio at 24 kHz on
        // 2026-07-22, which cost 97 minutes of the user's own side).
        //
        // Recovering is the one case where switching away from a *forced* device is
        // still right: a mic another process holds in echo-cancellation mode cannot
        // physically hand us signal, so honoring the override just records zeros.
        let aggregate = AudioInputDevices.liveAggregate(owning: dead)
        if aggregate != nil || AudioInputDevices.looksVoiceProcessed(dead) {
            let target = aggregate ?? AudioInputDevices.resolve(
                favorites: config.favoriteInputUIDs,
                override: nil,
                callDeviceUIDs: CallDetector.meetingAppDeviceUIDs(),
                excluding: deadInputUIDs)
            if let target {
                let why = aggregate != nil
                    ? "aggregate '\(target.name)' owns it"
                    : "a call app holds it in echo-cancellation mode (\(signalPath))"
                Log.write("deadmic: '\(dead.name)' is silent because \(why) — switching to '\(target.name)'")
                Notifier.shared.alertDeadMic(device: dead.name, switchedTo: target.name)
                DeadAirPanel.shared.show(
                    title: "Switched microphone",
                    body: "'\(dead.name)' went silent — a call app had claimed it for echo cancellation. Recording from '\(target.name)' instead and kept going.",
                    secondary: ("Mic Settings…", { [weak self] in self?.openSettings() }),
                    autoDismissAfter: 15)
                restartCapture(on: aggregate)
                return
            }
            Log.write("deadmic: '\(dead.name)' looks voice-processed but there is no other input to move to")
        }

        if config.overrideInputUID == dead.uid {
            // The user forced this device in Settings and nothing suggests another
            // process has taken it — alert, don't override them. On a call the
            // overwhelmingly common cause is simply being muted, so lead with that
            // rather than implying the device is broken.
            Log.write("deadmic: '\(dead.name)' (forced input) is silent — likely muted; alerting, not switching")
            Notifier.shared.alertDeadMic(device: dead.name, switchedTo: nil)
            DeadAirPanel.shared.show(
                title: "Not hearing your mic",
                body: "If you're muted, that's expected — the other side of the call is still being recorded. If you're not, '\(dead.name)' (your chosen input) isn't picking up any sound, so pick a different one.",
                primary: ("Open Mic Settings", { [weak self] in self?.openSettings() }),
                autoDismissAfter: 20)
            lastError = "'\(dead.name)' is silent — you may be muted, or it isn't picking up sound. Change it in Settings ▸ General."
            return
        }

        let callUIDs = CallDetector.meetingAppDeviceUIDs()
        let replacement = AudioInputDevices.resolve(favorites: config.favoriteInputUIDs,
                                                    override: nil,
                                                    callDeviceUIDs: callUIDs,
                                                    excluding: deadInputUIDs)
        guard let replacement else {
            Log.write("deadmic: '\(dead.name)' is silent and no other input is available — alerting")
            Notifier.shared.alertDeadMic(device: dead.name, switchedTo: nil)
            DeadAirPanel.shared.show(
                title: "Mic is silent",
                body: "'\(dead.name)' is capturing nothing and no other input is available. The other side of a call is still being recorded.",
                primary: ("Open Mic Settings", { [weak self] in self?.openSettings() }))
            lastError = "'\(dead.name)' is capturing silence and no other input is available."
            return
        }
        Log.write("deadmic: switching to '\(replacement.name)' and restarting the capture")
        Notifier.shared.alertDeadMic(device: dead.name, switchedTo: replacement.name)
        DeadAirPanel.shared.show(
            title: "Mic was silent",
            body: "'\(dead.name)' captured nothing — switched to '\(replacement.name)' and kept recording.",
            secondary: ("Mic Settings…", { [weak self] in self?.openSettings() }),
            autoDismissAfter: 15)
        restartCapture(on: nil)
    }

    /// Ends the current slice without filing it and rebinds the capture. `device`
    /// pins the exact input to use (an aggregate the resolver would never pick);
    /// nil lets the resolver choose, minus everything already proved dead.
    private func restartCapture(on device: AudioInputDevice?) {
        pendingRecoveryDevice = device
        stopRecordingAndProcess(carryForward: true)
        Task { @MainActor in
            // Give the engine a beat to release the old device before rebinding.
            try? await Task.sleep(for: .milliseconds(400))
            // stopRecordingAndProcess cleared the call flag; re-derive it so the
            // recovered fragment is still treated (titled, grouped) as a call.
            self.recordingIsCall = CallDetector.meetingAppUsingInput() != nil
            self.startRecording(isRecovery: true)
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
        levels = Array(repeating: 0, count: levels.count)
    }

    /// Quick text-only personal note — skips audio stages, runs classify/persist.
    func saveNote(title: String, body: String) {
        let recordID = UUID()
        let dir = HistoryStore.capturesDir.appendingPathComponent(recordID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let noteURL = dir.appendingPathComponent("note.md")
        let doc = "---\ntitle: \"\(title)\"\nsource: transcripts-note\n---\n\n\(body)\n"
        try? doc.write(to: noteURL, atomically: true, encoding: .utf8)

        history.upsert(RecordingRecord(
            id: recordID, title: title, recordedAt: Date(), endedAt: Date(), activeApp: nil,
            isCall: false, status: .processing, captureDir: dir.path, audioPath: nil,
            documentPath: nil, destination: nil, errorText: nil))
        refreshRecents()

        let recording = Recording(audioURL: noteURL, startedAt: Date(), endedAt: Date(), title: title, isNote: true)
        // Notes carry their text as the transcript directly.
        runPipeline(for: recording, recordID: recordID, seedTranscript: noteURL)
    }

    // MARK: - Pipeline

    private func runPipeline(for recording: Recording, recordID: UUID? = nil, seedTranscript: URL? = nil, retryAttempt: Int = 0) {
        let cfg = config
        // Room mode describes a microphone with several people in front of it,
        // which a detected call is definitionally not: there the mic is you and
        // the system track is everyone else, and that split is better evidence
        // than any amount of clustering. Deciding it per recording rather than
        // once in Settings is what lets the same Mac record a game night and a
        // Teams call without the setting being wrong for one of them.
        let isCall = recordID.flatMap { id in history.records.first { $0.id == id }?.isCall } ?? false
        let stages = nativeStages(for: cfg, roomMode: cfg.micRecordsARoom && !isCall)
        let runner: CommandRunner = ProcessCommandRunner()
        let engine = PipelineEngine(config: cfg, runner: runner, nativeStages: stages) { msg in
            Log.write("pipeline: \(msg)")
        }

        Task { @MainActor in
            do {
                // The chosen backend should actually be there when the pipeline
                // arrives at summarize/classify — launch Ollama if it's the pick.
                await self.ensureOllamaRunning(cfg)
                // For notes, pre-seed the transcript so summarize/classify see text.
                let result: PipelineContext
                if let seedTranscript {
                    result = try await self.processNote(recording: recording, transcript: seedTranscript, cfg: cfg)
                } else {
                    result = try await engine.process(
                        recording, forcedDestination: self.sessions.destinationOverride)
                }
                let md = result.finalPaths.first { $0.pathExtension == "md" }
                let dropped = result.finalPaths.map(\.lastPathComponent).joined(separator: ", ")
                Log.write("pipeline: done → [\(dropped)] routed to \(result.routing?.destination ?? "?")")
                if let mirrorError = result.userInfo["vaultMirrorError"] {
                    Log.write("vault mirror: failed — \(mirrorError)")
                }
                let summaryTitle = result.userInfo["summaryTitle"]
                let fallbackTitle = md.flatMap(Self.frontmatterTitle) ?? recording.title ?? recording.activeApp?.appName
                self.updateRecord(recordID) { r in
                    r.status = .completed
                    // The summary's content-derived title is the standard name. A user
                    // rename is never overwritten; a meeting-window name stands only
                    // while the summary produced nothing. Summarize skips blank
                    // transcripts entirely, so a summary title existing proves real
                    // content was captured — even when the mic side was silent (a call
                    // can be carried entirely by the system-audio side).
                    if r.renamedByUser != true {
                        if let summaryTitle, !summaryTitle.isEmpty {
                            r.title = summaryTitle
                            r.silent = false
                        } else if r.namedFromWindow != true, r.silent != true, let fallbackTitle {
                            r.title = fallbackTitle
                        }
                    }
                    r.documentPath = md?.path
                    r.destination = result.routing?.destination
                    r.errorText = nil
                }
                self.sessions.noteActivity(recordingID: recordID)
                self.cleanupCrashSafeCaptures(recordID: recordID, result: result)
                self.harvestVoiceSuggestions(from: result, recordID: recordID)
            } catch let pipelineError as PipelineError
                where { if case .stageTimedOut = pipelineError { return true }; return false }()
                    && retryAttempt == 0 {
                // A stage timed out on the first attempt — kick it off again automatically
                // rather than leaving the record in a permanent failed state.
                Log.write("pipeline: stage timed out, auto-retrying (attempt 1)")
                self.updateRecord(recordID) { r in
                    r.status = .processing
                    r.errorText = nil
                }
                self.refreshRecents()
                self.runPipeline(for: recording, recordID: recordID, seedTranscript: seedTranscript, retryAttempt: 1)
                return
            } catch {
                self.lastError = "Processing failed: \(Self.shortError(error))"
                Log.write("pipeline: FAILED — \(error)")
                self.updateRecord(recordID) { r in
                    r.status = .failed
                    r.errorText = "\(error)"
                }
            }
            self.refreshRecents()
            self.applyArmState()
        }
    }

    /// After a successful pipeline run the bulky crash-safe CAF originals have
    /// served their purpose — a finalized AAC exists (the encode archive and, for
    /// calls, the mix). Point the record's backup at the m4a and delete the CAFs
    /// so 30-day retention holds hours of AAC, not gigabytes of PCM. If nothing
    /// finalized exists, the CAFs stay (they're the only recoverable audio).
    private func cleanupCrashSafeCaptures(recordID: UUID?, result: PipelineContext) {
        let fm = FileManager.default
        let finalized = [result.archivedAudioURL, result.recording.audioURL]
            .compactMap { $0 }
            .first { $0.pathExtension.lowercased() == "m4a" && fm.fileExists(atPath: $0.path) }
        guard let finalized else { return }
        var removed = 0
        for caf in [result.recording.audioURL, result.recording.micAudioURL, result.recording.systemAudioURL] {
            guard let caf, caf.pathExtension.lowercased() == "caf", fm.fileExists(atPath: caf.path) else { continue }
            try? fm.removeItem(at: caf)
            removed += 1
        }
        if removed > 0 {
            updateRecord(recordID) { $0.audioPath = finalized.path }
            Log.write("backups: replaced \(removed) crash-safe CAF(s) with \(finalized.lastPathComponent)")
        }
    }

    /// Pairs Tier A's transcript-evidence names ("Speaker 2 = Tracy") with the
    /// voice embeddings captured at transcribe time, and queues suggest-and-
    /// confirm banners. Nothing is remembered until the user confirms — that
    /// per-person confirm IS the consent gate for voices other than their own.
    private func harvestVoiceSuggestions(from result: PipelineContext, recordID: UUID?) {
        // The embeddings are the real signal — one per distinct voice heard. Names
        // are a *bonus* from transcript evidence and are usually absent (nobody
        // gets addressed by name on most calls), so they must NOT gate the harvest:
        // requiring them meant a five-anonymous-speaker meeting produced zero
        // nameable voices, the exact case this is for.
        guard config.rememberVoices else { return }
        guard let embPath = result.userInfo["speakerEmbeddings"],
              let embData = try? Data(contentsOf: URL(fileURLWithPath: embPath)),
              let embeddings = try? JSONDecoder().decode([String: [Float]].self, from: embData)
        else {
            Log.write("voices: harvest skipped — no embeddings (key=\(result.userInfo["speakerEmbeddings"] ?? "nil"))")
            return
        }
        let anon = embeddings.keys.filter { SpeakerTurns.isAnonymousLabel($0) }
        Log.write("voices: harvest — \(embeddings.count) voice(s), \(anon.count) anonymous: \(anon.sorted().joined(separator: ", "))")
        let names: [String: String] = result.userInfo["speakerNames"]
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        // Per-cluster voice clips, if transcribe cut any (label → scratch path).
        let clips: [String: String] = result.userInfo["speakerClips"]
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let source = result.userInfo["summaryTitle"] ?? "a recent meeting"
        // The call already sorted itself somewhere — a Cases/<Client>/ folder puts
        // its outside voices with that client, anything else with the home org.
        // Prefill that as the affiliation guess; the user confirms or edits.
        let affiliation = Affiliation.suggested(destination: result.routing?.destination,
                                                homeOrg: config.homeOrganization)
        // The meeting's calendar identity, so a maintenance skill can pull this
        // meeting's Outlook invite (attendees → candidate names + affiliations).
        let meetingName = result.userInfo["meetingName"]
        let meetingDate = result.recording.startedAt
        // Every distinct voice we heard is nameable — not only the ones the
        // transcript happened to name. Iterate the diarized clusters (embeddings),
        // prefilling a name when Tier A guessed one and leaving it blank otherwise
        // so the user can name it by ear from the grid.
        for (label, embedding) in embeddings where SpeakerTurns.isAnonymousLabel(label) {
            let name = names[label] ?? ""
            // Move this cluster's clip out of the doomed scratch dir into the
            // durable pending area. Best-effort: no clip just means no play button.
            let samplePath = clips[label].flatMap {
                Self.adoptVoiceClip(at: $0, forPending: name.isEmpty ? label : name)
            }
            let queued = speakerStore.suggest(name: name, label: label, embedding: embedding,
                                              sourceTitle: source, sampleAudioPath: samplePath,
                                              affiliation: affiliation, meetingName: meetingName,
                                              meetingDate: meetingDate, recordingID: recordID?.uuidString)
            Log.write("voices: harvest \(label) name=\(name.isEmpty ? "(unnamed)" : name) clip=\(samplePath != nil) queued=\(queued != nil)")
            // A named guess that was deduped won't be queued — drop its now-orphan
            // clip so it doesn't linger in pending/.
            if queued == nil, let samplePath {
                try? FileManager.default.removeItem(atPath: samplePath)
            }
        }

        // Record the full per-meeting attribution (every speaker, named or not) so
        // it can be reviewed and corrected later — with a durable clip per voice.
        if let recordID {
            let md = result.finalPaths.first { $0.pathExtension == "md" }
            let speakers = embeddings.map { label, embedding -> MeetingSpeaker in
                let clip = clips[label].flatMap {
                    Self.adoptMeetingClip(at: $0, recordID: recordID, label: label)
                }
                return MeetingSpeaker(label: label, embedding: embedding, clipPath: clip,
                                      isSelf: label == FluidAudioDiarizer.selfName)
            }
            attributionStore.record(MeetingAttribution(
                recordingID: recordID.uuidString, meetingName: meetingName,
                meetingDate: meetingDate, transcriptPath: md?.path, speakers: speakers))
        }
        refreshVoiceSuggestions()
    }

    func refreshVoiceSuggestions() {
        voiceSuggestions = config.rememberVoices ? speakerStore.suggestions : []
    }

    /// The menu banner nags only about high-confidence, transcript-named voices —
    /// unnamed voices live in the grid and are never pushed as a banner.
    var namedVoiceSuggestions: [SpeakerSuggestion] { voiceSuggestions.filter(\.isNamed) }

    /// Confirm/decline a specific suggestion by id (the grid's path — unnamed
    /// voices share no name). `finalName` is what the user typed; `affiliation`
    /// is the (possibly edited) org/client the voice belongs to.
    func resolveVoiceSuggestion(id: UUID, accept: Bool, as finalName: String,
                                affiliation: String? = nil) {
        if accept {
            let name = finalName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let pendingClip = speakerStore.suggestion(id: id)?.sampleAudioPath
            let enrolledClip = pendingClip.flatMap { Self.promoteVoiceClip(at: $0, forEnrolled: name) }
            speakerStore.confirmSuggestion(id: id, as: name, affiliation: affiliation,
                                           enrolledSamplePath: enrolledClip)
            Log.write("voices: enrolled '\(name)'\(affiliation.map { " (\($0))" } ?? "")")
        } else {
            let resolved = speakerStore.declineSuggestion(id: id)
            resolved?.sampleAudioPath.map { try? FileManager.default.removeItem(atPath: $0) }
            Log.write("voices: dismissed a voice suggestion")
        }
        refreshVoiceSuggestions()
    }

    /// Edit an enrolled voice's affiliation from the grid.
    func setVoiceAffiliation(_ name: String, to affiliation: String) {
        speakerStore.setAffiliation(name: name, to: affiliation)
        objectWillChange.send()
    }

    /// The orgs/clients already in use — the dropdown of affiliations to pick from,
    /// so tagging is "choose from the recurring set" not "retype every time". Home
    /// org first, then everything seen on a profile, deduped case-insensitively.
    var knownAffiliations: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in [config.homeOrganization] + speakerStore.profiles.compactMap(\.affiliation) {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    // MARK: - Reviewing & correcting attributions

    /// Meeting attributions, newest first — what the review UI lists.
    var meetingAttributions: [MeetingAttribution] { attributionStore.all }

    func meetingAttribution(recordingID: String) -> MeetingAttribution? {
        attributionStore.attribution(recordingID: recordingID)
    }

    /// Reassign one meeting's speaker to a corrected name, propagating everywhere:
    /// the voiceprints shift (this meeting's sample leaves the wrong profile and
    /// joins the right one), the transcript's speaker labels are rewritten, and the
    /// stored attribution updates. Handles both failure modes — a wrong *match*
    /// (transcript wrong, no sample to move, so the real person just gains a
    /// sample) and a wrong *enrollment* (the bad sample is pulled out).
    func reassignSpeaker(recordingID: String, label oldLabel: String,
                         to newName: String, affiliation: String? = nil) {
        guard let attr = attributionStore.attribution(recordingID: recordingID),
              let speaker = attr.speakers.first(where: { $0.label == oldLabel }),
              !speaker.isSelf else { return }
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != oldLabel else { return }

        // Vectors: drop this meeting's contribution from the old profile (no-op for
        // an anonymous label or a match-only mislabel), add it to the new one.
        speakerStore.removeSample(fromProfileNamed: oldLabel, meetingID: recordingID)
        speakerStore.enroll(name: new, embedding: speaker.embedding,
                            sampleAudioPath: speaker.clipPath, affiliation: affiliation,
                            meetingID: recordingID)

        // Transcript: rewrite the speaker's turns + frontmatter entry.
        if let path = attr.transcriptPath,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let updated = SpeakerTurns.renameSpeaker(in: text, from: oldLabel, to: new)
            try? updated.write(toFile: path, atomically: true, encoding: .utf8)
        }

        // Attribution record: this meeting now attributes that voice to the new name.
        attributionStore.update(recordingID: recordingID) { a in
            if let i = a.speakers.firstIndex(where: { $0.label == oldLabel }) {
                a.speakers[i].label = new
            }
        }
        Log.write("voices: reassigned '\(oldLabel)' → '\(new)' in meeting \(recordingID)")
        refreshVoiceSuggestions()
        objectWillChange.send()
    }

    /// "This isn't anyone I know" — demote a wrongly-matched speaker back to an
    /// anonymous label. The fix for an over-match to a stranger: the wrong name's
    /// sample from this meeting is pulled from that profile (a no-op for a
    /// match-only mislabel), and the transcript's turns + frontmatter are relabeled
    /// to a neutral "Speaker". Nothing new is enrolled — the voice stays unknown.
    func markSpeakerUnknown(recordingID: String, label oldLabel: String) {
        guard let attr = attributionStore.attribution(recordingID: recordingID),
              let speaker = attr.speakers.first(where: { $0.label == oldLabel }),
              !speaker.isSelf,
              !SpeakerTurns.isAnonymousLabel(oldLabel) else { return }   // already anonymous

        speakerStore.removeSample(fromProfileNamed: oldLabel, meetingID: recordingID)

        // Give it a neutral, in-meeting-unique anonymous label.
        let existing = Set(attr.speakers.map(\.label))
        var n = 1
        while existing.contains("Speaker \(n)") { n += 1 }
        let anon = "Speaker \(n)"

        if let path = attr.transcriptPath,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let updated = SpeakerTurns.renameSpeaker(in: text, from: oldLabel, to: anon)
            try? updated.write(toFile: path, atomically: true, encoding: .utf8)
        }
        attributionStore.update(recordingID: recordingID) { a in
            if let i = a.speakers.firstIndex(where: { $0.label == oldLabel }) {
                a.speakers[i].label = anon
            }
        }
        Log.write("voices: demoted '\(oldLabel)' → '\(anon)' (not a known voice) in meeting \(recordingID)")
        objectWillChange.send()
    }

    var voiceProfiles: [SpeakerProfile] { speakerStore.profiles }

    func removeVoiceProfile(_ name: String) {
        let removed = speakerStore.remove(name: name)
        removed?.sampleAudioPath.map { try? FileManager.default.removeItem(atPath: $0) }
        Log.write("voices: removed profile '\(name)'")
        objectWillChange.send()
    }

    // MARK: - Voice clip storage

    /// Durable home for voice clips, outside the capture scratch dir that gets
    /// pruned. `pending/` holds unconfirmed suggestions; `enrolled/` holds the
    /// clip kept alongside a confirmed profile (retained by explicit choice, #6).
    private static func voicesDir(_ sub: String) -> URL {
        let dir = HistoryStore.dir.appendingPathComponent("voices/\(sub)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func clipSlug(_ name: String) -> String {
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "voice" : slug
    }

    /// Copies a freshly-cut clip out of scratch into `pending/`, returning the new
    /// path (or nil if the copy fails — the suggestion just goes clip-less).
    private static func adoptVoiceClip(at scratchPath: String, forPending name: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scratchPath) else { return nil }
        let dest = voicesDir("pending").appendingPathComponent("\(clipSlug(name))-\(UUID().uuidString.prefix(8)).m4a")
        do { try fm.copyItem(atPath: scratchPath, toPath: dest.path); return dest.path }
        catch { return nil }
    }

    /// Copies a cluster's clip into a durable per-meeting folder for the review UI,
    /// so it outlives the scratch dir. Returns the new path (or nil on failure).
    private static func adoptMeetingClip(at scratchPath: String, recordID: UUID, label: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scratchPath) else { return nil }
        let dir = voicesDir("meetings/\(recordID.uuidString)")
        let safe = label.replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let dest = dir.appendingPathComponent("\(safe.isEmpty ? "voice" : safe).m4a")
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(atPath: scratchPath, toPath: dest.path); return dest.path }
        catch { return nil }
    }

    /// Moves a confirmed clip from `pending/` to `enrolled/`.
    private static func promoteVoiceClip(at pendingPath: String, forEnrolled name: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pendingPath) else { return nil }
        let dest = voicesDir("enrolled").appendingPathComponent("\(clipSlug(name)).m4a")
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(atPath: pendingPath, toPath: dest.path); return dest.path }
        catch { return nil }
    }

    // MARK: - History & recovery

    /// Rebuilds the visible lists from the durable history store.
    private func refreshRecents() {
        allRecents = history.records.map { r in
            let audioExists = r.audioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return RecentItem(
                id: r.id, title: r.title, destination: r.destination, when: r.recordedAt,
                status: r.status, path: r.documentURL,
                retryable: r.status == .failed && audioExists,
                isCall: r.isCall, callKey: r.callKey, isEmpty: r.isEmpty)
        }
        let limit = max(1, config.recentsLimit)
        recents = Array(allRecents.prefix(limit))
    }

    // MARK: - Day / call grouping

    /// One call: the fragments of a single meeting collapsed into one row. A one-off
    /// recording or a note is just a group of one.
    struct CallGroup: Identifiable {
        let id: String
        let title: String
        let items: [RecentItem]      // newest first
        let when: Date
        let destination: String?
        /// Every fragment captured nothing usable (all silent).
        let allEmpty: Bool
        var count: Int { items.count }
        var isSingle: Bool { items.count == 1 }
    }

    struct DayGroup: Identifiable { let id: String; let label: String; let calls: [CallGroup] }

    /// Groups recents into ordered day sections and, within each day, collapses the
    /// fragments of one call into a single `CallGroup`.
    func groupedByDay(_ items: [RecentItem]) -> [DayGroup] {
        var days: [(label: String, items: [RecentItem])] = []
        for item in items {
            let label = Self.dayLabel(item.when)
            if let i = days.lastIndex(where: { $0.label == label }) {
                days[i].items.append(item)
            } else {
                days.append((label, [item]))
            }
        }
        return days.enumerated().map { idx, day in
            DayGroup(id: "\(day.label)-\(idx)", label: day.label, calls: Self.clusterCalls(day.items))
        }
    }

    /// Collapses a day's items (newest first, so a call's fragments are contiguous)
    /// into calls: items sharing a `callKey` merge; legacy fragments with no key merge
    /// when they're back-to-back calls (< 25 min apart). Notes/one-offs stay separate.
    private static func clusterCalls(_ items: [RecentItem]) -> [CallGroup] {
        var groups: [[RecentItem]] = []
        for item in items {
            if let li = groups.indices.last {
                let head = groups[li][0]
                let sameCall: Bool
                if let k = item.callKey {
                    sameCall = head.callKey == k
                } else if item.isCall, head.callKey == nil, head.isCall {
                    sameCall = abs(groups[li][groups[li].count - 1].when.timeIntervalSince(item.when)) < 1_500
                } else {
                    sameCall = false
                }
                if sameCall { groups[li].append(item); continue }
            }
            groups.append([item])
        }
        return groups.map { frags in
            let newest = frags[0]
            // Header prefers a real (non-empty) fragment's title over an empty one.
            let title = frags.first(where: { !$0.isEmpty })?.title ?? newest.title
            let dest = frags.compactMap(\.destination).first
            return CallGroup(
                id: newest.callKey ?? "call-\(newest.id.uuidString)",
                title: title, items: frags, when: newest.when,
                destination: dest, allEmpty: frags.allSatisfy(\.isEmpty))
        }
    }

    /// Stable per-call key: sanitized meeting name + calendar day, so a meeting's
    /// fragments group together while different meetings stay distinct.
    static func callKey(name: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "\(Recording.sanitize(name))|\(f.string(from: date))"
    }

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 {
            let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: date)
        }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: date)
    }

    /// A short, human-readable error for the menu (raw NSErrors dump nested UserInfo
    /// dicts — that's the concatenated wall). Full detail still goes to the log.
    static func shortError(_ error: Error) -> String {
        var msg = String(describing: error)
        if msg.contains("Error Domain=") || msg.count > 160 {
            msg = (error as NSError).localizedDescription
        }
        return msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
    }

    private func updateRecord(_ id: UUID?, _ mutate: (inout RecordingRecord) -> Void) {
        guard let id, var r = history.record(id) else { return }
        mutate(&r)
        history.upsert(r)
    }

    /// On launch, pick up anything left mid-flight by a crash/quit: records still
    /// marked recording/processing get reprocessed from their durable audio, or
    /// marked failed if nothing was recovered. Failed records with audio stay
    /// retryable from the menu.
    /// Rebuilds a `Recording` for reprocessing (recovery or retry). When the raw
    /// two-track CAFs survived in the capture dir (a crash mid-call, before the
    /// mix-and-cleanup ran), wire them back up so the pipeline can diarize and
    /// harvest voices — otherwise a recovered multi-person call would collapse to
    /// a single flat transcript with no speaker attribution. Both tracks started
    /// together at capture time, so a zero offset is the right approximation.
    private func rebuildRecording(from r: RecordingRecord, audio: URL) -> Recording {
        var rec = Recording(
            audioURL: audio, startedAt: r.recordedAt, endedAt: r.endedAt ?? Date(),
            activeApp: r.activeApp.map { ActiveAppContext(appName: $0, capturedAt: r.recordedAt) })
        if let dir = r.captureDir.map({ URL(fileURLWithPath: $0) }) {
            let fm = FileManager.default
            // Prefer the assembled tracks when the meeting was stitched back
            // together from fragments. `audio.caf` is only the *last* fragment —
            // on a session that survived a few relaunches that is the final few
            // minutes of the evening, and reprocessing from it would quietly
            // throw away the other three hours.
            let assembledMic = dir.appendingPathComponent("meeting-mic.m4a")
            let assembledSystem = dir.appendingPathComponent("meeting-system.m4a")
            let mic = fm.fileExists(atPath: assembledMic.path)
                ? assembledMic : dir.appendingPathComponent("audio.caf")
            let system = fm.fileExists(atPath: assembledSystem.path)
                ? assembledSystem : dir.appendingPathComponent("system.caf")
            if fm.fileExists(atPath: mic.path) {
                rec.micAudioURL = mic
                if fm.fileExists(atPath: system.path) {
                    rec.systemAudioURL = system
                    rec.systemAudioStartOffset = 0
                }
                Log.write("recovery: reprocessing from \(mic.lastPathComponent)"
                          + (rec.systemAudioURL != nil ? " + \(system.lastPathComponent)" : ""))
            }
        }
        return rec
    }

    // MARK: - Device ingest

    /// Starts (or retargets) the device-inbox poll. Call after any change to the
    /// configured folder so switching providers takes effect without a relaunch.
    func startDeviceWatcher() {
        if deviceWatcher == nil {
            deviceWatcher = DeviceInboxWatcher { [weak self] found in
                self?.ingest(found)
            }
        }
        let root = config.destinations.resolvedDeviceInbox
        deviceWatcher?.retarget(to: root)
        if let root {
            Log.write("device inbox: watching \(root.path)")
        }
    }

    /// Imports a capture recorded on the phone/iPad.
    ///
    /// The audio is copied into the local captures dir before anything else: the
    /// source lives in a cloud folder that can vanish, re-sync, or be pruned
    /// mid-pipeline, and a transcribe stage reading from under itself fails in
    /// confusing ways. Once copied, this is an ordinary recording and takes the
    /// same path as anything captured on the Mac.
    private func ingest(_ pending: [DeviceInbox.Pending]) {
        for item in pending {
            let capture = item.capture
            let recordID = capture.id
            let dir = HistoryStore.capturesDir.appendingPathComponent(recordID.uuidString, isDirectory: true)
            let local = dir.appendingPathComponent(capture.audioFilename)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: local.path) {
                    try FileManager.default.removeItem(at: local)
                }
                try FileManager.default.copyItem(at: item.audio, to: local)
            } catch {
                Log.write("device inbox: couldn't import \(capture.audioFilename) — \(error)")
                continue
            }

            let ended = capture.startedAt.addingTimeInterval(capture.duration)
            history.upsert(RecordingRecord(
                id: recordID,
                title: capture.titleHint ?? "\(capture.deviceName) — \(capture.startedAt.formatted(date: .abbreviated, time: .shortened))",
                recordedAt: capture.startedAt, endedAt: ended,
                activeApp: nil, isCall: false, status: .processing,
                captureDir: dir.path, audioPath: local.path,
                documentPath: nil, destination: nil, errorText: nil))

            var recording = Recording(audioURL: local, startedAt: capture.startedAt, endedAt: ended)
            recording.title = capture.titleHint
            if let sid = capture.sessionID {
                remoteTags[recordID] = RemoteSession.Item(
                    id: recordID, sessionID: sid, label: capture.sessionLabel,
                    startedAt: capture.startedAt, duration: capture.duration)
            }
            Log.write("device inbox: importing \(capture.audioFilename) from \(capture.deviceName)")

            // The device's draft is deliberately NOT seeded as the transcript —
            // it has no diarization and no second pass. The Mac re-transcribes
            // from the audio, which is the whole reason the audio is shipped.
            runPipeline(for: recording, recordID: recordID)
            deviceWatcher?.markHandled(capture.id)
            archiveIngested(item)
        }
        refreshRecents()
        // After the batch, not per capture: an evening arrives as several files
        // and the run is only whole once they are all in.
        Task { await reconcileRemoteSessions() }
    }

    /// Tagged captures seen this launch, keyed by recording id.
    ///
    /// Deliberately not persisted. A run's completion is remembered instead
    /// (see `SessionManager.firedRuns`), which is the fact that actually needs
    /// to survive; re-deriving the items from a fresh ingest is cheap and
    /// self-correcting.
    private var remoteTags: [UUID: RemoteSession.Item] = [:]

    private func reconcileRemoteSessions() async {
        guard !remoteTags.isEmpty else { return }
        await sessions.reconcileRemote(items: Array(remoteTags.values)) { [weak self] run, profile in
            guard let self else { return }
            // Reuse the same completion path as a locally-run session, so a
            // publish script cannot tell the difference between an evening
            // recorded here and one recorded on the phone.
            var synthetic = ActiveSession(
                profileID: profile.id, startedAt: run.startedAt, label: run.label,
                recordingIDs: run.items.map(\.id))
            synthetic.endedAt = run.endedAt
            synthetic.endReason = run.reason
            await self.runSessionCompletion(synthetic, profile)
        }
    }

    /// Moves an imported capture out of `Inbox/` so the device side can see it
    /// landed, and a re-scan doesn't keep finding it. Failing to move is not
    /// fatal — `markHandled` already prevents a duplicate import this session.
    private func archiveIngested(_ item: DeviceInbox.Pending) {
        guard let root = config.destinations.resolvedDeviceInbox else { return }
        let done = DeviceInbox.processed(under: root)
        do {
            try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
            for url in [item.audio, item.sidecar] {
                let dest = done.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: url, to: dest)
            }
        } catch {
            Log.write("device inbox: imported but couldn't archive \(item.audio.lastPathComponent) — \(error)")
        }
    }

    private func recoverInterrupted() {
        // Fragments set aside by an earlier run of the app, before anything else
        // decides what to do with the recordings around them.
        carriedFragments = relaunch.loadFragments().map(CarriedFragment.init)
        if !carriedFragments.isEmpty {
            Log.write("relaunch: picked up \(carriedFragments.count) held fragment(s) from a previous run")
        }

        // The app went away while a recording was live and recently enough that
        // the meeting is still going: carry the audio forward and pick it back
        // up, instead of filing half an evening as a finished note.
        if let marker = relaunch.resumableMarker() {
            resumeAfterRelaunch(marker)
            return
        }

        let interrupted = history.records.filter { $0.status == .recording || $0.status == .processing }
        guard !interrupted.isEmpty else { return }
        Log.write("recovery: \(interrupted.count) interrupted recording(s) found at launch")
        for r in interrupted {
            guard let audio = r.audioURL, FileManager.default.fileExists(atPath: audio.path),
                  (try? audio.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 1_000 else {
                updateRecord(r.id) { $0.status = .failed; $0.errorText = "interrupted before audio was saved" }
                continue
            }
            Log.write("recovery: reprocessing \(r.id) from \(audio.lastPathComponent)")
            updateRecord(r.id) { $0.status = .processing }
            runPipeline(for: rebuildRecording(from: r, audio: audio), recordID: r.id)
        }
        refreshRecents()
    }

    /// Picks a meeting back up after the app was restarted underneath it.
    ///
    /// Every interrupted capture becomes a carried fragment rather than a note,
    /// and recording restarts immediately. The stitching that mic recovery
    /// already used then reassembles the whole evening on one wall-clock
    /// timeline when it finally ends — so the only trace of the restart is a
    /// couple of seconds of silence where the app was gone.
    private func resumeAfterRelaunch(_ marker: RelaunchState.Marker) {
        let interrupted = history.records.filter { $0.status == .recording }
        for r in interrupted {
            guard let dir = r.captureDir.map({ URL(fileURLWithPath: $0) }) else { continue }
            let mic = dir.appendingPathComponent("audio.caf")
            guard FileManager.default.fileExists(atPath: mic.path),
                  (try? mic.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 1_000 else {
                updateRecord(r.id) { $0.status = .failed; $0.errorText = "interrupted before audio was saved" }
                continue
            }
            let system = dir.appendingPathComponent("system.caf")
            let hasSystem = FileManager.default.fileExists(atPath: system.path)
            carriedFragments.append(CarriedFragment(
                startedAt: r.recordedAt,
                micAudioURL: mic,
                systemAudioURL: hasSystem ? system : nil,
                // The offset was never persisted; the two tracks start together
                // closely enough that assuming zero beats dropping the track.
                systemAudioStartOffset: hasSystem ? 0 : nil))
            // No note for a fragment — the recording that ends the meeting owns it.
            history.remove(r.id)
        }
        refreshRecents()
        resumedFragmentCount = carriedFragments.count
        Log.write("relaunch: resuming '\(marker.title)' with \(carriedFragments.count) fragment(s) carried")
        recordingIsCall = marker.isCall
        startRecording(continuing: true)
    }

    // MARK: - Restarting under a live recording

    /// Stops a live recording the safe way and hands back once the audio is on
    /// disk. Called when the app is quitting — by the user, or by a rebuild.
    ///
    /// The capture is carried forward rather than filed, so relaunching picks the
    /// meeting back up. Nothing here is strictly required to save the audio (an
    /// LPCM CAF survives being killed outright), but doing it properly also
    /// flushes the last buffer, finalizes the system-audio writer, and stamps the
    /// live transcript — and it makes "rebuild the app mid-session" an ordinary
    /// thing rather than a gamble.
    func prepareForRelaunch(_ done: @escaping () -> Void) {
        guard recorder != nil else { done(); return }
        Log.write("relaunch: quitting with a recording live — carrying it forward")
        stopRecordingAndProcess(carryForward: true)
        // stopRecordingAndProcess finishes its file work in a detached task; give
        // it a moment to land, then go. The CAF is valid either way, so this is a
        // courtesy deadline, not a correctness one.
        Task { @MainActor in
            for _ in 0..<40 where self.recorder != nil || self.state == .processing {
                try? await Task.sleep(for: .milliseconds(50))
            }
            done()
        }
    }

    // MARK: - Backups (retained local copies)

    /// Prunes capture backups older than the retention window, keeping any still
    /// referenced by an interrupted/processing record (recovery safety).
    private func pruneBackups() {
        let days = config.backupRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keep = Set(history.records
            .filter { $0.status == .recording || $0.status == .processing }
            .compactMap { $0.captureDir })
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: HistoryStore.capturesDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        var pruned = 0
        for entry in entries where !keep.contains(entry.path) {
            let mod = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if mod < cutoff { try? FileManager.default.removeItem(at: entry); pruned += 1 }
        }
        if pruned > 0 { Log.write("backups: pruned \(pruned) recording(s) older than \(days) days") }
    }

    func revealBackups() {
        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.capturesDir])
    }

    /// The on-disk voice profile store — the file an agent (Copilot/Claude) edits
    /// to enrich names and affiliations from meeting invites or a knowledge base.
    var voicesFileURL: URL { FluidAudioDiarizer.profilesURL }

    func revealVoicesFile() {
        NSWorkspace.shared.activateFileViewerSelecting([voicesFileURL])
    }

    /// The earlier "Use Obsidian" preset used `open -a "Obsidian" "{path}"`, which only
    /// activates Obsidian without opening the note. Upgrade that exact preset to the
    /// obsidian:// URI form, which opens the specific file.
    /// Only migrates when the knowledge root actually sits inside a vault — the
    /// URI form fails outright anywhere else, so upgrading a working (if
    /// imprecise) `open -a` into a modal error would be a downgrade.
    private func migrateOpenCommand() {
        guard config.openCommand == #"open -a "Obsidian" "{path}""# else { return }
        let root = config.destinations.resolvedRoot
        guard Self.obsidianVaultRoot(
            containing: root.appendingPathComponent("probe.md").path) != nil else {
            Log.write("open: '\(root.path)' isn't in an Obsidian vault — keeping `open -a`")
            return
        }
        config.openCommand = #"open "obsidian://open?path={path_encoded}""#
        try? configStore.save(config)   // didSet doesn't fire in init
        Log.write("migrated Obsidian open command to the obsidian:// URI")
    }

    /// Turns on the vault mirror for Obsidian users, once.
    ///
    /// An Obsidian user's transcripts belong in their notes, and asking them to
    /// find and paste their own vault path is asking them to tell the app
    /// something Obsidian already records. So the first launch looks, and files
    /// there from then on — markdown only, alongside the iCloud copy the phone
    /// and iPad read, not instead of it.
    ///
    /// Runs once. `vaultMirrorDetected` is what makes clearing the mirror in
    /// Settings stick rather than being re-detected on the next launch, and it
    /// is why this is not simply a computed default.
    private func detectVaultMirror() {
        guard !config.destinations.vaultMirrorDetected else { return }
        config.destinations.vaultMirrorDetected = true
        defer { try? configStore.save(config) }   // didSet doesn't fire in init

        guard let vault = ObsidianVault.mostRecentlyOpened() else {
            Log.write("vault mirror: no Obsidian vault registered — leaving it off")
            return
        }
        // Filing into the vault a transcript already lives in would write it
        // twice into the same folder.
        guard ObsidianVault.root(containing:
                config.destinations.resolvedRoot.appendingPathComponent("probe.md").path) != vault else {
            Log.write("vault mirror: knowledge root is already inside '\(vault.lastPathComponent)' — leaving it off")
            return
        }
        config.destinations.vaultMirror = vault.path
        Log.write("vault mirror: filing markdown into '\(vault.path)'")
    }

    // MARK: - Rename

    /// Quick rename: prompt for a new title and update the recording. Updates the
    /// history/display title; the vault document keeps its filename.
    func promptRename(_ id: UUID) {
        guard let r = history.record(id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename recording"
        alert.informativeText = "Enter a new title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = r.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != r.title else { return }
        rename(id, to: title)
    }

    /// Sets a recording's title and locks it so reprocessing won't overwrite it.
    func rename(_ id: UUID, to title: String) {
        updateRecord(id) { $0.title = title; $0.renamedByUser = true }
        refreshRecents()
        Log.write("rename: \(id) → \(title)")
    }

    // MARK: - Delete

    /// Confirmed delete: vault artifacts (note + sibling audio) move to the
    /// Trash — recoverable, and vault-watcher commits the removal so Obsidian
    /// follows. The durable backup under Application Support is kept unless the
    /// checkbox opts in. (Deletion was deliberately omitted for a long time; it
    /// arrives Trash-only, never `rm`.)
    func promptDelete(_ id: UUID) {
        guard let r = history.record(id) else { return }
        guard r.status != .recording, r.status != .processing else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(r.title)”?"
        alert.informativeText = "The note and its audio move to the Trash, and the row disappears from Transcripts. The local backup is kept unless you also trash it."
        let checkbox = NSButton(checkboxWithTitle: "Also trash the local backup", target: nil, action: nil)
        alert.accessoryView = checkbox
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        delete(id, includeBackup: checkbox.state == .on)
    }

    func delete(_ id: UUID, includeBackup: Bool) {
        guard let r = history.record(id) else { return }
        let fm = FileManager.default
        var trashed: [String] = []
        if let doc = r.documentURL, fm.fileExists(atPath: doc.path) {
            // Sibling audio shares the document's base name (standard format).
            let base = doc.deletingPathExtension()
            for ext in ["m4a", "caf"] {
                let sibling = base.appendingPathExtension(ext)
                if fm.fileExists(atPath: sibling.path),
                   (try? fm.trashItem(at: sibling, resultingItemURL: nil)) != nil {
                    trashed.append(sibling.lastPathComponent)
                }
            }
            if (try? fm.trashItem(at: doc, resultingItemURL: nil)) != nil {
                trashed.append(doc.lastPathComponent)
            }
        }
        if includeBackup, let dirPath = r.captureDir {
            let dir = URL(fileURLWithPath: dirPath)
            if fm.fileExists(atPath: dir.path),
               (try? fm.trashItem(at: dir, resultingItemURL: nil)) != nil {
                trashed.append("backup \(dir.lastPathComponent)")
            }
        }
        history.remove(id)
        refreshRecents()
        Log.write("delete: '\(r.title)' — trashed \(trashed.isEmpty ? "nothing (files already gone)" : trashed.joined(separator: ", "))\(includeBackup ? "" : "; backup kept")")
    }

    // MARK: - Open externally

    /// True when a custom "open with" command is configured.
    var canOpenExternally: Bool {
        !(config.openCommand ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Friendly label for the open action, derived from the command
    /// (`open -a "Obsidian"` → "Open in Obsidian"), else a generic label.
    var openExternallyLabel: String {
        Self.appName(fromOpenCommand: config.openCommand).map { "Open in \($0)" } ?? "Open externally"
    }

    /// Opens a recording's document with the configured command (or the system default
    /// app when none is set). `{path}` in the command is replaced with the document
    /// path; otherwise the shell-quoted path is appended.
    func openExternally(_ id: UUID) {
        guard let r = history.record(id), let path = r.documentPath else {
            lastError = "This recording has no document to open."
            return
        }
        openDocument(atPath: path)
    }

    /// The live (mid-call) transcript, preferring the *visible* vault note —
    /// Obsidian live-refreshes it but refuses paths under dot-folders, so the
    /// human view is `Transcripts Live.md`, not `.transcripts/live.md`.
    var liveTranscriptURL: URL? {
        let vault = config.destinations.resolvedRoot
            .appendingPathComponent("Transcripts Live.md")
        if FileManager.default.fileExists(atPath: vault.path) { return vault }
        let local = HistoryStore.dir.appendingPathComponent("live.md")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// Opens the live transcript in the configured viewer — the "watch the call
    /// transcribe itself" button.
    func openLiveTranscript() {
        guard let url = liveTranscriptURL else {
            lastError = "No live transcript yet — it appears a few seconds into a recording."
            return
        }
        openDocument(atPath: url.path)
    }

    private func openDocument(atPath path: String) {
        let template = (config.openCommand ?? "").trimmingCharacters(in: .whitespaces)
        guard !template.isEmpty else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        // obsidian://open resolves a path only if it sits inside a registered
        // vault; anywhere else Obsidian puts up a modal "Vault not found" and the
        // note never opens. The knowledge root defaults to ~/Documents/Transcripts,
        // which is a plain folder unless the user deliberately made it a vault —
        // so this preset is a dead end for most setups (2026-08-03). Open the
        // file normally instead of handing the user an error sheet.
        if template.contains("obsidian://"), Self.obsidianVaultRoot(containing: path) == nil {
            Log.write("open: not inside an Obsidian vault — opening '\(path)' with the default app")
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        // Placeholders supply their own quoting (defaults quote them), so substitute
        // raw — quoting again would bake literal quotes into the value:
        //   {path}          → the raw filesystem path (for `open -a AppName "{path}"`)
        //   {path_encoded}  → URL-encoded path (for URIs like obsidian://open?path=…)
        // With no placeholder we append a shell-quoted path.
        let cmd: String
        if template.contains("{path}") || template.contains("{path_encoded}") {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: Self.uriPathAllowed) ?? path
            cmd = template
                .replacingOccurrences(of: "{path_encoded}", with: encoded)
                .replacingOccurrences(of: "{path}", with: path)
        } else {
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            cmd = "\(template) \(quoted)"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        do { try p.run(); Log.write("open: \(cmd)") }
        catch {
            Log.write("open: FAILED — \(error)")
            lastError = "Couldn't open externally: \(Self.shortError(error))"
        }
    }

    /// Walks up from `path` looking for the `.obsidian` folder that marks a vault
    /// root. Returns nil when the file lives outside every vault — the case where
    /// `obsidian://open` can only fail.
    static func obsidianVaultRoot(containing path: String) -> URL? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        while dir.path != "/" {
            var isDir: ObjCBool = false
            let marker = dir.appendingPathComponent(".obsidian").path
            if FileManager.default.fileExists(atPath: marker, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// Percent-encoding for a path placed into a URI value. Encodes everything except
    /// the unreserved set — importantly `/` becomes `%2F` and spaces `%20`, which
    /// obsidian://open?path= requires ("forward slashes must be encoded as %2F").
    private static let uriPathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Pulls an app name out of an `open -a "App"` style command, for labeling.
    private static func appName(fromOpenCommand command: String?) -> String? {
        guard let cmd = command?.trimmingCharacters(in: .whitespaces), !cmd.isEmpty else { return nil }
        // A URI scheme (e.g. obsidian://) names the app.
        if let r = cmd.range(of: "://") {
            let scheme = cmd[..<r.lowerBound]
            if let last = scheme.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).last, last.count >= 2 {
                return last.prefix(1).uppercased() + last.dropFirst()
            }
        }
        // `open -a "App"` style.
        if let r = cmd.range(of: "-a ") {
            var rest = String(cmd[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") {
                rest.removeFirst()
                return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
            }
            if let sp = rest.firstIndex(of: " ") { return String(rest[..<sp]) }
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    // MARK: - Re-sort existing recordings

    /// Re-runs classification on an existing recording's transcript and moves its
    /// files if the destination changed. Returns true if it moved.
    @discardableResult
    func resort(_ id: UUID) async -> Bool {
        guard let r = history.record(id), let docPath = r.documentPath else { return false }
        let mdURL = URL(fileURLWithPath: docPath)
        guard FileManager.default.fileExists(atPath: mdURL.path) else { return false }

        let cfg = config
        var ctx = PipelineContext(
            recording: Recording(audioURL: mdURL, startedAt: r.recordedAt, title: r.title),
            scratchDir: mdURL.deletingLastPathComponent())
        ctx.transcriptURL = mdURL
        let stage = classifyStage(for: cfg, model: Self.makeChatModel(for: cfg))
        try? await stage.run(&ctx)
        guard let dest = ctx.routing?.destination, !dest.isEmpty else { return false }

        // No-op if it already lives there.
        let root = cfg.destinations.resolvedRoot
        let destDir = root.appendingPathComponent(dest, isDirectory: true)
        if mdURL.deletingLastPathComponent().standardizedFileURL.path == destDir.standardizedFileURL.path {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let newDoc = destDir.appendingPathComponent(mdURL.lastPathComponent)
            try replaceMove(mdURL, to: newDoc)
            // Move the sibling audio (<slug>.m4a) too, if present in the vault.
            var newAudioPath = r.audioPath
            let audioSibling = mdURL.deletingPathExtension().appendingPathExtension("m4a")
            if FileManager.default.fileExists(atPath: audioSibling.path) {
                let newAudio = destDir.appendingPathComponent(audioSibling.lastPathComponent)
                try replaceMove(audioSibling, to: newAudio)
                newAudioPath = newAudio.path
            }
            updateRecord(id) { $0.documentPath = newDoc.path; $0.audioPath = newAudioPath; $0.destination = dest }
            Log.write("resort: \(r.title) → \(dest)")
            refreshRecents()
            return true
        } catch {
            Log.write("resort: failed to move \(r.title) — \(error)")
            return false
        }
    }

    /// Batch re-sort every completed recording per current rules (moves vault files).
    func resortAll() {
        let ids = history.records.filter { $0.status == .completed && $0.documentPath != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        guard Self.confirm(title: "Re-sort \(ids.count) recordings?",
                           message: "Transcripts will re-run the current sorting rules and move any recordings whose destination changed. This moves files within your knowledge vault.") else { return }
        Task { @MainActor in
            var moved = 0
            for id in ids { if await self.resort(id) { moved += 1 } }
            Log.write("resort: batch moved \(moved)/\(ids.count)")
            Self.info(title: "Re-sort complete", message: "Moved \(moved) of \(ids.count) recordings.")
        }
    }

    private func replaceMove(_ from: URL, to: URL) throws {
        if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
        try FileManager.default.moveItem(at: from, to: to)
    }

    /// Manually reprocess a failed recording from its saved audio.
    func retry(_ id: UUID) {
        guard let r = history.record(id), let audio = r.audioURL,
              FileManager.default.fileExists(atPath: audio.path) else {
            updateRecord(id) { $0.errorText = "cannot retry — audio no longer available" }
            refreshRecents()
            return
        }
        Log.write("retry: reprocessing \(id)")
        updateRecord(id) { $0.status = .processing; $0.errorText = nil }
        refreshRecents()
        runPipeline(for: rebuildRecording(from: r, audio: audio), recordID: id)
    }

    /// Notes bypass encode/transcribe; we hand a pre-built transcript to the
    /// remaining stages by running classify + persist natively.
    private func processNote(recording: Recording, transcript: URL, cfg: AppConfig) async throws -> PipelineContext {
        // Notes route straight through classify + persist with the typed text as
        // the transcript (encode/transcribe don't apply).
        var ctx = PipelineContext(recording: recording, scratchDir: transcript.deletingLastPathComponent())
        ctx.transcriptURL = transcript
        let classify = classifyStage(for: cfg, model: Self.makeChatModel(for: cfg))
        try await classify.run(&ctx)
        let persist = PersistStage(config: cfg, copyAudio: false)
        try await persist.run(&ctx)
        return ctx
    }

    func makeRoutingStore() -> RoutingStore {
        RoutingStore(knowledgeRoot: config.destinations.resolvedRoot)
    }

    /// Ensures `.transcripts/routing.json` exists and reveals it in Finder for hand-editing.
    func revealRoutingConfig() {
        let store = makeRoutingStore()
        _ = store.loadOrSeed()
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    private func classifyStage(for cfg: AppConfig, model: any ChatModel) -> ClassifyStage {
        let store = RoutingStore(knowledgeRoot: cfg.destinations.resolvedRoot)
        return ClassifyStage(
            model: model,
            knowledgeRoot: cfg.destinations.resolvedRoot,
            routing: routing,
            destinations: store.effectiveDestinations(routing),
            runner: ProcessCommandRunner())
    }

    private func nativeStages(for cfg: AppConfig, roomMode: Bool = false) -> [PipelineStage] {
        let llm = Self.makeChatModel(for: cfg)
        return [
            EncodeStage(codec: cfg.archiveCodec),
            TranscribeStage(model: cfg.whisper.model, rememberVoices: cfg.rememberVoices,
                            matchThreshold: Float(cfg.nameMatchConfidence),
                            roomMode: roomMode,
                            clusteringThreshold: cfg.roomVoiceSensitivity > 0 ? Float(cfg.roomVoiceSensitivity) : nil),
            SummarizeStage(model: llm),
            classifyStage(for: cfg, model: llm),
            PersistStage(config: cfg),
        ]
    }

    /// When Ollama is the selected provider, make sure the server is actually up
    /// before the pipeline needs it: launch the Ollama app (hidden) or a headless
    /// `ollama serve`, then wait briefly for the port. Without this, a reboot
    /// silently degraded every summary until the user remembered to start it.
    private func ensureOllamaRunning(_ cfg: AppConfig) async {
        guard cfg.llmProvider == .ollama else { return }
        let base = URL(string: cfg.ollama.url) ?? URL(string: "http://localhost:11434")!
        if await Self.ollamaResponds(base) { return }
        Log.write("ollama: not responding — launching it")

        let fm = FileManager.default
        let apps = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ollama.app"),
                    URL(fileURLWithPath: "/Applications/Ollama.app")]
        if let app = apps.first(where: { fm.fileExists(atPath: $0.path) }) {
            let config = NSWorkspace.OpenConfiguration()
            config.hides = true
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in }
        } else {
            // Headless install (brew formula only): spawn a detached server.
            let bins = ["\(NSHomeDirectory())/homebrew/bin/ollama",
                        "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            if let bin = bins.first(where: { fm.isExecutableFile(atPath: $0) }) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["serve"]
                try? p.run()
            }
        }

        for _ in 0..<30 {   // up to ~15s for the server to come up
            try? await Task.sleep(for: .milliseconds(500))
            if await Self.ollamaResponds(base) {
                Log.write("ollama: up")
                await ensureOllamaModel(cfg, base: base)
                return
            }
        }
        Log.write("ollama: still not responding — this run falls back to the on-device/extractive chain")
    }

    /// Selecting Ollama in Settings should be the *entire* setup: if the
    /// configured model isn't present, pull it in the background. The current
    /// run may summarize via the fallback chain while the pull completes; every
    /// run after that gets the real model.
    private func ensureOllamaModel(_ cfg: AppConfig, base: URL) async {
        let model = cfg.ollama.model
        guard !model.isEmpty else { return }
        var tags = URLRequest(url: base.appendingPathComponent("api/tags"))
        tags.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: tags),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return }
        let names = models.compactMap { $0["name"] as? String }
        guard !names.contains(model), !names.contains("\(model):latest") else { return }

        Log.write("ollama: model '\(model)' not present — pulling in the background")
        Task.detached {
            var pull = URLRequest(url: base.appendingPathComponent("api/pull"))
            pull.httpMethod = "POST"
            pull.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": false])
            pull.timeoutInterval = 3600   // multi-GB download
            if let (body, resp) = try? await URLSession.shared.data(for: pull),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               String(decoding: body, as: UTF8.self).contains("success") {
                Log.write("ollama: model '\(model)' pulled")
            } else {
                Log.write("ollama: pull of '\(model)' failed — check the model name in Settings")
            }
        }
    }

    private static func ollamaResponds(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// Builds the text-generation backend. Self-contained by default: Apple's
    /// on-device model with the built-in extractive summarizer as the always-
    /// succeeds floor — no daemon, no install. Ollama joins the chain ONLY when
    /// the user selects it as the provider; it's an option, not a dependency.
    static func makeChatModel(for cfg: AppConfig) -> any ChatModel {
        var chain: [any ChatModel] = []

        if cfg.llmProvider == .ollama {
            chain.append(OllamaClient(config: cfg.ollama))
        }

        #if canImport(FoundationModels)
        if FoundationModelsChatModel.isAvailable, #available(macOS 26, *) {
            chain.append(AppleFoundationModel())
        }
        #endif

        #if arch(arm64)
        // Built-in in-process model (MLX): covers Macs where Apple Intelligence
        // is off/blocked, with no external software. Downloads once, lazily.
        // Skipped when the build shipped without MLX's Metal shaders — MLX would
        // kill the process rather than let the chain degrade. See isAvailable.
        if MLXChatModel.isAvailable {
            chain.append(MLXChatModel())
        }
        #endif

        chain.append(ExtractiveChatModel()) // always-succeeds, zero-dependency
        return CascadingChatModel(chain)
    }

    /// One-line note about which LLM backend is active, for the menu/settings.
    /// When the preferred backend can't run, says exactly why — "titles will be
    /// rough" should never be a mystery.
    var llmStatus: String {
        if config.llmProvider == .ollama {
            return "Ollama (\(config.ollama.model))"
        }
        #if canImport(FoundationModels)
        if FoundationModelsChatModel.isAvailable {
            return "On-device (Apple Intelligence)"
        }
        #endif
        #if arch(arm64)
        guard MLXChatModel.isAvailable else {
            return "Built-in summarizer (rough titles; this build shipped without MLX's Metal shaders)"
        }
        if let reason = FoundationModelsChatModel.unavailableReason {
            return "Built-in model (MLX) — \(reason)"
        }
        return "Built-in model (MLX)"
        #else
        return "Built-in summarizer (rough titles; enable Apple Intelligence or Ollama)"
        #endif
    }

    /// Reads the `title:` value from a markdown file's YAML frontmatter, if present.
    private static func frontmatterTitle(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---\n") else { return nil }
        for line in text.components(separatedBy: "\n").dropFirst() {
            if line == "---" { break }
            if line.hasPrefix("title:") {
                return line.dropFirst("title:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private func persistConfig() {
        try? configStore.save(config)
    }

    // MARK: - Launch at login

    var launchAtLoginEnabled: Bool { LoginItem.isEnabled }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.setEnabled(on)
        objectWillChange.send()
    }

    /// Show the one-time prompt only if we haven't asked and it isn't already on.
    var shouldPromptLaunchAtLogin: Bool {
        !config.promptedLaunchAtLogin && !LoginItem.isEnabled
    }

    func answerLaunchAtLoginPrompt(enable: Bool) {
        if enable { LoginItem.setEnabled(true) }
        config.promptedLaunchAtLogin = true   // persists via didSet
    }

    // MARK: - Updates

    /// Set when a quiet check finds a newer release (drives the menu banner).
    @Published var updateAvailable: Updater.Release?

    /// Silent check on launch; only surfaces a banner if an update exists.
    func checkForUpdatesQuietly() {
        Task { @MainActor in
            if let r = try? await Updater.latest(includePrereleases: self.config.includePrereleases),
               Updater.isNewer(r.version) {
                self.updateAvailable = r
                Log.write("update: \(r.version) available (have \(Updater.currentVersion))")
            }
        }
    }

    /// User-initiated check with alerts either way.
    func checkForUpdatesInteractive() {
        Task { @MainActor in
            do {
                let r = try await Updater.latest(includePrereleases: self.config.includePrereleases)
                if Updater.isNewer(r.version) {
                    self.updateAvailable = r
                    if Self.confirm(title: "Update available",
                                    message: "Transcripts \(r.version) is available (you have \(Updater.currentVersion)). Download and install now?") {
                        self.installUpdate(r)
                    }
                } else {
                    Self.info(title: "You're up to date", message: "Transcripts \(Updater.currentVersion) is the latest version.")
                }
            } catch {
                Self.info(title: "Couldn't check for updates", message: error.localizedDescription)
            }
        }
    }

    func installUpdate(_ release: Updater.Release) {
        Task { @MainActor in
            do {
                Log.write("update: downloading \(release.version)")
                let zip = try await Updater.download(release)
                let unzipDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TranscriptsUpdate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-x", "-k", zip.path, unzipDir.path]
                try ditto.run(); ditto.waitUntilExit()
                guard ditto.terminationStatus == 0, let newApp = Self.findApp(in: unzipDir) else {
                    Self.info(title: "Update failed", message: "The downloaded archive couldn't be expanded.")
                    return
                }

                // Managed laptops have a read-only /Applications — always install to
                // the per-user ~/Applications, creating it (with consent) if needed.
                let appsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
                if !FileManager.default.fileExists(atPath: appsDir.path) {
                    guard Self.confirm(title: "Create ~/Applications?",
                                       message: "Transcripts installs to your personal Applications folder (the system /Applications is read-only on managed Macs). Create ~/Applications now?") else { return }
                    try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
                }

                let dest = appsDir.appendingPathComponent("Transcripts.app")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: newApp, to: dest)
                Log.write("update: installed \(release.version) → \(dest.path); relaunching")

                // Relaunch the new copy, then quit this one.
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [dest.path]
                try? open.run()
                NSApp.terminate(nil)
            } catch {
                Log.write("update: FAILED — \(error.localizedDescription)")
                Self.info(title: "Update failed", message: error.localizedDescription)
            }
        }
    }

    private static func findApp(in dir: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    @discardableResult
    private static func confirm(title: String, message: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func info(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Input device selection

    /// All selectable microphone inputs (rescanned each call — hot-plug friendly).
    func availableInputs() -> [AudioInputDevice] {
        let devices = AudioInputDevices.all()
        cacheFavoriteInputNames(from: devices)
        return devices
    }

    /// Favorites in the user's priority order, including unplugged devices using
    /// their last-seen names so Settings can still show and reorder them.
    func favoriteInputs(connectedDevices: [AudioInputDevice]? = nil) -> [FavoriteInputChoice] {
        let devices = connectedDevices ?? availableInputs()
        let devicesByUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        return config.favoriteInputUIDs.map { uid in
            let device = devicesByUID[uid]
            let name = device?.name
                ?? config.favoriteInputNamesByUID[uid]
                ?? AudioInputDevices.rememberedName(forUID: uid)
                ?? "Favorite microphone"
            return FavoriteInputChoice(uid: uid, name: name, device: device)
        }
    }

    /// The device that recording will actually use right now (override if connected,
    /// else the top connected favorite, else the smart default).
    var resolvedInput: AudioInputDevice? {
        AudioInputDevices.resolve(favorites: config.favoriteInputUIDs, override: config.overrideInputUID)
    }

    func isFavoriteInput(_ uid: String) -> Bool { config.favoriteInputUIDs.contains(uid) }

    /// Explicitly force a device (beats favorites); pass nil to clear and follow favorites.
    func setInputOverride(_ uid: String?) {
        config.overrideInputUID = uid
        Log.write("input override = \(uid ?? "(cleared — using favorites)")")
    }
    var hasInputOverride: Bool { config.overrideInputUID != nil }

    func toggleFavoriteInput(_ uid: String) {
        if let i = config.favoriteInputUIDs.firstIndex(of: uid) {
            config.favoriteInputUIDs.remove(at: i)
            config.favoriteInputNamesByUID.removeValue(forKey: uid)
        } else {
            config.favoriteInputUIDs.append(uid)
            if let device = AudioInputDevices.all().first(where: { $0.uid == uid }) {
                config.favoriteInputNamesByUID[uid] = device.name
            }
        }
    }

    func moveFavoriteInputs(from offsets: IndexSet, to destination: Int) {
        config.favoriteInputUIDs.move(fromOffsets: offsets, toOffset: destination)
    }

    func moveFavoriteInput(uid: String, by delta: Int) {
        guard let index = config.favoriteInputUIDs.firstIndex(of: uid) else { return }
        let destination = index + delta
        guard destination >= 0, destination < config.favoriteInputUIDs.count else { return }
        let moved = config.favoriteInputUIDs.remove(at: index)
        config.favoriteInputUIDs.insert(moved, at: destination)
    }

    /// One-time migration of the old docked/undocked single prefs into favorites.
    /// Skips the built-in mic (it's the automatic fallback, not a favorite).
    /// The running multi-recording session, if any. See `SessionManager`.
    let sessions: SessionManager

    /// Runs a finished session's `onComplete`, with its files substituted in.
    ///
    /// Failures are logged and swallowed on purpose: the session is over and its
    /// recordings are already filed, so a broken publish script must not put the
    /// app into an error state hours after the fact. The log is where you look.
    private func runSessionCompletion(_ session: ActiveSession, _ profile: SessionProfile) async {
        guard let command = profile.onComplete else { return }
        let recs = session.recordingIDs.compactMap { id in history.record(id) }
        let transcripts = recs.compactMap(\.documentURL)
        let audio = recs.compactMap(\.audioURL)
        let vars = SessionVariables.variables(
            session: session, profile: profile,
            sessionDirectory: nil, transcripts: transcripts, audio: audio)
        let resolved = TemplateEngine.resolve(command, with: vars)
        Log.write("session: running onComplete for '\(profile.id)' over \(recs.count) recording(s)")
        do {
            let result = try await ProcessCommandRunner().run(resolved, stdin: nil)
            if result.exitCode != 0 {
                Log.write("session: onComplete exited \(result.exitCode): \(result.stderrString.prefix(400))")
            } else {
                Log.write("session: onComplete finished")
            }
        } catch {
            Log.write("session: onComplete failed — \(error)")
        }
    }

    private func migrateInputPrefs() {
        guard config.favoriteInputUIDs.isEmpty else { return }
        let devices = AudioInputDevices.all()
        var seed: [String] = []
        var names: [String: String] = [:]
        for uid in [config.dockedInputUID, config.preferredInputUID].compactMap({ $0 }) where !seed.contains(uid) {
            if let d = devices.first(where: { $0.uid == uid }), AudioInputDevices.isBuiltIn(d) { continue }
            seed.append(uid)
            if let d = devices.first(where: { $0.uid == uid }) {
                names[uid] = d.name
            }
        }
        guard !seed.isEmpty else { return }
        config.favoriteInputUIDs = seed          // didSet doesn't fire in init
        config.favoriteInputNamesByUID = names
        try? configStore.save(config)
        Log.write("migrated \(seed.count) input preference(s) to favorites")
    }

    private func cacheFavoriteInputNames(from devices: [AudioInputDevice]) {
        guard !config.favoriteInputUIDs.isEmpty else { return }
        var names = config.favoriteInputNamesByUID
        var changed = false
        for device in devices where config.favoriteInputUIDs.contains(device.uid) {
            if names[device.uid] != device.name {
                names[device.uid] = device.name
                changed = true
            }
        }
        guard changed else { return }
        config.favoriteInputNamesByUID = names
    }

    private func backfillFavoriteInputNames() {
        guard !config.favoriteInputUIDs.isEmpty else { return }

        let devicesByUID = Dictionary(uniqueKeysWithValues: AudioInputDevices.all().map { ($0.uid, $0.name) })
        var names = config.favoriteInputNamesByUID
        var changed = false

        for uid in config.favoriteInputUIDs {
            if let liveName = devicesByUID[uid], names[uid] != liveName {
                names[uid] = liveName
                changed = true
                continue
            }
            if names[uid] == nil, let remembered = AudioInputDevices.rememberedName(forUID: uid) {
                names[uid] = remembered
                changed = true
            }
        }

        guard changed else { return }
        config.favoriteInputNamesByUID = names
        try? configStore.save(config)
    }

    // MARK: - Window opening (AppKit-hosted)

    /// Set by `StatusBarController` to open the AppKit-hosted Recordings window and
    /// the SwiftUI Settings scene from the popover — `openWindow`/`SettingsLink`
    /// aren't wired inside an `NSPopover`, so the popover asks the controller instead.
    var onOpenRecordings: ((UUID?) -> Void)?
    var onOpenSettings: (() -> Void)?

    func openRecordings(_ id: UUID?) { selectedRecordID = id; onOpenRecordings?(id) }
    func openSettings() { onOpenSettings?() }

    /// Primary action when a recents row is clicked: open in the configured external
    /// app when one is set and there's a document, else open the in-app browser.
    func openRecent(_ item: RecentItem) {
        if item.path != nil, canOpenExternally { openExternally(item.id) }
        else { openRecordings(item.id) }
    }

    // MARK: - UI helpers

    var statusSymbol: String {
        switch state {
        case .idle: return "mic.slash"
        case .armed: return "mic"
        case .recording: return "waveform"
        case .processing: return "gearshape.2"
        }
    }

    /// The menu-bar icon for the current style + state: outline when off, solid white
    /// while watching, colored while recording.
    var menuBarImage: NSImage {
        let iconState: MenuBarIconRenderer.IconState
        switch state {
        case .idle: iconState = .idle
        case .armed, .processing: iconState = .armed
        case .recording: iconState = .recording
        }
        return MenuBarIconRenderer.image(style: config.menuBarIcon, state: iconState,
                                         tint: .fromHex(config.recordingColorHex))
    }

    /// While recording, the waveform brightens with the live input level — proof
    /// audio is actually flowing, which a static icon cannot give you. The
    /// microphone style keeps its fixed recording icon.
    func recordingIcon() -> NSImage {
        let tint = NSColor.fromHex(config.recordingColorHex)
        switch config.menuBarIcon {
        case .transport: return MenuBarIconRenderer.transportPulse(level: inputLevel, tint: tint)
        case .waveform: return MenuBarIconRenderer.levelPulse(level: inputLevel, tint: tint)
        case .mark: return MenuBarIconRenderer.markPulse(level: inputLevel, tint: tint)
        case .microphone:
            return MenuBarIconRenderer.image(style: .microphone, state: .recording, tint: tint)
        }
    }

    /// The recording-indicator color as a SwiftUI `Color`, for the popover marks.
    var recordingColor: Color { MenuBarIconRenderer.recordingColor(hex: config.recordingColorHex) }

    /// True only while audio is actively being captured — drives the animated
    /// waveform in the menu bar so the icon genuinely reflects live recording.
    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = state { return true }
        return false
    }
}
