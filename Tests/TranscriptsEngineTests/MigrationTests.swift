import XCTest
@testable import TranscriptsEngine

/// The history decode and the migration bundle, tested around the incident
/// that motivated them: a store build opened a migrated `history.json`,
/// decoded none of it, and saved over the file (2026-09-28).
final class MigrationTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func record(_ title: String, daysAgo: Double = 0) -> RecordingRecord {
        RecordingRecord(id: UUID(), title: title,
                        recordedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
                        isCall: false, status: .completed)
    }

    private func write(_ json: String, to dir: URL) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent("history.json"))
    }

    // MARK: - Tolerant decode

    func testOneBadRecordCostsOneRecord() {
        // A status this build has never heard of, between two good records —
        // the exact shape of a newer edition's file read by an older build.
        let json = """
        [{"id":"\(UUID().uuidString)","title":"kept","recordedAt":"2026-01-01T00:00:00Z",
          "isCall":false,"status":"completed"},
         {"id":"\(UUID().uuidString)","title":"future","recordedAt":"2026-01-02T00:00:00Z",
          "isCall":false,"status":"beamedToTheMoon"},
         {"id":"\(UUID().uuidString)","title":"also kept","recordedAt":"2026-01-03T00:00:00Z",
          "isCall":true,"status":"failed"}]
        """
        let (records, dropped) = HistoryStore.decodeRecords(from: Data(json.utf8))
        XCTAssertEqual(records.map(\.title), ["kept", "also kept"])
        XCTAssertEqual(dropped, 1)
    }

    func testLoadSalvagesAndPreservesTheOriginal() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","title":"good","recordedAt":"2026-01-02T00:00:00Z",
          "isCall":true,"status":"completed"},
         {"not":"a record"}]
        """
        try write(json, to: scratch)
        let store = HistoryStore(directory: scratch)
        XCTAssertEqual(store.records.map(\.title), ["good"])
        let preserved = scratch.appendingPathComponent("history.json.rejected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path),
                      "the bytes a load could not fully read must survive the next save")
    }

    func testUnreadableFileIsPreservedNotDestroyed() throws {
        try write("not json at all", to: scratch)
        let store = HistoryStore(directory: scratch)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("history.json.rejected").path))
    }

    func testCleanFileLoadsWithoutARejectedCopy() throws {
        let a = scratch.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let store = HistoryStore(directory: a)
        store.upsert(record("one"))
        let reloaded = HistoryStore(directory: a)
        XCTAssertEqual(reloaded.records.map(\.title), ["one"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: a.appendingPathComponent("history.json.rejected").path))
    }

    // MARK: - Bundle round trip

    func testExportImportMergesWithoutOverwriting() throws {
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        let target = scratch.appendingPathComponent("target", isDirectory: true)
        for dir in [source, target] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let sourceStore = HistoryStore(directory: source)
        let shared = record("on both", daysAgo: 2)
        sourceStore.upsert(shared)
        sourceStore.upsert(record("only in source", daysAgo: 1))
        try Data("{\"profiles\":[]}".utf8)
            .write(to: source.appendingPathComponent("speakers.json"))
        let sample = source.appendingPathComponent("voices/enrolled", isDirectory: true)
        try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        try Data("aac".utf8).write(to: sample.appendingPathComponent("ryan.m4a"))

        let targetStore = HistoryStore(directory: target)
        targetStore.upsert(shared)
        targetStore.upsert(record("only in target"))

        // Through the wire format, exactly as the CLI pipe carries it.
        let bundle = try Migration.decode(Migration.encode(Migration.exportBundle(from: source)))
        let summary = Migration.apply(bundle, history: targetStore, filesDir: target)

        XCTAssertEqual(summary.recordsImported, 1)
        XCTAssertEqual(summary.recordsKept, 1)
        XCTAssertTrue(summary.speakersImported)
        XCTAssertEqual(summary.voiceFilesImported, 1)
        XCTAssertEqual(Set(targetStore.records.map(\.title)),
                       ["on both", "only in source", "only in target"])

        // Importing again must change nothing — and must not clobber the
        // speakers file the first pass installed.
        let again = Migration.apply(bundle, history: targetStore, filesDir: target)
        XCTAssertEqual(again.recordsImported, 0)
        XCTAssertTrue(again.speakersKept)
        XCTAssertEqual(again.voiceFilesImported, 0)
    }

    func testHostileVoicePathsStayInsideVoices() throws {
        let target = scratch.appendingPathComponent("t", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let bundle = MigrationBundle(
            version: 1, exportedAt: Date(), history: [], speakers: nil,
            voices: ["../../escape.m4a": Data("x".utf8)])
        let summary = Migration.apply(bundle, history: HistoryStore(directory: target),
                                      filesDir: target)
        XCTAssertEqual(summary.voiceFilesImported, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("escape.m4a").path))
    }
}
