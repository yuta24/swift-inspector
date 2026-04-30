import XCTest
import InspectCore
@testable import AppInspector

/// Exercises the export → on-disk → re-load path that backs B1 (export
/// bug bundle) and B2 (offline viewer). Goes through `BugBundleService`
/// for the file I/O and through `AppInspectorModel` for the state
/// transitions, so a regression in any of: manifest construction, JSON
/// encoding, file write, file read, manifest decoding, or offline-mode
/// state plumbing surfaces here.
@MainActor
final class BugBundleRoundTripTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BugBundleRoundTrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        temporaryDirectory = base
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func test_currentBugBundle_returnsNilWhenRootsEmpty() {
        let model = AppInspectorModel()
        XCTAssertNil(model.currentBugBundle())
    }

    func test_exportThenLoad_round_trip_preserves_hierarchy() throws {
        // Arrange: a small hierarchy with screenshot bytes so we
        // confirm `Data` survives base64 round-tripping inside the
        // exported JSON document.
        let leaf = ViewNode(
            className: "UILabel",
            frame: CGRect(x: 8, y: 8, width: 100, height: 20),
            backgroundColor: RGBAColor(red: 0, green: 0.5, blue: 1, alpha: 1),
            screenshot: Data([0xFF, 0xD8, 0xFF, 0xE0])
        )
        let root = ViewNode(
            className: "UIWindow",
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            safeAreaInsets: EdgeInsets(top: 47, left: 0, bottom: 34, right: 0),
            children: [leaf]
        )

        let exporter = AppInspectorModel()
        exporter.roots = [root]
        // selectedNodeID isn't carried into a bundle (it's UI state),
        // but setting it here makes sure it isn't accidentally
        // smuggled in via some side channel.
        exporter.selectedNodeID = leaf.id

        let bundle = try XCTUnwrap(exporter.currentBugBundle())
        XCTAssertEqual(bundle.roots, [root])

        let url = temporaryDirectory.appendingPathComponent(
            "bundle.\(BugBundle.fileExtension)"
        )
        try BugBundleService.write(bundle, to: url)

        // Act: read back via the same service the menu uses, then
        // hand it to a fresh model — simulating "another engineer
        // opened the .swiftinspector file".
        let reloaded = try BugBundleService.read(from: url)
        let viewer = AppInspectorModel()
        viewer.loadOfflineBundle(reloaded, from: url)

        // Assert: hierarchy round-trips intact, offline state is
        // populated, and a default selection is established so the
        // canvas has something to show on first paint.
        XCTAssertEqual(viewer.roots, [root])
        XCTAssertEqual(
            viewer.roots.first?.children.first?.screenshot,
            Data([0xFF, 0xD8, 0xFF, 0xE0])
        )
        XCTAssertTrue(viewer.isOfflineMode)
        XCTAssertEqual(viewer.offlineBundleURL, url)
        XCTAssertNotNil(viewer.selectedNodeID)
    }

    func test_consecutiveLoadOfflineBundle_replacesStateCleanly() throws {
        // Two loads in a row without an intervening close. State must
        // converge on the *second* bundle's roots / URL / manifest with
        // no leakage from the first — otherwise a user opening bundle
        // B over bundle A would see A's notes lingering or A's URL
        // stuck in the sidebar header.
        let firstRoot = ViewNode(
            className: "UIWindow",
            frame: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        let secondRoot = ViewNode(
            className: "UIWindow",
            frame: CGRect(x: 0, y: 0, width: 393, height: 852)
        )
        let firstBundle = BugBundle(
            manifest: BugBundle.Manifest(
                exporterAppVersion: "1.0",
                notes: "first",
                deviceName: "iPhone SE"
            ),
            roots: [firstRoot]
        )
        let secondBundle = BugBundle(
            manifest: BugBundle.Manifest(
                exporterAppVersion: "1.0",
                notes: "second",
                deviceName: "iPhone 15 Pro"
            ),
            roots: [secondRoot]
        )
        let firstURL = temporaryDirectory.appendingPathComponent(
            "first.\(BugBundle.fileExtension)"
        )
        let secondURL = temporaryDirectory.appendingPathComponent(
            "second.\(BugBundle.fileExtension)"
        )
        try BugBundleService.write(firstBundle, to: firstURL)
        try BugBundleService.write(secondBundle, to: secondURL)

        let model = AppInspectorModel()
        model.loadOfflineBundle(try BugBundleService.read(from: firstURL), from: firstURL)
        model.loadOfflineBundle(try BugBundleService.read(from: secondURL), from: secondURL)

        XCTAssertTrue(model.isOfflineMode)
        XCTAssertEqual(model.offlineBundleURL, secondURL)
        XCTAssertEqual(model.offlineBundleManifest?.notes, "second")
        XCTAssertEqual(model.offlineBundleManifest?.deviceName, "iPhone 15 Pro")
        XCTAssertEqual(model.roots, [secondRoot])
    }

    func test_currentBugBundle_inOfflineMode_preservesOriginalManifest() throws {
        // Re-export from offline mode must keep the *capture-time*
        // metadata (deviceName, systemVersion, original createdAt) so
        // a QA engineer typing repro steps and saving to a new path
        // doesn't accidentally overwrite the device label with a blank
        // (the live `lastHandshake` is nil while offline).
        let originalCreated = Date(timeIntervalSince1970: 1_700_000_000)
        let original = BugBundle.Manifest(
            schemaVersion: BugBundle.schemaVersion,
            createdAt: originalCreated,
            exporterAppVersion: "0.5",
            notes: "first round",
            deviceName: "iPhone 15 Pro",
            systemName: "iOS",
            systemVersion: "17.4",
            protocolVersion: 5
        )
        let root = ViewNode(
            className: "UIWindow",
            frame: CGRect(x: 0, y: 0, width: 393, height: 852)
        )
        let bundle = BugBundle(manifest: original, roots: [root])
        let url = temporaryDirectory.appendingPathComponent(
            "preserve.\(BugBundle.fileExtension)"
        )
        try BugBundleService.write(bundle, to: url)
        let reloaded = try BugBundleService.read(from: url)

        let model = AppInspectorModel()
        model.loadOfflineBundle(reloaded, from: url)

        // Re-export with new notes — device fields and original
        // createdAt must survive untouched.
        let reexported = try XCTUnwrap(model.currentBugBundle(notes: "second round"))
        XCTAssertEqual(reexported.manifest.notes, "second round")
        XCTAssertEqual(reexported.manifest.deviceName, "iPhone 15 Pro")
        XCTAssertEqual(reexported.manifest.systemVersion, "17.4")
        XCTAssertEqual(reexported.manifest.protocolVersion, 5)
        XCTAssertEqual(reexported.manifest.createdAt, originalCreated)

        // Re-export without explicit notes preserves the originals
        // (overwriting on every save would wipe notes accidentally).
        let untouched = try XCTUnwrap(model.currentBugBundle())
        XCTAssertEqual(untouched.manifest.notes, "first round")
    }

    func test_loadOfflineBundle_thenClose_clearsState() throws {
        let root = ViewNode(
            className: "UIWindow",
            frame: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        let bundle = BugBundle(
            manifest: BugBundle.Manifest(exporterAppVersion: "test"),
            roots: [root]
        )
        let url = temporaryDirectory.appendingPathComponent(
            "close.\(BugBundle.fileExtension)"
        )
        try BugBundleService.write(bundle, to: url)
        let reloaded = try BugBundleService.read(from: url)

        let model = AppInspectorModel()
        model.loadOfflineBundle(reloaded, from: url)
        XCTAssertTrue(model.isOfflineMode)
        XCTAssertFalse(model.roots.isEmpty)

        model.closeOfflineBundle()
        XCTAssertFalse(model.isOfflineMode)
        XCTAssertNil(model.offlineBundleURL)
        XCTAssertNil(model.offlineBundleManifest)
        XCTAssertTrue(model.roots.isEmpty)
        XCTAssertNil(model.selectedNodeID)
    }

    func test_defaultFileName_includesDeviceAndStamp() {
        let stamp = Date(timeIntervalSince1970: 1_777_000_000)
        // deviceName is included verbatim after sanitization; the
        // formatted timestamp is local-time (so users see the time
        // they exported at), so we only assert the *shape* of the
        // appended stamp instead of pinning to a specific UTC moment.
        let fileName = BugBundleService.defaultFileName(
            deviceName: "iPhone 15 Pro",
            at: stamp
        )
        XCTAssertTrue(fileName.hasPrefix("iPhone 15 Pro-"))
        // Trailing `yyyy-MM-dd-HHmm` shape: "-2026-04-30-1530".
        let trailing = fileName.dropFirst("iPhone 15 Pro".count)
        let regex = try! NSRegularExpression(pattern: "^-\\d{4}-\\d{2}-\\d{2}-\\d{4}$")
        XCTAssertNotNil(
            regex.firstMatch(
                in: String(trailing),
                range: NSRange(location: 0, length: trailing.utf16.count)
            ),
            "Unexpected stamp shape: \(trailing)"
        )
    }

    func test_defaultFileName_sanitizesPathSeparators() {
        let stamp = ISO8601DateFormatter()
            .date(from: "2026-04-30T15:30:00Z")!
        let fileName = BugBundleService.defaultFileName(
            deviceName: "Tester:/MainPhone",
            at: stamp
        )
        XCTAssertFalse(fileName.contains("/"))
        XCTAssertFalse(fileName.contains(":"))
    }

    func test_defaultFileName_fallsBackWhenDeviceNameMissing() {
        let stamp = ISO8601DateFormatter()
            .date(from: "2026-04-30T15:30:00Z")!
        let fileName = BugBundleService.defaultFileName(
            deviceName: nil,
            at: stamp
        )
        XCTAssertTrue(fileName.hasPrefix("Bug Bundle-"))
    }
}
