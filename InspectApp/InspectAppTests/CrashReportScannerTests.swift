import XCTest
@testable import AppInspector

final class CrashReportScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CrashReportScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    func test_returns_matching_ips_files_sorted_newest_first() throws {
        try writeIPS(
            named: "AppInspector-2026-04-25-100000.ips",
            timestamp: "2026-04-25 10:00:00.00 +0900",
            bundleID: "com.yuta24.swift-inspector"
        )
        try writeIPS(
            named: "AppInspector-2026-04-25-130000.ips",
            timestamp: "2026-04-25 13:00:00.00 +0900",
            bundleID: "com.yuta24.swift-inspector"
        )

        let reports = CrashReportScanner.scan(
            bundleID: "com.yuta24.swift-inspector",
            processName: "AppInspector",
            since: .distantPast,
            directory: tempDir
        )

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].fileName, "AppInspector-2026-04-25-130000.ips")
        XCTAssertEqual(reports[1].fileName, "AppInspector-2026-04-25-100000.ips")
        XCTAssertEqual(reports[0].exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(reports[0].signal, "SIGSEGV")
        XCTAssertEqual(reports[0].appVersion, "0.1.0")
    }

    func test_skips_files_older_than_since_cursor() throws {
        let oldFile = try writeIPS(
            named: "AppInspector-2026-04-20-090000.ips",
            timestamp: "2026-04-20 09:00:00.00 +0900",
            bundleID: "com.yuta24.swift-inspector"
        )
        let cutoff = Date()
        // Backdate the modification timestamp so the cursor filter has
        // something to discard.
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(-60 * 60)],
            ofItemAtPath: oldFile.path
        )

        try writeIPS(
            named: "AppInspector-2026-04-25-130000.ips",
            timestamp: "2026-04-25 13:00:00.00 +0900",
            bundleID: "com.yuta24.swift-inspector"
        )

        let reports = CrashReportScanner.scan(
            bundleID: "com.yuta24.swift-inspector",
            processName: "AppInspector",
            since: cutoff,
            directory: tempDir
        )

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].fileName, "AppInspector-2026-04-25-130000.ips")
    }

    func test_skips_other_processes_by_name_prefix() throws {
        try writeIPS(
            named: "Safari-2026-04-25-130000.ips",
            timestamp: "2026-04-25 13:00:00.00 +0900",
            bundleID: "com.apple.Safari"
        )
        try writeIPS(
            named: "AppInspector-2026-04-25-140000.ips",
            timestamp: "2026-04-25 14:00:00.00 +0900",
            bundleID: "com.yuta24.swift-inspector"
        )

        let reports = CrashReportScanner.scan(
            bundleID: "com.yuta24.swift-inspector",
            processName: "AppInspector",
            since: .distantPast,
            directory: tempDir
        )

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].fileName, "AppInspector-2026-04-25-140000.ips")
    }

    func test_filters_by_bundleID_when_prefix_collides() throws {
        // A different process whose name happens to share the AppInspector
        // prefix — the bundleID mismatch should keep it out.
        try writeIPS(
            named: "AppInspectorHelper-2026-04-25-130000.ips",
            timestamp: "2026-04-25 13:00:00.00 +0900",
            bundleID: "com.example.OtherTool"
        )
        // Also: the prefix matches, so this would slip through if we
        // *only* compared bundleID.
        try writeIPS(
            named: "AppInspector-2026-04-25-140000.ips",
            timestamp: "2026-04-25 14:00:00.00 +0900",
            bundleID: "com.yuta24.swift-inspector"
        )

        let reports = CrashReportScanner.scan(
            bundleID: "com.yuta24.swift-inspector",
            processName: "AppInspector",
            since: .distantPast,
            directory: tempDir
        )

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].bundleID, "com.yuta24.swift-inspector")
    }

    func test_returns_empty_for_missing_directory() {
        let bogus = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let reports = CrashReportScanner.scan(
            bundleID: "com.yuta24.swift-inspector",
            processName: "AppInspector",
            since: .distantPast,
            directory: bogus
        )
        XCTAssertEqual(reports.count, 0)
    }

    // MARK: Fixtures

    @discardableResult
    private func writeIPS(named name: String, timestamp: String, bundleID: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let header: [String: Any] = [
            "app_name": name.split(separator: "-").first.map(String.init) ?? "Unknown",
            "timestamp": timestamp,
            "app_version": "0.1.0",
            "bundleID": bundleID,
            "os_version": "macOS 14.5 (23F79)",
            "name": "AppInspector",
            "bug_type": "309",
        ]
        let body: [String: Any] = [
            "exception": [
                "type": "EXC_BAD_ACCESS",
                "signal": "SIGSEGV",
                "subtype": "KERN_INVALID_ADDRESS at 0x10",
            ],
            "faultingThread": 0,
            "threads": [],
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [])
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: .prettyPrinted)
        var combined = Data()
        combined.append(headerData)
        combined.append(0x0A) // newline separator between header and body
        combined.append(bodyData)
        try combined.write(to: url)
        return url
    }
}
