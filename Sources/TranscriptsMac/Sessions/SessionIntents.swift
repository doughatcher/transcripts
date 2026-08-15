import AppIntents
import Foundation
import TranscriptsCore

/// Shortcuts actions for starting and ending a session.
///
/// App Intents rather than a URL scheme: these appear in Shortcuts natively,
/// compose with other actions, and are reachable from the command line via
/// `shortcuts run` — which is what makes a Monday-evening `launchd` job or a
/// calendar automation possible without the app inventing its own scheduler.
///
/// Starting a session begins recording by default. The earlier design left that
/// to call detection, on the reasoning that a time-of-day automation can fire
/// while you are still parking the car — but that only holds for time alone. A
/// trigger that combines *arriving somewhere* with *the right evening* fires
/// when you are already at the table, and the real failure mode is forgetting to
/// press record at all. The toggle remains, for triggers that are only a clock.

/// A session profile from `routing.json`, offered as a Shortcuts picker.
struct SessionProfileEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Session" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = SessionProfileQuery()
}

struct SessionProfileQuery: EntityQuery {
    /// Read from disk rather than from the running controller: Shortcuts may
    /// query while the app is not launched, and a picker that is empty until
    /// you open the app would be its own bug report.
    private func profiles() -> [SessionProfile] {
        let cfg = (try? ConfigStore().load()) ?? .default
        return RoutingStore(knowledgeRoot: cfg.destinations.resolvedRoot).loadOrSeed().sessions
    }

    func entities(for identifiers: [String]) async throws -> [SessionProfileEntity] {
        profiles().filter { identifiers.contains($0.id) }
            .map { SessionProfileEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [SessionProfileEntity] {
        profiles().map { SessionProfileEntity(id: $0.id, name: $0.name) }
    }
}

struct StartSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Session"
    static var description = IntentDescription(
        "Begins a named session. Recordings made from now on are grouped together, and the session's completion action runs once when it ends.")
    /// The app must be running to hold the session: it owns the clock and the
    /// capture that follows.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session")
    var session: SessionProfileEntity

    /// Names this occasion rather than its kind — "Session 42, The Sunken Keep".
    /// Flows into the completion command as `${sessionLabel}`, and shapes
    /// `${slug}`, so a journal folder can be named after the night itself.
    @Parameter(title: "Label", description: "Optional name for this particular session.")
    var label: String?

    @Parameter(title: "Start recording", default: true)
    var startRecording: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = AppController.shared
        guard controller.sessions.start(profileID: session.id, label: label) else {
            throw $session.needsValueError("That session isn't in routing.json any more.")
        }
        var said = "Started \(label?.isEmpty == false ? label! : session.name)."
        if startRecording {
            // Not while something is already being captured: an automation that
            // double-fires, or one that lands on a call already in progress,
            // must not interrupt a recording to start an identical one.
            switch controller.state {
            case .recording, .processing:
                said += " Already recording."
            default:
                controller.startRecording()
                said += " Recording."
            }
        }
        return .result(dialog: "\(said)")
    }
}

struct EndSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "End Session"
    static var description = IntentDescription(
        "Ends the running session and runs its completion action. Sessions also end on their own after a long enough quiet spell, or at their configured stop time.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = AppController.shared.sessions.profile?.name
        guard AppController.shared.sessions.active?.isRunning == true else {
            return .result(dialog: "No session is running.")
        }
        // Stop first: a session that ends mid-take would complete without its
        // final recording, which is exactly the one you were still making.
        if case .recording = AppController.shared.state {
            AppController.shared.stopRecordingAndProcess()
        }
        AppController.shared.sessions.end(reason: .explicit)
        return .result(dialog: "Ended \(name ?? "the session").")
    }
}

struct TranscriptsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: ["Start a \(.applicationName) session", "Begin \(.applicationName) session"],
            shortTitle: "Start Session",
            systemImageName: "record.circle")
        AppShortcut(
            intent: EndSessionIntent(),
            phrases: ["End my \(.applicationName) session", "Finish \(.applicationName) session"],
            shortTitle: "End Session",
            systemImageName: "stop.circle")
    }
}
