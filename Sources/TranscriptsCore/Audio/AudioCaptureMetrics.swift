import Foundation

/// Counters only: no samples or transcript text. The capturer supplies its own
/// lock. Capture time is the source clock, never callback arrival time.
public struct AudioCaptureMetrics: Codable, Sendable {
    public private(set) var receivedBuffers = 0
    public private(set) var writtenBuffers = 0
    public private(set) var droppedBuffers = 0
    public private(set) var writeFailures = 0
    public private(set) var framesWritten: Int64 = 0
    public private(set) var writtenSeconds: Double = 0
    public private(set) var firstCaptureSeconds: Double?
    public private(set) var lastCaptureSeconds: Double?
    public private(set) var firstArrivalAt: Date?
    public private(set) var lastArrivalAt: Date?
    public private(set) var discontinuities = 0
    public private(set) var largestGapSeconds: Double = 0
    private var expectedNextCaptureSeconds: Double?

    public init() {}

    public mutating func observe(frames: Int, sampleRate: Double,
                                 captureSeconds: Double?, arrivalAt: Date = Date(),
                                 written: Bool, writeFailed: Bool = false) {
        receivedBuffers += 1
        if firstArrivalAt == nil { firstArrivalAt = arrivalAt }
        lastArrivalAt = arrivalAt
        let duration = frames > 0 && sampleRate.isFinite && sampleRate > 0
            ? Double(frames) / sampleRate : 0
        if let time = captureSeconds, time.isFinite {
            if firstCaptureSeconds == nil { firstCaptureSeconds = time }
            if let expected = expectedNextCaptureSeconds {
                let gap = time - expected
                if abs(gap) > 0.05 {
                    discontinuities += 1
                    largestGapSeconds = max(largestGapSeconds, abs(gap))
                }
            }
            lastCaptureSeconds = time
            expectedNextCaptureSeconds = time + duration
        }
        if written {
            writtenBuffers += 1
            framesWritten += Int64(max(0, frames))
            writtenSeconds += duration
        } else {
            droppedBuffers += 1
        }
        if writeFailed { writeFailures += 1 }
    }
}
