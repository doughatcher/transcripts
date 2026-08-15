import Foundation
import AVFoundation
import TranscriptsCore

/// Native Encode stage. The Recorder captures crash-safe LPCM `.caf` (readable at
/// any truncation point, so an interrupted recording is never lost); this stage
/// transcodes it to the archive-quality AAC `.m4a` that gets filed in the vault.
/// Call recordings arrive already mixed to `.m4a` and are adopted as-is.
///
/// On transcode failure the CAF itself is adopted — a bulkier archive beats a
/// dropped recording.
public struct EncodeStage: PipelineStage {
    public let id: StageID = .encode
    public let codec: String

    public init(codec: String) { self.codec = codec }

    public func run(_ context: inout PipelineContext) async throws {
        let source = context.recording.audioURL
        guard source.pathExtension.lowercased() == "caf" else {
            // Already archive-quality (e.g. the mixed call .m4a); adopt it.
            context.archivedAudioURL = source
            return
        }
        let target = source.deletingLastPathComponent().appendingPathComponent("audio-archive.m4a")
        // A single-input "mix" is exactly a transcode: composition + AppleM4A export.
        if let encoded = await AudioMixer.mix([source], into: target) {
            context.archivedAudioURL = encoded
        } else {
            context.archivedAudioURL = source
        }
    }
}
