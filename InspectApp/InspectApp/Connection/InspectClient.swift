import Foundation
import Network
import InspectCore

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
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStatus?("connected")
                self.onConnected?()
                self.receiveNext()
            case let .failed(error):
                self.onStatus?("failed: \(error.localizedDescription)")
                self.onDisconnected?()
            case .cancelled:
                self.onStatus?("disconnected")
                self.onDisconnected?()
            case let .waiting(error):
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
        guard let connection else { return }
        do {
            let data = try serializer.encode(message)
            let framed = Framing.frame(data)
            connection.send(content: framed, completion: .contentProcessed { _ in })
        } catch {
            onStatus?("encode failed: \(error.localizedDescription)")
        }
    }

    private func receiveNext() {
        guard let connection else { return }
        connection.receive(
            minimumIncompleteLength: Framing.headerSize,
            maximumLength: Framing.headerSize
        ) { [weak self] header, _, isComplete, error in
            guard let self, let connection = self.connection else { return }
            if let error {
                self.onStatus?("receive error: \(error.localizedDescription)")
                return
            }
            guard let header, let length = Framing.parseLength(header) else {
                if isComplete { connection.cancel() }
                return
            }
            connection.receive(
                minimumIncompleteLength: length,
                maximumLength: length
            ) { payload, _, isComplete, error in
                if let error {
                    self.onStatus?("receive error: \(error.localizedDescription)")
                    return
                }
                if let payload, !payload.isEmpty {
                    do {
                        let message = try self.serializer.decode(payload)
                        self.onMessage?(message)
                    } catch {
                        self.onStatus?("decode failed: \(error.localizedDescription)")
                    }
                }
                if isComplete {
                    connection.cancel()
                } else {
                    self.receiveNext()
                }
            }
        }
    }
}
