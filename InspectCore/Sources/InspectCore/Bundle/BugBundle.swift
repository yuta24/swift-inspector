import Foundation

/// A self-contained snapshot of a captured device hierarchy that can be
/// written to disk and re-opened on a different machine without a live
/// connection — the building block of "1-click bug report bundle" /
/// "offline viewer" workflows.
///
/// On-disk format is a single JSON file with the `.swiftinspector`
/// extension. Screenshots are kept inline as base64-encoded image bytes
/// (matching the wire-format `Data` strategy in `JSONMessageSerializer`)
/// so the artefact survives copy-paste through Slack / GitHub / Jira as
/// one shareable file. The single-file decision over a directory or a
/// `.zip` is deliberate: those split apart on most upload paths and
/// require a recipient to know they're a bundle.
public struct BugBundle: Codable, Sendable {
    public let manifest: Manifest
    public let roots: [ViewNode]

    public init(manifest: Manifest, roots: [ViewNode]) {
        self.manifest = manifest
        self.roots = roots
    }

    public struct Manifest: Codable, Hashable, Sendable {
        /// On-disk format version. Bumped only when an old reader can no
        /// longer make sense of a new file. Adding optional fields does
        /// not require a bump because every consumer routes through
        /// `Codable` and unknown keys decode to `nil` / defaults.
        public let schemaVersion: Int
        /// Wall-clock time the bundle was written. Encoded as ISO 8601 so
        /// a human triaging the JSON can read it without parsing.
        public let createdAt: Date
        /// Marketing version of the AppInspector that produced the
        /// bundle (`CFBundleShortVersionString`). Free-form — recorded
        /// for diagnostics, not parsed by readers.
        public let exporterAppVersion: String?
        /// Optional free-form note from the user (e.g. repro steps).
        /// Surfaced in the offline viewer so a triaging engineer sees it
        /// without having to open the JSON in a text editor.
        public let notes: String?

        // Snapshot-time device context, mirrored from the handshake.
        // Every field is optional so a bundle can still be re-saved when
        // no device is currently connected (future "edit notes and save
        // again" flow). Readers must tolerate any combination of nils.
        public let deviceName: String?
        public let systemName: String?
        public let systemVersion: String?
        public let protocolVersion: Int?

        public init(
            schemaVersion: Int = BugBundle.schemaVersion,
            createdAt: Date = Date(),
            exporterAppVersion: String?,
            notes: String? = nil,
            deviceName: String? = nil,
            systemName: String? = nil,
            systemVersion: String? = nil,
            protocolVersion: Int? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.createdAt = createdAt
            self.exporterAppVersion = exporterAppVersion
            self.notes = notes
            self.deviceName = deviceName
            self.systemName = systemName
            self.systemVersion = systemVersion
            self.protocolVersion = protocolVersion
        }
    }

    /// Current on-disk format version. Update only when a backwards-
    /// incompatible schema change lands; readers reject bundles whose
    /// `schemaVersion` is newer than this constant so users get a clear
    /// "upgrade your AppInspector" error instead of silently mis-parsing.
    public static let schemaVersion: Int = 1

    /// File extension used for `BugBundle` documents. Centralized so the
    /// macOS client's NSSavePanel / NSOpenPanel filters and any future
    /// UTI registration stay in agreement.
    public static let fileExtension: String = "swiftinspector"

    /// Encodes the bundle as a single JSON document. Pretty-printed and
    /// key-sorted so a reviewer can eyeball the manifest in a text
    /// editor; the size cost is negligible against the embedded image
    /// payloads.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dataEncodingStrategy = .base64
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a bundle from JSON, rejecting any file whose schema is
    /// newer than this build understands. Schema-mismatch surfaces as
    /// `DecodeError.unsupportedSchemaVersion` (a `LocalizedError`) so
    /// callers can present an "upgrade AppInspector" message instead
    /// of the generic `DecodingError` text the system would otherwise
    /// fall back to.
    public static func decoded(from data: Data) throws -> BugBundle {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(BugBundle.self, from: data)
        guard bundle.manifest.schemaVersion <= BugBundle.schemaVersion else {
            throw DecodeError.unsupportedSchemaVersion(
                found: bundle.manifest.schemaVersion,
                supported: BugBundle.schemaVersion
            )
        }
        return bundle
    }

    /// Domain errors raised by `BugBundle.decoded(from:)`. Conforms to
    /// `LocalizedError` so `error.localizedDescription` carries a
    /// user-readable message — `DecodingError` does not, which would
    /// otherwise leave the user staring at "The data couldn't be read
    /// because it is missing." instead of the actual reason.
    public enum DecodeError: LocalizedError, Equatable {
        case unsupportedSchemaVersion(found: Int, supported: Int)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedSchemaVersion(found, supported):
                return String(
                    format: "Bundle uses schema version %lld, but this AppInspector only supports up to %lld. Upgrade AppInspector to open it.",
                    locale: Locale.current,
                    found, supported
                )
            }
        }
    }
}
