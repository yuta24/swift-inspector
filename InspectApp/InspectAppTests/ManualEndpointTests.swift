import XCTest
import Network
import InspectCore
@testable import AppInspector

/// Covers the "Connect by IP" workflow's model-level plumbing. The
/// sheet's UI is exercised manually; what matters here is that the
/// model's manual-endpoint list, dedup rules, and `markConnected`
/// mirroring all behave correctly so a typed-in entry survives the
/// existing connection state machine intact.
@MainActor
final class ManualEndpointTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ManualEndpointTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeModel() -> AppInspectorModel {
        AppInspectorModel(userDefaults: userDefaults)
    }

    func test_addManualEndpoint_appendsAndReturnsID() {
        let model = makeModel()
        let id = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        XCTAssertNotNil(id)
        XCTAssertEqual(model.manualEndpoints.count, 1)
        XCTAssertEqual(model.manualEndpoints.first?.id, id)
        XCTAssertEqual(model.manualEndpoints.first?.name, "192.168.1.42:8765")
    }

    func test_addManualEndpoint_isIdempotentForSameHostPort() {
        let model = makeModel()
        let first = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        let second = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        XCTAssertEqual(first, second)
        XCTAssertEqual(model.manualEndpoints.count, 1)
    }

    func test_addManualEndpoint_trimsWhitespace() {
        let model = makeModel()
        let id = model.addManualEndpoint(host: "  192.168.1.42 ", port: 8765)
        XCTAssertEqual(id, "manual:192.168.1.42:8765")
        XCTAssertEqual(model.manualEndpoints.first?.name, "192.168.1.42:8765")
    }

    func test_addManualEndpoint_rejectsEmptyHost() {
        let model = makeModel()
        XCTAssertNil(model.addManualEndpoint(host: "", port: 8765))
        XCTAssertNil(model.addManualEndpoint(host: "   ", port: 8765))
        XCTAssertTrue(model.manualEndpoints.isEmpty)
    }

    func test_addManualEndpoint_ipv6_bareLiteralIsBracketedForDisplay() {
        let model = makeModel()
        let id = model.addManualEndpoint(host: "fe80::1", port: 8765)
        XCTAssertEqual(id, "manual:[fe80::1]:8765")
        XCTAssertEqual(model.manualEndpoints.first?.name, "[fe80::1]:8765")
    }

    func test_addManualEndpoint_ipv6_bracketedInputIsDedupedWithBare() {
        let model = makeModel()
        let bare = model.addManualEndpoint(host: "::1", port: 8765)
        let bracketed = model.addManualEndpoint(host: "[::1]", port: 8765)
        XCTAssertEqual(bare, bracketed)
        XCTAssertEqual(model.manualEndpoints.count, 1)
    }

    func test_addManualEndpoint_rejectsBracketsWithEmptyContent() {
        let model = makeModel()
        XCTAssertNil(model.addManualEndpoint(host: "[]", port: 8765))
        XCTAssertTrue(model.manualEndpoints.isEmpty)
    }

    func test_removeManualEndpoint_dropsByID() {
        let model = makeModel()
        let id = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        XCTAssertNotNil(id)
        model.removeManualEndpoint(id: id!)
        XCTAssertTrue(model.manualEndpoints.isEmpty)
    }

    func test_removeManualEndpoint_clearsSelectionWhenSelectedEndpointIsRemoved() {
        let model = makeModel()
        let id = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        model.selectedEndpointID = id

        model.removeManualEndpoint(id: id!)

        XCTAssertNil(model.selectedEndpointID)
    }

    func test_removeManualEndpoint_doesNotRemoveConnectedEndpoint() {
        let model = makeModel()
        let id = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        model.markConnected(endpointID: id)

        model.removeManualEndpoint(id: id!)

        XCTAssertEqual(model.manualEndpoints.count, 1)
        XCTAssertEqual(model.manualEndpoints.first?.id, id)
    }

    func test_removeManualEndpoint_doesNotRemoveSelectedEndpointWhileConnecting() {
        let model = makeModel()
        let id = model.addManualEndpoint(host: "192.0.2.1", port: 8765)
        model.selectedEndpointID = id
        let endpoint = model.manualEndpoints.first!

        model.connect(to: endpoint)
        XCTAssertTrue(model.isConnecting)

        model.removeManualEndpoint(id: id!)
        model.disconnect()

        XCTAssertEqual(model.manualEndpoints.count, 1)
        XCTAssertEqual(model.manualEndpoints.first?.id, id)
    }

    func test_manualEndpoints_areLoadedFromUserDefaultsOnNextModel() {
        let firstModel = makeModel()
        let id = firstModel.addManualEndpoint(host: "192.168.1.42", port: 8765)
        XCTAssertEqual(id, "manual:192.168.1.42:8765")

        let secondModel = makeModel()

        XCTAssertEqual(secondModel.manualEndpoints.count, 1)
        XCTAssertEqual(secondModel.manualEndpoints.first?.id, "manual:192.168.1.42:8765")
        XCTAssertEqual(secondModel.manualEndpoints.first?.name, "192.168.1.42:8765")
    }

    func test_removeManualEndpoint_removesPersistedEntry() {
        let firstModel = makeModel()
        let id = firstModel.addManualEndpoint(host: "192.168.1.42", port: 8765)
        firstModel.removeManualEndpoint(id: id!)

        let secondModel = makeModel()

        XCTAssertTrue(secondModel.manualEndpoints.isEmpty)
    }

    func test_allEndpoints_combinesDiscoveredAndManual() {
        let model = makeModel()
        // Inject a fake discovered entry directly so the test doesn't
        // need a real Bonjour browser running.
        let discovered = InspectEndpoint(
            id: "Designer-iPhone",
            name: "Designer-iPhone",
            endpoint: NWEndpoint.hostPort(
                host: NWEndpoint.Host("192.168.1.10"),
                port: NWEndpoint.Port(rawValue: 8765)!
            )
        )
        model.discovered = [discovered]
        _ = model.addManualEndpoint(host: "192.168.1.42", port: 8765)

        let combined = model.allEndpoints.map(\.id)
        XCTAssertEqual(combined, ["Designer-iPhone", "manual:192.168.1.42:8765"])
    }

    func test_markConnected_mirrorsFlagOntoManualEndpoint() {
        // The whole point of `markConnected` updating `manualEndpoints`
        // alongside `discovered` is so the Picker renders the typed-in
        // entry as "connected" while the socket is up. Without this
        // path, the manual entry would always appear disconnected and
        // the UI would silently mismatch the actual connection state.
        let model = makeModel()
        let id = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        XCTAssertEqual(id, "manual:192.168.1.42:8765")
        XCTAssertEqual(model.manualEndpoints.first?.isConnected, false)

        model.markConnected(endpointID: id!)
        XCTAssertEqual(model.manualEndpoints.first?.isConnected, true)

        // Clearing (the `finalizeDisconnectState` path) flips the flag
        // back off — without this assertion, a stale `true` after a
        // disconnect would slip through.
        model.markConnected(endpointID: nil)
        XCTAssertEqual(model.manualEndpoints.first?.isConnected, false)
    }

    func test_markConnected_doesNotFlagSiblingManualEndpoints() {
        let model = makeModel()
        let firstID = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        let secondID = model.addManualEndpoint(host: "192.168.1.43", port: 8765)
        model.markConnected(endpointID: firstID!)

        let first = model.manualEndpoints.first { $0.id == firstID }
        let second = model.manualEndpoints.first { $0.id == secondID }
        XCTAssertEqual(first?.isConnected, true)
        XCTAssertEqual(second?.isConnected, false)
    }

    func test_allEndpoints_dedupsManualThatMatchesDiscoveredID() {
        // If a discovered endpoint happens to share an id with a manual
        // entry (unlikely in practice — Bonjour service names look
        // nothing like `manual:host:port` — but tested for correctness)
        // the discovered one wins because it carries a friendlier label.
        let model = makeModel()
        let id = "manual:192.168.1.42:8765"
        let discovered = InspectEndpoint(
            id: id,
            name: "Designer-iPhone",
            endpoint: NWEndpoint.hostPort(
                host: NWEndpoint.Host("192.168.1.42"),
                port: NWEndpoint.Port(rawValue: 8765)!
            )
        )
        model.discovered = [discovered]
        _ = model.addManualEndpoint(host: "192.168.1.42", port: 8765)

        XCTAssertEqual(model.allEndpoints.count, 1)
        XCTAssertEqual(model.allEndpoints.first?.name, "Designer-iPhone")
    }
}
