import Foundation

public protocol MessageSerializer: Sendable {
    func encode(_ message: InspectMessage) throws -> Data
    func decode(_ data: Data) throws -> InspectMessage
}
