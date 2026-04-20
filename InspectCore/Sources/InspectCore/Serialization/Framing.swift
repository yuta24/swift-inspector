import Foundation

public enum Framing {
    public static let headerSize: Int = 4
    public static let maxPayloadBytes: Int = 64 * 1024 * 1024

    public static func frame(_ payload: Data) -> Data {
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
        guard length >= 0, length <= maxPayloadBytes else { return nil }
        return length
    }
}
