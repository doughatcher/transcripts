import Testing
import Foundation
@testable import TranscriptsCore

// Migrated from XCTest to swift-testing so the suite runs under the
// CommandLineTools toolchain (which ships `Testing` but not `XCTest`).

@Suite struct HexColorTests {

    @Test func parsesSixDigitHexWithOrWithoutHash() {
        let a = HexColor.components("#159BD7")
        let b = HexColor.components("159BD7")
        #expect(a?.r == b?.r && a?.g == b?.g && a?.b == b?.b)
        // #159BD7 → (21, 155, 215)
        #expect(abs((a?.r ?? 0) - 21.0/255) < 1e-9)
        #expect(abs((a?.g ?? 0) - 155.0/255) < 1e-9)
        #expect(abs((a?.b ?? 0) - 215.0/255) < 1e-9)
    }

    @Test func rejectsMalformedHex() {
        #expect(HexColor.components("nope") == nil)
        #expect(HexColor.components("#12345") == nil)   // 5 digits
        #expect(HexColor.components("#1234567") == nil) // 7 digits
        #expect(HexColor.components("#GGGGGG") == nil)  // non-hex
    }

    @Test func normalizeFallsBackToRedOnGarbage() {
        #expect(HexColor.normalize("garbage") == HexColor.recordingRed)
        #expect(HexColor.normalize("#159bd7") == "#159BD7")  // canonical uppercase
    }

    @Test func stringRoundTripsComponents() {
        let c = HexColor.components("#FF453B")!
        #expect(HexColor.string(r: c.r, g: c.g, b: c.b) == "#FF453B")
    }

    @Test func recordingColorDefaultsToMachineDefaultAndDecodesTolerantly() throws {
        // A config JSON with no recordingColorHex key keeps whatever this machine's
        // default is — the neutral red. Asserted
        // against the same computed default rather than a literal so the suite
        // passes on CI and on a corporate laptop alike.
        let json = #"{"pipeline":null}"#.data(using: .utf8)!
        let cfg = try? JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg?.recordingColorHex == AppConfig.defaultRecordingColorHex)
    }

    @Test func normalizeHonorsAnExplicitFallback() {
        #expect(HexColor.normalize("garbage", fallback: HexColor.recordingRed) == HexColor.recordingRed)
        // A parseable value ignores the fallback entirely.
        #expect(HexColor.normalize("#159bd7", fallback: HexColor.recordingRed) == "#159BD7")
    }
}

@Suite struct DefaultsTests {
    /// A fresh install starts neutral. The ancestor of this code sniffed MDM
    /// enrollment to decide whether to show an agency's mark by default; that is
    /// gone, and the defaults must not quietly grow a house style again.
    @Test func defaultsAreNeutral() {
        // Transport symbols: a square, a record light, a disc. Nobody's branding
        // — which is the property this test exists to hold. The Transcripts mark
        // remains available, it is just not imposed.
        #expect(AppConfig.defaultMenuBarIcon == .transport)
        #expect(AppConfig.defaultRecordingColorHex == HexColor.recordingRed)
    }

    /// A saved config predates every field added after it. Decoding must keep
    /// the roots the user chose: `AppConfig`'s fallback for an unparseable
    /// `destinations` is a *fresh* one, so a throwing decode here would silently
    /// move where every future recording is filed.
    @Test func destinationsSurviveFieldsAddedLater() throws {
        let json = #"""
        {"destinations":{"knowledgeRoot":"~/Vaults/Mine","deviceInbox":"~/iCloud/Transcripts"}}
        """#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.destinations.knowledgeRoot == "~/Vaults/Mine")
        #expect(cfg.destinations.deviceInbox == "~/iCloud/Transcripts")
        // Absent means "not looked yet", so first launch may still detect one.
        #expect(cfg.destinations.vaultMirror == nil)
        #expect(cfg.destinations.vaultMirrorDetected == false)
    }

    /// Clearing the mirror has to stick. The detection flag is what stops the
    /// next launch from finding the vault again and turning it back on.
    @Test func clearedVaultMirrorStaysCleared() throws {
        let json = #"""
        {"destinations":{"knowledgeRoot":"~/K","vaultMirrorDetected":true}}
        """#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.destinations.vaultMirror == nil)
        #expect(cfg.destinations.vaultMirrorDetected == true)
        #expect(cfg.destinations.resolvedVaultMirror == nil)
    }

    /// Blank is off, and a tilde expands — the mirror is hand-editable JSON like
    /// the rest of the config.
    @Test func vaultMirrorResolution() {
        #expect(DestinationsConfig(vaultMirror: "   ").resolvedVaultMirror == nil)
        #expect(DestinationsConfig(vaultMirror: "~/Cloud Vault").resolvedVaultMirror?.path
                == (("~/Cloud Vault" as NSString).expandingTildeInPath))
    }

    /// A malformed default would render an invisible menu-bar icon.
    @Test func defaultColorIsParseable() {
        #expect(HexColor.components(AppConfig.defaultRecordingColorHex) != nil)
    }
}

@Suite struct SpeakerMatchTests {
    // Orthogonal-ish embeddings: each voice most similar to itself.
    let alice: [Float] = [1, 0, 0]
    let bob: [Float] = [0, 1, 0]
    let cara: [Float] = [0, 0, 1]
    var profiles: [SpeakerMatch.Profile] {
        [.init(name: "Alice", embedding: alice), .init(name: "Bob", embedding: bob),
         .init(name: "Cara", embedding: cara)]
    }

    @Test func matchesEachClusterToItsNearestProfile() {
        let out = SpeakerMatch.assign(
            clusters: ["1": alice, "2": bob], profiles: profiles, threshold: 0.6)
        let byC = Dictionary(uniqueKeysWithValues: out.map { ($0.cluster, $0.name) })
        #expect(byC["1"] == "Alice")
        #expect(byC["2"] == "Bob")
    }

    @Test func oneProfileCannotClaimTwoClusters() {
        // The Nestle failure in miniature: several clusters, all closest to the same
        // profile, must NOT all become that person. Second-best pairings lose the
        // now-taken profile and fall through to their own best free one (or nil).
        let almostAlice: [Float] = [0.9, 0.1, 0]
        let out = SpeakerMatch.assign(
            clusters: ["1": alice, "2": almostAlice], profiles: profiles, threshold: 0.6)
        let names = out.compactMap(\.name)
        #expect(names.filter { $0 == "Alice" }.count == 1)   // Alice used once, not twice
    }

    @Test func belowThresholdStaysAnonymous() {
        // A stranger (equidistant, low similarity to everyone) gets no name — the
        // whole point: keep Me/Others rather than guess.
        let stranger: [Float] = [0.58, 0.58, 0.58]
        let out = SpeakerMatch.assign(
            clusters: ["1": stranger], profiles: profiles, threshold: 0.7)
        #expect(out.first?.name == nil)
        #expect(out.first?.confidence == 0)
    }

    @Test func sevenProfilesCannotNameAFourPersonCall() {
        // Directly the shipped bug: 7 enrolled profiles, but only 3 real clusters →
        // at most 3 names, each distinct, never 7.
        let manyProfiles = (0..<7).map { i -> SpeakerMatch.Profile in
            var e = [Float](repeating: 0, count: 7); e[i] = 1
            return .init(name: "P\(i)", embedding: e)
        }
        var c0 = [Float](repeating: 0, count: 7); c0[0] = 1
        var c3 = [Float](repeating: 0, count: 7); c3[3] = 1
        var c5 = [Float](repeating: 0, count: 7); c5[5] = 1
        let out = SpeakerMatch.assign(
            clusters: ["1": c0, "2": c3, "3": c5], profiles: manyProfiles, threshold: 0.6)
        #expect(out.compactMap(\.name).count == 3)
        #expect(Set(out.compactMap(\.name)) == ["P0", "P3", "P5"])
    }

    @Test func confidenceBandsReadSensibly() {
        #expect(SpeakerMatch.band(0, threshold: 0.65) == "none")
        #expect(SpeakerMatch.band(0.9, threshold: 0.65) == "high")
        #expect(SpeakerMatch.band(0.7, threshold: 0.65) == "medium")
        #expect(SpeakerMatch.band(0.5, threshold: 0.65) == "low")
    }
}

@Suite struct TranscriptsCoreTests {

    // MARK: - StageProvider Codable (clean JSON shape)

    @Test func stageProviderEncodesAsBareString() throws {
        let enc = JSONEncoder()
        #expect(String(decoding: try enc.encode(StageProvider.native), as: UTF8.self) == "\"native\"")
        #expect(String(decoding: try enc.encode(StageProvider.disabled), as: UTF8.self) == "\"disabled\"")
    }

    @Test func stageProviderDecodesString() throws {
        let dec = JSONDecoder()
        #expect(try dec.decode(StageProvider.self, from: Data("\"native\"".utf8)) == .native)
        #expect(try dec.decode(StageProvider.self, from: Data("\"disabled\"".utf8)) == .disabled)
    }

    @Test func stageProviderRoundTripsExternalCommand() throws {
        let cmd = ExternalCommand(executable: "/bin/bash", arguments: ["-c", "echo hi"])
        let provider = StageProvider.externalCommand(cmd)
        let data = try JSONEncoder().encode(provider)
        let back = try JSONDecoder().decode(StageProvider.self, from: data)
        #expect(back == provider)
    }

    // MARK: - RoutingDecision matches the plaud-sorter JSON contract

    @Test func routingDecisionDecodesSnakeCase() throws {
        let json = """
        {"destination":"Cases/Acme/transcripts/","primary_case":"Acme","confidence":0.92,"note":"kickoff"}
        """
        let d = try JSONDecoder().decode(RoutingDecision.self, from: Data(json.utf8))
        #expect(d.destination == "Cases/Acme/transcripts/")
        #expect(d.primaryCase == "Acme")
        #expect(abs((d.confidence ?? 0) - 0.92) < 0.0001)
    }

    // MARK: - Config round-trip

    @Test func configStoreRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-test-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
        let store = ConfigStore(url: tmp)
        let original = AppConfig.default
        try store.save(original)
        let loaded = try store.load()
        #expect(loaded == original)
    }

    @Test func defaultConfigHasAllStagesNative() {
        let cfg = AppConfig.default
        #expect(cfg.pipeline.stages.count == StageID.allCases.count)
        #expect(cfg.pipeline.stages.allSatisfy { $0.provider == .native })
    }

    // MARK: - Template substitution

    @Test func templateSubstitution() {
        let vars = ["audioURL": "/tmp/a.m4a", "activeApp": "Microsoft Teams"]
        let out = TemplateEngine.substitute("file=${audioURL} app=${activeApp} x=${unknown}", with: vars)
        #expect(out == "file=/tmp/a.m4a app=Microsoft Teams x=${unknown}")
    }

    @Test func templateVariablesIncludeActiveApp() {
        let rec = Recording(
            audioURL: URL(fileURLWithPath: "/tmp/a.m4a"),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 60),
            activeApp: ActiveAppContext(appName: "Microsoft Teams", bundleID: "com.microsoft.teams2", capturedAt: Date(timeIntervalSince1970: 0))
        )
        let ctx = PipelineContext(recording: rec, scratchDir: URL(fileURLWithPath: "/tmp/scratch"))
        let vars = TemplateEngine.variables(for: ctx)
        #expect(vars["activeApp"] == "Microsoft Teams")
        #expect(vars["activeAppBundleID"] == "com.microsoft.teams2")
        #expect(vars["durationSeconds"] == "60")
    }

    // MARK: - ExternalStageResult parsing

    @Test func externalStageResultParsesLooseStdout() {
        let stdout = "some log line\n{\"transcriptURL\":\"/tmp/out.md\",\"userInfo\":{\"engine\":\"deepgram\"}}\nbye"
        let parsed = ExternalStageResult.parse(stdout)
        #expect(parsed?.transcriptURL?.path == "/tmp/out.md")
        #expect(parsed?.userInfo?["engine"] == "deepgram")
    }

    @Test func externalStageResultReturnsNilForNoJSON() {
        #expect(ExternalStageResult.parse("just plain text, no object") == nil)
    }

    // MARK: - Recording slug (unique, timestamped, filesystem-safe)

    @Test func recordingSlugIsTimestampedAndAppTagged() {
        let rec = Recording(
            audioURL: URL(fileURLWithPath: "/tmp/a.m4a"),
            startedAt: Date(timeIntervalSince1970: 1_751_382_000), // fixed instant
            endedAt: nil,
            activeApp: ActiveAppContext(appName: "Microsoft Teams", bundleID: "com.microsoft.teams2", capturedAt: Date(timeIntervalSince1970: 0))
        )
        let slug = rec.slug
        // Date-time prefix + sanitized app tag; no spaces or path separators.
        #expect(slug.contains("microsoft-teams"))
        #expect(!slug.contains(" "))
        #expect(!slug.contains("/"))
        #expect(slug.hasPrefix("20")) // starts with the year
    }

    @Test func recordingSlugFallsBackWithoutApp() {
        let rec = Recording(audioURL: URL(fileURLWithPath: "/tmp/a.m4a"), startedAt: Date(timeIntervalSince1970: 0))
        #expect(!rec.slug.isEmpty)
        #expect(!rec.slug.contains("/"))
    }

    @Test func titledSlugUsesStampPlusTitle() {
        let rec = Recording(
            audioURL: URL(fileURLWithPath: "/tmp/a.m4a"),
            startedAt: Date(timeIntervalSince1970: 1_751_382_000),
            activeApp: ActiveAppContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", capturedAt: Date(timeIntervalSince1970: 0))
        )
        let titled = rec.slug(titled: "Strategy for Lower-Cost Discovery Option")
        #expect(titled == "\(rec.stamp)-strategy-for-lower-cost-discovery-option")
        // No title (or an unusable one) falls back to the app-tagged slug.
        #expect(rec.slug(titled: nil) == rec.slug)
        #expect(rec.slug(titled: "???") == rec.slug)
    }

    @Test func titleSlugClampsAtWordBoundary() {
        let long = "A very long meeting title that keeps going and going and definitely exceeds the filename budget"
        let slug = Recording.titleSlug(long)
        #expect(slug.count <= 60)
        #expect(!slug.hasSuffix("-"))
        // Cut lands on a word boundary — the slug is a prefix of the full sanitized
        // title and the next character in the full form is a hyphen.
        let full = Recording.sanitize(long)
        #expect(full.hasPrefix(slug))
        #expect(full[full.index(full.startIndex, offsetBy: slug.count)] == "-")
    }

    // MARK: - Speaker attribution (two-track interleave + diarization labeling)

    @Test func speakerTurnsInterleaveTwoTracksOnOneTimeline() {
        // Mic track: me at 0s and 10s. System track (started 2s late): them at 3s
        // relative — 5s absolute, landing between my two utterances.
        let mine = [
            TranscriptSegment(start: 0, end: 2, text: "Hi, can you hear me?"),
            TranscriptSegment(start: 10, end: 12, text: "Great, let's start."),
        ]
        let theirs = [TranscriptSegment(start: 3, end: 5, text: "Loud and clear.")]
        let offset = 2.0

        let labeled = mine.map { AttributedSegment(speaker: "Me", start: $0.start, text: $0.text) }
            + SpeakerTurns.assign(theirs, spans: [], fallback: "Others")
                .map { AttributedSegment(speaker: $0.speaker, start: $0.start + offset, text: $0.text) }
        let turns = SpeakerTurns.turns(labeled)

        #expect(turns.map(\.speaker) == ["Me", "Others", "Me"])
        #expect(turns[1].text == "Loud and clear.")
        #expect(SpeakerTurns.speakers(turns) == ["Me", "Others"])
        // The system track's turn is stamped on the *mic* timeline: 3s into its
        // own track, 2s of offset, so 5s into the recording.
        #expect(turns[1].start == 5)
        #expect(SpeakerTurns.markdown(turns, timed: true)
            .hasPrefix("**Me:** [0:00] Hi, can you hear me?"))
        #expect(SpeakerTurns.markdown(turns, timed: false)
            .hasPrefix("**Me:** Hi, can you hear me?"))
    }

    @Test func coalescedTurnKeepsTheFirstSegmentsStart() {
        // A speaker who talks for ninety seconds is one turn, and the useful
        // place to jump to is where they started, not where they stopped.
        let segs = [
            AttributedSegment(speaker: "Me", start: 12, text: "First."),
            AttributedSegment(speaker: "Me", start: 74, text: "Still me."),
            AttributedSegment(speaker: "Me", start: 101, text: "Done."),
        ]
        let turns = SpeakerTurns.turns(segs)
        #expect(turns.count == 1)
        #expect(turns[0].start == 12)
        #expect(SpeakerTurns.markdown(turns, timed: true)
            == "**Me:** [0:12] First. Still me. Done.")
    }

    @Test func aLongMonologueBreaksIntoParagraphsInsteadOfOneWall() {
        // Live has only two labels — "Me" and "Others" — so everything one track
        // hears is consecutive-same-speaker. Unbounded, the live file showed
        // readable turns for a few seconds and then collapsed into a single
        // growing run-on; playing a film into the room was the worst case.
        let segs = (0..<12).map {
            AttributedSegment(speaker: "Me", start: Double($0) * 5,
                              text: String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces))
        }
        let turns = SpeakerTurns.turns(segs)
        #expect(turns.count > 1)
        #expect(turns.allSatisfy { $0.text.count <= 600 })
        // Each paragraph carries the stamp of when it began, so click-to-seek
        // lands on the text being read rather than the top of the block.
        #expect(turns[0].start == 0)
        #expect(turns[1].start > turns[0].start)
        // Still one speaker — splitting a turn must never invent one.
        #expect(SpeakerTurns.speakers(turns) == ["Me"])
    }

    @Test func stampAndReadStampRoundTrip() {
        #expect(SpeakerTurns.stamp(0) == "[0:00]")
        #expect(SpeakerTurns.stamp(64) == "[1:04]")
        #expect(SpeakerTurns.stamp(3_724) == "[1:02:04]")
        #expect(SpeakerTurns.readStamp("[1:02:04] hello")?.seconds == 3_724)
        #expect(SpeakerTurns.readStamp("[1:04] hello")?.rest == "hello")
        // Prose that merely opens with a bracket is not a stamp — this is the
        // guard that keeps "[no speech detected]" and "[inaudible] ..." intact.
        #expect(SpeakerTurns.readStamp("[no speech detected]") == nil)
        #expect(SpeakerTurns.readStamp("[1:4] hello") == nil)
        #expect(SpeakerTurns.readStamp("no bracket") == nil)
    }

    @Test func readTurnLineHandlesStampedAndUnstampedTurns() {
        let stamped = SpeakerTurns.readTurnLine("**Tracy:** [12:04] Morning.")
        #expect(stamped?.speaker == "Tracy")
        #expect(stamped?.seconds == 724)
        #expect(stamped?.text == "Morning.")
        // Every transcript written before this existed. Same call, nil seconds —
        // which is why the readers need no format version to know what to do.
        let plain = SpeakerTurns.readTurnLine("**Tracy:** Morning.")
        #expect(plain?.seconds == nil)
        #expect(plain?.text == "Morning.")
        #expect(SpeakerTurns.readTurnLine("## Transcript") == nil)
    }

    /// The mitigation that protects the summaries: stamps come back out before
    /// the transcript reaches the model.
    @Test func stripStampsRemovesTurnStampsAndLeavesProseAlone() {
        let doc = """
        **Me:** [0:00] Morning.

        **Tracy:** [1:04] Hi. [not a stamp] stays.

        Plain paragraph with [brackets] in it.
        """
        let out = SpeakerTurns.stripStamps(doc)
        #expect(out.contains("**Me:** Morning."))
        #expect(out.contains("**Tracy:** Hi. [not a stamp] stays."))
        #expect(out.contains("Plain paragraph with [brackets] in it."))
        #expect(!out.contains("[0:00]"))
        #expect(!out.contains("[1:04]"))
    }

    /// The mitigation that protects speaker naming: the stamp must never come
    /// first, or `parseTurns` finds nothing and every inferred name is dropped.
    @Test func stampedTurnsStillParseForSpeakerNaming() {
        let doc = """
        **Speaker 1:** [0:00] Thanks Tracy, go ahead.

        **Speaker 2:** [0:09] Sure, happy to.
        """
        let turns = SpeakerNames.parseTurns(doc)
        #expect(turns.count == 2)
        #expect(turns[0].speaker == "Speaker 1")
        // Stripped here too, so the evidence search sees prose and not a clock.
        #expect(turns[0].text == "Thanks Tracy, go ahead.")
        #expect(SpeakerNames.validated(["Speaker 2": "Tracy"], transcript: doc) == ["Speaker 2": "Tracy"])
    }

    @Test func renameSpeakerStillWorksOnStampedTurns() {
        let doc = "**Speaker 2:** [1:04] Hello there."
        #expect(SpeakerTurns.renameSpeaker(in: doc, from: "Speaker 2", to: "Tracy")
            == "**Tracy:** [1:04] Hello there.")
    }

    @Test func speakerTurnsCoalesceConsecutiveSameSpeaker() {
        let segs = [
            AttributedSegment(speaker: "Me", start: 0, text: "First."),
            AttributedSegment(speaker: "Me", start: 2, text: "Second."),
            AttributedSegment(speaker: "Others", start: 5, text: "Reply."),
        ]
        let turns = SpeakerTurns.turns(segs)
        #expect(turns.count == 2)
        #expect(turns[0].text == "First. Second.")
    }

    @Test func assignPicksMaxOverlapSpeakerAndFallsBack() {
        let spans = [
            SpeakerSpan(speaker: "SPEAKER_00", start: 0, end: 4),
            SpeakerSpan(speaker: "SPEAKER_01", start: 4, end: 10),
        ]
        let segs = [
            TranscriptSegment(start: 1, end: 3, text: "a"),   // inside SPEAKER_00
            TranscriptSegment(start: 3, end: 8, text: "b"),   // 1s vs 4s → SPEAKER_01
            TranscriptSegment(start: 20, end: 22, text: "c"), // no overlap → fallback
        ]
        let out = SpeakerTurns.assign(segs, spans: spans, fallback: "Others")
        #expect(out.map(\.speaker) == ["SPEAKER_00", "SPEAKER_01", "Others"])
    }

    @Test func renumberMapsDiarizerIdsToStableLabelsByFirstAppearance() {
        let spans = [
            SpeakerSpan(speaker: "SPEAKER_07", start: 5, end: 8),
            SpeakerSpan(speaker: "SPEAKER_02", start: 0, end: 4),
            SpeakerSpan(speaker: "SPEAKER_07", start: 9, end: 12),
        ]
        let out = SpeakerTurns.renumber(spans)
        // SPEAKER_02 speaks first → Speaker 1; SPEAKER_07 → Speaker 2 (both spans).
        #expect(out.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 2"])
    }

    @Test func turnsDropEmptySegments() {
        let segs = [
            AttributedSegment(speaker: "Me", start: 0, text: "  "),
            AttributedSegment(speaker: "Others", start: 1, text: "hello"),
        ]
        let turns = SpeakerTurns.turns(segs)
        #expect(turns.count == 1)
        #expect(turns[0].speaker == "Others")
    }

    // MARK: - Version ordering (beta train)

    @Test func versionOrderingHandlesPrereleases() {
        // Pre-release precedes its release; beats everything below it.
        #expect(AppVersion.compare("0.8.1-beta.1", "0.8.1") < 0)
        #expect(AppVersion.compare("0.8.1-beta.1", "0.8.0") > 0)
        #expect(AppVersion.compare("v0.8.1-beta.2", "v0.8.1-beta.1") > 0)
        #expect(AppVersion.compare("0.8.1-beta.1", "0.8.1-beta.1") == 0)
        #expect(AppVersion.compare("0.9.0", "0.8.1-beta.9") > 0)
        // Plain versions still order the obvious way.
        #expect(AppVersion.compare("v0.10.0", "v0.9.9") > 0)
    }

    @Test func picksTheAssetMatchingTheVersionNotTheFirstZip() {
        // The exact bug that shipped: a release carried every past version's zip,
        // and "first zip" installed 0.4.0 — a downgrade loop. The right asset is
        // the one for THIS version, regardless of order.
        let manyZips = ["Transcripts-0.4.0.zip", "Transcripts-0.5.0.zip", "Transcripts-0.8.0.zip",
                        "Transcripts-0.8.1-beta.4.zip"]
        #expect(AppVersion.assetName(from: manyZips, version: "0.8.1-beta.4") == "Transcripts-0.8.1-beta.4.zip")
        #expect(AppVersion.assetName(from: manyZips, version: "0.8.0") == "Transcripts-0.8.0.zip")

        // A single clean release: the one zip is fine.
        #expect(AppVersion.assetName(from: ["Transcripts-0.9.0.zip"], version: "0.9.0") == "Transcripts-0.9.0.zip")

        // Rather than guess wrong: no version match among several zips → nil.
        #expect(AppVersion.assetName(from: ["Transcripts-0.4.0.zip", "Transcripts-0.5.0.zip"],
                                     version: "0.9.0") == nil)
        // Non-zip assets are ignored.
        #expect(AppVersion.assetName(from: ["notes.txt", "Transcripts-0.9.0.zip"], version: "0.9.0") == "Transcripts-0.9.0.zip")
    }

    // MARK: - Voice profiles (#6 Tier B)

    @Test func profileStoreSuggestConfirmEnrollRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.suggest(name: "Tracy", embedding: [0.5, 0.5], sourceTitle: "Standup")
        #expect(store.suggestions.count == 1)

        // Confirm → enrolled; suggestion cleared; persisted across reload.
        store.resolveSuggestion(name: "Tracy", accept: true)
        #expect(store.suggestions.isEmpty)
        let reloaded = SpeakerProfileStore(url: url)
        #expect(reloaded.profile(named: "tracy")?.embedding == [0.5, 0.5])

        // Repeat enrollment folds in as a running average (1 meeting + 1 new).
        reloaded.enroll(name: "Tracy", embedding: [1.0, 0.0])
        #expect(reloaded.profile(named: "Tracy")?.embedding == [0.75, 0.25])
        #expect(reloaded.profile(named: "Tracy")?.meetings == 2)
    }

    @Test func sampleClipPathSurvivesSuggestAndEnroll() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.suggest(name: "Tracy", embedding: [0.5], sourceTitle: "Standup",
                      sampleAudioPath: "/voices/pending/tracy.m4a")
        #expect(store.suggestion(named: "Tracy")?.sampleAudioPath == "/voices/pending/tracy.m4a")

        // Confirm relocates the clip; the enrolled profile carries the new path.
        store.confirmSuggestion(originalName: "Tracy", as: "Tracy",
                                enrolledSamplePath: "/voices/enrolled/tracy.m4a")
        let reloaded = SpeakerProfileStore(url: url)
        #expect(reloaded.profile(named: "Tracy")?.sampleAudioPath == "/voices/enrolled/tracy.m4a")
    }

    @Test func confirmUnderACorrectedNameEnrollsTheNewName() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        // Transcript guessed "Tracey"; the user fixes it to "Tracy" on confirm.
        store.suggest(name: "Tracey", embedding: [0.5], sourceTitle: "Standup")
        store.confirmSuggestion(originalName: "Tracey", as: "Tracy")
        #expect(store.profile(named: "Tracy") != nil)
        #expect(store.profile(named: "Tracey") == nil)
        // Correcting the name must NOT blacklist the original as declined.
        store.suggest(name: "Tracey", embedding: [0.5], sourceTitle: "Later call")
        #expect(store.suggestion(named: "Tracey") != nil)
    }

    @Test func removeReturnsProfileSoCallerCanCleanUpTheClip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.enroll(name: "Marc", embedding: [1], sampleAudioPath: "/voices/enrolled/marc.m4a")
        let removed = store.remove(name: "Marc")
        #expect(removed?.sampleAudioPath == "/voices/enrolled/marc.m4a")
        #expect(store.profile(named: "Marc") == nil)
        #expect(store.remove(name: "Nobody") == nil)
    }

    // MARK: - Per-sample voiceprints (#6 correctable attribution)

    @Test func voiceprintIsTheMeanOfSamplesAndSurvivesDropout() {
        // Two samples average elementwise; dropping the outlier re-derives cleanly —
        // the whole point of storing samples instead of a one-way running average.
        #expect(VoiceMath.mean([[0.5, 0.5], [1.0, 0.0]]) == [0.75, 0.25])
        #expect(VoiceMath.mean([[1, 2, 3]]) == [1, 2, 3])
        #expect(VoiceMath.mean([]) == [])
    }

    @Test func enrollAccumulatesPerMeetingSamplesAndReplacesSameMeeting() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.enroll(name: "Gaurav", embedding: [1, 0], meetingID: "m1")
        store.enroll(name: "Gaurav", embedding: [0, 1], meetingID: "m2")
        #expect(store.profile(named: "Gaurav")?.meetings == 2)
        #expect(store.profile(named: "Gaurav")?.embedding == [0.5, 0.5])

        // Re-enrolling from the SAME meeting replaces that sample, doesn't double it.
        store.enroll(name: "Gaurav", embedding: [1, 1], meetingID: "m2")
        #expect(store.profile(named: "Gaurav")?.meetings == 2)
        #expect(store.profile(named: "Gaurav")?.embedding == [1.0, 0.5])
    }

    @Test func removingAMeetingSampleReDerivesTheVoiceprint() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.enroll(name: "Gaurav", embedding: [1, 0], meetingID: "good")
        store.enroll(name: "Gaurav", embedding: [0, 1], meetingID: "wrong")   // a bad match
        #expect(store.profile(named: "Gaurav")?.embedding == [0.5, 0.5])

        // Drop the wrong meeting's contribution — voiceprint snaps back, and we get
        // the sample back to move onto the right person.
        let moved = store.removeSample(fromProfileNamed: "Gaurav", meetingID: "wrong")
        #expect(moved?.embedding == [0, 1])
        #expect(store.profile(named: "Gaurav")?.embedding == [1, 0])
        #expect(store.profile(named: "Gaurav")?.meetings == 1)
    }

    @Test func removingTheLastSampleRemovesTheProfile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.enroll(name: "Ghost", embedding: [1], meetingID: "only")
        store.removeSample(fromProfileNamed: "Ghost", meetingID: "only")
        #expect(store.profile(named: "Ghost") == nil)
    }

    @Test func removeSampleNoOpsOnAMatchOnlyMislabel() throws {
        // The transcript said "Gaurav" because a voice matched his profile, but no
        // sample was ever enrolled from that meeting — there's nothing to remove,
        // and his voiceprint must stay intact.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.enroll(name: "Gaurav", embedding: [1, 0], meetingID: "m1")
        #expect(store.removeSample(fromProfileNamed: "Gaurav", meetingID: "othercall") == nil)
        #expect(store.profile(named: "Gaurav")?.embedding == [1, 0])
    }

    @Test func legacyProfileWithoutSamplesMigratesToOneSample() throws {
        // A speakers.json written before per-sample storage: a rolled-up embedding
        // and a meetings count, no samples array. It must decode with the voiceprint
        // unchanged, as a single seeded sample.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"profiles":[{"name":"Tracy","embedding":[0.2,0.8],"meetings":4,"isSelf":false,
        "updatedAt":0,"affiliation":"Contoso Rollout"}],"suggestions":[],"declinedNames":[]}
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let store = SpeakerProfileStore(url: url)
        let p = try #require(store.profile(named: "Tracy"))
        #expect(p.embedding == [0.2, 0.8])
        #expect(p.meetings == 1)               // collapsed to one seeded sample
        #expect(p.affiliation == "Contoso Rollout")
    }

    @Test func renamingASpeakerRewritesTurnsAndFrontmatterOnly() {
        let doc = """
        ---
        title: "Estimate Review"
        speakers: ["Me", "Gaurav", "Speaker 2"]
        ---

        **Me:** Kicking off.

        **Gaurav:** Here's the number, and thanks Gaurav for the prep.

        **Speaker 2:** Sounds good.
        """
        let out = SpeakerTurns.renameSpeaker(in: doc, from: "Gaurav", to: "Raj")
        // The turn prefix flips…
        #expect(out.contains("**Raj:** Here's the number"))
        #expect(!out.contains("**Gaurav:**"))
        // …the frontmatter entry flips…
        #expect(out.contains("speakers: [\"Me\", \"Raj\", \"Speaker 2\"]"))
        // …but body prose that merely mentions the name is left alone.
        #expect(out.contains("thanks Gaurav for the prep"))
    }

    @Test func renamingIsANoOpForEqualOrEmptyNames() {
        let doc = "**Tracy:** hi"
        #expect(SpeakerTurns.renameSpeaker(in: doc, from: "Tracy", to: "Tracy") == doc)
        #expect(SpeakerTurns.renameSpeaker(in: doc, from: "Tracy", to: "  ") == doc)
    }

    @Test func affiliationPathSplitsIntoOrgAndGroup() {
        #expect(Affiliation.org(of: "Acme / Platform Project Team") == "Acme")
        #expect(Affiliation.group(of: "Acme / Platform Project Team") == "Platform Project Team")
        // A bare org has no group.
        #expect(Affiliation.org(of: "Northwind") == "Northwind")
        #expect(Affiliation.group(of: "Northwind") == nil)
        // Deeper nesting keeps everything after the org as the group.
        #expect(Affiliation.group(of: "Contoso / Rollout / Ops") == "Rollout / Ops")
    }

    @Test func orgsInDedupesByOrganization() {
        let affs = ["Acme / Platform Project Team", "Acme / Platform External",
                    "Contoso / Rollout", "Northwind"]
        // Two Acme groups collapse to one org; order is first-seen.
        #expect(Affiliation.orgs(in: affs) == ["Acme", "Contoso", "Northwind"])
    }

    @Test func affiliationDefaultsToClientForCaseCallsElseHomeOrg() {
        #expect(Affiliation.suggested(destination: "Cases/Contoso Rollout/transcripts/",
                                      homeOrg: "Acme") == "Contoso Rollout")
        #expect(Affiliation.suggested(destination: "personal/Plaud/Acme/transcripts/",
                                      homeOrg: "Acme") == "Acme")
        #expect(Affiliation.suggested(destination: "transcripts/",
                                      homeOrg: "Globex") == "Globex")
        #expect(Affiliation.suggested(destination: nil, homeOrg: "Acme") == "Acme")
    }

    @Test func suggestionCarriesMeetingIdentityForInviteLookup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let when = Date(timeIntervalSince1970: 1_784_800_000)
        let store = SpeakerProfileStore(url: url)
        let id = try #require(store.suggest(name: "", label: "Speaker 1", embedding: [1],
                                            sourceTitle: "Project Scope and Budget Review",
                                            meetingName: "TE Ballpark Review", meetingDate: when))
        // The skill needs both the calendar name and the time to find the invite —
        // and they must survive a round-trip to disk.
        let reloaded = SpeakerProfileStore(url: url)
        let s = try #require(reloaded.suggestion(id: id))
        #expect(s.meetingName == "TE Ballpark Review")
        #expect(s.meetingDate == when)
    }

    @Test func affiliationRidesThroughConfirmAndIsEditable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        let id = try #require(store.suggest(name: "", label: "Speaker 2", embedding: [1],
                                            sourceTitle: "Standup", affiliation: "Contoso Rollout"))
        // User keeps the prefilled affiliation on confirm.
        store.confirmSuggestion(id: id, as: "Robert")
        #expect(store.profile(named: "Robert")?.affiliation == "Contoso Rollout")

        // …and can correct it later; empty clears it.
        store.setAffiliation(name: "Robert", to: "Contoso HQ")
        #expect(store.profile(named: "Robert")?.affiliation == "Contoso HQ")
        store.setAffiliation(name: "Robert", to: "")
        #expect(store.profile(named: "Robert")?.affiliation == nil)
    }

    @Test func confirmCanOverrideThePrefilledAffiliation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        // Prefilled with the client, but this speaker was actually a colleague.
        let id = try #require(store.suggest(name: "Dana", embedding: [1], sourceTitle: "Call",
                                            affiliation: "Contoso Rollout"))
        store.confirmSuggestion(id: id, as: "Dana", affiliation: "Acme")
        #expect(store.profile(named: "Dana")?.affiliation == "Acme")
    }

    @Test func unnamedVoicesAreQueuedAndNamedById() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        // A voice we heard but couldn't name — empty name, still queued.
        let id = store.suggest(name: "", label: "Speaker 2", embedding: [0.1, 0.9],
                               sourceTitle: "Standup")
        let sid = try #require(id)
        #expect(store.suggestions.count == 1)
        #expect(store.suggestion(id: sid)?.isNamed == false)

        // The user listens and types the name → enrolled under it.
        store.confirmSuggestion(id: sid, as: "Priya")
        #expect(store.suggestions.isEmpty)
        #expect(store.profile(named: "Priya")?.embedding == [0.1, 0.9])
    }

    @Test func unnamedVoicesAreNotDedupedTheWayNamesAre() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        // Two different unknown voices from one call both get cards…
        store.suggest(name: "", label: "Speaker 1", embedding: [1], sourceTitle: "Call")
        store.suggest(name: "", label: "Speaker 2", embedding: [2], sourceTitle: "Call")
        #expect(store.suggestions.count == 2)
        // …while a named guess still dedupes.
        store.suggest(name: "Marc", embedding: [3], sourceTitle: "Call")
        store.suggest(name: "Marc", embedding: [3], sourceTitle: "Call")
        #expect(store.suggestions.filter { $0.name == "Marc" }.count == 1)
    }

    @Test func decliningAnUnnamedVoiceDoesNotBlacklistOtherStrangers() throws {
        // Ignoring one voice must not affect an unrelated one that happens to
        // reuse the same diarizer label in a later meeting.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        let id = try #require(store.suggest(name: "", label: "Speaker 2",
                                            embedding: [1, 0], sourceTitle: "Call"))
        store.declineSuggestion(id: id)
        #expect(store.suggestions.isEmpty)
        // A genuinely different voice, same label, unaffected.
        store.suggest(name: "", label: "Speaker 2", embedding: [0, 1], sourceTitle: "Later")
        #expect(store.suggestions.count == 1)
    }

    @Test func pendingListIsCappedEvictingUnnamedFirst() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.suggest(name: "Keeper", embedding: [0], sourceTitle: "Call")   // named, must survive
        for i in 0..<(SpeakerProfileStore.maxPendingSuggestions + 5) {
            store.suggest(name: "", label: "Speaker \(i)", embedding: [Float(i)], sourceTitle: "Call")
        }
        #expect(store.suggestions.count == SpeakerProfileStore.maxPendingSuggestions)
        // The named guess was never evicted — anonymous ones dropped first.
        #expect(store.suggestions.contains { $0.name == "Keeper" })
    }

    @Test func declinedSuggestionsAreNotReAsked() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        store.suggest(name: "Marc", embedding: [1], sourceTitle: "Call")
        store.resolveSuggestion(name: "Marc", accept: false)
        store.suggest(name: "Marc", embedding: [1], sourceTitle: "Another call")
        #expect(store.suggestions.isEmpty)   // declined once, never re-nagged
        // …until an explicit enrollment clears the decline.
        store.enroll(name: "Marc", embedding: [1])
        #expect(store.profile(named: "Marc") != nil)
    }

    @Test func decliningAnUnnamedVoiceStopsItResurfacing() throws {
        // "Ignore" must mean ignore: the same stranger showing up in a later
        // meeting (a fresh cluster label, no name) must not become a new pending
        // card just because nothing was there to blacklist by name.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-speakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SpeakerProfileStore(url: url)
        let voice: [Float] = [1, 0, 0]
        let id = try #require(store.suggest(name: "", label: "Speaker 1",
                                            embedding: voice, sourceTitle: "Call A"))
        store.declineSuggestion(id: id)
        #expect(store.suggestions.isEmpty)

        // Same voice, later meeting, different label, still unnamed — suppressed.
        let again = store.suggest(name: "", label: "Speaker 3",
                                  embedding: voice, sourceTitle: "Call B")
        #expect(again == nil)
        #expect(store.suggestions.isEmpty)

        // A genuinely different voice is unaffected.
        let stranger2 = try #require(store.suggest(name: "", label: "Speaker 1",
                                                    embedding: [0, 1, 0], sourceTitle: "Call C"))
        #expect(store.suggestion(id: stranger2) != nil)
    }

    @Test func enrolledNamesSurviveRenumbering() {
        // Diarizer output mixing an enrolled profile ("Tracy"), the operator
        // ("Me" via own-voice match), and an anonymous cluster.
        let spans = [
            SpeakerSpan(speaker: "Tracy", start: 0, end: 5),
            SpeakerSpan(speaker: "Me", start: 5, end: 8),
            SpeakerSpan(speaker: "3", start: 8, end: 12),
        ]
        let out = SpeakerTurns.renumber(spans)
        #expect(out.map(\.speaker) == ["Tracy", "Me", "Speaker 1"])
        let map = SpeakerTurns.labelMap(spans)
        #expect(map == ["Tracy": "Tracy", "Me": "Me", "3": "Speaker 1"])
    }

    // MARK: - Speaker naming from transcript evidence (#6 Tier A)

    @Test func speakerMappingParsesAndRejectsNonAnswers() {
        let summary = """
        **Action Items:**
        - N/A

        **Speakers:**
        - Speaker 2: Tracy
        - Speaker 3: Karthik Subramanian
        - Speaker 4: Unknown
        - Speaker 5: probably the client's whole engineering team
        """
        let m = SpeakerNames.mapping(from: summary)
        #expect(m == ["Speaker 2": "Tracy", "Speaker 3": "Karthik Subramanian"])
    }

    @Test func speakerNamesRequireAddressEvidence() {
        // "Back to Tracy." then Tracy speaks = addressed; nobody said "Bob".
        let transcript = """
        **Speaker 1:** Back to Tracy.

        **Speaker 2:** Thank you.
        """
        let m = SpeakerNames.validated(["Speaker 2": "Tracy", "Speaker 3": "Bob"],
                                       transcript: transcript)
        #expect(m == ["Speaker 2": "Tracy"])
    }

    @Test func mentionedNamesAreNotAddressEvidence() {
        // Field data 2026-07-13: "Rick and Morty" spoken while describing a
        // feature — in a 1:1 every turn is adjacent, so occurrence alone must
        // never name the other speaker. Mid-sentence mention ≠ vocative.
        let transcript = """
        **Me:** So the feature works like it does in the show Rick and Morty you know where a Meeseeks exists to complete one task and then vanishes forever after.

        **Speaker 1:** Yeah, that makes sense to me.
        """
        #expect(SpeakerNames.validated(["Speaker 1": "Rick"], transcript: transcript).isEmpty)

        // Absent people discussed by name must not name a present speaker.
        let absent = """
        **Me:** So then I talked to Marc yesterday about the estimate and he said it would slip but honestly nobody was surprised by that at this point.

        **Speaker 1:** Right, that tracks.
        """
        #expect(SpeakerNames.validated(["Speaker 1": "Marc"], transcript: absent).isEmpty)
    }

    @Test func selfIntroductionIsAddressEvidence() {
        let transcript = """
        **Speaker 3:** Hi everyone, I'm Karthik, I'll walk through the demo prep today.

        **Me:** Great, go ahead.
        """
        let m = SpeakerNames.validated(["Speaker 3": "Karthik"], transcript: transcript)
        #expect(m == ["Speaker 3": "Karthik"])
    }

    @Test func speakerNamesRewriteTurnLabels() {
        let body = "## Transcript\n\n**Speaker 2:** Thank you.\n\n**Me:** Sure."
        let out = SpeakerNames.apply(["Speaker 2": "Tracy"], to: body)
        #expect(out.contains("**Tracy:** Thank you."))
        #expect(!out.contains("Speaker 2"))
        #expect(out.contains("**Me:** Sure."))
    }

    @Test func summarizeRenamesSpeakersEndToEnd() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let t = scratch.appendingPathComponent("t.md")
        try """
        ---
        title: "x"
        speakers: ["Me", "Speaker 2"]
        ---

        ## Transcript

        **Me:** Back to Tracy for the estimate discussion we planned.

        **Speaker 2:** Thank you, the estimate is nearly ready for review.
        """.write(to: t, atomically: true, encoding: .utf8)

        var ctx = PipelineContext(
            recording: Recording(audioURL: t, startedAt: Date(timeIntervalSince1970: 0)),
            scratchDir: scratch)
        ctx.transcriptURL = t
        let reply = """
        TITLE: Estimate Review

        **TL;DR:** Estimate nearly ready.

        **Speakers:**
        - Speaker 2: Tracy
        """
        try await SummarizeStage(model: CannedChatModel(reply: reply)).run(&ctx)

        let out = try String(contentsOf: t, encoding: .utf8)
        #expect(out.contains("**Tracy:** Thank you"))
        #expect(out.contains(#"speakers: ["Me", "Tracy"]"#))
    }

    // MARK: - Meeting name selection (field data from 2026-07-13)

    @Test func meetingNameFoundInLaterSegmentOfJoinScreen() {
        // Teams' pre-join window leads with chrome but carries the real name
        // in a later |-segment — that segment must win.
        let name = MeetingName.pick(from: [
            "Meeting join | Riley / Sam | acme.example | sam.reed@acme.example | Microsoft Teams"
        ])
        #expect(name == "Riley / Sam")
    }

    @Test func meetingNameStripsChromeGluedToTheName() {
        #expect(MeetingName.pick(from: ["Meeting join - Sprint Review | Microsoft Teams"]) == "Sprint Review")
        #expect(MeetingName.pick(from: ["Zoom Meeting — Quarterly Planning"]) == "Quarterly Planning")
    }

    @Test func meetingNamePrefersTheRealMeetingWindow() {
        let name = MeetingName.pick(from: [
            "Quarterly Planning Touchpoint | acme.example | sam.reed@acme.example | Microsoft Teams",
            "dnd (Channel) - A Slightly Lighter Scurry - Slack",
        ])
        #expect(name == "Quarterly Planning Touchpoint")
    }

    @Test func meetingNameRejectsSlackChatChrome() {
        // The exact windows that mis-titled recordings before the rules landed.
        #expect(MeetingName.pick(from: [
            "alex.rivera (DM) - Acme - Slack [Main] 🏠🔊",
            "! Jamie Lee (DM) - Acme - 1 new item - Slack",
            "adobe-commerce (Channel) - Acme - Slack",
        ]) == nil)
    }

    @Test func meetingNameRejectsScreenShareChrome() {
        // Field data 2026-07-13: Teams' share UI stole a live title mid-call.
        #expect(MeetingName.pick(from: ["Sharing control bar", "Presenter view | Microsoft Teams"]) == nil)
        #expect(MeetingName.pick(from: [
            "Sharing control bar",
            "Sam / Riley | acme.example | Microsoft Teams",
        ]) == "Sam / Riley")
    }

    @Test func meetingNameRejectsEmailsDomainsAndPureChrome() {
        #expect(MeetingName.pick(from: [
            "sam.reed@acme.example | Microsoft Teams",
            "acme.example",
            "Meeting join",
            "Chat | Microsoft Teams",
        ]) == nil)
    }

    // MARK: - Extractive fallback vs attributed transcripts

    @Test func extractiveTitleIgnoresSpeakerLabelsAndFiller() {
        // An attributed standup transcript: "Others" appears as a label on every
        // turn and the words are mostly pleasantries — neither may become the title.
        let transcript = (0..<40).map { i in
            "**\(i % 3 == 0 ? "Me" : "Others"):** Thank you all, great work on the deployment pipeline everyone."
        }.joined(separator: "\n\n")
        let out = ExtractiveChatModel.summarize(transcript)
        let title = out.components(separatedBy: "\n").first ?? ""
        #expect(!title.localizedCaseInsensitiveContains("others"))
        #expect(!title.localizedCaseInsensitiveContains("thank"))
    }

    @Test func topKeywordsExcludeFiller() {
        let freq: [String: Double] = ["thank": 1.0, "great": 0.9, "deployment": 0.8, "pipeline": 0.7]
        #expect(ExtractiveChatModel.topKeywords(freq, count: 2) == ["deployment", "pipeline"])
    }

    private struct CannedChatModel: ChatModel {
        let reply: String
        func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String { reply }
    }

    @Test func summarizePublishesTitleOnlyFromRealModels() async throws {
        func run(reply: String) async throws -> PipelineContext {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcripts-sum-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let t = scratch.appendingPathComponent("t.md")
            try "---\ntitle: \"x\"\n---\n\n## Transcript\n\nWe discussed the quarterly roadmap at length today.\n"
                .write(to: t, atomically: true, encoding: .utf8)
            var ctx = PipelineContext(
                recording: Recording(audioURL: t, startedAt: Date(timeIntervalSince1970: 0)),
                scratchDir: scratch)
            ctx.transcriptURL = t
            try await SummarizeStage(model: CannedChatModel(reply: reply)).run(&ctx)
            try? FileManager.default.removeItem(at: scratch)
            return ctx
        }

        // A real model's title is published (drives file naming + display)…
        let real = try await run(reply: "TITLE: Quarterly Roadmap Review\n\n**TL;DR:** Roadmap.\n")
        #expect(real.userInfo["summaryTitle"] == "Quarterly Roadmap Review")

        // …the extractive fallback's is not (frontmatter only).
        let extractive = try await run(reply: """
        TITLE: Quarterly roadmap discussed

        **TL;DR:** Roadmap.

        **Action Items:**
        - (extract manually — generated without a language model)
        """)
        #expect(extractive.userInfo["summaryTitle"] == nil)
    }

    // MARK: - Persist renames artifacts to the summary title

    private func makePersistFixture() throws -> (tmp: URL, scratch: URL, root: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-persist-test-\(UUID().uuidString)", isDirectory: true)
        let scratch = tmp.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return (tmp, scratch, tmp.appendingPathComponent("vault", isDirectory: true))
    }

    @Test func persistRenamesArtifactsFromSummaryTitle() async throws {
        let (tmp, scratch, root) = try makePersistFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = Recording(
            audioURL: scratch.appendingPathComponent("audio.m4a"),
            startedAt: Date(timeIntervalSince1970: 1_751_382_000),
            activeApp: ActiveAppContext(appName: "Slack", bundleID: nil, capturedAt: Date(timeIntervalSince1970: 0))
        )
        try Data([0x00]).write(to: rec.audioURL)
        let transcript = scratch.appendingPathComponent("\(rec.slug).md")
        try "---\ntitle: \"x\"\naudio_file: \(rec.slug).m4a\n---\n\n## Transcript\n\nhello\n"
            .write(to: transcript, atomically: true, encoding: .utf8)

        var ctx = PipelineContext(recording: rec, scratchDir: scratch)
        ctx.transcriptURL = transcript
        ctx.userInfo["slug"] = rec.slug
        ctx.userInfo["summaryTitle"] = "Strategy for Lower-Cost Discovery Option"

        try await PersistStage(knowledgeRoot: root).run(&ctx)

        let base = "\(rec.stamp)-strategy-for-lower-cost-discovery-option"
        let names = ctx.finalPaths.map(\.lastPathComponent).sorted()
        #expect(names == ["\(base).m4a", "\(base).md"])
        let doc = try String(contentsOf: ctx.finalPaths.first { $0.pathExtension == "md" }!, encoding: .utf8)
        #expect(doc.contains("audio_file: \(base).m4a"))
        #expect(doc.contains("## Transcript"))
        #expect(doc.contains("sorted: true"))
    }

    /// The vault gets the readable copy and none of the weight: same routed
    /// subfolder, markdown only, and a pointer to where the audio actually
    /// stayed rather than the name of a sibling that isn't beside it.
    @Test func persistMirrorsMarkdownOnlyIntoTheVault() async throws {
        let (tmp, scratch, root) = try makePersistFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Not "Vault": the fixture's knowledge root is `vault`, and on a
        // case-insensitive volume that is the same directory — which is the
        // clobber `persistRefusesToMirrorOntoTheKnowledgeRoot` covers.
        let vault = tmp.appendingPathComponent("Obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let rec = Recording(audioURL: scratch.appendingPathComponent("audio.m4a"),
                            startedAt: Date(timeIntervalSince1970: 1_751_382_000))
        try Data([0x00]).write(to: rec.audioURL)
        let transcript = scratch.appendingPathComponent("\(rec.slug).md")
        try "---\ntitle: \"x\"\naudio_file: \(rec.slug).m4a\n---\n\nbody\n"
            .write(to: transcript, atomically: true, encoding: .utf8)

        var ctx = PipelineContext(recording: rec, scratchDir: scratch)
        ctx.transcriptURL = transcript
        ctx.userInfo["slug"] = rec.slug
        ctx.routing = RoutingDecision(destination: "Clients/Acme/transcripts/", confidence: 1, note: nil)

        try await PersistStage(knowledgeRoot: root, vaultMirror: vault).run(&ctx)

        // Same routed subfolder as the real copy.
        let mirrored = vault.appendingPathComponent("Clients/Acme/transcripts/\(rec.slug).md")
        #expect(FileManager.default.fileExists(atPath: mirrored.path))
        // Markdown only — a synced vault must not fill up with recordings.
        #expect(!FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Clients/Acme/transcripts/\(rec.slug).m4a").path))

        let doc = try String(contentsOf: mirrored, encoding: .utf8)
        #expect(doc.contains("audio_path: \(root.path)/Clients/Acme/transcripts/\(rec.slug).m4a"))
        #expect(doc.contains("audio_file: \n") || doc.contains("audio_file:\n"))
        #expect(doc.contains("sorted: true"))
        // The real copy is untouched and still names its sibling.
        let filed = try String(contentsOf: ctx.finalPaths.first { $0.pathExtension == "md" }!,
                               encoding: .utf8)
        #expect(filed.contains("audio_file: \(rec.slug).m4a"))
        #expect(ctx.userInfo["vaultMirrorError"] == nil)
    }

    /// Pointing the mirror at the knowledge root would have the mirror write
    /// over the copy just filed — blanking the `audio_file` the canonical
    /// transcript needs to find its own audio. Caught first by a fixture whose
    /// root is `vault` on a case-insensitive volume, which is exactly how a user
    /// would hit it.
    @Test func persistRefusesToMirrorOntoTheKnowledgeRoot() async throws {
        let (tmp, scratch, root) = try makePersistFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = Recording(audioURL: scratch.appendingPathComponent("audio.m4a"),
                            startedAt: Date(timeIntervalSince1970: 1_751_382_000))
        try Data([0x00]).write(to: rec.audioURL)
        let transcript = scratch.appendingPathComponent("\(rec.slug).md")
        try "---\ntitle: \"x\"\naudio_file: \(rec.slug).m4a\n---\n\nbody\n"
            .write(to: transcript, atomically: true, encoding: .utf8)

        var ctx = PipelineContext(recording: rec, scratchDir: scratch)
        ctx.transcriptURL = transcript
        ctx.userInfo["slug"] = rec.slug

        // Same directory, spelled differently — the case-insensitive trap.
        let alias = root.deletingLastPathComponent().appendingPathComponent("VAULT", isDirectory: true)
        try await PersistStage(knowledgeRoot: root, vaultMirror: alias).run(&ctx)

        let filed = try String(contentsOf: ctx.finalPaths.first { $0.pathExtension == "md" }!,
                               encoding: .utf8)
        #expect(filed.contains("audio_file: \(rec.slug).m4a"))
        #expect(!filed.contains("audio_path:"))
        #expect(ctx.userInfo["vaultMirrorError"]?.contains("knowledge root") == true)
    }

    /// A vault on a sync folder that isn't mounted must not fail the run that
    /// already filed the real copy.
    @Test func persistSurvivesAnUnwritableVault() async throws {
        let (tmp, scratch, root) = try makePersistFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = Recording(audioURL: scratch.appendingPathComponent("audio.m4a"),
                            startedAt: Date(timeIntervalSince1970: 1_751_382_000))
        try Data([0x00]).write(to: rec.audioURL)
        let transcript = scratch.appendingPathComponent("\(rec.slug).md")
        try "---\ntitle: \"x\"\n---\n\nbody\n".write(to: transcript, atomically: true, encoding: .utf8)

        var ctx = PipelineContext(recording: rec, scratchDir: scratch)
        ctx.transcriptURL = transcript
        ctx.userInfo["slug"] = rec.slug

        // A file where the vault directory should be: creating anything under it fails.
        let blocked = tmp.appendingPathComponent("not-a-dir")
        try Data([0x00]).write(to: blocked)

        try await PersistStage(knowledgeRoot: root, vaultMirror: blocked).run(&ctx)

        #expect(ctx.finalPaths.contains { $0.pathExtension == "md" })
        #expect(ctx.userInfo["vaultMirrorError"] != nil)
    }

    @Test func persistKeepsOriginalNamesWithoutSummaryTitle() async throws {
        let (tmp, scratch, root) = try makePersistFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = Recording(audioURL: scratch.appendingPathComponent("audio.m4a"),
                            startedAt: Date(timeIntervalSince1970: 1_751_382_000))
        try Data([0x00]).write(to: rec.audioURL)
        let transcript = scratch.appendingPathComponent("\(rec.slug).md")
        try "---\ntitle: \"x\"\n---\n\nbody\n".write(to: transcript, atomically: true, encoding: .utf8)

        var ctx = PipelineContext(recording: rec, scratchDir: scratch)
        ctx.transcriptURL = transcript
        ctx.userInfo["slug"] = rec.slug

        try await PersistStage(knowledgeRoot: root).run(&ctx)

        let names = ctx.finalPaths.map(\.lastPathComponent).sorted()
        #expect(names == ["\(rec.slug).m4a", "\(rec.slug).md"])
    }

    // MARK: - Routing config + discovery

    @Test func routingConfigRoundTripsAndToleratesMissingKeys() throws {
        let cfg = RoutingConfig(mode: .automatic, fallback: "transcripts/", confidenceThreshold: 0.6,
                                destinations: [.init(path: "Cases/Acme/transcripts/", keywords: ["acme"])])
        let data = try JSONEncoder().encode(cfg)
        #expect(try JSONDecoder().decode(RoutingConfig.self, from: data) == cfg)
        // Missing keys fall back to defaults.
        let partial = try JSONDecoder().decode(RoutingConfig.self, from: Data("{\"fallback\":\"x/\"}".utf8))
        #expect(partial.mode == .automatic)
        #expect(partial.fallback == "x/")
        #expect(partial.confidenceThreshold == 0.55)
    }

    @Test func routingStoreDiscoversTranscriptFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Cases/Contoso Rollout/transcripts"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let found = RoutingStore.discover(in: root).map(\.path)
        #expect(found.contains("transcripts/"))
        #expect(found.contains("Cases/Contoso Rollout/transcripts/"))
        // Parent-name keywords are derived for the case.
        let contoso = RoutingStore.discover(in: root).first { $0.path.contains("Contoso") }
        #expect(contoso?.keywords.contains("contoso") == true)
    }

    struct ThrowingChatModel: ChatModel {
        func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
            throw NSError(domain: "test", code: 1)
        }
    }

    @Test func automaticRailsRouteByKeywordWithoutModel() async throws {
        let md = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).md")
        try "## Transcript\n\nWe met with the Contoso team about Rollout rollout.".write(to: md, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: md) }

        let dests = [
            RoutingConfig.Destination(path: "Cases/Contoso Rollout/transcripts/", keywords: ["contoso rollout", "contoso", "rollout"]),
            RoutingConfig.Destination(path: "Cases/Fabrikam/transcripts/", keywords: ["fabrikam"]),
        ]
        let stage = ClassifyStage(model: ThrowingChatModel(),
                                  knowledgeRoot: URL(fileURLWithPath: "/tmp"),
                                  routing: RoutingConfig(mode: .automatic),
                                  destinations: dests)
        var ctx = PipelineContext(recording: Recording(audioURL: md, startedAt: Date()),
                                  scratchDir: md.deletingLastPathComponent())
        ctx.transcriptURL = md
        try await stage.run(&ctx)
        // Rails match Contoso+Rollout (2 hits) over Fabrikam (0) — no model call needed.
        #expect(ctx.routing?.destination == "Cases/Contoso Rollout/transcripts/")
        #expect(ctx.routing?.note?.contains("rails") == true)
    }

    @Test func windowTitleRoutesEvenWhenTranscriptIsGeneric() async throws {
        let md = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).md")
        // Transcript names no client — only the meeting window title does.
        try "## Transcript\n\nQuick sync, went over the plan and next steps, nothing else.".write(to: md, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: md) }

        let dests = [
            RoutingConfig.Destination(path: "Cases/Contoso Rollout/transcripts/", keywords: ["contoso rollout", "contoso", "rollout"]),
            RoutingConfig.Destination(path: "Cases/Fabrikam/transcripts/", keywords: ["fabrikam"]),
        ]
        let stage = ClassifyStage(model: ThrowingChatModel(), knowledgeRoot: URL(fileURLWithPath: "/tmp"),
                                  routing: RoutingConfig(mode: .automatic), destinations: dests)
        var ctx = PipelineContext(
            recording: Recording(audioURL: md, startedAt: Date(),
                                 windowTitles: ["Contoso Rollout Standup | Microsoft Teams"]),
            scratchDir: md.deletingLastPathComponent())
        ctx.transcriptURL = md
        try await stage.run(&ctx)
        #expect(ctx.routing?.destination == "Cases/Contoso Rollout/transcripts/")
        #expect(ctx.routing?.note?.contains("meeting title") == true)
    }

    @Test func offModeFilesToFallback() async throws {
        let md = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).md")
        try "## Transcript\n\nAnything.".write(to: md, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: md) }
        let stage = ClassifyStage(model: ThrowingChatModel(), knowledgeRoot: URL(fileURLWithPath: "/tmp"),
                                  routing: RoutingConfig(mode: .off, fallback: "transcripts/"))
        var ctx = PipelineContext(recording: Recording(audioURL: md, startedAt: Date()), scratchDir: md.deletingLastPathComponent())
        ctx.transcriptURL = md
        try await stage.run(&ctx)
        #expect(ctx.routing?.destination == "transcripts/")
    }

    /// Demo: route sample transcripts against the real vault. Run with:
    ///   TRANSCRIPTS_DEMO=1 DEVELOPER_DIR=... swift test --filter routingDemo
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPTS_DEMO"] != nil))
    func routingDemoAgainstRealVault() async throws {
        let root = URL(fileURLWithPath: (("~/repos/knowledge") as NSString).expandingTildeInPath)
        let store = RoutingStore(knowledgeRoot: root)
        let cfg = store.loadOrSeed()
        let dests = store.effectiveDestinations(cfg)
        let stage = ClassifyStage(model: OllamaClient(config: .init()),
                                  knowledgeRoot: root, routing: cfg, destinations: dests,
                                  runner: ProcessCommandRunner())

        let samples: [(String, String)] = [
            ("Komatsu", "We reviewed the Komatsu parts catalog integration and the dealer portal timeline."),
            ("Contoso Rollout", "Standup on Contoso Rollout AEM foundational work and the ADO backlog re-estimation."),
            ("Fabrikam", "Colin walked us through the Fabrikam Shop Pay estimate and the caveats to include."),
            ("TE Connectivity", "Discovery call about TE Connectivity's commerce migration."),
            ("D&D (personal)", "We planned the next Dungeons and Dragons session and the campaign arc."),
            ("Internal tooling", "Team sync about our internal Claude Code tooling and the vault watcher."),
        ]
        print("\n=== Routing demo (\(dests.count) destinations) ===")
        for (name, text) in samples {
            let md = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).md")
            try "## Transcript\n\n\(text)".write(to: md, atomically: true, encoding: .utf8)
            var ctx = PipelineContext(recording: Recording(audioURL: md, startedAt: Date(), title: name),
                                      scratchDir: md.deletingLastPathComponent())
            ctx.transcriptURL = md
            try await stage.run(&ctx)
            let r = ctx.routing
            print(String(format: "  %-18@ → %@  (%.0f%%, %@)", name as NSString,
                         (r?.destination ?? "?") as NSString, (r?.confidence ?? 0) * 100,
                         (r?.note ?? "") as NSString))
            try? FileManager.default.removeItem(at: md)
        }
    }

    // MARK: - PipelineEngine with a fake runner

    /// Records the last command and returns canned stdout.
    final class FakeRunner: CommandRunner, @unchecked Sendable {
        var lastCommand: ExternalCommand?
        var lastStdin: Data?
        let cannedStdout: String
        let exitCode: Int32
        init(stdout: String = "", exitCode: Int32 = 0) { self.cannedStdout = stdout; self.exitCode = exitCode }
        func run(_ command: ExternalCommand, stdin: Data?) async throws -> CommandResult {
            lastCommand = command
            lastStdin = stdin
            return CommandResult(exitCode: exitCode, stdout: Data(cannedStdout.utf8), stderr: Data())
        }
    }

    func makeRecording() -> Recording {
        Recording(audioURL: URL(fileURLWithPath: "/tmp/a.m4a"), startedAt: Date())
    }

    @Test func handoffModeRunsCommandAndMergesResult() async throws {
        var cfg = AppConfig.default
        cfg.pipeline.mode = .handoff
        cfg.pipeline.handoffCommand = ExternalCommand(executable: "/bin/echo", arguments: ["${audioURL}"])
        let runner = FakeRunner(stdout: "{\"transcriptURL\":\"/tmp/handoff.md\"}")
        let engine = PipelineEngine(config: cfg, runner: runner, nativeStages: [])

        let ctx = try await engine.process(makeRecording())

        #expect(runner.lastCommand?.arguments == ["/tmp/a.m4a"]) // substituted
        #expect(ctx.transcriptURL?.path == "/tmp/handoff.md")    // merged
        #expect(runner.lastStdin != nil)                         // context piped in
    }

    @Test func bakedInExternalStageMergesAndFeedsDownstream() async throws {
        // One external transcribe stage that reports a transcript path; everything
        // else disabled so we isolate the merge.
        var cfg = AppConfig.default
        cfg.pipeline.mode = .bakedIn
        cfg.pipeline.stages = [
            StageConfig(id: .encode, provider: .disabled),
            StageConfig(id: .transcribe, provider: .externalCommand(
                ExternalCommand(executable: "/bin/echo"))),
            StageConfig(id: .summarize, provider: .disabled),
            StageConfig(id: .classify, provider: .disabled),
            StageConfig(id: .persist, provider: .disabled),
        ]
        let runner = FakeRunner(stdout: "{\"transcriptURL\":\"/tmp/t.md\"}")
        let engine = PipelineEngine(config: cfg, runner: runner, nativeStages: [])

        let ctx = try await engine.process(makeRecording())
        #expect(ctx.transcriptURL?.path == "/tmp/t.md")
    }

    @Test func externalNonZeroExitThrows() async throws {
        var cfg = AppConfig.default
        cfg.pipeline.mode = .handoff
        cfg.pipeline.handoffCommand = ExternalCommand(executable: "/bin/false")
        let runner = FakeRunner(stdout: "", exitCode: 3)
        let engine = PipelineEngine(config: cfg, runner: runner, nativeStages: [])

        let error = await #expect(throws: PipelineError.self) {
            _ = try await engine.process(makeRecording())
        }
        guard case .externalCommandFailed(_, let code, _) = error else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
        #expect(code == 3)
    }

    @Test func missingNativeStageThrows() async throws {
        var cfg = AppConfig.default
        cfg.pipeline.mode = .bakedIn
        cfg.pipeline.stages = [StageConfig(id: .persist, provider: .native)]
        let engine = PipelineEngine(config: cfg, runner: FakeRunner(), nativeStages: []) // none registered

        let error = await #expect(throws: PipelineError.self) {
            _ = try await engine.process(makeRecording())
        }
        guard case .missingNativeStage(let id) = error else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
        #expect(id == .persist)
    }

    // MARK: - Naming the stage that is running

    /// Collects stage callbacks from whatever context they fire on.
    final class StageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [StageID] = []
        func record(_ id: StageID) { lock.lock(); seen.append(id); lock.unlock() }
        var stages: [StageID] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    /// The menu names the stage it is on. Without this the only signal a long
    /// transcribe gives is a spinner, which reads exactly like a hang — and a
    /// recording that looks hung is one a user stops trusting mid-call.
    @Test func reportsEachStageAsItStarts() async throws {
        var cfg = AppConfig.default
        cfg.pipeline.mode = .bakedIn
        cfg.pipeline.stages = [
            StageConfig(id: .encode, provider: .externalCommand(ExternalCommand(executable: "/bin/echo"))),
            StageConfig(id: .transcribe, provider: .externalCommand(ExternalCommand(executable: "/bin/echo"))),
            StageConfig(id: .summarize, provider: .disabled),
            StageConfig(id: .classify, provider: .externalCommand(ExternalCommand(executable: "/bin/echo"))),
            StageConfig(id: .persist, provider: .disabled),
        ]
        let seen = StageLog()
        let engine = PipelineEngine(config: cfg, runner: FakeRunner(stdout: "{}"),
                                    nativeStages: [], log: { _ in },
                                    onStage: { seen.record($0) })

        _ = try await engine.process(makeRecording())

        // In order, and a disabled stage is not announced: it never runs, and
        // showing it would put a stage on screen that does nothing.
        #expect(seen.stages == [.encode, .transcribe, .classify])
    }

    /// Every stage has to be nameable, or the panel falls back to a blank.
    @Test func everyStageHasALabel() {
        for stage in StageID.allCases {
            #expect(!stage.label.isEmpty)
        }
    }

    // MARK: - A stage that hangs must not hang the pipeline

    /// A native stage that never returns — the shape of the 2026-07-22 incident,
    /// where two recordings entered `transcribe` and stayed there for 19 hours.
    struct HangingStage: PipelineStage {
        let id: StageID
        func run(_ context: inout PipelineContext) async throws {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    struct MarkerStage: PipelineStage {
        let id: StageID
        func run(_ context: inout PipelineContext) async throws {
            context.transcriptURL = URL(fileURLWithPath: "/tmp/ran.md")
        }
    }

    @Test func hungStageTimesOutInsteadOfBlockingForever() async throws {
        let error = await #expect(throws: PipelineError.self) {
            _ = try await PipelineEngine.withTimeout(0.2, stage: .transcribe) {
                try await Task.sleep(for: .seconds(3600))
            }
        }
        guard case .stageTimedOut(let id, _) = error else {
            Issue.record("wrong error: \(String(describing: error))")
            return
        }
        #expect(id == .transcribe)
    }

    @Test func aStageThatFinishesInTimeReturnsItsWork() async throws {
        let value = try await PipelineEngine.withTimeout(30, stage: .persist) { 42 }
        #expect(value == 42)
    }

    @Test func timeoutScalesWithRecordingLengthAndHasAFloor() {
        // A two-hour call must not be cut off mid-transcribe…
        #expect(PipelineEngine.timeout(for: .transcribe, duration: 7_200) == 21_600)
        // …and a 20-second voice note still gets room for a cold model load.
        #expect(PipelineEngine.timeout(for: .transcribe, duration: 20) == 900)
        #expect(PipelineEngine.timeout(for: .encode, duration: nil) == 900)
        // Text stages don't scale with audio.
        #expect(PipelineEngine.timeout(for: .summarize, duration: 7_200) == 600)
    }

    @Test func nativeStagesStillRunNormallyUnderTheTimeout() async throws {
        var cfg = AppConfig.default
        cfg.pipeline.mode = .bakedIn
        cfg.pipeline.stages = [StageConfig(id: .persist, provider: .native)]
        let engine = PipelineEngine(config: cfg, runner: FakeRunner(),
                                    nativeStages: [MarkerStage(id: .persist)])

        let ctx = try await engine.process(makeRecording())
        #expect(ctx.transcriptURL?.path == "/tmp/ran.md")
    }

    // MARK: - Summarize: chunking for small context windows

    /// Records every prompt and returns a canned summary.
    actor SpyChatModel: ChatModel {
        struct Call { let system: String; let user: String }
        private(set) var calls: [Call] = []
        let reply: String
        init(reply: String) { self.reply = reply }
        func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
            calls.append(Call(system: system, user: user))
            return reply
        }
    }

    /// The models decorate the title line, and a decorated title used to be no
    /// title at all: the transcript kept the meeting-window name, the file kept
    /// the app-name slug, and the `TITLE:` line stayed visible in the summary.
    @Test func extractsTitleThroughWhateverMarkdownTheModelUsed() {
        let forms = [
            "TITLE: Post-Sales Interview Process",
            "# TITLE: Post-Sales Interview Process",
            "## Title: Post-Sales Interview Process",
            "**TITLE: Post-Sales Interview Process**",
            "**TITLE:** Post-Sales Interview Process",
            "*Title*: Post-Sales Interview Process",
            "`TITLE: Post-Sales Interview Process`",
        ]
        for form in forms {
            let (title, body) = SummarizeStage.extractTitle(from: "\(form)\n\n**TL;DR:** it happened")
            #expect(title == "Post-Sales Interview Process", "failed on: \(form)")
            // The line is consumed, not left for the reader to see.
            #expect(!body.uppercased().contains("TITLE:"), "left the line behind on: \(form)")
            #expect(body.contains("TL;DR"))
        }
    }

    /// Unwrapping the decoration must not reach inside the title. Stripping
    /// `#` and `_` everywhere renamed "C# to F# Migration" to "C to F
    /// Migration" — in the frontmatter, the filename slug and the Mac's
    /// history, none of which the reader can see is wrong without the audio.
    @Test func extractTitleKeepsPunctuationThatBelongsToTheTitle() {
        let cases = [
            ("**TITLE: C# to F# Migration**", "C# to F# Migration"),
            ("TITLE: C# to F# Migration", "C# to F# Migration"),
            ("**TITLE:** Rename read_me to README", "Rename read_me to README"),
            ("## Title: Q3 Planning #2", "Q3 Planning #2"),
            ("TITLE: Standup: Tuesday", "Standup: Tuesday"),
            ("`TITLE: The *real* problem`", "The *real* problem"),
        ]
        for (input, expected) in cases {
            let (title, _) = SummarizeStage.extractTitle(from: "\(input)\n\nbody")
            #expect(title == expected, "input: \(input)")
        }
    }

    @Test func extractTitleLeavesOrdinarySummariesAlone() {
        let (title, body) = SummarizeStage.extractTitle(from: "**TL;DR:** no title line here")
        #expect(title == nil)
        #expect(body == "**TL;DR:** no title line here")

        // A colon-bearing sentence is not a title line.
        let (t2, _) = SummarizeStage.extractTitle(from: "The title: of this talk was never given")
        #expect(t2 == nil)

        // An empty title is not a title.
        let (t3, _) = SummarizeStage.extractTitle(from: "**TITLE:**\n\nbody")
        #expect(t3 == nil)
    }

    @Test func summarizeSingleShotWhenTranscriptFits() async throws {
        let spy = SpyChatModel(reply: "TITLE: Weekly Sync\n\n**TL;DR:** ok")
        _ = try await SummarizeStage.summarize("short transcript", with: spy)
        let calls = await spy.calls
        #expect(calls.count == 1)
        #expect(calls[0].user.contains("short transcript"))
    }

    @Test func summarizeChunksLongTranscriptsAndReduces() async throws {
        let sentence = "We discussed the quarterly roadmap and the launch plan in detail. "
        let long = String(repeating: sentence, count: 400) // ~27k chars, over budget
        let spy = SpyChatModel(reply: "TITLE: Roadmap Review\n\n**TL;DR:** ok")
        _ = try await SummarizeStage.summarize(long, with: spy)
        let calls = await spy.calls
        #expect(calls.count >= 3) // ≥2 chunk-condense calls + 1 final reduce
        // Every prompt stays inside the on-device context budget (plus the small
        // prompt scaffolding), so no call can throw exceededContextWindowSize.
        for call in calls {
            #expect(call.user.count <= SummarizeStage.promptCharBudget + 200)
        }
        #expect(calls.last!.user.contains("CONDENSED NOTES"))
    }

    @Test func chunkRespectsBudgetAndLosesNothing() {
        let text = String(repeating: "One sentence here. Another follows! A third? ", count: 500)
        let chunks = SummarizeStage.chunk(text, budget: 1_000)
        #expect(chunks.count > 1)
        for c in chunks { #expect(c.count <= 1_000) }
        let originalWords = text.split(separator: " ").count
        let chunkedWords = chunks.map { $0.split(separator: " ").count }.reduce(0, +)
        #expect(chunkedWords == originalWords)
    }

    @Test func chunkPassesThroughShortText() {
        #expect(SummarizeStage.chunk("tiny", budget: 1_000) == ["tiny"])
    }

    // MARK: - Extractive fallback titles

    @Test func extractiveTitleSkipsFillerWords() {
        let title = ExtractiveChatModel.deriveTitle(
            from: "Um, I don't know, maybe we should review the migration timeline")
        #expect(title.lowercased().contains("migration"))
        #expect(!title.lowercased().contains("um"))
        #expect(!title.lowercased().contains("don't"))
    }

    @Test func extractiveTitleFallsBackToKeywords() {
        let title = ExtractiveChatModel.deriveTitle(
            from: "Um, I don't know.",
            keywords: ["roadmap", "budget", "hiring"])
        #expect(title == "Roadmap, Budget, Hiring")
    }

    @Test func extractiveSummaryOfFillerHeavySpeechAvoidsFillerTitle() {
        let transcript = """
        Um, I don't know. Yeah, I don't I don't see why not. So the contract renewal \
        with the vendor needs a signature before the deadline on Friday. The vendor \
        contract renewal covers support and licensing. I don't, I'm not, you know.
        """
        let out = ExtractiveChatModel.summarize(transcript)
        let title = out.components(separatedBy: "\n").first ?? ""
        #expect(title.hasPrefix("TITLE: "))
        #expect(!title.lowercased().contains("um,"))
        #expect(!title.lowercased().contains("i don't know"))
    }
}

@Suite struct DeviceInboxTests {

    /// Builds an inbox in a temp dir and returns its root.
    private func makeInbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcripts-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: DeviceInbox.inbox(under: root),
                                                withIntermediateDirectories: true)
        return root
    }

    private func write(_ capture: DeviceCapture, audioBytes: Int, under root: URL) throws {
        let dir = DeviceInbox.inbox(under: root)
        try Data(repeating: 0x41, count: audioBytes)
            .write(to: dir.appendingPathComponent(capture.audioFilename))
        try DeviceInbox.makeEncoder().encode(capture)
            .write(to: dir.appendingPathComponent("\(capture.id.uuidString).json"))
    }

    private func capture(_ name: String = "a.m4a") -> DeviceCapture {
        DeviceCapture(deviceName: "Test iPad", deviceModel: "iPad",
                      startedAt: Date(timeIntervalSince1970: 1_000), duration: 12,
                      audioFilename: name, appVersion: "test")
    }

    @Test func findsACompleteCapture() throws {
        let root = try makeInbox()
        let c = capture()
        try write(c, audioBytes: 32, under: root)
        let pending = try DeviceInbox.pending(under: root)
        #expect(pending.count == 1)
        #expect(pending.first?.capture.id == c.id)
    }

    /// Audio is written first and the sidecar last, so audio alone means the
    /// capture is still arriving — importing it would truncate the recording.
    @Test func ignoresAudioWithNoSidecar() throws {
        let root = try makeInbox()
        try Data(repeating: 0x41, count: 32)
            .write(to: DeviceInbox.inbox(under: root).appendingPathComponent("orphan.m4a"))
        #expect(try DeviceInbox.pending(under: root).isEmpty)
    }

    /// A cloud placeholder that hasn't downloaded reports zero bytes; it must be
    /// skipped this pass and picked up once the provider materializes it.
    @Test func skipsAnUndownloadedPlaceholder() throws {
        let root = try makeInbox()
        try write(capture(), audioBytes: 0, under: root)
        #expect(try DeviceInbox.pending(under: root).isEmpty)
    }

    @Test func skipsSidecarWhoseAudioIsMissing() throws {
        let root = try makeInbox()
        let c = capture("gone.m4a")
        try DeviceInbox.makeEncoder().encode(c)
            .write(to: DeviceInbox.inbox(under: root).appendingPathComponent("\(c.id.uuidString).json"))
        #expect(try DeviceInbox.pending(under: root).isEmpty)
    }

    /// A missing inbox is an empty inbox — the device may simply not have synced
    /// anything yet, which is not an error worth surfacing.
    @Test func treatsAMissingInboxAsEmpty() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcripts-absent-\(UUID().uuidString)")
        #expect(try DeviceInbox.pending(under: root).isEmpty)
    }

    @Test func refusesASidecarFromANewerSchema() throws {
        let root = try makeInbox()
        var c = capture()
        c.schema = DeviceCapture.currentSchema + 1
        try write(c, audioBytes: 32, under: root)
        #expect(try DeviceInbox.pending(under: root).isEmpty)
    }

    @Test func returnsCapturesOldestFirst() throws {
        let root = try makeInbox()
        var older = capture("older.m4a")
        older.startedAt = Date(timeIntervalSince1970: 500)
        var newer = capture("newer.m4a")
        newer.startedAt = Date(timeIntervalSince1970: 5_000)
        try write(newer, audioBytes: 32, under: root)
        try write(older, audioBytes: 32, under: root)
        let pending = try DeviceInbox.pending(under: root)
        #expect(pending.map(\.capture.audioFilename) == ["older.m4a", "newer.m4a"])
    }

    @Test func draftTranscriptSurvivesTheRoundTrip() throws {
        var c = capture()
        c.draftTranscript = "hello from the device"
        let data = try DeviceInbox.makeEncoder().encode(c)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(DeviceCapture.self, from: data)
        #expect(back.draftTranscript == "hello from the device")
        #expect(back.id == c.id)
    }
}

@Suite struct LocationsTests {

    /// A configured install must never be relocated by a change of default —
    /// `ConfigStore.load` only builds `.default` when no file exists, and a
    /// decoded config keeps whatever root it was saved with.
    @Test func decodingAnExistingConfigKeepsItsRoot() throws {
        let json = """
        {"pipeline":[],"destinations":{"knowledgeRoot":"~/Documents/Transcripts"}}
        """
        // Decode just the destinations to stay independent of the full config shape.
        struct Wrapper: Codable { var destinations: DestinationsConfig }
        let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        #expect(decoded.destinations.knowledgeRoot == "~/Documents/Transcripts")
        #expect(decoded.destinations.deviceInbox == nil)
    }

    @Test func fallsBackToDocumentsWhenICloudIsAbsent() {
        // An empty temp home has no iCloud Drive folder.
        let empty = FileManager()
        let root = Locations.defaultKnowledgeRoot(fileManager: empty)
        // On a machine with iCloud this resolves to the iCloud path; without,
        // to ~/Documents. Either way it must be non-empty and absolute-ish.
        #expect(root.hasPrefix("~/"))
        #expect(root.hasSuffix(Locations.folderName))
    }

    @Test func deviceInboxIsNilWithoutICloud() {
        // Mirrors the rule: no invented local folder a phone could never reach.
        if !Locations.isICloudAvailable {
            #expect(Locations.defaultDeviceInbox() == nil)
        } else {
            #expect(Locations.defaultDeviceInbox() != nil)
        }
    }

    @Test func inboxAndKnowledgeRootAgreeWhenICloudExists() {
        guard Locations.isICloudAvailable else { return }
        #expect(Locations.defaultDeviceInbox() == Locations.defaultKnowledgeRoot())
    }
}

/// Mirrors Transcripts's RecordingSession freshness rule. Duplicated rather
/// than shared because the type lives in the iOS app target, which the macOS
/// test bundle can't link — the rule is what matters, and it is one line.
@Suite struct ResumeFreshnessTests {

    private func isFresh(startedAt: Date, lastSeen: Date?, window: TimeInterval = 5 * 60) -> Bool {
        Date().timeIntervalSince(lastSeen ?? startedAt) < window
    }

    /// The regression: a three-hour session interrupted one second ago must
    /// resume. Keyed on startedAt it went stale after 15 minutes and stopped
    /// resuming on exactly the long recordings the feature exists for.
    @Test func aLongRecordingKilledJustNowStillResumes() {
        let threeHoursAgo = Date().addingTimeInterval(-3 * 3600)
        #expect(isFresh(startedAt: threeHoursAgo, lastSeen: Date().addingTimeInterval(-1)))
    }

    /// The case the window is actually for: the app died and nobody came back
    /// for hours. Reopening the microphone then would be a nasty surprise.
    @Test func anAbandonedRecordingDoesNotResume() {
        let old = Date().addingTimeInterval(-6 * 3600)
        #expect(!isFresh(startedAt: old, lastSeen: old))
    }

    /// A short take killed moments ago — the ordinary reinstall — resumes.
    @Test func aRecentKillResumes() {
        let began = Date().addingTimeInterval(-90)
        #expect(isFresh(startedAt: began, lastSeen: Date().addingTimeInterval(-3)))
    }

    /// Markers written before the heartbeat existed have no lastSeen and must
    /// still decide something sane rather than crashing or always resuming.
    @Test func aMarkerWithoutAHeartbeatFallsBackToStartedAt() {
        #expect(isFresh(startedAt: Date().addingTimeInterval(-30), lastSeen: nil))
        #expect(!isFresh(startedAt: Date().addingTimeInterval(-3600), lastSeen: nil))
    }
}


/// Joining recordings back into one is always the user's explicit act. These
/// pin the part that protects them from the expensive mistake: merging two
/// different meetings, which for anyone filing by client writes one client's
/// words into another's folder.
@Suite struct MergePlanTests {
    func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 0).addingTimeInterval(minutes * 60) }

    func piece(_ title: String, from: Double, to: Double,
               audio: String? = "/tmp/a.m4a", busy: Bool = false) -> MergePlan.Piece {
        MergePlan.Piece(id: UUID(), title: title, startedAt: at(from), endedAt: at(to),
                        audioPath: audio, isBusy: busy)
    }

    @Test func oneRecordingIsNotAMerge() {
        let out = MergePlan.plan([piece("Renewal pricing", from: 0, to: 10)])
        #expect(!out.isAllowed)
        #expect(out.blockers.contains(.needsTwo))
    }

    @Test func twoHalvesOfOneMeetingMergeWithoutComplaint() {
        let out = MergePlan.plan([
            piece("Renewal pricing", from: 0, to: 20),
            piece("Renewal pricing", from: 22, to: 40),
        ])
        #expect(out.isAllowed)
        #expect(out.cautions.isEmpty)
    }

    /// The pieces are laid on a timeline, so order is not the caller's problem.
    @Test func ordersChronologicallyWhateverTheSelectionOrder() {
        let out = MergePlan.plan([
            piece("Renewal pricing", from: 22, to: 40),
            piece("Renewal pricing", from: 0, to: 20),
        ])
        #expect(out.ordered.map(\.startedAt) == [at(0), at(22)])
        #expect(out.span == 40 * 60)
    }

    /// Its audio is not final yet, so there is nothing stable to assemble.
    @Test func refusesARecordingStillInFlight() {
        let out = MergePlan.plan([
            piece("Renewal pricing", from: 0, to: 20),
            piece("Renewal pricing", from: 22, to: 40, busy: true),
        ])
        #expect(!out.isAllowed)
        #expect(out.blockers.contains(.stillRunning("Renewal pricing")))
    }

    @Test func refusesARecordingWhoseAudioIsGone() {
        let out = MergePlan.plan([
            piece("Renewal pricing", from: 0, to: 20),
            piece("Sprint retro", from: 22, to: 40, audio: nil),
        ])
        #expect(!out.isAllowed)
        #expect(out.blockers.contains(.noAudio("Sprint retro")))
    }

    /// The expensive mistake, made visible before it is committed to.
    @Test func warnsWhenThePiecesAreNotTheSameSubject() {
        let out = MergePlan.plan([
            piece("Renewal pricing", from: 0, to: 20),
            piece("Sprint retro", from: 22, to: 40),
        ])
        #expect(out.isAllowed)          // the user was in the room; we only warn
        #expect(out.cautions.contains(where: {
            if case .differentSubjects = $0 { return true }; return false
        }))
    }

    /// A name given at two levels of detail is one subject, not two.
    @Test func doesNotWarnWhenTheSecondTitleIsALongerFormOfTheFirst() {
        let out = MergePlan.plan([
            piece("Pricing", from: 0, to: 20),
            piece("Q3 pricing for enterprise", from: 22, to: 40),
        ])
        #expect(out.cautions.isEmpty)
    }

    /// Back-to-back calls are the case this whole feature has to survive.
    @Test func warnsOnAGapWideEnoughToBeADifferentCall() {
        let out = MergePlan.plan([
            piece("Renewal pricing", from: 0, to: 20),
            piece("Renewal pricing", from: 80, to: 100),
        ])
        #expect(out.cautions.contains(.longGap(minutes: 60)))
    }

    @Test func warnsWhenThePiecesAreFromDifferentDays() {
        let out = MergePlan.plan([
            piece("Renewal pricing", from: 0, to: 20),
            piece("Renewal pricing", from: 60 * 30, to: 60 * 31),
        ])
        #expect(out.cautions.contains(.spansDays))
    }
}
