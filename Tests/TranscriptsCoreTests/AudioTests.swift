import Testing
import Foundation
import AVFoundation
@testable import TranscriptsCore

// Tests for the critical audio path: which mic gets chosen, how remembered mics
// are labeled, when a recording counts as silent, and whether the mic + system
// audio actually end up mixed into one file. No audio hardware needed — the
// selection rules are pure logic, and the mixer test synthesizes tone files and
// analyzes the mixed output mathematically.

// MARK: - Which microphone records? (InputSelection.resolve)

@Suite struct InputSelectionTests {

    // Fixture devices mirroring the real desk setup: built-in mic, two USB mics.
    let builtIn = AudioInputCandidate(uid: "BuiltInMicrophoneDevice",
                                      name: "MacBook Pro Microphone")
    let brio = AudioInputCandidate(uid: "AppleUSBAudioEngine:Logitech:MX Brio:2416AP:2",
                                   name: "MX Brio")
    let dock = AudioInputCandidate(uid: "AppleUSBAudioEngine:Microsoft:Microsoft Audio Dock:0001:3",
                                   name: "Microsoft Audio Dock")

    private func def(_ d: AudioInputCandidate) -> AudioInputCandidate {
        AudioInputCandidate(uid: d.uid, name: d.name, isSystemDefault: true)
    }

    @Test func overrideBeatsFavorites() {
        // User clicked a specific connected mic in Settings — that always wins,
        // even when a higher-priority favorite is also connected.
        let chosen = InputSelection.resolve(devices: [builtIn, brio, dock],
                                            favorites: [brio.uid, dock.uid],
                                            override: dock.uid)
        #expect(chosen?.uid == dock.uid)
    }

    @Test func unpluggedOverrideIsIgnored() {
        // The override device was unplugged — fall back to favorites rather than
        // recording nothing.
        let chosen = InputSelection.resolve(devices: [builtIn, brio],
                                            favorites: [brio.uid],
                                            override: dock.uid)
        #expect(chosen?.uid == brio.uid)
    }

    let airpods = AudioInputCandidate(uid: "BT:AirPodsPro:0001", name: "Doug's AirPods Pro")

    @Test func callDeviceBeatsFavorites() {
        // The AirPods case: undocked, Teams is talking through the AirPods, which
        // aren't a favorite. Follow the conversation, not the favorites list.
        let chosen = InputSelection.resolve(devices: [builtIn, airpods, brio],
                                            favorites: [brio.uid, builtIn.uid],
                                            callDeviceUIDs: [airpods.uid])
        #expect(chosen?.uid == airpods.uid)
    }

    @Test func overrideStillBeatsCallDevice() {
        // An explicit user override outranks even the call's own device.
        let chosen = InputSelection.resolve(devices: [builtIn, airpods, brio],
                                            favorites: [],
                                            override: brio.uid,
                                            callDeviceUIDs: [airpods.uid])
        #expect(chosen?.uid == brio.uid)
    }

    @Test func unknownCallDeviceUIDsAreIgnored() {
        // The meeting app's device list can include its *output* device — a UID
        // that matches no input candidate must not derail selection.
        let chosen = InputSelection.resolve(devices: [builtIn, brio],
                                            favorites: [brio.uid],
                                            callDeviceUIDs: ["BT:AirPodsPro:0001-output"])
        #expect(chosen?.uid == brio.uid)
    }

    @Test func excludedDeadDeviceIsNeverRePicked() {
        // Dead-mic recovery: the silent device is excluded from every tier — even
        // as an override — so the restart lands on the next viable input.
        let chosen = InputSelection.resolve(devices: [def(builtIn), airpods],
                                            favorites: [builtIn.uid],
                                            override: builtIn.uid,
                                            excluding: [builtIn.uid])
        #expect(chosen?.uid == airpods.uid)
    }

    @Test func favoritePriorityOrderWinsEvenOverSystemDefault() {
        // THE ranking contract from Settings: "top = highest priority ... records
        // from the highest-priority favorite that's connected, top to bottom."
        // macOS loves to flip its default input to whatever was plugged in last;
        // that must NOT outrank the user's explicit ordering. (Regression lock:
        // an earlier rule preferred the macOS default among connected favorites.)
        let chosen = InputSelection.resolve(devices: [builtIn, brio, def(dock)],
                                            favorites: [brio.uid, dock.uid],
                                            override: nil)
        #expect(chosen?.uid == brio.uid)
    }

    @Test func lowerPriorityFavoriteUsedWhenTopIsUnplugged() {
        // At the desk with only the dock: rank-1 Brio is unplugged, so rank-2 wins.
        let chosen = InputSelection.resolve(devices: [builtIn, dock],
                                            favorites: [brio.uid, dock.uid],
                                            override: nil)
        #expect(chosen?.uid == dock.uid)
    }

    @Test func externalFavoriteOutranksBuiltInFavoriteRegardlessOfOrder() {
        // The built-in mic can be a favorite (it's the laptop-on-the-go choice),
        // but when any external favorite is connected the external wins even if
        // the built-in is ranked higher — docked/clamshell Macs report the
        // built-in as present yet capture silence from it.
        let chosen = InputSelection.resolve(devices: [builtIn, brio],
                                            favorites: [builtIn.uid, brio.uid],
                                            override: nil)
        #expect(chosen?.uid == brio.uid)
    }

    @Test func builtInFavoriteWinsWhenItIsTheOnlyFavoriteConnected() {
        // Laptop in a coffee shop: no external mics, built-in favorite records.
        let chosen = InputSelection.resolve(devices: [builtIn],
                                            favorites: [brio.uid, builtIn.uid],
                                            override: nil)
        #expect(chosen?.uid == builtIn.uid)
    }

    @Test func noFavoritesConnectedFallsBackToExternalSystemDefault() {
        // A brand-new machine (no favorites yet): follow the macOS default when
        // it's an external mic.
        let chosen = InputSelection.resolve(devices: [builtIn, def(dock)],
                                            favorites: [],
                                            override: nil)
        #expect(chosen?.uid == dock.uid)
    }

    @Test func dockedMacBuiltInDefaultLosesToExternalMic() {
        // Clamshell/docked: macOS still says the (silent) built-in is the default.
        // Any external mic must beat it or recordings come out empty.
        let chosen = InputSelection.resolve(devices: [def(builtIn), dock],
                                            favorites: [],
                                            override: nil)
        #expect(chosen?.uid == dock.uid)
    }

    @Test func onlyBuiltInConnectedIsStillUsable() {
        // Nothing else available — record from the built-in rather than nothing.
        let chosen = InputSelection.resolve(devices: [builtIn], favorites: [], override: nil)
        #expect(chosen?.uid == builtIn.uid)
    }

    @Test func noDevicesGivesNil() {
        #expect(InputSelection.resolve(devices: [], favorites: [], override: nil) == nil)
    }

    @Test func builtInNameHeuristic() {
        #expect(InputSelection.isBuiltInName("MacBook Pro Microphone"))
        #expect(InputSelection.isBuiltInName("Built-in Microphone"))
        #expect(InputSelection.isBuiltInName("built in mic"))
        #expect(!InputSelection.isBuiltInName("MX Brio"))
        #expect(!InputSelection.isBuiltInName("Microsoft Audio Dock"))
    }
}

// MARK: - Aggregate steals the built-in mic (InputSelection.aggregateOwning)

@Suite struct AggregateOwnershipTests {
    typealias Facts = InputSelection.AggregateFacts

    // Teams' echo-cancellation aggregate wrapping the built-in mic (Tyler's #12).
    let builtIn = "BuiltInMicrophoneDevice"
    let teamsAggregate = Facts(uid: "CADefaultDeviceAggregate-3485-21",
                               subDeviceUIDs: ["BuiltInMicrophoneDevice", "BuiltInSpeakerDevice"])

    @Test func findsAggregateThatSwallowedTheDeadMic() {
        // The raw built-in read silent; its live signal is inside the aggregate.
        #expect(InputSelection.aggregateOwning(deadUID: builtIn, aggregates: [teamsAggregate])
                == teamsAggregate.uid)
    }

    @Test func noAggregateMeansOrdinaryDeadMic() {
        // Nothing owns this mic — a plain dead/muted device, not a stolen one.
        #expect(InputSelection.aggregateOwning(deadUID: builtIn, aggregates: []) == nil)
    }

    @Test func aggregateNotContainingTheMicIsIgnored() {
        let unrelated = Facts(uid: "SomeOtherAggregate",
                              subDeviceUIDs: ["AppleUSBAudioEngine:Logitech:MX Brio:2416AP:2"])
        #expect(InputSelection.aggregateOwning(deadUID: builtIn, aggregates: [unrelated]) == nil)
    }

    @Test func anAggregateNeverRecoversToItself() {
        // Guards the restart loop: if the dead device *is* an aggregate, we must
        // not point it back at itself.
        let selfWrapping = Facts(uid: builtIn, subDeviceUIDs: [builtIn])
        #expect(InputSelection.aggregateOwning(deadUID: builtIn, aggregates: [selfWrapping]) == nil)
    }
}

// MARK: - Naming unplugged favorites (InputSelection.rememberedName)

@Suite struct RememberedNameTests {

    @Test func builtInUIDGetsFriendlyName() {
        #expect(InputSelection.rememberedName(forUID: "BuiltInMicrophoneDevice")
                == "MacBook Pro Microphone")
    }

    @Test func usbUIDParsesManufacturerAndModel() {
        // "AppleUSBAudioEngine:<manufacturer>:<model>:<serial>:<interface>"
        #expect(InputSelection.rememberedName(forUID: "AppleUSBAudioEngine:Logitech:MX Brio:2416AP00ZVA8:2")
                == "Logitech MX Brio")
    }

    @Test func usbUIDDropsDuplicatedManufacturer() {
        // Model already contains the manufacturer — don't produce
        // "Microsoft Microsoft Audio Dock".
        #expect(InputSelection.rememberedName(forUID: "AppleUSBAudioEngine:Microsoft:Microsoft Audio Dock:0001:3")
                == "Microsoft Audio Dock")
    }

    @Test func usbUIDUnknownManufacturerUsesModelAlone() {
        #expect(InputSelection.rememberedName(forUID: "AppleUSBAudioEngine:Unknown Manufacturer:USB Condenser Mic:123:2")
                == "USB Condenser Mic")
    }

    @Test func nonUSBUIDFallsBackToLastComponent() {
        #expect(InputSelection.rememberedName(forUID: "VirtualAudioDriver:Teams Audio")
                == "Teams Audio")
    }

    @Test func unparseableUIDGivesNilSoCallerUsesGenericLabel() {
        #expect(InputSelection.rememberedName(forUID: "") == nil)
    }
}

// MARK: - Silence detection & meter math (AudioLevel)

@Suite struct AudioLevelTests {

    @Test func zeroSignalMetersZeroAndCountsAsSilent() {
        #expect(AudioLevel.meterLevel(sumSquares: 0, sampleCount: 4096) == 0)
        #expect(AudioLevel.isSilent(peak: 0))
    }

    @Test func quietRoomIsSilentButNotDead() {
        // A healthy mic in a silent room reads small-but-nonzero ambient noise
        // (field data: MX Brio probes at 0.003–0.008). That's "nothing worth
        // transcribing" but must NOT read as a dead device — the release gate
        // and the dead-mic auto-switch only act on digital zero.
        let ambient: Float = 0.005
        #expect(AudioLevel.isSilent(peak: ambient))
        #expect(!AudioLevel.isDigitallyDead(peak: ambient))
        #expect(AudioLevel.isDigitallyDead(peak: 0))        // clamshell built-in
        #expect(!AudioLevel.isDigitallyDead(peak: 0.3))     // speech
    }

    @Test func silenceThresholdBoundary() {
        // The single source of truth for "this recording captured nothing":
        // strictly below 0.01 is silent; exactly 0.01 is a (barely) live signal.
        #expect(AudioLevel.isSilent(peak: 0.0099))
        #expect(!AudioLevel.isSilent(peak: 0.01))
        #expect(!AudioLevel.isSilent(peak: 0.5))
    }

    @Test func quietSpeechLevelMatchesTheRMSFormula() {
        // Mirror Recorder's per-buffer accumulation over a synthetic sine of
        // amplitude 0.05 (quiet speech). RMS = a/√2, level = min(1, rms × 6).
        let amplitude: Float = 0.05
        let n = 48_000
        var sumSquares: Float = 0
        for i in 0..<n {
            let s = amplitude * sinf(2 * .pi * 440 * Float(i) / 48_000)
            sumSquares += s * s
        }
        let level = AudioLevel.meterLevel(sumSquares: sumSquares, sampleCount: n)
        let expected = min(1, (amplitude / Float(2).squareRoot()) * 6)   // ≈ 0.212
        #expect(abs(level - expected) < 0.01)
    }

    @Test func loudSignalClampsToFullScale() {
        // Amplitude 0.5 sine → rms×6 ≈ 2.1 → the meter clamps at 1.
        let n = 1000
        let sumSquares = Float(n) * 0.5 * 0.5 / 2
        #expect(AudioLevel.meterLevel(sumSquares: sumSquares, sampleCount: n) == 1)
    }

    @Test func degenerateInputIsSafe() {
        #expect(AudioLevel.meterLevel(sumSquares: 0, sampleCount: 0) == 0)
        #expect(AudioLevel.meterLevel(sumSquares: -1, sampleCount: 100) == 0)
    }
}

// MARK: - Mixing both call sides into one file (AudioMixer)

@Suite struct AudioMixerTests {

    /// Writes a 1-second pure sine tone to a PCM .caf file — a stand-in for one
    /// side of a call (mic or system audio) with a mathematically known signature.
    private func makeToneFile(frequency: Double, amplitude: Float,
                              seconds: Double = 1.0, name: String) throws -> URL {
        let sampleRate = 48_000.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-mix-\(name)-\(UUID().uuidString).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = amplitude * sinf(2 * .pi * Float(frequency) * Float(i) / Float(sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    /// Decodes an audio file to mono samples (channels averaged).
    private func readMono(_ url: URL) throws -> (samples: [Double], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Double](repeating: 0, count: n)
        for c in 0..<channels {
            let ch = buffer.floatChannelData![c]
            for i in 0..<n { mono[i] += Double(ch[i]) }
        }
        if channels > 1 { for i in 0..<n { mono[i] /= Double(channels) } }
        return (mono, format.sampleRate)
    }

    /// Amplitude of the sinusoid at `frequency` in `samples` (Goertzel algorithm).
    /// A pure tone of amplitude A measures ≈ A; an absent tone measures ≈ 0.
    private func toneAmplitude(in samples: [Double], frequency: Double,
                               sampleRate: Double) -> Double {
        let coeff = 2 * cos(2 * .pi * frequency / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s0 = x + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 2 * sqrt(max(0, power)) / Double(samples.count)
    }

    @Test func mixCombinesBothCallSidesIntoOneFile() async throws {
        // The core promise of call capture: your mic (440 Hz stand-in) and the
        // other participants (880 Hz stand-in) both end up in the mixed file.
        let mic = try makeToneFile(frequency: 440, amplitude: 0.35, name: "mic")
        let system = try makeToneFile(frequency: 880, amplitude: 0.35, name: "sys")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-mixed-\(UUID().uuidString).m4a")
        defer { for f in [mic, system, out] { try? FileManager.default.removeItem(at: f) } }

        let mixed = await AudioMixer.mix([mic, system], into: out)
        let url = try #require(mixed)

        let (samples, rate) = try readMono(url)
        // Duration survived the mix (1 s ± AAC priming/padding slop).
        #expect(abs(Double(samples.count) / rate - 1.0) < 0.1)
        // Both tones are strongly present…
        #expect(toneAmplitude(in: samples, frequency: 440, sampleRate: rate) > 0.15)
        #expect(toneAmplitude(in: samples, frequency: 880, sampleRate: rate) > 0.15)
        // …and a frequency nobody played is not (sanity check on the analysis).
        #expect(toneAmplitude(in: samples, frequency: 1320, sampleRate: rate) < 0.05)
    }

    @Test func singleInputMixTranscodesCafToM4a() async throws {
        // EncodeStage's contract: a one-input "mix" turns the crash-safe LPCM
        // .caf capture into the archive AAC .m4a with the signal intact.
        let caf = try makeToneFile(frequency: 440, amplitude: 0.35, name: "enc")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-encode-\(UUID().uuidString).m4a")
        defer { for f in [caf, out] { try? FileManager.default.removeItem(at: f) } }

        let encoded = await AudioMixer.mix([caf], into: out)
        let url = try #require(encoded)
        let (samples, rate) = try readMono(url)
        #expect(abs(Double(samples.count) / rate - 1.0) < 0.1)
        #expect(toneAmplitude(in: samples, frequency: 440, sampleRate: rate) > 0.15)
    }

    @Test func truncatedCafIsStillReadable() throws {
        // The crash-safety claim behind recording to CAF: chop the file mid-data
        // (what a SIGKILL/power-loss leaves behind) and the audio still opens
        // and yields most of its frames. An unfinalized AAC would be unreadable.
        let caf = try makeToneFile(frequency: 440, amplitude: 0.35, name: "trunc")
        defer { try? FileManager.default.removeItem(at: caf) }

        let size = try #require((try FileManager.default.attributesOfItem(atPath: caf.path)[.size]) as? Int)
        let handle = try FileHandle(forWritingTo: caf)
        try handle.truncate(atOffset: UInt64(Double(size) * 0.6))
        try handle.close()

        let file = try AVAudioFile(forReading: caf)
        #expect(file.length > 0)
        // Roughly the surviving 60% of a 1-second, 48 kHz tone.
        #expect(Double(file.length) > 48_000.0 * 0.4)
    }

    @Test func mixKeepsTheGoodSideWhenOneInputIsUnreadable() async throws {
        // Degrade contract: if the system-audio file is missing/corrupt (e.g.
        // Screen Recording revoked mid-call), the mic side must still survive.
        let mic = try makeToneFile(frequency: 440, amplitude: 0.35, name: "mic")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-nonexistent-\(UUID().uuidString).m4a")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-mixed-\(UUID().uuidString).m4a")
        defer { for f in [mic, out] { try? FileManager.default.removeItem(at: f) } }

        let mixed = await AudioMixer.mix([mic, missing], into: out)
        let url = try #require(mixed)
        let (samples, rate) = try readMono(url)
        #expect(toneAmplitude(in: samples, frequency: 440, sampleRate: rate) > 0.15)
    }

    @Test func mixReturnsNilWhenNoInputIsUsable() async {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-mixed-\(UUID().uuidString).m4a")
        let missing1 = FileManager.default.temporaryDirectory.appendingPathComponent("nope1.m4a")
        let missing2 = FileManager.default.temporaryDirectory.appendingPathComponent("nope2.m4a")
        let mixed = await AudioMixer.mix([missing1, missing2], into: out)
        #expect(mixed == nil)
    }

    // MARK: - Stitching a meeting back together after a mic recovery

    @Test func assemblePlacesFragmentsAtTheirOwnOffsets() async throws {
        // A meeting interrupted by a mic switch: 1s of audio, a gap while the
        // engine rebinds, then the rest. Both slices must land where they actually
        // happened so everything after the switch stays in sync.
        let first = try makeToneFile(frequency: 440, amplitude: 0.35, name: "frag1")
        let second = try makeToneFile(frequency: 880, amplitude: 0.35, name: "frag2")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-assembled-\(UUID().uuidString).m4a")
        defer { for f in [first, second, out] { try? FileManager.default.removeItem(at: f) } }

        let assembled = await AudioMixer.assemble([
            .init(url: first, at: 0),
            .init(url: second, at: 3),
        ], into: out)
        let url = try #require(assembled)

        let (samples, rate) = try readMono(url)
        // Timeline runs to the end of the second fragment: 3s offset + 1s of audio.
        #expect(abs(Double(samples.count) / rate - 4.0) < 0.2)

        // First second is the 440 Hz slice, and only that.
        let head = Array(samples[0..<Int(rate)])
        #expect(toneAmplitude(in: head, frequency: 440, sampleRate: rate) > 0.15)
        #expect(toneAmplitude(in: head, frequency: 880, sampleRate: rate) < 0.05)

        // The switchover gap is silence, not a shifted copy of the audio.
        let gap = Array(samples[Int(rate * 1.3)..<Int(rate * 2.7)])
        #expect(toneAmplitude(in: gap, frequency: 440, sampleRate: rate) < 0.05)
        #expect(toneAmplitude(in: gap, frequency: 880, sampleRate: rate) < 0.05)

        // The second fragment sits at 3s, undisplaced.
        let tail = Array(samples[Int(rate * 3.1)..<Int(rate * 3.9)])
        #expect(toneAmplitude(in: tail, frequency: 880, sampleRate: rate) > 0.15)
    }

    @Test func assembleSkipsUnreadableFragmentsRatherThanFailing() async throws {
        // Losing one fragment must not cost the whole meeting.
        let good = try makeToneFile(frequency: 440, amplitude: 0.35, name: "good")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-gone-\(UUID().uuidString).caf")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-assembled-\(UUID().uuidString).m4a")
        defer { for f in [good, out] { try? FileManager.default.removeItem(at: f) } }

        let assembled = await AudioMixer.assemble([
            .init(url: missing, at: 0),
            .init(url: good, at: 2),
        ], into: out)
        let url = try #require(assembled)
        let (samples, rate) = try readMono(url)
        #expect(toneAmplitude(in: samples, frequency: 440, sampleRate: rate) > 0.1)
    }

    @Test func assembleReturnsNilWhenNothingIsReadable() async {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-assembled-\(UUID().uuidString).m4a")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope.caf")
        let assembled = await AudioMixer.assemble([.init(url: missing, at: 0)], into: out)
        #expect(assembled == nil)
    }

    // MARK: - Cutting a voice sample for the naming grid

    @Test func clipExtractsTheRequestedWindow() async throws {
        // A 3s tone; grab the middle second and confirm the tone survived and the
        // clip is ~1s (± AAC slop), i.e. we cut a window, not the whole file.
        let src = try makeToneFile(frequency: 440, amplitude: 0.35, seconds: 3, name: "src")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-clip-\(UUID().uuidString).m4a")
        defer { for f in [src, out] { try? FileManager.default.removeItem(at: f) } }

        let clip = await AudioMixer.clip(src, from: 1.0, seconds: 1.0, into: out)
        let url = try #require(clip)
        let (samples, rate) = try readMono(url)
        #expect(abs(Double(samples.count) / rate - 1.0) < 0.15)
        #expect(toneAmplitude(in: samples, frequency: 440, sampleRate: rate) > 0.15)
    }

    @Test func clipClampsAWindowPastTheEnd() async throws {
        // Asking for 10s of a 1s file yields the 1s that exists, not nil.
        let src = try makeToneFile(frequency: 440, amplitude: 0.35, seconds: 1, name: "short")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-clip-\(UUID().uuidString).m4a")
        defer { for f in [src, out] { try? FileManager.default.removeItem(at: f) } }

        let clip = await AudioMixer.clip(src, from: 0.5, seconds: 10, into: out)
        let url = try #require(clip)
        let (samples, rate) = try readMono(url)
        #expect(Double(samples.count) / rate < 1.0)   // only ~0.5s remained
        #expect(toneAmplitude(in: samples, frequency: 440, sampleRate: rate) > 0.1)
    }

    @Test func clipReturnsNilPastTheEnd() async throws {
        let src = try makeToneFile(frequency: 440, amplitude: 0.35, seconds: 1, name: "past")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-clip-\(UUID().uuidString).m4a")
        defer { for f in [src, out] { try? FileManager.default.removeItem(at: f) } }
        let clip = await AudioMixer.clip(src, from: 5, seconds: 1, into: out)
        #expect(clip == nil)
    }
}

// MARK: - Which span becomes the "hear this voice" sample

@Suite struct SampleWindowTests {

    @Test func picksEachSpeakersLongestSpan() {
        // Speaker 1 has a 1s and a 4s span; the 4s one should be the sample.
        let spans = [
            SpeakerSpan(speaker: "Speaker 1", start: 0, end: 1),
            SpeakerSpan(speaker: "Speaker 2", start: 1, end: 5),
            SpeakerSpan(speaker: "Speaker 1", start: 5, end: 9),
        ]
        let w = SpeakerTurns.sampleWindows(spans, maxSeconds: 6, minSeconds: 1.5, onsetSkip: 0)
        #expect(w["Speaker 1"]?.start == 5)   // the 4s span, not the 1s one
        #expect(w["Speaker 2"]?.start == 1)
    }

    @Test func capsTheWindowAtMaxSeconds() {
        let spans = [SpeakerSpan(speaker: "Speaker 1", start: 10, end: 40)]  // 30s
        let w = SpeakerTurns.sampleWindows(spans, maxSeconds: 6, onsetSkip: 0)
        #expect(w["Speaker 1"]?.seconds == 6)
    }

    @Test func skipsTheOnsetWhenThereIsRoom() {
        let spans = [SpeakerSpan(speaker: "Speaker 1", start: 0, end: 10)]
        let w = SpeakerTurns.sampleWindows(spans, maxSeconds: 6, minSeconds: 1.5, onsetSkip: 0.25)
        #expect(w["Speaker 1"]?.start == 0.25)
        #expect(w["Speaker 1"]?.seconds == 6)
    }

    @Test func dropsSpeakersTooShortToRecognize() {
        // A one-word interjection isn't worth a sample.
        let spans = [SpeakerSpan(speaker: "Speaker 3", start: 0, end: 0.8)]
        let w = SpeakerTurns.sampleWindows(spans, minSeconds: 1.5)
        #expect(w["Speaker 3"] == nil)
    }
}

// MARK: - Has a call app taken the mic? (InputSelection.looksVoiceProcessed)

@Suite struct VoiceProcessingDetectionTests {

    @Test func wiredMicAtVoiceRateLooksStolen() {
        // GH #12 / 2026-07-22: an MX Brio recorded pure digital zero for 75 minutes
        // while Teams held it, and the only visible sign was the rate — 24 kHz on
        // exactly the silent sessions, 48 kHz on every healthy one.
        #expect(InputSelection.looksVoiceProcessed(transport: .usb, sampleRate: 24_000))
        #expect(InputSelection.looksVoiceProcessed(transport: .builtIn, sampleRate: 24_000))
        #expect(InputSelection.looksVoiceProcessed(transport: .usb, sampleRate: 16_000))
    }

    @Test func wiredMicAtItsNormalRateDoesNot() {
        #expect(!InputSelection.looksVoiceProcessed(transport: .usb, sampleRate: 48_000))
        #expect(!InputSelection.looksVoiceProcessed(transport: .builtIn, sampleRate: 48_000))
        #expect(!InputSelection.looksVoiceProcessed(transport: .usb, sampleRate: 44_100))
    }

    @Test func bluetoothHeadsetAtVoiceRateIsNormal() {
        // The false positive this rule exists to avoid: AirPods run at 24 kHz in
        // headset mode natively and record fine there (peak 1.787 on 2026-07-22).
        // Condemning them on rate alone would switch away from a working mic.
        #expect(!InputSelection.looksVoiceProcessed(transport: .bluetooth, sampleRate: 24_000))
    }

    @Test func unknownTransportIsLeftAlone() {
        // Virtual/loopback devices have their own reasons for odd rates; without a
        // physical stream to be stolen, the heuristic doesn't apply.
        #expect(!InputSelection.looksVoiceProcessed(transport: .other, sampleRate: 24_000))
    }

    @Test func absentRateIsNotEvidence() {
        // A device that won't report a rate reads as 0 — that's missing data, not a
        // stolen mic, and must not trigger a switch.
        #expect(!InputSelection.looksVoiceProcessed(transport: .usb, sampleRate: 0))
    }
}
