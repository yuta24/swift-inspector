import Foundation
import InspectCore

/// Drives live mode using whichever mechanism the connected server supports.
/// Push (subscribeUpdates) is preferred when the server is recent enough; an
/// older server falls back to client-side polling on a `Timer`. The choice is
/// passed in by the model — the controller doesn't itself know what
/// `serverProtocolVersion` means.
///
/// Owns nothing related to the connection lifecycle: when the model
/// disconnects, it must call `stop()` first so any in-flight subscription
/// gets cleanly torn down. (Sending `unsubscribeUpdates` after the socket has
/// closed is a silent no-op, but the local `isSubscribed` bookkeeping would
/// otherwise drift.)
@MainActor
final class LiveModeController {
    /// Fires each time the active transport changes. The model uses this to
    /// publish a UI-facing badge ("push" vs "poll" vs idle).
    var onTransportChanged: (LiveTransport) -> Void = { _ in }

    private(set) var transport: LiveTransport = .none {
        didSet {
            guard oldValue != transport else { return }
            onTransportChanged(transport)
        }
    }

    private var isSubscribed = false
    private var liveTimer: Timer?
    private var interval: TimeInterval = 1.0

    private let send: (InspectMessage) -> Void
    private let requestSnapshot: () -> Void

    init(
        send: @escaping (InspectMessage) -> Void,
        requestSnapshot: @escaping () -> Void
    ) {
        self.send = send
        self.requestSnapshot = requestSnapshot
    }

    /// Starts live updates using push (`subscribeUpdates`) when the server is
    /// new enough, otherwise polling. Re-entrant — calling on top of an
    /// existing live session swaps the transport cleanly.
    func start(supportsPush: Bool, intervalSec: TimeInterval) {
        stop()
        interval = intervalSec
        if supportsPush {
            sendSubscribe()
            transport = .push
        } else {
            startLiveTimer()
            transport = .poll
        }
    }

    func stop() {
        stopLiveTimer()
        if isSubscribed {
            send(.unsubscribeUpdates)
            isSubscribed = false
        }
        transport = .none
    }

    /// Updates the cadence both for an active session and for the next start.
    /// Storing the new interval up front means a paused live session that
    /// gets resumed later picks up the user's most recent preset.
    func setInterval(_ newInterval: TimeInterval) {
        interval = newInterval
        switch transport {
        case .push:
            // Re-subscribe so the server's rate limit follows the user's
            // preset.
            send(.unsubscribeUpdates)
            isSubscribed = false
            sendSubscribe()
        case .poll:
            startLiveTimer()
        case .none:
            break
        }
    }

    deinit {
        liveTimer?.invalidate()
    }

    // MARK: - Private

    private func sendSubscribe() {
        let intervalMs = Int((interval * 1000).rounded())
        send(.subscribeUpdates(intervalMs: intervalMs))
        isSubscribed = true
    }

    private func startLiveTimer() {
        stopLiveTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }
}
