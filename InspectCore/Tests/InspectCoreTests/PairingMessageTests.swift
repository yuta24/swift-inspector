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

    /// Forward-compat: a peer running a newer protocol can introduce a new
    /// `InspectMessage` case without breaking older receivers. The unknown
    /// wire tag must surface as `.unknownMessage(tag)` instead of throwing.
    func testUnknownMessageDecodesToUnknownMessageCase() throws {
        let payload = #"{"requestMemoryProfile":{"pid":4321}}"#.data(using: .utf8)!
        let decoded = try serializer.decode(payload)
        guard case let .unknownMessage(tag) = decoded else {
            XCTFail("expected .unknownMessage, got \(decoded)")
            return
        }
        XCTAssertEqual(tag, "requestMemoryProfile")
    }

    /// Same forward-compat guarantee for `PairOutcome`: a future variant
    /// (e.g. `.pendingApproval`) must surface as `.unknown(tag)` instead of
    /// killing the receive chain.
    func testUnknownPairOutcomeDecodesToUnknownVariant() throws {
        let payload = #"{"pairResult":{"_0":{"pendingApproval":{}}}}"#.data(using: .utf8)!
        let decoded = try serializer.decode(payload)
        guard case let .pairResult(outcome) = decoded,
              case let .unknown(tag) = outcome else {
            XCTFail("expected .pairResult(.unknown(...)), got \(decoded)")
            return
        }
        XCTAssertEqual(tag, "pendingApproval")
    }

    /// Round-trip: encoding `.unknownMessage` preserves the wire tag (with
    /// an empty payload, since the original payload was discarded on decode)
    /// so the message can survive a proxy / bug-bundle pass through this
    /// receiver without losing the diagnostic tag.
    func testUnknownMessageRoundTripsTag() throws {
        let data = try serializer.encode(.unknownMessage("requestMemoryProfile"))
        let decoded = try serializer.decode(data)
        guard case let .unknownMessage(tag) = decoded else {
            XCTFail("expected .unknownMessage round-trip, got \(decoded)")
            return
        }
        XCTAssertEqual(tag, "requestMemoryProfile")
    }

    /// Pins the wire format for an empty-payload case so a future refactor
    /// of the manual Codable can't silently drift away from Swift's
    /// auto-synth shape (`{caseName: {}}`).
    func testRequestHierarchyWireFormatPinned() throws {
        let data = try makeSortedEncoder().encode(InspectMessage.requestHierarchy)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"requestHierarchy":{}}"#)
        let decoded = try serializer.decode(data)
        guard case .requestHierarchy = decoded else {
            XCTFail("expected .requestHierarchy, got \(decoded)")
            return
        }
    }

    /// Pins the wire format for a single labelled associated value
    /// (`{caseName: {label: value}}`).
    func testSubscribeUpdatesWireFormatPinned() throws {
        let data = try makeSortedEncoder().encode(InspectMessage.subscribeUpdates(intervalMs: 500))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"subscribeUpdates":{"intervalMs":500}}"#)
        let decoded = try serializer.decode(data)
        guard case let .subscribeUpdates(intervalMs) = decoded else {
            XCTFail("expected .subscribeUpdates, got \(decoded)")
            return
        }
        XCTAssertEqual(intervalMs, 500)
    }

    /// Optional associated value: auto-synth omits the key entirely when
    /// the value is nil. Pin both branches so the encoder doesn't
    /// regress to writing `"ident": null`, which would not be byte-equal
    /// to a payload produced by an auto-synth peer.
    func testHighlightViewOptionalIdentWireFormat() throws {
        let nilData = try makeSortedEncoder().encode(InspectMessage.highlightView(ident: nil))
        XCTAssertEqual(String(data: nilData, encoding: .utf8), #"{"highlightView":{}}"#)

        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let someData = try makeSortedEncoder().encode(InspectMessage.highlightView(ident: uuid))
        XCTAssertEqual(
            String(data: someData, encoding: .utf8),
            #"{"highlightView":{"ident":"11111111-2222-3333-4444-555555555555"}}"#
        )

        // Cross-version: a peer that previously sent the auto-synth
        // "omit key" form must still decode cleanly here.
        let autoSynthOmitted = #"{"highlightView":{}}"#.data(using: .utf8)!
        guard case let .highlightView(decodedIdent) = try serializer.decode(autoSynthOmitted) else {
            XCTFail("expected .highlightView from omit-key payload")
            return
        }
        XCTAssertNil(decodedIdent)
    }

    private func makeSortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dataEncodingStrategy = .base64
        return encoder
    }
}
