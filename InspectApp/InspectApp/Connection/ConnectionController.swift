import Foundation
import InspectCore
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "connection")

/// Owns the Bonjour browser, the live `InspectClient`, and the handshake /
/// pairing / connecting-timeout state machine. Consumes the wire-protocol
/// concerns that used to live directly on `AppInspectorModel`, and exposes a
/// callback-based API so the model can stay focused on UI-facing state.
///
/// The browser is started once (`startBrowsing`) and then kept alive for the
/// rest of the session — `connect`/`disconnect` only swap out the per-peer
/// `InspectClient`. `serverProtocolVersion` is published as an immutable
/// snapshot once the handshake arrives, so callers can gate version-dependent
/// messages without poking at this controller.
@MainActor
final class ConnectionController {
    var onDiscoveredChanged: ([InspectEndpoint]) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onConnectingChanged: (Bool) -> Void = { _ in }
    /// Fires when the TCP connection becomes ready, before the server's
    /// handshake. The hierarchy must not be requested at this point — wait
    /// for `onHandshake` (legacy path) or `onPairOutcome(.approved)` (v4+).
    var onConnected: (InspectEndpoint) -> Void = { _ in }
    /// Fires for every disconnect, whether user-initiated, server-initiated,
    /// or a connection failure. The model resets transient state from here.
    var onDisconnected: () -> Void = { }
    var onConnectionError: (String) -> Void = { _ in }
    /// Fires once per connection, after the server's handshake. Carries the
    /// device label (e.g. "iPhone 15 — iOS 17.4") and protocol version. The
    /// model uses it to populate `connectedDeviceName` and to decide whether
    /// to ask for the hierarchy directly (legacy) or wait for pair approval.
    var onHandshake: (InspectMessage.Handshake, _ deviceLabel: String) -> Void = { _, _ in }
    var onAwaitingPairChanged: (Bool) -> Void = { _ in }
    /// Fires once per pairing exchange. `.approved` means the model should
    /// kick off `requestHierarchy()` (and any post-pair setup like
    /// `setOptions`); `.rejected` means it should display the reason and
    /// disconnect.
    var onPairOutcome: (InspectMessage.PairOutcome) -> Void = { _ in }
    /// Fires when the device user never answered the pair prompt within
    /// `pairApprovalTimeout`. Distinct from `onPairOutcome(.rejected)` so the
    /// model can surface a different error message and status prefix.
    var onPairTimeout: () -> Void = { }
    /// Fires for messages other than `handshake` / `pairResult`, which are
    /// consumed internally. Hierarchy / error / etc. are forwarded verbatim.
    var onMessage: (InspectMessage) -> Void = { _ in }

    private(set) var serverProtocolVersion: Int?

    private let browser = InspectBrowser()
    private var client: InspectClient?
    /// The client we're currently awaiting a `pairResult` for. Cleared as
    /// soon as a result lands (or the connection tears down). The pair
    /// timeout closure checks identity against this so a late-firing timer
    /// for an earlier connection can't surface a phantom timeout on a
    /// connection that already succeeded.
    private weak var pairingClient: InspectClient?

    /// Upper bound on how long `isConnecting` may stay true without either
    /// `onConnected` or `onDisconnected` firing. NWConnection can sit in
    /// `.waiting` indefinitely on flaky networks, which would otherwise
    /// latch the "Connecting…" spinner forever.
    private static let connectingTimeout: TimeInterval = 10.0
    /// Upper bound on how long we wait for the device user to approve a
    /// pair request. Generous because the device is the user's other hand —
    /// they may need to unlock it, dismiss a different alert, or walk over
    /// to it. After this we surface an explicit timeout so the Mac client
    /// doesn't sit silently forever.
    private static let pairApprovalTimeout: TimeInterval = 60.0

    func startBrowsing() {
        browser.onChange = { [weak self] endpoints in
            Task { @MainActor in
                self?.onDiscoveredChanged(endpoints)
            }
        }
        browser.start()
        onStatus("browsing")
    }

    func connect(to endpoint: InspectEndpoint) {
        disconnect()
        let client = InspectClient()
        // Each callback re-checks `self.client === client` after hopping
        // to MainActor. NWConnection callbacks fire on the client's
        // private queue, and the `Task { @MainActor }` hop can re-order
        // arbitrarily relative to a subsequent `disconnect()` /
        // `connect()` issued from the UI. Without this identity guard a
        // late `.cancelled` (or a final `.hierarchy`) from the *previous*
        // client would clobber the new connection's freshly-set state
        // (e.g. the new spinner, the new handshake-derived label).
        client.onStatus = { [weak self, weak client] message in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.onStatus(message)
            }
        }
        client.onConnected = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.onConnectingChanged(false)
                self.onConnected(endpoint)
                // Don't request the hierarchy yet — we wait for the server's
                // handshake so we can decide whether pairing is required
                // (protocol >= 4) or skip it (older servers).
            }
        }
        client.onFailed = { [weak self, weak client] error in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.onConnectionError(error.localizedDescription)
            }
        }
        client.onDisconnected = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.serverProtocolVersion = nil
                self.onConnectingChanged(false)
                self.onAwaitingPairChanged(false)
                self.onDisconnected()
            }
        }
        client.onMessage = { [weak self, weak client] message in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.handle(message)
            }
        }
        self.client = client
        onConnectingChanged(true)
        client.connect(to: endpoint.endpoint)
        onStatus("connecting to \(endpoint.name)")
        scheduleConnectingAutoClear(for: client)
    }

    func disconnect() {
        // Detach callbacks on the old client before cancelling its
        // NWConnection. Otherwise a late `.cancelled` state transition
        // from the dying connection would dispatch an async Task that
        // clobbers the NEXT connection's state (e.g. the user rapidly
        // switching devices would see the new spinner disappear mid-
        // connect).
        client?.onStatus = nil
        client?.onConnected = nil
        client?.onDisconnected = nil
        client?.onFailed = nil
        client?.onMessage = nil

        if client != nil {
            // Best-effort: clear any server-side highlight overlay before
            // tearing down. Safe even on legacy peers — they ignore the
            // message.
            client?.send(.highlightView(ident: nil))
            client?.disconnect()
        }
        client = nil
        pairingClient = nil
        serverProtocolVersion = nil
        onConnectingChanged(false)
        onAwaitingPairChanged(false)
    }

    func shutdown() {
        disconnect()
        browser.stop()
        onStatus("idle")
    }

    func send(_ message: InspectMessage) {
        client?.send(message)
    }

    // MARK: - Private

    /// Clears `isConnecting` if the specified client is still the active one
    /// after the timeout. Capturing the client identity prevents a rapid
    /// reconnect from being tripped by the previous attempt's timeout.
    private func scheduleConnectingAutoClear(for client: InspectClient) {
        let deadlineNs = UInt64(Self.connectingTimeout * 1_000_000_000)
        Task { @MainActor [weak self, weak client] in
            try? await Task.sleep(nanoseconds: deadlineNs)
            guard let self, let client, self.client === client else { return }
            self.onConnectingChanged(false)
        }
    }

    private func handle(_ message: InspectMessage) {
        switch message {
        case let .handshake(handshake):
            logger.info("Handshake: \(handshake.deviceName, privacy: .public) \(handshake.systemName, privacy: .public) \(handshake.systemVersion, privacy: .public) protocol=\(handshake.protocolVersion)")
            serverProtocolVersion = handshake.protocolVersion
            let label = "\(handshake.deviceName) — \(handshake.systemName) \(handshake.systemVersion)"
            onHandshake(handshake, label)
            beginPairingIfNeeded(for: handshake)
        case let .pairResult(outcome):
            handlePairResult(outcome)
        default:
            onMessage(message)
        }
    }

    /// Decides between the v4 pair flow and the legacy "request hierarchy
    /// immediately" path based on the server's advertised protocol version.
    /// Pre-v4 servers don't understand `requestPair`, so sending it would
    /// just earn an `error("decode failed")` — fall back to the old behavior
    /// instead so older devices still work after an AppInspector upgrade.
    private func beginPairingIfNeeded(for handshake: InspectMessage.Handshake) {
        if handshake.protocolVersion >= InspectProtocol.pairingMinVersion {
            onAwaitingPairChanged(true)
            onStatus(String(localized: "Approve the connection on the device…"))
            let identity = ClientIdentityStore.current()
            pairingClient = client
            client?.send(.requestPair(identity))
            schedulePairTimeout(for: client)
        } else {
            // Legacy path: surface the device label as the status so the UI
            // mirrors the old behavior exactly. The model's `onPairOutcome`
            // path won't fire here, so the model is responsible for wiring
            // `onHandshake` to its initial `requestHierarchy()` for legacy
            // peers.
            onStatus("connected: \(handshake.deviceName)")
        }
    }

    private func handlePairResult(_ outcome: InspectMessage.PairOutcome) {
        pairingClient = nil
        onAwaitingPairChanged(false)
        switch outcome {
        case .approved:
            logger.info("Pair approved")
        case let .rejected(reason):
            logger.info("Pair rejected: \(reason, privacy: .public)")
        case let .unknown(tag):
            logger.warning("Pair outcome is unknown variant from newer device: \(tag, privacy: .public)")
        }
        onPairOutcome(outcome)
    }

    /// Bails out of the pair-waiting state if the device user never
    /// responds. Without this the "デバイス側で承認してください…" banner
    /// would stay up forever and the user would think the app is hung.
    private func schedulePairTimeout(for client: InspectClient?) {
        let deadlineNs = UInt64(Self.pairApprovalTimeout * 1_000_000_000)
        Task { @MainActor [weak self, weak client] in
            try? await Task.sleep(nanoseconds: deadlineNs)
            guard let self, let client, self.pairingClient === client else { return }
            self.pairingClient = nil
            self.onAwaitingPairChanged(false)
            self.onPairTimeout()
        }
    }
}
