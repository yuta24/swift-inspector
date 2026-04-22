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

    private let queue = DispatchQueue(label: "swift-inspector.client")
    private let serializer: MessageSerializer = JSONMessageSerializer()
    private var connection: NWConnection?

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
                self.onStatus?("failed: \(error.localizedDescription)")
                self.onDisconnected?()
            case .cancelled:
                logger.info("Client connection cancelled")
                self.onStatus?("disconnected")
                self.onDisconnected?()
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
    }

    func send(_ message: InspectMessage) {
        guard let connection else {
            logger.warning("Client send called with no connection")
            return
        }
        do {
            let data = try serializer.encode(message)
            let framed = Framing.frame(data)
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

    private func receiveNext() {
        guard let connection else {
            logger.warning("Client receiveNext called with no connection")
            return
        }
        logger.debug("Client waiting for next message header…")
        connection.receive(
            minimumIncompleteLength: Framing.headerSize,
            maximumLength: Framing.headerSize
        ) { [weak self] header, _, isComplete, error in
            guard let self, let connection = self.connection else { return }
            if let error {
                logger.error("Client header receive error: \(error.localizedDescription, privacy: .public)")
                self.onStatus?("receive error: \(error.localizedDescription)")
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
            ) { payload, _, isComplete, error in
                if let error {
                    logger.error("Client payload receive error: \(error.localizedDescription, privacy: .public)")
                    self.onStatus?("receive error: \(error.localizedDescription)")
                    return
                }
                if let payload, !payload.isEmpty {
                    logger.info("Client received \(payload.count) bytes payload")
                    do {
                        let message = try self.serializer.decode(payload)
                        switch message {
                        case .handshake(let h):
                            logger.info("Client decoded handshake: \(h.deviceName, privacy: .public)")
                        case .hierarchy(let roots):
                            logger.info("Client decoded hierarchy: \(roots.count) root(s)")
                        case .error(let msg):
                            logger.error("Client received error message: \(msg, privacy: .public)")
                        case .requestHierarchy, .requestHierarchyLite, .subscribeUpdates, .unsubscribeUpdates:
                            logger.debug("Client received request/subscribe message (unexpected)")
                        case .highlightView:
                            logger.debug("Client received highlightView (unexpected)")
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
