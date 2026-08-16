import CallKit
import Foundation

/// Notices that a phone call is in progress.
///
/// It cannot record one. `CXCall` exposes four booleans and a UUID — connected,
/// on hold, outgoing, ended — and no `AVAudioSession` category routes telephony
/// audio anywhere an app can reach. That is a deliberate platform boundary, not
/// a gap to work around.
///
/// What the knowledge is worth is not recording but *not being surprised*.
/// During a call iOS takes the audio session exclusively, so a capture running
/// underneath is interrupted and, historically, simply stopped producing audio
/// while still claiming to record. Knowing a call started lets the app stop
/// cleanly, keep what it already has, and say why — rather than leaving a take
/// that looks forty minutes long and holds four.
@MainActor
final class CallAwareness: ObservableObject {
    @Published private(set) var callInProgress = false

    private let observer = CXCallObserver()
    private final class Delegate: NSObject, CXCallObserverDelegate {
        var onChange: (@MainActor (Bool) -> Void)?
        func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
            // Any connected, un-ended call counts. A call on hold still owns the
            // audio route, so it is not a window to record in.
            let busy = observer.calls.contains { !$0.hasEnded }
            Task { @MainActor [onChange] in onChange?(busy) }
        }
    }
    private let delegate = Delegate()

    init(onCallStarted: @escaping @MainActor () -> Void) {
        delegate.onChange = { [weak self] busy in
            guard let self else { return }
            let wasBusy = self.callInProgress
            self.callInProgress = busy
            if busy && !wasBusy { onCallStarted() }
        }
        observer.setDelegate(delegate, queue: nil)
        callInProgress = observer.calls.contains { !$0.hasEnded }
    }
}
