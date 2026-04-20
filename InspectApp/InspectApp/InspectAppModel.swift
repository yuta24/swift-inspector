import Foundation
import Network
import InspectCore

@MainActor
final class InspectAppModel: ObservableObject {
    @Published var discovered: [InspectEndpoint] = []
    @Published var roots: [ViewNode] = []
    @Published var selectedEndpointID: InspectEndpoint.ID?
    @Published var selectedNodeID: UUID?
    @Published var hierarchyFilter = HierarchyFilter()
    @Published var status: String = "idle"
    @Published var isConnected: Bool = false
    @Published var connectedDeviceName: String = ""

    private let browser = InspectBrowser()
    private var client: InspectClient?
    private var connectedEndpointID: InspectEndpoint.ID?

    var selectedNode: ViewNode? {
        guard let id = selectedNodeID else { return nil }
        return Self.findNode(id: id, in: roots)
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

    private func handle(_ message: InspectMessage) {
        switch message {
        case let .handshake(handshake):
            connectedDeviceName = "\(handshake.deviceName) — \(handshake.systemName) \(handshake.systemVersion)"
            status = "connected: \(handshake.deviceName)"
        case let .hierarchy(roots):
            self.roots = roots
            if let id = selectedNodeID, Self.findNode(id: id, in: roots) == nil {
                selectedNodeID = roots.first?.id
            } else if selectedNodeID == nil {
                selectedNodeID = roots.first?.id
            }
        case let .error(message):
            status = "error: \(message)"
        case .requestHierarchy:
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

    private static func findNode(id: UUID, in nodes: [ViewNode]) -> ViewNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNode(id: id, in: node.children) { return found }
        }
        return nil
    }
}
