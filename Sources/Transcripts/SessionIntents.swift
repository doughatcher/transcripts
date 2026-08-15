import AppIntents
import Foundation

/// Shortcuts actions on iPhone and iPad.
///
/// This is the device that is actually at the table, so this is where the
/// automation belongs: an iOS personal automation can combine *arriving
/// somewhere* with *the right evening*, which macOS cannot, and which is exactly
/// the trigger that makes recording a weekly game reliable.
///
/// The actions mirror the Mac's, but the work behind them does not. iOS suspends
/// the app between takes and has no shell, so nothing here runs a clock or a
/// completion script. It records, and stamps each capture with the session it
/// belongs to; whichever Mac picks those up does the grouping and the publishing
/// whenever it next wakes.

struct MobileSessionEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Session" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = MobileSessionQuery()
}

struct MobileSessionQuery: EntityQuery {
    /// Read from the shared folder's `routing.json` — the same file the Mac
    /// writes — so sessions are configured once and both devices agree.
    @MainActor
    private func profiles() -> [SessionProfile] {
        SessionState.profiles(in: Destination())
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MobileSessionEntity] {
        profiles().filter { identifiers.contains($0.id) }
            .map { MobileSessionEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MobileSessionEntity] {
        profiles().map { MobileSessionEntity(id: $0.id, name: $0.name) }
    }
}

struct StartMobileSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Session"
    static var description = IntentDescription(
        "Begins a session and starts recording. Recordings made during it are tagged, so a Mac watching the same folder can group them and run the session's completion action.")
    /// Capture needs the app foregrounded to take the microphone.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session")
    var session: MobileSessionEntity

    /// Names this occasion rather than its kind — "Session 42, The Sunken Keep".
    @Parameter(title: "Label", description: "Optional name for this particular session.")
    var label: String?

    @Parameter(title: "Start recording", default: true)
    var startRecording: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = RecorderModel.shared
        model.session.start(id: session.id, label: label)

        var said = "Started \(label?.isEmpty == false ? label! : session.name)."
        if startRecording {
            // A re-fired automation must not interrupt a take to start an
            // identical one.
            if model.isRecording {
                said += " Already recording."
            } else {
                model.toggle()
                said += " Recording."
            }
        }
        return .result(dialog: "\(said)")
    }
}

struct EndMobileSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "End Session"
    static var description = IntentDescription(
        "Stops recording and ends the session on this device.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = RecorderModel.shared
        guard model.session.isRunning else {
            return .result(dialog: "No session is running.")
        }
        let name = model.session.label ?? model.session.id ?? "the session"
        // Stop first, or the final take is never exported into the session it
        // belongs to — and that is the one you were still making.
        if model.isRecording { model.toggle() }
        model.session.end()
        return .result(dialog: "Ended \(name).")
    }
}

struct TranscriptsMobileShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartMobileSessionIntent(),
            phrases: ["Start a \(.applicationName) session", "Begin \(.applicationName) session"],
            shortTitle: "Start Session",
            systemImageName: "record.circle")
        AppShortcut(
            intent: EndMobileSessionIntent(),
            phrases: ["End my \(.applicationName) session", "Finish \(.applicationName) session"],
            shortTitle: "End Session",
            systemImageName: "stop.circle")
    }
}
