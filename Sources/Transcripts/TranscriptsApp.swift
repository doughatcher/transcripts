import SwiftUI

/// A pocket recorder, complete in itself: it captures clean audio, transcribes
/// it live on-device, and keeps a browsable library. No diarization, no LLM —
/// deliberately. Each recording is also described by a `DeviceCapture` sidecar
/// and dropped into a folder a companion Mac can watch, so heavier processing
/// (speaker names, summaries) can happen there when one exists.
@main
struct TranscriptsApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
    }
}
