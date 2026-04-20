import Foundation

public struct JSONMessageSerializer: MessageSerializer {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.dataEncodingStrategy = .base64
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        self.encoder = encoder
        self.decoder = decoder
    }

    public func encode(_ message: InspectMessage) throws -> Data {
        try encoder.encode(message)
    }

    public func decode(_ data: Data) throws -> InspectMessage {
        try decoder.decode(InspectMessage.self, from: data)
    }
}

public extension MessageSerializer where Self == JSONMessageSerializer {
    static var json: JSONMessageSerializer { JSONMessageSerializer() }
}
