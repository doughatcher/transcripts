import XCTest
import FluidAudio
@testable import TranscriptsEngine

/// The call path kept the library's one-second speech floor long after rooms
/// and the live pass dropped it, and every short reply on a call printed as
/// "Others" beside the diarized voices (2026-10-14).
final class DiarizerConfigTests: XCTestCase {
    func testCallsKeepShortReplies() {
        let call = FluidAudioDiarizer(rememberVoices: false).diarizerConfig
        XCTAssertEqual(call.minSpeechDuration, 0.5)
    }

    func testRoomsShareTheFloorAndLoosenClustering() {
        let room = FluidAudioDiarizer(rememberVoices: false, roomMode: true).diarizerConfig
        XCTAssertEqual(room.minSpeechDuration, 0.5)
        XCTAssertEqual(room.clusteringThreshold, FluidAudioDiarizer.roomClusteringThreshold)
    }

    func testCallsKeepTheLibraryClustering() {
        let call = FluidAudioDiarizer(rememberVoices: false).diarizerConfig
        XCTAssertEqual(call.clusteringThreshold, DiarizerConfig.default.clusteringThreshold)
    }
}
