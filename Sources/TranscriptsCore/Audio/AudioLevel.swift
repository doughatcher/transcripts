import Foundation

/// The pure math behind the live input meter and the "was this recording silent?"
/// verdict. `Recorder` accumulates raw numbers from each audio buffer (hot path,
/// no allocation) and delegates the interpretation here so it can be unit-tested
/// against synthetic signals.
public enum AudioLevel {

    /// Peak below this means the mic captured nothing (dead, muted, or the wrong
    /// device) — the recording is flagged as empty instead of transcribing static.
    /// Single source of truth: the recorder's warning and the UI's "silent" flag
    /// must agree.
    public static let silencePeakThreshold: Float = 0.01

    public static func isSilent(peak: Float) -> Bool {
        peak < silencePeakThreshold
    }

    /// A *dead device* reads digital zero (no ADC noise at all) — a clamshell
    /// built-in mic, a hardware-muted input. A healthy mic in a silent room
    /// still shows ambient noise well above this. Used where the question is
    /// "is this device alive?" (dead-mic recovery, the release self-check), as
    /// opposed to `isSilent`, which asks "was anything worth transcribing?"
    public static let digitalSilencePeak: Float = 0.0005

    public static func isDigitallyDead(peak: Float) -> Bool {
        peak < digitalSilencePeak
    }

    /// Maps accumulated signal energy to a lively 0…1 level for the EQ meter.
    /// RMS of typical speech is small (~0.05–0.2), so it's scaled ×6 and clamped.
    public static func meterLevel(sumSquares: Float, sampleCount: Int) -> Float {
        guard sampleCount > 0, sumSquares >= 0 else { return 0 }
        let rms = (sumSquares / Float(sampleCount)).squareRoot()
        return min(1, rms * 6)
    }
}
