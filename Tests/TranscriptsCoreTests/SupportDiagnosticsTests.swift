import Foundation
import Testing
@testable import TranscriptsCore

@Test func supportSummaryExcludesMeetingContentAndPersonalIdentifiers() throws {
    let event: [String: Any] = ["event": "audio-route", "at": 123, "data": [
        "actualInputID": 1, "defaultOutputID": 2,
        "devices": [["id": 1, "name": "iPhone Microphone", "uid": "secret-uid"], ["id": 2, "name": "Doug’s AirPods", "uid": "other-secret"]],
        "transcript": "private meeting words", "path": "/Users/private-person/recordings", "writtenBuffers": 24,
        "writerError": "error opening /Users/private-person/secret"
    ]]
    let raw = try JSONSerialization.data(withJSONObject: event)
    let summary = try SupportDiagnostics.summary(jsonLines: raw)
    let text = String(decoding: summary, as: UTF8.self)
    #expect(text.contains("continuity-iphone"))
    #expect(text.contains("bluetooth"))
    #expect(text.contains("writtenBuffers"))
    for hidden in ["secret-uid", "other-secret", "Doug", "private meeting", "/Users/"] { #expect(!text.contains(hidden)) }
}
