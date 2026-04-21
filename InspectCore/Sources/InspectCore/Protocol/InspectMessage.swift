import Foundation

public enum InspectMessage: Codable, Sendable {
    case handshake(Handshake)
    case requestHierarchy
    /// Like `requestHierarchy` but instructs the server to skip screenshot
    /// capture. Used by live mode: structure + frames update on every tick,
    /// while the last full capture's screenshots are retained client-side.
    case requestHierarchyLite
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
}

public enum InspectProtocol {
    public static let version: Int = 2
    public static let bonjourServiceType: String = "_swift-inspector._tcp"
}
