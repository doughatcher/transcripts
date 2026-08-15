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
/// Deliberately no "record now" intent. Starting a session is a statement about
/// the evening, not about the microphone; capture still begins when a call is
/// detected or when you press record, so an automation that fires while you are
/// still parking the car does not produce an hour of car-door noise.

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

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AppController.shared.sessions.start(profileID: session.id) else {
            throw $session.needsValueError("That session isn't in routing.json any more.")
        }
        return .result(dialog: "Started \(session.name).")
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
