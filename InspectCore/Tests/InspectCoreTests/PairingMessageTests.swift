import XCTest
@testable import InspectCore

final class PairingMessageTests: XCTestCase {
    private let serializer = JSONMessageSerializer()

    func testRequestPairRoundtrip() throws {
        let identity = InspectMessage.ClientIdentity(
            clientID: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0",
            clientName: "Yuta's MacBook Pro"
        )
        let data = try serializer.encode(.requestPair(identity))
        let decoded = try serializer.decode(data)
        guard case let .requestPair(roundTripped) = decoded else {
            XCTFail("expected .requestPair, got \(decoded)")
            return
        }
        XCTAssertEqual(roundTripped, identity)
    }

    func testPairResultApprovedRoundtrip() throws {
        let data = try serializer.encode(.pairResult(.approved))
        let decoded = try serializer.decode(data)
        guard case let .pairResult(outcome) = decoded else {
            XCTFail("expected .pairResult, got \(decoded)")
            return
        }
        XCTAssertEqual(outcome, .approved)
    }

    func testPairResultRejectedRoundtrip() throws {
        let reason = "デバイス側で接続が拒否されました"
        let data = try serializer.encode(.pairResult(.rejected(reason: reason)))
        let decoded = try serializer.decode(data)
        guard case let .pairResult(outcome) = decoded else {
            XCTFail("expected .pairResult, got \(decoded)")
            return
        }
        XCTAssertEqual(outcome, .rejected(reason: reason))
    }

    /// Pair-required handshake bumps the version. Pinning it ensures a
    /// future minor refactor doesn't accidentally roll the wire constant
    /// backward and silently disable pairing on every up-to-date pair of
    /// peers.
    func testProtocolVersionGatesPairing() {
        XCTAssertGreaterThanOrEqual(InspectProtocol.version, InspectProtocol.pairingMinVersion)
        XCTAssertEqual(InspectProtocol.pairingMinVersion, 4)
    }
}
