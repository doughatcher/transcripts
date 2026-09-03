import Foundation
import CoreAudio
import CoreMedia
import TranscriptsEngine   // Log

/// Reads the system audio mix through a Core Audio **process tap**
/// (macOS 14.2+): a tap over every process except our own, wrapped in a
/// private aggregate device whose IO callback hands us the buffers.
///
/// Why this exists when ScreenCaptureKit already captured system audio: the
/// permission. A tap falls under "System Audio Recording Only", which macOS
/// grants with a plain Allow/Don't Allow dialog. ScreenCaptureKit needs the
/// Screen Recording grant, which has no dialog — the user is routed into
/// System Settings, and on MDM-managed Macs that pane demands an
/// administrator's password a standard user does not have.
///
/// One sharp edge, inherited from the OS: when the permission is *declined*,
/// tap creation does not fail — it succeeds and delivers silence. The capturer
/// flags an all-silent track at stop() rather than pretending it can detect
/// the denial here.
@available(macOS 14.2, *)
final class SystemAudioTap {

    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private let procID: AudioDeviceIOProcID

    /// Builds tap → aggregate → IO proc and starts the flow; `onBuffer` receives
    /// interleaved PCM as CMSampleBuffers on `queue`. Returns nil (reason logged)
    /// on any failure, so the caller can fall back to ScreenCaptureKit.
    static func start(queue: DispatchQueue,
                      onBuffer: @escaping (CMSampleBuffer) -> Void) -> SystemAudioTap? {
        // Our own process is excluded from the mix for the same reason the
        // ScreenCaptureKit path ran with excludesCurrentProcessAudio: anything
        // the app itself plays must not loop into the recording.
        var excluded: [AudioObjectID] = []
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var procObject = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                      UInt32(MemoryLayout<pid_t>.size), &pid,
                                      &size, &procObject) == noErr,
           procObject != kAudioObjectUnknown {
            excluded.append(procObject)
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Transcripts system audio"
        // Private on both objects: neither the tap nor the aggregate should be
        // visible to other audio software as something it could select.
        description.isPrivate = true
        // muteBehavior is left at its default, CATapUnmuted: the tap must not
        // mute what it captures, or the call goes silent in the user's ears.

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            Log.write("sysaudio: tap creation failed (\(err))")
            return nil
        }

        // The tap's own format (device-rate interleaved PCM); the writer
        // converts to the recording format, exactly as it did for SCStream.
        var asbd = AudioStreamBasicDescription()
        addr.mSelector = kAudioTapPropertyFormat
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        var format: CMAudioFormatDescription?
        if err == noErr {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                           layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &format)
        }
        guard err == noErr, let format, asbd.mBytesPerFrame > 0 else {
            Log.write("sysaudio: tap format unreadable (\(err))")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Transcripts system-audio tap",
            kAudioAggregateDeviceUIDKey as String: AudioInputDevices.systemAudioTapUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: description.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey as String: true],
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr, aggregateID != kAudioObjectUnknown else {
            Log.write("sysaudio: tap aggregate failed (\(err))")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let sampleRate = CMTimeScale(asbd.mSampleRate)
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            _, inInputData, inInputTime, _, _ in
            let frames = Int(inInputData.pointee.mBuffers.mDataByteSize) / bytesPerFrame
            guard frames > 0 else { return }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: sampleRate),
                presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(inInputTime.pointee.mHostTime),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
                                       dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                       formatDescription: format, sampleCount: CMItemCount(frames),
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                       sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                       sampleBufferOut: &sample) == noErr, let sample else { return }
            guard CMSampleBufferSetDataBufferFromAudioBufferList(
                sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: inInputData) == noErr else { return }
            onBuffer(sample)
        }
        guard err == noErr, let procID else {
            Log.write("sysaudio: tap IO proc failed (\(err))")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            Log.write("sysaudio: tap start failed (\(err))")
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        return SystemAudioTap(tapID: tapID, aggregateID: aggregateID, procID: procID)
    }

    private init(tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.procID = procID
    }

    func stop() {
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}
