import Foundation
import Testing
@testable import TranscriptsCore

@Suite struct AudioCaptureMetricsTests {
    @Test func distinguishesBackpressureFromFailedWrites() {
        var metrics = AudioCaptureMetrics()
        metrics.observe(frames: 480, sampleRate: 48_000, captureSeconds: 10, written: true)
        metrics.observe(frames: 480, sampleRate: 48_000, captureSeconds: 10.01, written: false)
        metrics.observe(frames: 480, sampleRate: 48_000, captureSeconds: 10.02,
                        written: false, writeFailed: true)
        #expect(metrics.receivedBuffers == 3)
        #expect(metrics.writtenBuffers == 1)
        #expect(metrics.droppedBuffers == 2)
        #expect(metrics.writeFailures == 1)
        #expect(metrics.framesWritten == 480)
        #expect(abs(metrics.writtenSeconds - 0.01) < 0.000001)
        // A refused write is not a source-clock gap.
        #expect(metrics.discontinuities == 0)
    }

    @Test func detectsGapsAndClockResetsWithoutConfusingCallbackDelay() {
        var metrics = AudioCaptureMetrics()
        let arrival = Date(timeIntervalSince1970: 1_000)
        metrics.observe(frames: 480, sampleRate: 48_000, captureSeconds: 10,
                        arrivalAt: arrival, written: true)
        metrics.observe(frames: 480, sampleRate: 48_000, captureSeconds: 10.01,
                        arrivalAt: arrival.addingTimeInterval(2), written: true)
        #expect(metrics.discontinuities == 0)
        metrics.observe(frames: 480, sampleRate: 48_000, captureSeconds: 10.52, written: true)
        metrics.observe(frames: 480, sampleRate: 48_000, captureSeconds: 9, written: true)
        #expect(metrics.discontinuities == 2)
        #expect(abs(metrics.largestGapSeconds - 1.53) < 0.000001)
        #expect(metrics.firstCaptureSeconds == 10)
        #expect(metrics.lastCaptureSeconds == 9)
        #expect(metrics.firstArrivalAt == arrival)
    }

    @Test func handlesRateChangesAndInvalidTimestamps() throws {
        var metrics = AudioCaptureMetrics()
        metrics.observe(frames: 480, sampleRate: 48_000, captureSeconds: 10, written: true)
        metrics.observe(frames: 240, sampleRate: 24_000, captureSeconds: 10.01, written: true)
        metrics.observe(frames: 0, sampleRate: 0, captureSeconds: .nan, written: false)
        metrics.observe(frames: 240, sampleRate: 24_000, captureSeconds: .infinity, written: true)
        #expect(metrics.discontinuities == 0)
        #expect(metrics.lastCaptureSeconds == 10.01)
        #expect(abs(metrics.writtenSeconds - 0.03) < 0.000001)
        // Invalid clock values must not poison the JSON sidecar.
        let encoded = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(AudioCaptureMetrics.self, from: encoded)
        #expect(decoded.writtenBuffers == 3)
    }
}
