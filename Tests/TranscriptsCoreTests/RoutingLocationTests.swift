import Foundation
import Testing
@testable import TranscriptsCore

struct RoutingLocationTests {
    @Test func migratesLegacyRulesWithoutRemovingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(".transcripts/routing.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = RoutingConfig(mode: .off, fallback: "Recordings/", destinations: [
            .init(path: "Cases/Contoso/transcripts/", keywords: ["contoso"])
        ], sessions: [.init(id: "workshop", name: "Workshop", destination: "Recordings/Workshop/")])
        try JSONEncoder().encode(config).write(to: legacy)
        let store = RoutingStore(knowledgeRoot: root)
        #expect(store.loadOrSeed() == config)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(store.fileURL == root.appendingPathComponent("Recordings/routing.json"))
        #expect(try JSONDecoder().decode(RoutingConfig.self, from: Data(contentsOf: store.fileURL)) == config)
    }

    @Test func preferredRulesWinAndSaveStaysInRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingStore(knowledgeRoot: root)
        let config = RoutingConfig(mode: .off, fallback: "Recordings/")
        try store.save(config)
        let legacy = root.appendingPathComponent(".transcripts/routing.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(RoutingConfig.default).write(to: legacy)
        #expect(RoutingStore.read(in: root) == config)
        #expect(store.loadOrSeed() == config)
    }
}
