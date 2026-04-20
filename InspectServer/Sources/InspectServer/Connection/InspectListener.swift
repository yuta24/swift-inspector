#if DEBUG
import Foundation
import Network
import InspectCore

#if canImport(UIKit)
import UIKit
#endif

public final class InspectListener {
    private let queue = DispatchQueue(label: "swift-inspector.listener")
    private let serializer: MessageSerializer
    private let serviceName: String
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(
        serviceName: String? = nil,
        serializer: MessageSerializer = JSONMessageSerializer()
    ) {
        self.serializer = serializer
        self.serviceName = serviceName ?? Self.defaultServiceName()
    }

    public func start() throws {
        stop()
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(
            name: serviceName,
            type: InspectProtocol.bonjourServiceType
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHandshake(on: connection)
                self.receiveNext(on: connection)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: key)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendHandshake(on connection: NWConnection) {
        let handshake = InspectMessage.Handshake(
            deviceName: Self.deviceName(),
            systemName: Self.systemName(),
            systemVersion: Self.systemVersion()
        )
        send(.handshake(handshake), on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: Framing.headerSize,
            maximumLength: Framing.headerSize
        ) { [weak self] header, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(connection, error: error)
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
                    self.fail(connection, error: error)
                    return
                }
                if let payload, !payload.isEmpty {
                    self.handle(payload, on: connection)
                }
                if isComplete {
                    connection.cancel()
                } else {
                    self.receiveNext(on: connection)
                }
            }
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        let message: InspectMessage
        do {
            message = try serializer.decode(data)
        } catch {
            send(.error("decode failed: \(error)"), on: connection)
            return
        }

        switch message {
        case .requestHierarchy:
            Task { @MainActor in
                let roots = Self.captureRoots()
                self.send(.hierarchy(roots: roots), on: connection)
            }
        case .handshake, .hierarchy, .error:
            break
        }
    }

    private func send(_ message: InspectMessage, on connection: NWConnection) {
        let data: Data
        do {
            data = try serializer.encode(message)
        } catch {
            return
        }
        let framed = Framing.frame(data)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func fail(_ connection: NWConnection, error: Error) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    @MainActor
    private static func captureRoots() -> [ViewNode] {
        #if canImport(UIKit)
        return HierarchyScanner.captureAllWindows()
        #else
        return []
        #endif
    }

    private static func defaultServiceName() -> String {
        #if canImport(UIKit)
        return "\(DeviceModel.marketingName()) (\(UIDevice.current.systemName) \(UIDevice.current.systemVersion))"
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(ProcessInfo.processInfo.hostName) (macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion))"
        #endif
    }

    private static func deviceName() -> String {
        #if canImport(UIKit)
        return DeviceModel.marketingName()
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    private static func systemName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemName
        #else
        return "macOS"
        #endif
    }

    private static func systemVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }
}
#endif
