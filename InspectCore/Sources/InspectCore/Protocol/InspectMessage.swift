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
    /// Client-supplied capture preferences. Sent once after pairing; persists
    /// for the rest of the session. Older servers (protocol < 5) reject this
    /// at decode time, so the client must gate by `InspectProtocol.optionsMinVersion`.
    case setOptions(SnapshotOptions)
    case hierarchy(roots: [ViewNode])
    case highlightView(ident: UUID?)
    case error(String)
    /// Forward-compat fallback. A peer running a newer protocol version may
    /// send a case this build doesn't recognize; rather than failing the
    /// whole receive chain, the decoder surfaces the unknown wire tag here
    /// so the caller can log and skip it. Receivers should treat this as
    /// "drop, continue"; senders never construct it (encoding it produces
    /// an empty-payload object under the original tag, which round-trips
    /// but loses the original payload).
    case unknownMessage(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "InspectMessage: payload has no case key"
            ))
        }
        if container.allKeys.count > 1 {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "InspectMessage: expected one case key, got \(container.allKeys.map(\.stringValue))"
            ))
        }
        switch key.stringValue {
        case "handshake":
            let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            self = .handshake(try nested.decode(Handshake.self, forKey: .underscoreZero))
        case "requestPair":
            let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            self = .requestPair(try nested.decode(ClientIdentity.self, forKey: .underscoreZero))
        case "pairResult":
            let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            self = .pairResult(try nested.decode(PairOutcome.self, forKey: .underscoreZero))
        case "requestHierarchy":
            self = .requestHierarchy
        case "requestHierarchyLite":
            self = .requestHierarchyLite
        case "subscribeUpdates":
            let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            self = .subscribeUpdates(intervalMs: try nested.decode(Int.self, forKey: AnyCodingKey("intervalMs")))
        case "unsubscribeUpdates":
            self = .unsubscribeUpdates
        case "setOptions":
            let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            self = .setOptions(try nested.decode(SnapshotOptions.self, forKey: .underscoreZero))
        case "hierarchy":
            let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            self = .hierarchy(roots: try nested.decode([ViewNode].self, forKey: AnyCodingKey("roots")))
        case "highlightView":
            let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            let ident = try nested.decodeIfPresent(UUID.self, forKey: AnyCodingKey("ident"))
            self = .highlightView(ident: ident)
        case "error":
            let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            self = .error(try nested.decode(String.self, forKey: .underscoreZero))
        default:
            self = .unknownMessage(key.stringValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        switch self {
        case .handshake(let value):
            var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("handshake"))
            try nested.encode(value, forKey: .underscoreZero)
        case .requestPair(let value):
            var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("requestPair"))
            try nested.encode(value, forKey: .underscoreZero)
        case .pairResult(let value):
            var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("pairResult"))
            try nested.encode(value, forKey: .underscoreZero)
        case .requestHierarchy:
            try container.encode(EmptyPayload(), forKey: AnyCodingKey("requestHierarchy"))
        case .requestHierarchyLite:
            try container.encode(EmptyPayload(), forKey: AnyCodingKey("requestHierarchyLite"))
        case .subscribeUpdates(let intervalMs):
            var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("subscribeUpdates"))
            try nested.encode(intervalMs, forKey: AnyCodingKey("intervalMs"))
        case .unsubscribeUpdates:
            try container.encode(EmptyPayload(), forKey: AnyCodingKey("unsubscribeUpdates"))
        case .setOptions(let value):
            var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("setOptions"))
            try nested.encode(value, forKey: .underscoreZero)
        case .hierarchy(let roots):
            var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("hierarchy"))
            try nested.encode(roots, forKey: AnyCodingKey("roots"))
        case .highlightView(let ident):
            var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("highlightView"))
            // Auto-synth omits the key entirely when an optional associated
            // value is nil (verified empirically against Swift 6's Codable
            // synthesis). Match that with encodeIfPresent so we stay
            // byte-equivalent on the wire.
            try nested.encodeIfPresent(ident, forKey: AnyCodingKey("ident"))
        case .error(let message):
            var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("error"))
            try nested.encode(message, forKey: .underscoreZero)
        case .unknownMessage(let tag):
            try container.encode(EmptyPayload(), forKey: AnyCodingKey(tag))
        }
    }

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
        /// Forward-compat fallback for variants this decoder doesn't
        /// recognize. Receivers should treat this like a rejection with an
        /// opaque reason; the associated string is the unrecognized wire tag.
        case unknown(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let key = container.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath,
                    debugDescription: "PairOutcome: payload has no variant key"
                ))
            }
            if container.allKeys.count > 1 {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath,
                    debugDescription: "PairOutcome: expected one variant key, got \(container.allKeys.map(\.stringValue))"
                ))
            }
            switch key.stringValue {
            case "approved":
                self = .approved
            case "rejected":
                let nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
                self = .rejected(reason: try nested.decode(String.self, forKey: AnyCodingKey("reason")))
            default:
                self = .unknown(key.stringValue)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            switch self {
            case .approved:
                try container.encode(EmptyPayload(), forKey: AnyCodingKey("approved"))
            case .rejected(let reason):
                var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("rejected"))
                try nested.encode(reason, forKey: AnyCodingKey("reason"))
            case .unknown(let tag):
                try container.encode(EmptyPayload(), forKey: AnyCodingKey(tag))
            }
        }
    }

    /// Capture-quality knobs the client can override per session. Kept
    /// minimal on purpose: every field is optional so the wire payload only
    /// carries what the client actually wants to change, and additions in
    /// future versions can decode against older clients without breaking.
    public struct SnapshotOptions: Codable, Hashable, Sendable {
        /// JPEG compression quality for group screenshots, 0.0–1.0. Higher
        /// is sharper but bigger. Server default is 0.7.
        public let screenshotJPEGQuality: Double?

        public init(screenshotJPEGQuality: Double? = nil) {
            self.screenshotJPEGQuality = screenshotJPEGQuality
        }
    }
}

public enum InspectProtocol {
    public static let version: Int = 5
    public static let bonjourServiceType: String = "_swift-inspector._tcp"
    /// Earliest server version that understands `subscribeUpdates`. Clients
    /// fall back to polling when connected to older servers.
    public static let subscribeUpdatesMinVersion: Int = 3
    /// Earliest server version that requires pairing before inspection.
    /// Clients connecting to older servers skip the pair step and start
    /// requesting hierarchies immediately for backward compatibility.
    public static let pairingMinVersion: Int = 4
    /// Earliest server version that accepts `setOptions`. Older servers
    /// would fail to decode the new case, so the client must skip sending
    /// it when the handshake reports a lower version.
    public static let optionsMinVersion: Int = 5
}

/// Top-level case keys are arbitrary strings (matching Swift's auto-synth
/// enum Codable wire shape: `{caseName: {payload}}`). Using a CodingKey type
/// that accepts any string lets us inspect unknown-from-future tags and route
/// them through `.unknownMessage` instead of throwing a decode error.
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        return nil
    }

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    static let underscoreZero = AnyCodingKey("_0")
}

/// Sentinel for empty-payload enum cases. Encodes as `{}` so the wire shape
/// matches Swift's auto-synth output for cases without associated values.
private struct EmptyPayload: Codable {}
