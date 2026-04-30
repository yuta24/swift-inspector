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
    func test_addManualEndpoint_appendsAndReturnsID() {
        let model = AppInspectorModel()
        let id = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        XCTAssertNotNil(id)
        XCTAssertEqual(model.manualEndpoints.count, 1)
        XCTAssertEqual(model.manualEndpoints.first?.id, id)
        XCTAssertEqual(model.manualEndpoints.first?.name, "192.168.1.42:8765")
    }

    func test_addManualEndpoint_isIdempotentForSameHostPort() {
        let model = AppInspectorModel()
        let first = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        let second = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        XCTAssertEqual(first, second)
        XCTAssertEqual(model.manualEndpoints.count, 1)
    }

    func test_addManualEndpoint_trimsWhitespace() {
        let model = AppInspectorModel()
        let id = model.addManualEndpoint(host: "  192.168.1.42 ", port: 8765)
        XCTAssertEqual(id, "manual:192.168.1.42:8765")
        XCTAssertEqual(model.manualEndpoints.first?.name, "192.168.1.42:8765")
    }

    func test_addManualEndpoint_rejectsEmptyHost() {
        let model = AppInspectorModel()
        XCTAssertNil(model.addManualEndpoint(host: "", port: 8765))
        XCTAssertNil(model.addManualEndpoint(host: "   ", port: 8765))
        XCTAssertTrue(model.manualEndpoints.isEmpty)
    }

    func test_removeManualEndpoint_dropsByID() {
        let model = AppInspectorModel()
        let id = model.addManualEndpoint(host: "192.168.1.42", port: 8765)
        XCTAssertNotNil(id)
        model.removeManualEndpoint(id: id!)
        XCTAssertTrue(model.manualEndpoints.isEmpty)
    }

    func test_allEndpoints_combinesDiscoveredAndManual() {
        let model = AppInspectorModel()
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

    func test_allEndpoints_dedupsManualThatMatchesDiscoveredID() {
        // If a discovered endpoint happens to share an id with a manual
        // entry (unlikely in practice — Bonjour service names look
        // nothing like `manual:host:port` — but tested for correctness)
        // the discovered one wins because it carries a friendlier label.
        let model = AppInspectorModel()
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
