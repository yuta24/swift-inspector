import Foundation

public enum InspectMessage: Codable, Sendable {
    case handshake(Handshake)
    /// First message from the client after the server's handshake. The server
    /// uses the embedded identity to look up a remembered approval (or to
    /// prompt the device-side user) before any inspection traffic is allowed.
    case requestPair(ClientIdentity)
    /// Server's response to `requestPair`. The connection stays open after
    /// `.rejected` only long enough for the client to read the reason; the
    /// server cancels it immediately after.
    case pairResult(PairOutcome)
    case requestHierarchy
    /// Like `requestHierarchy` but instructs the server to skip screenshot
    /// capture. Used by live mode: structure + frames update on every tick,
    /// while the last full capture's screenshots are retained client-side.
    case requestHierarchyLite
    /// Asks the server to start pushing hierarchy snapshots (screenshot-less)
    /// whenever it detects layout changes, rate-limited to at most one push
    /// per `intervalMs` milliseconds. Replaces client-side polling for live
    /// mode in protocol v3+.
    case subscribeUpdates(intervalMs: Int)
    case unsubscribeUpdates
    case hierarchy(roots: [ViewNode])
    case highlightView(ident: UUID?)
    case error(String)

    public struct Handshake: Codable, Hashable, Sendable {
        public let protocolVersion: Int
        public let deviceName: String
        public let systemName: String
        public let systemVersion: String

        public init(
            protocolVersion: Int = InspectProtocol.version,
            deviceName: String,
            systemName: String,
            systemVersion: String
        ) {
            self.protocolVersion = protocolVersion
            self.deviceName = deviceName
            self.systemName = systemName
            self.systemVersion = systemVersion
        }
    }

    /// Stable identity of a macOS client requesting pairing. `clientID` is a
    /// UUID generated and persisted on the client's first launch — it lets
    /// the device remember "this Mac" across sessions even when the host
    /// name changes. `clientName` is the human-readable label shown in the
    /// device-side approval prompt.
    public struct ClientIdentity: Codable, Hashable, Sendable {
        public let clientID: String
        public let clientName: String

        public init(clientID: String, clientName: String) {
            self.clientID = clientID
            self.clientName = clientName
        }
    }

    public enum PairOutcome: Codable, Sendable, Equatable {
        /// Pairing succeeded; the connection may now be used for inspection.
        case approved
        /// User declined or the device couldn't present the prompt. The
        /// reason is shown verbatim in the client's connection-error banner.
        case rejected(reason: String)
    }
}

public enum InspectProtocol {
    public static let version: Int = 4
    public static let bonjourServiceType: String = "_swift-inspector._tcp"
    /// Earliest server version that understands `subscribeUpdates`. Clients
    /// fall back to polling when connected to older servers.
    public static let subscribeUpdatesMinVersion: Int = 3
    /// Earliest server version that requires pairing before inspection.
    /// Clients connecting to older servers skip the pair step and start
    /// requesting hierarchies immediately for backward compatibility.
    public static let pairingMinVersion: Int = 4
}
