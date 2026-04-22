#if DEBUG
import Foundation
import Network
import InspectCore
import os.log

#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "swift-inspector", category: "server")

public final class InspectListener {
    private let queue = DispatchQueue(label: "swift-inspector.listener")
    private let serializer: MessageSerializer
    private let serviceName: String
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    #if DEBUG && canImport(UIKit)
    /// Subscribers for push-updates mode (protocol v3+). Mutated only on the
    /// main actor so it stays in sync with the MainActor-isolated monitor.
    @MainActor private var subscribers: [ObjectIdentifier: NWConnection] = [:]
    @MainActor private var monitor: HierarchyChangeMonitor?
    #endif

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
            logger.info("Accepted new connection")
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        logger.info("Listener started: service=\(self.serviceName, privacy: .public)")
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
            logger.debug("Server connection state: \(String(describing: state), privacy: .public)")
            switch state {
            case .ready:
                logger.info("Connection ready, sending handshake")
                self.sendHandshake(on: connection)
                self.receiveNext(on: connection)
            case let .failed(error):
                logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                self.connections.removeValue(forKey: key)
                #if DEBUG && canImport(UIKit)
                Task { @MainActor [weak self] in
                    self?.removeSubscriber(connection)
                }
                #endif
            case .cancelled:
                logger.info("Connection cancelled")
                self.connections.removeValue(forKey: key)
                #if DEBUG && canImport(UIKit)
                Task { @MainActor [weak self] in
                    self?.removeSubscriber(connection)
                }
                #endif
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
        logger.debug("Server waiting for next message header…")
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
                logger.warning("Server received invalid header (isComplete=\(isComplete))")
                if isComplete { connection.cancel() }
                return
            }
            logger.debug("Server header parsed, expecting \(length) bytes payload")
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
                } else {
                    logger.warning("Server received empty payload")
                }
                if isComplete {
                    logger.info("Server connection completed by peer")
                    connection.cancel()
                } else {
                    self.receiveNext(on: connection)
                }
            }
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        logger.debug("Server received payload: \(data.count) bytes")
        let message: InspectMessage
        do {
            message = try serializer.decode(data)
        } catch {
            logger.error("Server decode failed: \(error.localizedDescription, privacy: .public)")
            send(.error("decode failed: \(error)"), on: connection)
            return
        }

        switch message {
        case .requestHierarchy:
            logger.info("Received requestHierarchy, capturing roots…")
            Task { @MainActor in
                let roots = Self.captureRoots(captureScreenshots: true)
                logger.info("Captured \(roots.count) root(s), encoding…")
                let nodeCount = Self.countNodes(in: roots)
                logger.info("Total node count: \(nodeCount)")
                self.send(.hierarchy(roots: roots), on: connection)
            }
        case .requestHierarchyLite:
            logger.info("Received requestHierarchyLite, capturing roots without screenshots…")
            Task { @MainActor in
                let roots = Self.captureRoots(captureScreenshots: false)
                let nodeCount = Self.countNodes(in: roots)
                logger.info("Lite capture: \(roots.count) root(s), \(nodeCount) node(s)")
                self.send(.hierarchy(roots: roots), on: connection)
            }
        case .subscribeUpdates(let intervalMs):
            logger.info("Received subscribeUpdates (intervalMs=\(intervalMs))")
            #if DEBUG && canImport(UIKit)
            let clampedInterval = max(0.016, Double(intervalMs) / 1000.0)
            Task { @MainActor [weak self] in
                self?.addSubscriber(connection, intervalSec: clampedInterval)
            }
            #else
            send(.error("subscribeUpdates is not supported on this platform"), on: connection)
            #endif
        case .unsubscribeUpdates:
            logger.info("Received unsubscribeUpdates")
            #if DEBUG && canImport(UIKit)
            Task { @MainActor [weak self] in
                self?.removeSubscriber(connection)
            }
            #endif
        case .highlightView(let ident):
            logger.info("Received highlightView: \(ident?.uuidString ?? "nil", privacy: .public)")
            Task { @MainActor in
                Self.applyHighlight(ident: ident)
            }
        case .handshake, .hierarchy, .error:
            logger.debug("Server ignoring message: \(String(describing: message).prefix(80), privacy: .public)")
            break
        }
    }

    private func send(_ message: InspectMessage, on connection: NWConnection) {
        let data: Data
        do {
            data = try serializer.encode(message)
        } catch {
            logger.error("Server encode failed: \(String(describing: error), privacy: .public)")
            if case .hierarchy(let roots) = message {
                Self.logEncodingDiagnostics(roots: roots)
            }
            return
        }
        let framed = Framing.frame(data)
        logger.info("Server sending \(framed.count) bytes (payload: \(data.count) bytes)")
        connection.send(content: framed, completion: .contentProcessed { error in
            if let error {
                logger.error("Server send error: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.debug("Server send completed successfully")
            }
        })
    }

    private func fail(_ connection: NWConnection, error: Error) {
        logger.error("Connection failure: \(error.localizedDescription, privacy: .public)")
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private static func countNodes(in nodes: [ViewNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countNodes(in: $1.children) }
    }

    private static func logEncodingDiagnostics(roots: [ViewNode]) {
        func check(_ node: ViewNode) {
            let hasNaN = !node.alpha.isFinite
                || !node.cornerRadius.isFinite
                || !node.borderWidth.isFinite
                || !node.frame.origin.x.isFinite
                || !node.frame.origin.y.isFinite
                || !node.frame.size.width.isFinite
                || !node.frame.size.height.isFinite
            if hasNaN {
                logger.error("""
                    Node with non-finite value: \(node.className, privacy: .public) \
                    frame=\(String(describing: node.frame), privacy: .public) \
                    alpha=\(node.alpha) \
                    cornerRadius=\(node.cornerRadius) \
                    borderWidth=\(node.borderWidth)
                    """)
            }
            for child in node.children {
                check(child)
            }
        }
        for root in roots {
            check(root)
        }
    }

    @MainActor
    private static func applyHighlight(ident: UUID?) {
        #if canImport(UIKit)
        if let ident {
            HighlightOverlay.highlight(viewWithIdent: ident)
        } else {
            HighlightOverlay.clear()
        }
        #endif
    }

    #if DEBUG && canImport(UIKit)
    @MainActor
    private func addSubscriber(_ connection: NWConnection, intervalSec: TimeInterval) {
        let key = ObjectIdentifier(connection)
        let wasEmpty = subscribers.isEmpty
        subscribers[key] = connection
        if wasEmpty {
            let monitor = HierarchyChangeMonitor()
            monitor.start(minIntervalSec: intervalSec) { [weak self] in
                self?.pushHierarchyToSubscribers()
            }
            self.monitor = monitor
        }
    }

    @MainActor
    private func removeSubscriber(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard subscribers.removeValue(forKey: key) != nil else { return }
        if subscribers.isEmpty {
            monitor?.stop()
            monitor = nil
        }
    }

    @MainActor
    private func pushHierarchyToSubscribers() {
        guard !subscribers.isEmpty else { return }
        let roots = HierarchyScanner.captureAllWindows(captureScreenshots: false)
        let message = InspectMessage.hierarchy(roots: roots)
        for connection in subscribers.values {
            self.send(message, on: connection)
        }
    }
    #endif

    @MainActor
    private static func captureRoots(captureScreenshots: Bool) -> [ViewNode] {
        #if canImport(UIKit)
        return HierarchyScanner.captureAllWindows(captureScreenshots: captureScreenshots)
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
