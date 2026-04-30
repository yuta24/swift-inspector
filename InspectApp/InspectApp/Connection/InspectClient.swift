import Foundation
import Network
import InspectCore
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "client")

final class InspectClient {
    var onMessage: ((InspectMessage) -> Void)?
    var onStatus: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    /// Invoked only when NWConnection transitions to `.failed`. Distinct from
    /// `onDisconnected`, which also fires on user-initiated cancel — callers
    /// that need to flag an actual error (to drive a Retry UI, say) should
    /// listen here rather than sniff the status string.
    var onFailed: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "swift-inspector.client")
    private let serializer: MessageSerializer = JSONMessageSerializer()
    private var connection: NWConnection?
    /// Latched the first time a failure path fires (either from a
    /// `receive` completion error or from the NWConnection's
    /// `stateUpdateHandler` transitioning to `.failed`). Subsequent
    /// failure paths skip the user-visible callbacks so callers don't
    /// see `onFailed` and `onDisconnected` fire twice for one drop. All
    /// access on `queue`.
    private var hasFailed: Bool = false

    func connect(to endpoint: NWEndpoint) {
        disconnect()
        logger.info("Connecting to \(String(describing: endpoint), privacy: .public)")
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            logger.debug("Client connection state: \(String(describing: state), privacy: .public)")
            switch state {
            case .ready:
                logger.info("Client connected, waiting for messages")
                self.onStatus?("connected")
                self.onConnected?()
                self.receiveNext()
            case let .failed(error):
                logger.error("Client connection failed: \(error.localizedDescription, privacy: .public)")
                if !self.hasFailed {
                    self.hasFailed = true
                    self.onStatus?("failed: \(error.localizedDescription)")
                    self.onFailed?(error)
                    self.onDisconnected?()
                }
            case .cancelled:
                logger.info("Client connection cancelled")
                // Skip the disconnected status when we already announced a
                // failure for this connection — the model would otherwise
                // overwrite the "failed" banner with a generic
                // "disconnected" right after.
                if !self.hasFailed {
                    self.onStatus?("disconnected")
                    self.onDisconnected?()
                }
            case let .waiting(error):
                logger.warning("Client connection waiting: \(error.localizedDescription, privacy: .public)")
                self.onStatus?("waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        hasFailed = false
    }

    func send(_ message: InspectMessage) {
        guard let connection else {
            logger.warning("Client send called with no connection")
            return
        }
        do {
            let data = try serializer.encode(message)
            let framed = try Framing.frame(data)
            logger.info("Client sending \(framed.count) bytes")
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    logger.error("Client send error: \(error.localizedDescription, privacy: .public)")
                }
            })
        } catch {
            logger.error("Client encode failed: \(error.localizedDescription, privacy: .public)")
            onStatus?("encode failed: \(error.localizedDescription)")
        }
    }

    /// Drives a deterministic disconnect when an error fires inside a
    /// `receive` completion. NWConnection's `stateUpdateHandler` does not
    /// always transition to `.failed` for receive-side errors (it sometimes
    /// only emits `.cancelled`, especially after a TCP RST), which would
    /// leave callers waiting forever on `onFailed` and never showing a
    /// Retry affordance. Mirror the `.failed` semantics here so the model
    /// gets the same signal regardless of which layer noticed the drop.
    /// Idempotent — `hasFailed` latches so a stateUpdateHandler `.failed`
    /// arriving alongside a receive error doesn't double-fire `onFailed`
    /// / `onDisconnected`.
    private func failConnection(_ connection: NWConnection, error: Error) {
        guard !hasFailed else {
            connection.cancel()
            return
        }
        hasFailed = true
        onStatus?("failed: \(error.localizedDescription)")
        onFailed?(error)
        onDisconnected?()
        connection.cancel()
    }

    private func receiveNext() {
        guard let connection else {
            logger.warning("Client receiveNext called with no connection")
            return
        }
        logger.debug("Client waiting for next message header…")
        connection.receive(
            minimumIncompleteLength: Framing.headerSize,
            maximumLength: Framing.headerSize
        ) { [weak self, connection] header, _, isComplete, error in
            guard let self else { return }
            // A `disconnect()` clears `self.connection`; a follow-up `connect()`
            // installs a new NWConnection there. NWConnection still delivers
            // any in-flight `receive` completions on the old object after
            // cancel — without this identity check, that stale callback would
            // call `failConnection` / `receiveNext` against the *new*
            // connection and start a second parallel receive chain on it.
            guard connection === self.connection else { return }
            if let error {
                logger.error("Client header receive error: \(error.localizedDescription, privacy: .public)")
                self.failConnection(connection, error: error)
                return
            }
            guard let header, let length = Framing.parseLength(header) else {
                logger.warning("Client received invalid header (isComplete=\(isComplete))")
                if isComplete { connection.cancel() }
                return
            }
            logger.debug("Client header parsed, expecting \(length) bytes payload")
            connection.receive(
                minimumIncompleteLength: length,
                maximumLength: length
            ) { [weak self, connection] payload, _, isComplete, error in
                // Re-do the weak unwrap explicitly — without `[weak self]`
                // here NWConnection holds this completion, which would
                // strong-capture the outer `self` (rebound non-optional
                // by `guard let self`) and keep `InspectClient` alive
                // even after `disconnect()` clears the `connection` ref.
                guard let self else { return }
                guard connection === self.connection else { return }
                if let error {
                    logger.error("Client payload receive error: \(error.localizedDescription, privacy: .public)")
                    self.failConnection(connection, error: error)
                    return
                }
                if let payload, !payload.isEmpty {
                    logger.info("Client received \(payload.count) bytes payload")
                    do {
                        let message = try self.serializer.decode(payload)
                        switch message {
                        case .handshake(let h):
                            logger.info("Client decoded handshake: \(h.deviceName, privacy: .public)")
                        case .pairResult(let outcome):
                            logger.info("Client decoded pairResult: \(String(describing: outcome), privacy: .public)")
                        case .hierarchy(let roots):
                            logger.info("Client decoded hierarchy: \(roots.count) root(s)")
                        case .error(let msg):
                            logger.error("Client received error message: \(msg, privacy: .public)")
                        case .requestPair, .requestHierarchy, .requestHierarchyLite, .subscribeUpdates, .unsubscribeUpdates, .setOptions:
                            logger.debug("Client received request/subscribe message (unexpected)")
                        case .highlightView:
                            logger.debug("Client received highlightView (unexpected)")
                        case .unknownMessage(let tag):
                            logger.warning("Client received unknown message tag from newer peer: \(tag, privacy: .public)")
                        }
                        self.onMessage?(message)
                    } catch {
                        logger.error("Client decode failed: \(error.localizedDescription, privacy: .public)")
                        self.onStatus?("decode failed: \(error.localizedDescription)")
                    }
                } else {
                    logger.warning("Client received empty payload")
                }
                if isComplete {
                    logger.info("Client connection completed by peer")
                    connection.cancel()
                } else {
                    self.receiveNext()
                }
            }
        }
    }
}
