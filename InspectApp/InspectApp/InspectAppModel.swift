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
    /// The node currently being Option-hovered in the 3D scene. LookIn-style
    /// transient "compare" target — takes priority over `measurementReferenceID`
    /// while set, and cleared when Option is released.
    @Published var measurementHoverID: UUID?
    @Published var hierarchyFilter = HierarchyFilter()
    @Published var status: String = "idle"
    @Published var isConnected: Bool = false
    @Published var connectedDeviceName: String = ""
    @Published var isLiveMode: Bool = false
    @Published var liveInterval: TimeInterval = 1.0

    private let browser = InspectBrowser()
    private var client: InspectClient?
    private var connectedEndpointID: InspectEndpoint.ID?
    private var highlightCancellable: AnyCancellable?
    private var liveTimer: Timer?
    /// True while a `requestHierarchy` has been sent but the response hasn't
    /// arrived yet. Live mode ticks that arrive during this window are dropped
    /// to avoid queueing up redundant captures on the device.
    private var isInflight: Bool = false
    /// Wall-clock time of the last `requestHierarchy` send. If a response
    /// never arrives (dropped connection, device paused in debugger) we
    /// don't want `isInflight` to latch forever and stall live mode.
    private var inflightSentAt: Date?
    private static let inflightTimeout: TimeInterval = 5.0

    var selectedNode: ViewNode? {
        guard let id = selectedNodeID else { return nil }
        return Self.findNode(id: id, in: roots)
    }

    var measurementReferenceNode: ViewNode? {
        guard let id = measurementReferenceID else { return nil }
        return Self.findNode(id: id, in: roots)
    }

    /// The "compare" node currently shown alongside the selection. Option-hover
    /// wins over the pinned reference so transient exploration doesn't require
    /// re-pinning; when Option is released, `measurementHoverID` clears and the
    /// pinned reference (if any) reappears.
    var measurementCompareNode: ViewNode? {
        if let id = measurementHoverID,
           let node = Self.findNode(id: id, in: roots) {
            return node
        }
        return measurementReferenceNode
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
        stopLiveTimer()
        isLiveMode = false
        isInflight = false
        inflightSentAt = nil
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

    func requestHierarchy(lite: Bool = false) {
        if isInflight, let sentAt = inflightSentAt, Date().timeIntervalSince(sentAt) < Self.inflightTimeout {
            logger.debug("Skipping requestHierarchy: previous response still in-flight")
            return
        }
        isInflight = true
        inflightSentAt = Date()
        client?.send(lite ? .requestHierarchyLite : .requestHierarchy)
    }

    func toggleLiveMode() {
        isLiveMode.toggle()
        if isLiveMode {
            startLiveTimer()
        } else {
            stopLiveTimer()
        }
    }

    private func startLiveTimer() {
        stopLiveTimer()
        guard isConnected else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: liveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLiveMode, self.isConnected else { return }
                self.requestHierarchy(lite: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func setLiveInterval(_ interval: TimeInterval) {
        liveInterval = interval
        if isLiveMode {
            startLiveTimer()
        }
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
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
        case let .hierarchy(newRoots):
            let nodeCount = Self.countNodes(in: newRoots)
            logger.info("Model received hierarchy: \(newRoots.count) root(s), \(nodeCount) total node(s)")
            isInflight = false
            inflightSentAt = nil
            applyHierarchyPreservingSelection(newRoots: newRoots)
        case let .error(message):
            logger.error("Model received error: \(message, privacy: .public)")
            isInflight = false
            inflightSentAt = nil
            status = "error: \(message)"
        case .requestHierarchy, .requestHierarchyLite, .highlightView:
            break
        }
    }

    /// Replaces `roots` with `newRoots` while re-mapping `selectedNodeID`,
    /// `measurementReferenceID`, and `measurementHoverID` across the new tree.
    ///
    /// Every capture by `HierarchyScanner` assigns fresh UUIDs, so we can't
    /// use ident equality across snapshots. Instead we compute a *stable path*
    /// (accessibility-identifier or class-and-sibling-index chain) for each
    /// previously-tracked node in the old tree, then look up the same path in
    /// the new tree to recover its new UUID. This is what lets live mode tick
    /// without blowing away the user's selection on every update.
    private func applyHierarchyPreservingSelection(newRoots: [ViewNode]) {
        let oldRoots = self.roots

        // Carry screenshots forward from the previous snapshot when the new
        // one came back without them (lite capture path). Without this, the
        // 3D scene would render blank planes on every live tick.
        let mergedRoots = Self.carryingScreenshots(into: newRoots, from: oldRoots)

        let preservedSelectionID = Self.remap(
            id: selectedNodeID,
            oldRoots: oldRoots,
            newRoots: mergedRoots
        )
        let preservedReferenceID = Self.remap(
            id: measurementReferenceID,
            oldRoots: oldRoots,
            newRoots: mergedRoots
        )
        let preservedHoverID = Self.remap(
            id: measurementHoverID,
            oldRoots: oldRoots,
            newRoots: mergedRoots
        )

        self.roots = mergedRoots

        if let preservedSelectionID {
            selectedNodeID = preservedSelectionID
        } else if selectedNodeID == nil || Self.findNode(id: selectedNodeID!, in: mergedRoots) == nil {
            selectedNodeID = mergedRoots.first?.id
        }
        measurementReferenceID = preservedReferenceID
        measurementHoverID = preservedHoverID
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

    // MARK: Stable path remapping

    /// Re-maps an id from the previous snapshot onto the new one using a
    /// path-based fingerprint. Returns nil when the path doesn't exist in
    /// the new tree (e.g. the view was removed).
    static func remap(
        id: UUID?,
        oldRoots: [ViewNode],
        newRoots: [ViewNode]
    ) -> UUID? {
        guard let id else { return nil }
        guard let path = stablePath(for: id, in: oldRoots) else { return nil }
        return findNode(byPath: path, in: newRoots)?.id
    }

    /// A stable fingerprint of a node's location in the tree, independent of
    /// the (per-capture) UUID. Prefers `accessibilityIdentifier` when present
    /// so identifiers survive sibling reordering; falls back to className +
    /// sibling index.
    static func stablePath(for id: UUID, in roots: [ViewNode]) -> [String]? {
        for (index, root) in roots.enumerated() {
            if let path = path(to: id, in: root, prefix: [segment(for: root, siblingIndex: index)]) {
                return path
            }
        }
        return nil
    }

    private static func path(
        to id: UUID,
        in node: ViewNode,
        prefix: [String]
    ) -> [String]? {
        if node.id == id { return prefix }
        for (index, child) in node.children.enumerated() {
            let next = prefix + [segment(for: child, siblingIndex: index)]
            if let found = path(to: id, in: child, prefix: next) { return found }
        }
        return nil
    }

    private static func segment(for node: ViewNode, siblingIndex: Int) -> String {
        if let ident = node.accessibilityIdentifier, !ident.isEmpty {
            return "#\(ident)"
        }
        return "\(node.className)[\(siblingIndex)]"
    }

    // MARK: Screenshot carry-over

    /// For live mode: the server omits screenshot payloads to keep captures
    /// cheap. We reattach images from the previous snapshot by matching nodes
    /// along the same stable path. A node that existed before keeps its old
    /// image until the next full refresh; newly-added nodes stay blank until
    /// the user triggers a full refresh (Cmd+R).
    static func carryingScreenshots(into newRoots: [ViewNode], from oldRoots: [ViewNode]) -> [ViewNode] {
        var cache: [String: (Data?, Data?)] = [:]
        collectImages(from: oldRoots, prefix: [], into: &cache)
        if cache.isEmpty { return newRoots }
        return newRoots.enumerated().map { index, root in
            rebuild(
                node: root,
                path: [segment(for: root, siblingIndex: index)],
                cache: cache
            )
        }
    }

    private static func collectImages(
        from nodes: [ViewNode],
        prefix: [String],
        into cache: inout [String: (Data?, Data?)]
    ) {
        for (index, node) in nodes.enumerated() {
            let path = prefix + [segment(for: node, siblingIndex: index)]
            if node.screenshot != nil || node.soloScreenshot != nil {
                cache[path.joined(separator: "/")] = (node.screenshot, node.soloScreenshot)
            }
            collectImages(from: node.children, prefix: path, into: &cache)
        }
    }

    private static func rebuild(
        node: ViewNode,
        path: [String],
        cache: [String: (Data?, Data?)]
    ) -> ViewNode {
        let rebuiltChildren = node.children.enumerated().map { index, child in
            rebuild(
                node: child,
                path: path + [segment(for: child, siblingIndex: index)],
                cache: cache
            )
        }

        // Only borrow images when the new node didn't carry any itself
        // (i.e. this was a lite capture, not a fresh full capture).
        if node.screenshot == nil && node.soloScreenshot == nil,
           let (oldScreenshot, oldSolo) = cache[path.joined(separator: "/")] {
            return node
                .replacingChildren(rebuiltChildren)
                .replacingImages(screenshot: oldScreenshot, soloScreenshot: oldSolo)
        }
        return node.replacingChildren(rebuiltChildren)
    }

    static func findNode(byPath path: [String], in roots: [ViewNode]) -> ViewNode? {
        guard let first = path.first else { return nil }
        for (index, root) in roots.enumerated() {
            if segment(for: root, siblingIndex: index) == first {
                return resolve(path: Array(path.dropFirst()), in: root)
            }
        }
        return nil
    }

    private static func resolve(path: [String], in node: ViewNode) -> ViewNode? {
        guard let first = path.first else { return node }
        for (index, child) in node.children.enumerated() {
            if segment(for: child, siblingIndex: index) == first {
                return resolve(path: Array(path.dropFirst()), in: child)
            }
        }
        return nil
    }
}
