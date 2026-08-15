import ActivityKit
import Foundation

/// Shape of the Live Activity, compiled into *both* the app and the widget
/// extension — they're separate processes and the type has to match exactly on
/// each side or the activity silently fails to render.
///
/// `ContentState` deliberately carries `startedAt` rather than an elapsed count.
/// ActivityKit rate-limits updates, so a ticking timer pushed once a second gets
/// throttled and goes stale; handing the view a start date lets it render a
/// self-advancing timer locally with no updates at all. State pushes are then
/// reserved for things that genuinely change — transcription stopping, say.
struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        /// Whether live text is running, so the island can say so honestly
        /// rather than implying a transcript is being captured when it isn't.
        var transcribing: Bool
    }

    /// Fixed for the life of the activity.
    var deviceName: String
}
