import Foundation
import Combine
import Network
import InspectCore
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "model")

/// How live mode is currently being driven. `.push` means the server is
/// streaming updates (v3+ subscription), `.poll` means the client is
/// requesting snapshots on a timer. Surfaced in the UI so the user can
/// tell whether they're relying on device cooperation or local cadence.
enum LiveTransport: Equatable {
    case none
    case push
    case poll
}

/// View-facing facade for the AppInspector UI.
///
/// The model intentionally keeps a wide surface of `@Published` properties so
/// SwiftUI views can bind directly. The actual machinery is split across two
/// helpers it owns:
///
/// - ``ConnectionController`` runs the Bonjour browser, the per-peer
///   `InspectClient`, and the handshake / pairing handshake. It signals
///   relevant transitions back here through callbacks.
/// - ``LiveModeController`` owns the live-update loop (push subscription or
///   polling timer) and the transport-change publication.
///
/// What stays here is the *UI* layer: published state, selection / focus /
/// measurement remapping across snapshots, and the small handful of
/// orchestration steps (inflight bookkeeping, post-pair hierarchy fetch,
/// highlight push) that need to coordinate between the two helpers.
@MainActor
final class AppInspectorModel: ObservableObject {
    @Published var discovered: [InspectEndpoint] = []
    /// User-typed endpoints that bypassed Bonjour discovery — added via
    /// the "Connect by IP" sheet for environments where mDNS is blocked
    /// (corp Wi-Fi with client isolation, guest networks, etc.). Lives
    /// outside `discovered` so the browser's periodic refresh doesn't
    /// wipe them, and so the UI can mark them visually.
    @Published private(set) var manualEndpoints: [InspectEndpoint] = []
    @Published var roots: [ViewNode] = []
    @Published var selectedEndpointID: InspectEndpoint.ID?
    @Published var selectedNodeID: UUID?
    /// When set, tree and 3D scene show only this node and its descendants
    /// instead of the full hierarchy. Cleared on disconnect, or when the
    /// focused node no longer appears in a fresh capture (live-mode remap
    /// fails).
    @Published var focusedNodeID: UUID?
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
    /// True between the moment `connect(to:)` is called and the TCP
    /// connection reaches `.ready`. Drives the "connecting…" spinner so
    /// users can tell a click was registered.
    @Published var isConnecting: Bool = false
    @Published var connectedDeviceName: String = ""
    /// Most recent server handshake. Cleared on disconnect. Used by the
    /// bug-bundle exporter to attach device metadata to a saved snapshot
    /// without inventing a second source of truth alongside
    /// `connectedDeviceName` (which is a display string, not structured
    /// data). Nil when no live connection has produced a handshake yet.
    @Published private(set) var lastHandshake: InspectMessage.Handshake?
    /// True while the inspector is showing a `BugBundle` loaded from
    /// disk rather than a live device. Mutually exclusive with
    /// `isConnected` — entering offline mode tears down any live
    /// connection first, and any `connect(to:)` exits offline mode.
    @Published private(set) var isOfflineMode: Bool = false
    /// On-disk URL of the bundle currently being viewed in offline
    /// mode. Surfaced in the sidebar so the user can tell which file
    /// they're looking at.
    @Published private(set) var offlineBundleURL: URL?
    /// Manifest of the bundle currently being viewed in offline mode.
    /// Provides the device label / notes / created-at the offline
    /// banner displays without re-reading the file.
    @Published private(set) var offlineBundleManifest: BugBundle.Manifest?
    /// True between sending `requestPair` and receiving the device's
    /// `pairResult`. The UI surfaces a "デバイス側で承認してください…" banner
    /// during this window so the user knows to look at the device, not the
    /// Mac. False against pre-pairing servers (protocol < 4) where the
    /// step is skipped entirely.
    @Published private(set) var isAwaitingPairApproval: Bool = false
    @Published var isLiveMode: Bool = false
    @Published var liveInterval: TimeInterval = 1.0
    /// Transport currently backing live mode. Never `.poll` or `.push`
    /// while `isLiveMode` is false.
    @Published var liveTransport: LiveTransport = .none
    /// True while a `requestHierarchy` has been sent but the response hasn't
    /// arrived yet. Surfaced to the UI so the toolbar can show a spinner.
    @Published private(set) var isInflight: Bool = false
    /// Endpoint the live connection is bound to. Diverges from
    /// `selectedEndpointID` when the Picker is staging a different choice —
    /// the UI uses the mismatch to render a "Switch" action.
    @Published private(set) var connectedEndpointID: InspectEndpoint.ID?
    /// Last connect attempt's failure message, if any. Cleared when a fresh
    /// connect is initiated or the user changes the staged selection. Drives
    /// the Retry action in the sidebar.
    @Published var connectionError: String?
    /// Stable paths of tree rows the user has expanded. Set membership, not
    /// UUID-keyed, so the expansion survives captures that regenerate every
    /// node's `ident`. Entries that no longer match any node in the current
    /// tree are harmless — they just don't resolve.
    @Published var expandedPaths: Set<String> = []

    private let connection = ConnectionController()
    private lazy var live: LiveModeController = LiveModeController(
        send: { [weak self] message in self?.connection.send(message) },
        requestSnapshot: { [weak self] in self?.requestHierarchy(lite: true) }
    )

    private var highlightCancellable: AnyCancellable?
    /// Wall-clock time of the last `requestHierarchy` send. If a response
    /// never arrives (dropped connection, device paused in debugger) we
    /// don't want `isInflight` to latch forever and stall live mode.
    private var inflightSentAt: Date?
    private static let inflightTimeout: TimeInterval = 5.0

    var selectedNode: ViewNode? {
        guard let id = selectedNodeID else { return nil }
        return HierarchyRemapping.findNode(id: id, in: roots)
    }

    var focusedNode: ViewNode? {
        guard let id = focusedNodeID else { return nil }
        return HierarchyRemapping.findNode(id: id, in: roots)
    }

    /// Nodes the tree and 3D scene render. When a focus is set, only the
    /// focused subtree is returned (as a single-element array); otherwise the
    /// full `roots`. Computed on access so there's no second source of truth
    /// to keep in sync on every capture.
    var displayRoots: [ViewNode] {
        if let focused = focusedNode {
            return [focused]
        }
        return roots
    }

    /// Enters focus mode on the given node. Also makes it the current
    /// selection so the inspector and scene highlight line up with the new
    /// root. Pass `nil` to clear focus (equivalent to `clearFocus()`).
    func focus(on nodeID: UUID?) {
        focusedNodeID = nodeID
        if let nodeID {
            selectedNodeID = nodeID
        }
    }

    func clearFocus() {
        focusedNodeID = nil
    }

    var measurementReferenceNode: ViewNode? {
        guard let id = measurementReferenceID else { return nil }
        return HierarchyRemapping.findNode(id: id, in: roots)
    }

    /// The "compare" node currently shown alongside the selection. Option-hover
    /// wins over the pinned reference so transient exploration doesn't require
    /// re-pinning; when Option is released, `measurementHoverID` clears and the
    /// pinned reference (if any) reappears.
    var measurementCompareNode: ViewNode? {
        if let id = measurementHoverID,
           let node = HierarchyRemapping.findNode(id: id, in: roots) {
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
        wireConnectionCallbacks()
        wireLiveCallbacks()
        wireHighlightSubscription()
    }

    func startBrowsing() {
        connection.startBrowsing()
    }

    /// Combined list of Bonjour-discovered + manually-added endpoints,
    /// in that order. The Picker binds to this so manually-typed
    /// endpoints sit alongside discovered ones rather than living in a
    /// separate UI surface — switching between a corp-network IP entry
    /// and a guest-network Bonjour discovery is a single click.
    var allEndpoints: [InspectEndpoint] {
        // De-dup by id so a Bonjour result that resolves to the same
        // host:port a user already typed doesn't show twice. Discovered
        // wins on tie because its `name` carries the device's Bonjour
        // service name (more readable than `192.168.1.42:8765`).
        let discoveredIDs = Set(discovered.map(\.id))
        let extras = manualEndpoints.filter { !discoveredIDs.contains($0.id) }
        return discovered + extras
    }

    /// Adds a user-typed endpoint to the manual list and returns its
    /// id so the caller (typically the "Connect by IP" sheet) can
    /// immediately stage it as the active selection. Inputs that don't
    /// parse as `host:port` return nil rather than producing a broken
    /// endpoint that would fail at NWConnection construction time.
    @discardableResult
    func addManualEndpoint(host: String, port: UInt16) -> InspectEndpoint.ID? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }
        let id = "manual:\(trimmedHost):\(port)"
        // Idempotent re-add: typing the same host:port twice should
        // surface the existing entry, not duplicate it.
        if let existing = manualEndpoints.first(where: { $0.id == id }) {
            return existing.id
        }
        let endpoint = InspectEndpoint(
            id: id,
            name: "\(trimmedHost):\(port)",
            endpoint: NWEndpoint.hostPort(host: NWEndpoint.Host(trimmedHost), port: nwPort)
        )
        manualEndpoints.append(endpoint)
        return endpoint.id
    }

    /// Removes a previously-added manual endpoint. No-op for ids that
    /// don't exist; not exposed as a UI action yet but tests and a
    /// future "remove from list" affordance need a clean entry point.
    func removeManualEndpoint(id: InspectEndpoint.ID) {
        manualEndpoints.removeAll { $0.id == id }
    }

    func connect(to endpoint: InspectEndpoint) {
        // Connecting to a live device implicitly leaves offline-viewer
        // mode — the two cannot share the canvas. Done before clearing
        // `connectionError` so closeOfflineBundle's status reset doesn't
        // overwrite the "connecting…" label we set below.
        if isOfflineMode {
            closeOfflineBundle()
        }
        connectionError = nil
        connection.connect(to: endpoint)
        status = "connecting to \(endpoint.name)"
    }

    func disconnect() {
        // Drop live mode before tearing down the socket so the controller
        // can send a clean `unsubscribeUpdates` while the connection is
        // still alive.
        if isLiveMode {
            isLiveMode = false
        }
        live.stop()
        connection.disconnect()
        // Mirror the user-initiated path: we want a deterministic UI state
        // even before the late `.cancelled` callback lands.
        finalizeDisconnectState()
        // User-initiated disconnect detaches onStatus first, so the
        // client's own `.cancelled` transition no longer drives the label.
        // Reflect the new idle-but-still-discovering state explicitly.
        status = "browsing"
    }

    func shutdown() {
        disconnect()
        connection.shutdown()
        status = "idle"
    }

    func requestHierarchy(lite: Bool = false) {
        if isInflight, let sentAt = inflightSentAt, Date().timeIntervalSince(sentAt) < Self.inflightTimeout {
            logger.debug("Skipping requestHierarchy: previous response still in-flight")
            return
        }
        let sentAt = Date()
        isInflight = true
        inflightSentAt = sentAt
        connection.send(lite ? .requestHierarchyLite : .requestHierarchy)
        scheduleInflightAutoClear(for: sentAt)
    }

    func toggleLiveMode() {
        isLiveMode.toggle()
        if isLiveMode {
            startLive()
        } else {
            live.stop()
        }
    }

    func setLiveInterval(_ interval: TimeInterval) {
        liveInterval = interval
        live.setInterval(interval)
    }

    func highlightSelectedNode() {
        connection.send(.highlightView(ident: selectedNodeID))
    }

    func clearHighlight() {
        connection.send(.highlightView(ident: nil))
    }

    /// Sends the user's current capture preferences to the connected server.
    /// No-op when the server is too old to understand the message (protocol
    /// < 5) — those servers would reject it at decode time and surface an
    /// error in the status bar. Safe to call any time after pair approval;
    /// each call replaces the server-side options wholesale.
    func sendCurrentOptionsIfSupported() {
        guard let version = connection.serverProtocolVersion,
              version >= InspectProtocol.optionsMinVersion else {
            return
        }
        let options = InspectMessage.SnapshotOptions(
            screenshotJPEGQuality: UserPreferences.screenshotJPEGQuality
        )
        connection.send(.setOptions(options))
    }

    // MARK: - Callback wiring

    private func wireConnectionCallbacks() {
        connection.onDiscoveredChanged = { [weak self] endpoints in
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
        connection.onStatus = { [weak self] message in
            self?.status = message
        }
        connection.onConnectingChanged = { [weak self] flag in
            self?.isConnecting = flag
        }
        connection.onConnected = { [weak self] endpoint in
            guard let self else { return }
            self.isConnected = true
            self.connectedEndpointID = endpoint.id
            self.markConnected(endpointID: endpoint.id)
        }
        connection.onDisconnected = { [weak self] in
            self?.finalizeDisconnectState()
        }
        connection.onConnectionError = { [weak self] reason in
            self?.connectionError = reason
        }
        connection.onHandshake = { [weak self] handshake, label in
            guard let self else { return }
            self.lastHandshake = handshake
            self.connectedDeviceName = label
            // Pre-v4 servers don't pair: the handshake itself is the green
            // light to start fetching hierarchies. v4+ peers wait for
            // `onPairOutcome(.approved)` instead.
            if handshake.protocolVersion < InspectProtocol.pairingMinVersion {
                self.status = "connected: \(handshake.deviceName)"
                self.requestHierarchy()
            }
        }
        connection.onAwaitingPairChanged = { [weak self] flag in
            self?.isAwaitingPairApproval = flag
        }
        connection.onPairOutcome = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .approved:
                self.status = "connected: \(self.connectedDeviceName)"
                self.sendCurrentOptionsIfSupported()
                self.requestHierarchy()
            case let .rejected(reason):
                self.connectionError = reason
                self.status = "rejected: \(reason)"
                // The server cancels the socket itself after sending the
                // rejection; calling disconnect() here makes the teardown
                // deterministic from the UI side and clears the live timer
                // before the late `.cancelled` callback arrives.
                self.disconnect()
            }
        }
        connection.onPairTimeout = { [weak self] in
            guard let self else { return }
            self.connectionError = String(localized: "Device did not approve in time")
            self.status = "pair timeout"
            self.disconnect()
        }
        connection.onMessage = { [weak self] message in
            self?.handle(message)
        }
    }

    private func wireLiveCallbacks() {
        live.onTransportChanged = { [weak self] transport in
            self?.liveTransport = transport
        }
    }

    private func wireHighlightSubscription() {
        highlightCancellable = $selectedNodeID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] nodeID in
                guard let self, self.isConnected else { return }
                self.connection.send(.highlightView(ident: nodeID))
            }
    }

    // MARK: - State helpers

    /// Resets the published transient state that should not survive a
    /// disconnect, regardless of whether the disconnect was initiated by the
    /// user, the peer, or a connection failure.
    private func finalizeDisconnectState() {
        isConnected = false
        isLiveMode = false
        live.stop()
        isInflight = false
        inflightSentAt = nil
        connectedEndpointID = nil
        connectedDeviceName = ""
        lastHandshake = nil
        markConnected(endpointID: nil)
        resetCapturedState()
    }

    /// Clears everything derived from a captured hierarchy so the detail,
    /// sidebar tree, and measurement overlays don't linger after the
    /// connection closes.
    private func resetCapturedState() {
        roots = []
        selectedNodeID = nil
        focusedNodeID = nil
        measurementReferenceID = nil
        measurementHoverID = nil
        expandedPaths = []
    }

    private func markConnected(endpointID: InspectEndpoint.ID?) {
        discovered = discovered.map { endpoint in
            var copy = endpoint
            copy.isConnected = (endpoint.id == endpointID)
            return copy
        }
        // Manual endpoints share the same `isConnected` flag — without
        // this mirror, the Picker would render a manual entry as
        // "disconnected" even while the socket is up, since `allEndpoints`
        // composes both lists verbatim.
        manualEndpoints = manualEndpoints.map { endpoint in
            var copy = endpoint
            copy.isConnected = (endpoint.id == endpointID)
            return copy
        }
    }

    /// Starts live updates using the best mechanism the connected server
    /// supports: subscribe-push (v3+) when available, client-side polling
    /// otherwise. `liveInterval` seeds the minimum update interval on the
    /// server so the user's presets still act as a rate limit.
    private func startLive() {
        guard isConnected else { return }
        let supportsPush = (connection.serverProtocolVersion ?? 0) >= InspectProtocol.subscribeUpdatesMinVersion
        live.start(supportsPush: supportsPush, intervalSec: liveInterval)
    }

    /// Clears `isInflight` if the matching request is still outstanding after
    /// the timeout window. Without this, a lost response would leave the
    /// toolbar spinner running forever — the user would see it and assume
    /// the app is hung.
    private func scheduleInflightAutoClear(for sentAt: Date) {
        let deadlineNs = UInt64((Self.inflightTimeout + 0.1) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: deadlineNs)
            guard let self else { return }
            if self.isInflight, self.inflightSentAt == sentAt {
                self.isInflight = false
                self.inflightSentAt = nil
            }
        }
    }

    // MARK: - Message handling

    private func handle(_ message: InspectMessage) {
        switch message {
        case let .hierarchy(newRoots):
            let nodeCount = HierarchyRemapping.countNodes(in: newRoots)
            logger.info("Model received hierarchy: \(newRoots.count) root(s), \(nodeCount) total node(s)")
            isInflight = false
            inflightSentAt = nil
            applyHierarchyPreservingSelection(newRoots: newRoots)
        case let .error(message):
            logger.error("Model received error: \(message, privacy: .public)")
            isInflight = false
            inflightSentAt = nil
            status = "error: \(message)"
        case .handshake, .pairResult, .requestPair, .requestHierarchy, .requestHierarchyLite, .subscribeUpdates, .unsubscribeUpdates, .highlightView, .setOptions:
            // handshake/pairResult are consumed inside ConnectionController.
            // Outbound message cases never appear here.
            break
        }
    }

    /// Replaces `roots` with `newRoots` while re-mapping `selectedNodeID`,
    /// `measurementReferenceID`, `measurementHoverID`, and `focusedNodeID`
    /// across the new tree.
    private func applyHierarchyPreservingSelection(newRoots: [ViewNode]) {
        let oldRoots = self.roots

        // Carry screenshots forward from the previous snapshot when the new
        // one came back without them (lite capture path). Without this, the
        // 3D scene would render blank planes on every live tick.
        let mergedRoots = HierarchyRemapping.carryingScreenshots(into: newRoots, from: oldRoots)

        let preservedSelectionID = HierarchyRemapping.remap(
            id: selectedNodeID,
            oldRoots: oldRoots,
            newRoots: mergedRoots
        )
        let preservedReferenceID = HierarchyRemapping.remap(
            id: measurementReferenceID,
            oldRoots: oldRoots,
            newRoots: mergedRoots
        )
        let preservedHoverID = HierarchyRemapping.remap(
            id: measurementHoverID,
            oldRoots: oldRoots,
            newRoots: mergedRoots
        )
        let preservedFocusID = HierarchyRemapping.remap(
            id: focusedNodeID,
            oldRoots: oldRoots,
            newRoots: mergedRoots
        )

        self.roots = mergedRoots
        // If the focused node vanished from the new tree, drop focus so the
        // user isn't stuck staring at an empty scene with no way to escape
        // besides disconnecting. Applied before selection fallback so the
        // fallback sees up-to-date focus state.
        focusedNodeID = preservedFocusID

        if let preservedSelectionID {
            selectedNodeID = preservedSelectionID
        } else if selectedNodeID.flatMap({ HierarchyRemapping.findNode(id: $0, in: mergedRoots) }) == nil {
            // While focused, prefer the focused node as the default selection
            // so the fallback doesn't jump to a root the user can't see.
            selectedNodeID = preservedFocusID ?? mergedRoots.first?.id
        }
        measurementReferenceID = preservedReferenceID
        measurementHoverID = preservedHoverID
    }

    // MARK: - Bug Bundle (export / offline viewer)

    /// Builds a `BugBundle` from the currently-displayed hierarchy plus
    /// the last server handshake. Returns `nil` when there's nothing
    /// worth exporting (no captured roots) so the caller can keep its
    /// menu item disabled. The full `roots` are exported, not
    /// `displayRoots`, so a bundle saved while focused on a subtree
    /// still carries the rest of the tree for later context.
    func currentBugBundle(notes: String? = nil) -> BugBundle? {
        guard !roots.isEmpty else { return nil }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let manifest: BugBundle.Manifest
        if let existing = offlineBundleManifest {
            // Re-exporting a loaded bundle (the QA "type repro steps and
            // save to a new path" case): preserve the original capture
            // metadata. `createdAt` is *capture* time, not save time, so
            // it must survive the round-trip; same for the device fields.
            // `notes` overrides only when the caller passes a value, so
            // default re-export keeps whatever was already in the manifest.
            manifest = BugBundle.Manifest(
                schemaVersion: existing.schemaVersion,
                createdAt: existing.createdAt,
                exporterAppVersion: appVersion ?? existing.exporterAppVersion,
                notes: notes ?? existing.notes,
                deviceName: existing.deviceName,
                systemName: existing.systemName,
                systemVersion: existing.systemVersion,
                protocolVersion: existing.protocolVersion
            )
        } else {
            manifest = BugBundle.Manifest(
                exporterAppVersion: appVersion,
                notes: notes,
                deviceName: lastHandshake?.deviceName,
                systemName: lastHandshake?.systemName,
                systemVersion: lastHandshake?.systemVersion,
                protocolVersion: lastHandshake?.protocolVersion
            )
        }
        return BugBundle(manifest: manifest, roots: roots)
    }

    /// Replaces the live hierarchy with one read from a `.swiftinspector`
    /// file. Drops any current connection first so the canvas isn't a
    /// half-live, half-archived mix. Reuses
    /// `applyHierarchyPreservingSelection` so selection/measurement
    /// remap behaves the same as a live update.
    func loadOfflineBundle(_ bundle: BugBundle, from url: URL) {
        if isConnected {
            disconnect()
        }
        isOfflineMode = true
        offlineBundleURL = url
        offlineBundleManifest = bundle.manifest

        applyHierarchyPreservingSelection(newRoots: bundle.roots)
        if selectedNodeID == nil {
            selectedNodeID = bundle.roots.first?.id
        }

        let label = bundle.manifest.deviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil
            ?? url.deletingPathExtension().lastPathComponent
        status = String(localized: "offline: \(label)")
    }

    /// Exits offline-viewer mode and returns to the idle "browsing for
    /// devices" state. Safe to call when not in offline mode (no-op).
    func closeOfflineBundle() {
        guard isOfflineMode else { return }
        isOfflineMode = false
        offlineBundleURL = nil
        offlineBundleManifest = nil
        resetCapturedState()
        status = "browsing"
    }
}

private extension String {
    /// Returns `nil` when the receiver is empty so callers can chain
    /// `?? fallback` without an extra `isEmpty` check at the call site.
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
