import Foundation
import Testing
@testable import TranscriptsCore

/// The "done-done" rules. These exist because the failure mode is expensive and
/// slow to notice: a session that ends early splits one evening in two and fires
/// the completion action on half a game, and you find out on Tuesday.
@Suite struct SessionLifecycleTests {
    /// A fixed Monday 18:00 so nothing here depends on when the suite runs.
    let cal = Calendar(identifier: .gregorian)
    var start: Date {
        DateComponents(calendar: cal, year: 2026, month: 8, day: 17, hour: 18).date!
    }
    func profile(idle: TimeInterval = 3600, stop: String? = nil) -> SessionProfile {
        SessionProfile(id: "dnd", name: "D&D", idleTimeout: idle, hardStop: stop)
    }
    func session(startedAt: Date, lastActivity: Date? = nil) -> ActiveSession {
        ActiveSession(profileID: "dnd", startedAt: startedAt, lastActivityAt: lastActivity)
    }

    @Test func keepsRunningWhileActive() {
        let s = session(startedAt: start, lastActivity: start.addingTimeInterval(3000))
        let now = start.addingTimeInterval(3300)   // 5 min since last activity
        #expect(SessionLifecycle.endReason(for: s, profile: profile(), now: now, calendar: cal) == nil)
    }

    /// The case that motivates a generous default: a long dinner break must not
    /// look like the end of the evening.
    @Test func aLongBreakIsNotTheEnd() {
        let s = session(startedAt: start, lastActivity: start.addingTimeInterval(3600))
        let now = start.addingTimeInterval(3600 + 45 * 60)   // 45 minutes idle
        #expect(SessionLifecycle.endReason(for: s, profile: profile(idle: 3600),
                                           now: now, calendar: cal) == nil)
    }

    @Test func endsWhenIdleLongEnough() {
        let s = session(startedAt: start, lastActivity: start.addingTimeInterval(3600))
        let now = start.addingTimeInterval(3600 + 3601)
        #expect(SessionLifecycle.endReason(for: s, profile: profile(idle: 3600),
                                           now: now, calendar: cal) == .idle)
    }

    @Test func zeroTimeoutDisablesTheIdleClock() {
        let s = session(startedAt: start, lastActivity: start)
        let now = start.addingTimeInterval(86_400)
        #expect(SessionLifecycle.endReason(for: s, profile: profile(idle: 0),
                                           now: now, calendar: cal) == nil)
    }

    /// The backstop wins over the idle clock: past the stop time the session is
    /// over whether or not someone is still recording.
    @Test func hardStopBeatsRecentActivity() {
        let s = session(startedAt: start, lastActivity: start.addingTimeInterval(5 * 3600))
        let now = DateComponents(calendar: cal, year: 2026, month: 8, day: 17, hour: 23, minute: 31).date!
        #expect(SessionLifecycle.endReason(for: s, profile: profile(stop: "23:30"),
                                           now: now, calendar: cal) == .hardStop)
    }

    @Test func hardStopIsTonightForAnEveningSession() {
        let stop = SessionLifecycle.hardStopDate(for: profile(stop: "23:30"),
                                                 startedAt: start, calendar: cal)
        let expected = DateComponents(calendar: cal, year: 2026, month: 8, day: 17,
                                      hour: 23, minute: 30).date!
        #expect(stop == expected)
    }

    /// A session starting at 22:00 with a 01:00 stop must end in the small hours
    /// of the next day — not three hours before it began.
    @Test func hardStopRollsPastMidnight() {
        let late = DateComponents(calendar: cal, year: 2026, month: 8, day: 17, hour: 22).date!
        let stop = SessionLifecycle.hardStopDate(for: profile(stop: "01:00"),
                                                 startedAt: late, calendar: cal)
        let expected = DateComponents(calendar: cal, year: 2026, month: 8, day: 18, hour: 1).date!
        #expect(stop == expected)
    }

    /// A typo in the time costs you the backstop, not the session.
    @Test func malformedHardStopIsIgnored() {
        #expect(profile(stop: "half past eleven").hardStopComponents == nil)
        #expect(profile(stop: "25:00").hardStopComponents == nil)
        #expect(profile(stop: "23:70").hardStopComponents == nil)
        let s = session(startedAt: start, lastActivity: start)
        #expect(SessionLifecycle.endReason(for: s, profile: profile(idle: 0, stop: "nope"),
                                           now: start.addingTimeInterval(86_400),
                                           calendar: cal) == nil)
    }

    @Test func anEndedSessionNeverEndsAgain() {
        var s = session(startedAt: start, lastActivity: start)
        s.endedAt = start.addingTimeInterval(100)
        s.endReason = .explicit
        #expect(SessionLifecycle.endReason(for: s, profile: profile(idle: 1),
                                           now: start.addingTimeInterval(9999),
                                           calendar: cal) == nil)
    }

    /// Ended-but-unfired is the state a relaunch has to recognise, and it must
    /// be distinguishable from already-fired — otherwise a crash between the two
    /// either double-publishes the evening or drops it.
    @Test func completionIsTrackedSeparatelyFromEnding() {
        var s = session(startedAt: start)
        #expect(s.isRunning)
        #expect(!s.needsCompletion)

        s.endedAt = start.addingTimeInterval(3600)
        #expect(!s.isRunning)
        #expect(s.needsCompletion)

        s.completedAt = start.addingTimeInterval(3610)
        #expect(!s.needsCompletion)
    }
}

@Suite struct SessionPersistenceTests {
    /// A session outlives the app: the whole point is surviving a crash, a
    /// sleep, or a new build installed mid-evening.
    @Test func roundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)

        #expect(store.load() == nil)

        var s = ActiveSession(profileID: "dnd", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        s.recordingIDs = [UUID(), UUID()]
        s.endedAt = Date(timeIntervalSince1970: 1_800_010_000)
        s.endReason = .idle
        try store.save(s)

        let back = store.load()
        #expect(back == s)
        #expect(back?.needsCompletion == true)

        store.clear()
        #expect(store.load() == nil)
    }
}

@Suite struct SessionConfigTests {
    /// `sessions` is additive: an existing routing.json with no such key must
    /// still load, or adding this feature would break everyone's routing.
    @Test func routingWithoutSessionsStillDecodes() throws {
        let json = #"""
        {"mode":"automatic","fallback":"transcripts/","confidenceThreshold":0.55,
         "destinations":[{"path":"Cases/Contoso/transcripts/","keywords":["contoso"]}]}
        """#
        let cfg = try JSONDecoder().decode(RoutingConfig.self, from: Data(json.utf8))
        #expect(cfg.sessions.isEmpty)
        #expect(cfg.destinations.count == 1)
    }

    @Test func decodesASessionProfile() throws {
        let json = #"""
        {"mode":"automatic","fallback":"transcripts/","confidenceThreshold":0.55,
         "destinations":[],
         "sessions":[{"id":"dnd","name":"Curse of the Sunfall",
                      "destination":"Campaigns/CotSF/transcripts/",
                      "idleTimeout":5400,"hardStop":"23:30",
                      "onComplete":{"executable":"/bin/bash","arguments":["-c","publish ${slug}"]}}]}
        """#
        let cfg = try JSONDecoder().decode(RoutingConfig.self, from: Data(json.utf8))
        let p = try #require(cfg.sessions.first)
        #expect(p.id == "dnd")
        #expect(p.idleTimeout == 5400)
        #expect(p.hardStopComponents?.hour == 23)
        #expect(p.onComplete?.arguments.last == "-c publish ${slug}" || p.onComplete?.arguments.count == 2)
    }

    /// A profile with only an id should load — everything else has a default,
    /// so a minimal hand-written entry works.
    @Test func minimalProfileUsesDefaults() throws {
        let p = try JSONDecoder().decode(SessionProfile.self, from: Data(#"{"id":"dnd"}"#.utf8))
        #expect(p.name == "dnd")          // falls back to the id
        #expect(p.idleTimeout == 3600)
        #expect(p.hardStop == nil)
    }

    @Test func variablesCoverWhatAScriptNeeds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var s = ActiveSession(profileID: "dnd", startedAt: start)
        s.recordingIDs = [UUID(), UUID(), UUID()]
        s.endedAt = start.addingTimeInterval(3600)
        s.endReason = .idle
        let v = SessionVariables.variables(
            session: s,
            profile: SessionProfile(id: "dnd", name: "D&D"),
            sessionDirectory: URL(fileURLWithPath: "/tmp/s"),
            transcripts: [URL(fileURLWithPath: "/tmp/a.md"), URL(fileURLWithPath: "/tmp/b.md")],
            audio: [URL(fileURLWithPath: "/tmp/a.m4a")])
        #expect(v["sessionID"] == "dnd")
        #expect(v["recordingCount"] == "3")
        #expect(v["endReason"] == "idle")
        #expect(v["sessionDir"] == "/tmp/s")
        #expect(v["transcripts"] == "/tmp/a.md\n/tmp/b.md")
        #expect(v["slug"]?.hasSuffix("-dnd") == true)
    }
}
