import Foundation

public enum Framing {
    public static let headerSize: Int = 4
    public static let maxPayloadBytes: Int = 64 * 1024 * 1024

    public enum FramingError: Error, CustomStringConvertible {
        case payloadTooLarge(byteCount: Int, limit: Int)

        public var description: String {
            switch self {
            case let .payloadTooLarge(byteCount, limit):
                return "payload too large: \(byteCount) bytes exceeds frame cap of \(limit) bytes"
            }
        }
    }

    public static func frame(_ payload: Data) throws -> Data {
        // Mirror the receive-side cap so we never emit a frame the peer
        // will reject. Without this, a giant capture (deep tree on a Pro
        // Max with screenshots) silently overruns the limit, the peer
        // drops the connection on parseLength failure, and the user sees
        // an unexplained "disconnected" instead of a real error.
        guard payload.count <= maxPayloadBytes else {
            throw FramingError.payloadTooLarge(
                byteCount: payload.count,
                limit: maxPayloadBytes
            )
        }
        var length = UInt32(payload.count).bigEndian
        var out = Data(capacity: headerSize + payload.count)
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    public static func parseLength(_ header: Data) -> Int? {
        guard header.count == headerSize else { return nil }
        let value: UInt32 = header.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
        let length = Int(value)
        // Reject zero-length frames as well as oversized ones. A length-0
        // header would make the receiver call `receive(min: 0, max: 0)`,
        // which the OS satisfies synchronously with an empty buffer; the
        // caller would then schedule another header read against the same
        // peer and burn a CPU core on a tight loop until either side cancels.
        guard length > 0, length <= maxPayloadBytes else { return nil }
        return length
    }
}
