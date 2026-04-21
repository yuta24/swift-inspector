import Foundation
import Combine
import Network
import InspectCore
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "model")

@MainActor
final class InspectAppModel: ObservableObject {
    @Published var discovered: [InspectEndpoint] = []
    @Published var roots: [ViewNode] = []
    @Published var selectedEndpointID: InspectEndpoint.ID?
    @Published var selectedNodeID: UUID?
    /// The "reference" node for the distance measurement tool. When this
    /// and `selectedNodeID` are both set and differ, the inspector shows a
    /// `Measurement` section and the 3D scene overlays a line between the
    /// two nodes' centers.
    @Published var measurementReferenceID: UUID?
    @Published var hierarchyFilter = HierarchyFilter()
    @Published var status: String = "idle"
    @Published var isConnected: Bool = false
    @Published var connectedDeviceName: String = ""

    private let browser = InspectBrowser()
    private var client: InspectClient?
    private var connectedEndpointID: InspectEndpoint.ID?
    private var highlightCancellable: AnyCancellable?

    var selectedNode: ViewNode? {
        guard let id = selectedNodeID else { return nil }
        return Self.findNode(id: id, in: roots)
    }

    var measurementReferenceNode: ViewNode? {
        guard let id = measurementReferenceID else { return nil }
        return Self.findNode(id: id, in: roots)
    }

    /// Pins the currently selected node as the measurement reference.
    /// Tapping the button again on the same node clears it.
    func toggleMeasurementReference() {
        if measurementReferenceID == selectedNodeID {
            measurementReferenceID = nil
        } else {
            measurementReferenceID = selectedNodeID
        }
    }

    init() {
        highlightCancellable = $selectedNodeID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] nodeID in
                guard let self, self.isConnected else { return }
                self.client?.send(.highlightView(ident: nodeID))
            }
    }

    func startBrowsing() {
        browser.onChange = { [weak self] endpoints in
            Task { @MainActor in
                guard let self else { return }
                let merged = endpoints.map { endpoint -> InspectEndpoint in
                    var copy = endpoint
                    if copy.id == self.connectedEndpointID {
                        copy.isConnected = true
                    }
                    return copy
                }
                self.discovered = merged
            }
        }
        browser.start()
        status = "browsing"
    }

    func connect(to endpoint: InspectEndpoint) {
        disconnect()
        let client = InspectClient()
        client.onStatus = { [weak self] message in
            Task { @MainActor in self?.status = message }
        }
        client.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isConnected = true
                self.connectedEndpointID = endpoint.id
                self.markConnected(endpointID: endpoint.id)
                self.requestHierarchy()
            }
        }
        client.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isConnected = false
                self.connectedEndpointID = nil
                self.markConnected(endpointID: nil)
            }
        }
        client.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        client.connect(to: endpoint.endpoint)
        self.client = client
        status = "connecting to \(endpoint.name)"
    }

    func disconnect() {
        client?.send(.highlightView(ident: nil))
        client?.disconnect()
        client = nil
        isConnected = false
        connectedEndpointID = nil
        connectedDeviceName = ""
        markConnected(endpointID: nil)
    }

    func shutdown() {
        disconnect()
        browser.stop()
        status = "idle"
    }

    func requestHierarchy() {
        client?.send(.requestHierarchy)
    }

    func highlightSelectedNode() {
        client?.send(.highlightView(ident: selectedNodeID))
    }

    func clearHighlight() {
        client?.send(.highlightView(ident: nil))
    }

    private func handle(_ message: InspectMessage) {
        switch message {
        case let .handshake(handshake):
            logger.info("Model received handshake: \(handshake.deviceName, privacy: .public) \(handshake.systemName, privacy: .public) \(handshake.systemVersion, privacy: .public)")
            connectedDeviceName = "\(handshake.deviceName) — \(handshake.systemName) \(handshake.systemVersion)"
            status = "connected: \(handshake.deviceName)"
        case let .hierarchy(roots):
            let nodeCount = Self.countNodes(in: roots)
            logger.info("Model received hierarchy: \(roots.count) root(s), \(nodeCount) total node(s)")
            self.roots = roots
            if let id = selectedNodeID, Self.findNode(id: id, in: roots) == nil {
                logger.debug("Previously selected node not found, selecting first root")
                selectedNodeID = roots.first?.id
            } else if selectedNodeID == nil {
                selectedNodeID = roots.first?.id
            }
            // Clear measurement reference if the pinned node no longer
            // exists in the new hierarchy — otherwise the measurement
            // section would compare against a phantom frame.
            if let refID = measurementReferenceID, Self.findNode(id: refID, in: roots) == nil {
                measurementReferenceID = nil
            }
        case let .error(message):
            logger.error("Model received error: \(message, privacy: .public)")
            status = "error: \(message)"
        case .requestHierarchy, .highlightView:
            break
        }
    }

    private func markConnected(endpointID: InspectEndpoint.ID?) {
        discovered = discovered.map { endpoint in
            var copy = endpoint
            copy.isConnected = (endpoint.id == endpointID)
            return copy
        }
    }

    private static func countNodes(in nodes: [ViewNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countNodes(in: $1.children) }
    }

    private static func findNode(id: UUID, in nodes: [ViewNode]) -> ViewNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNode(id: id, in: node.children) { return found }
        }
        return nil
    }
}
