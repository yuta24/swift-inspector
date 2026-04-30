import XCTest
@testable import InspectCore

final class BugBundleTests: XCTestCase {
    func testRoundtripPreservesRootsAndManifest() throws {
        let child = ViewNode(
            className: "UILabel",
            frame: CGRect(x: 8, y: 8, width: 100, height: 20),
            backgroundColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            // Fake JPEG SOI bytes — we only care that the same bytes survive
            // the round-trip through base64 encoding.
            screenshot: Data([0xFF, 0xD8, 0xFF, 0xE0])
        )
        let parent = ViewNode(
            className: "UIWindow",
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            safeAreaInsets: EdgeInsets(top: 47, left: 0, bottom: 34, right: 0),
            children: [child]
        )
        let manifest = BugBundle.Manifest(
            exporterAppVersion: "1.2.3",
            notes: "Tap Login → freezes",
            deviceName: "iPhone 15 Pro",
            systemName: "iOS",
            systemVersion: "17.4",
            protocolVersion: 5
        )
        let bundle = BugBundle(manifest: manifest, roots: [parent])

        let data = try bundle.encoded()
        let decoded = try BugBundle.decoded(from: data)

        XCTAssertEqual(decoded.manifest.schemaVersion, BugBundle.schemaVersion)
        XCTAssertEqual(decoded.manifest.exporterAppVersion, "1.2.3")
        XCTAssertEqual(decoded.manifest.notes, "Tap Login → freezes")
        XCTAssertEqual(decoded.manifest.deviceName, "iPhone 15 Pro")
        XCTAssertEqual(decoded.manifest.systemName, "iOS")
        XCTAssertEqual(decoded.manifest.systemVersion, "17.4")
        XCTAssertEqual(decoded.manifest.protocolVersion, 5)
        XCTAssertEqual(decoded.roots, [parent])
        XCTAssertEqual(
            decoded.roots.first?.children.first?.screenshot,
            Data([0xFF, 0xD8, 0xFF, 0xE0])
        )
    }

    func testRoundtripWithMinimalManifest() throws {
        // Mirrors the "exported while no device was connected" path —
        // every device-side field is nil and the bundle is still valid.
        let manifest = BugBundle.Manifest(exporterAppVersion: nil)
        let bundle = BugBundle(manifest: manifest, roots: [])
        let data = try bundle.encoded()
        let decoded = try BugBundle.decoded(from: data)
        XCTAssertNil(decoded.manifest.deviceName)
        XCTAssertNil(decoded.manifest.systemName)
        XCTAssertNil(decoded.manifest.systemVersion)
        XCTAssertNil(decoded.manifest.protocolVersion)
        XCTAssertNil(decoded.manifest.notes)
        XCTAssertEqual(decoded.roots, [])
    }

    func testDecodingRejectsNewerSchemaVersion() throws {
        // Forge a bundle whose manifest declares a future schema. The
        // decoder must refuse it with the typed `DecodeError` (not a
        // generic `DecodingError`) so callers can surface a localized
        // upgrade prompt instead of "the data couldn't be read".
        let manifest = BugBundle.Manifest(
            schemaVersion: BugBundle.schemaVersion + 1,
            exporterAppVersion: "999.0"
        )
        let bundle = BugBundle(manifest: manifest, roots: [])
        let data = try bundle.encoded()
        XCTAssertThrowsError(try BugBundle.decoded(from: data)) { error in
            guard case let BugBundle.DecodeError.unsupportedSchemaVersion(found, supported) = error else {
                XCTFail("expected unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(found, BugBundle.schemaVersion + 1)
            XCTAssertEqual(supported, BugBundle.schemaVersion)
            // `LocalizedError` description must be populated — that's
            // the whole point of using a typed error here.
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    func testDecodingAcceptsOlderSchemaVersion() throws {
        // Older bundles must remain readable — we only reject *newer*.
        // Pin to a hard-coded older value (0) and assert manifest fields
        // come back populated, so the test exercises the full decode
        // path rather than passing trivially when `schemaVersion` is 1
        // (in which case `schemaVersion - 1` produces 0 and the gate
        // passes for free without proving anything).
        let manifest = BugBundle.Manifest(
            schemaVersion: 0,
            exporterAppVersion: "0.9",
            deviceName: "iPhone Legacy",
            systemVersion: "16.0"
        )
        let bundle = BugBundle(manifest: manifest, roots: [])
        let data = try bundle.encoded()
        let decoded = try BugBundle.decoded(from: data)
        XCTAssertEqual(decoded.manifest.schemaVersion, 0)
        XCTAssertEqual(decoded.manifest.exporterAppVersion, "0.9")
        XCTAssertEqual(decoded.manifest.deviceName, "iPhone Legacy")
        XCTAssertEqual(decoded.manifest.systemVersion, "16.0")
    }

    func testFileExtension() {
        XCTAssertEqual(BugBundle.fileExtension, "swiftinspector")
    }
}
