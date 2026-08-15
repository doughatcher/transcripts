import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TranscriptsWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// Lock screen banner + Dynamic Island for an in-progress recording.
///
/// The point is reassurance: once the app is backgrounded there is no other
/// signal that capture is still running, and a recorder you can't see is a
/// recorder you don't trust. Every presentation shows the same two facts — it's
/// recording, and for how long.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            // Lock screen / banner presentation.
            HStack(spacing: 14) {
                WaveBars()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcripts is recording").font(.headline)
                    Text(context.attributes.deviceName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Timer(from: context.state.startedAt).font(.title2)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        WaveBars()
                        Text("Recording")
                    }
                    .foregroundStyle(.red)
                    .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Timer(from: context.state.startedAt)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.transcribing
                         ? "Transcribing on this device"
                         : "Audio only — no live text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                WaveBars()
            } compactTrailing: {
                Timer(from: context.state.startedAt)
                    .font(.caption2)
                    // A wider clock gets truncated to nothing useful in the
                    // compact slot, so it is kept deliberately narrow.
                    .frame(maxWidth: 44)
            } minimal: {
                WaveBars()
            }
            .keylineTint(.red)
        }
    }
}

/// Self-advancing elapsed time. Rendered by the system from a date, so it stays
/// correct without the app pushing updates into a rate limit.
private struct Timer: View {
    let from: Date

    var body: some View {
        Text(timerInterval: from...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

/// Animated waveform standing in for a real level meter.
///
/// It is not driven by input level, and can't be: ActivityKit throttles updates,
/// so pushing amplitude at any useful rate gets dropped and drains the battery
/// for nothing — the same reason the elapsed time is a system-rendered timer
/// rather than a pushed count. `variableColor` animates inside the widget
/// process with no updates at all, which conveys the thing that actually matters
/// from a glance (audio is flowing) at zero cost.
private struct WaveBars: View {
    var body: some View {
        Image(systemName: "waveform")
            .foregroundStyle(.red)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers)
    }
}
