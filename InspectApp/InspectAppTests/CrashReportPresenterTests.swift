import XCTest
@testable import AppInspector

@MainActor
final class CrashReportPresenterTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CrashPresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "CrashPresenterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        tempDir = nil
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func test_first_run_seeds_cursor_and_skips_preexisting_reports() throws {
        // Pre-existing crash from before AppInspector ever scanned.
        try writeIPS(
            named: "AppInspector-2024-01-01-090000.ips",
            timestamp: "2024-01-01 09:00:00.00 +0900"
        )

        let presenter = makePresenter()
        presenter.scanOnLaunch()

        XCTAssertTrue(presenter.pendingReports.isEmpty,
                      "first run should seed the cursor at 'now' and not surface old reports")
        XCTAssertNotNil(defaults.object(forKey: "CrashReportPresenter.lastScanDate"))
    }

    func test_second_run_surfaces_new_crash_after_seed() throws {
        let presenter = makePresenter()
        presenter.scanOnLaunch() // seeds cursor at now, no reports

        // A crash that lands after the seed.
        let newReport = try writeIPS(
            named: "AppInspector-2099-01-01-090000.ips",
            timestamp: "2099-01-01 09:00:00.00 +0900"
        )
        // setAttributes nudges mtime forward so the cursor filter sees it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: newReport.path
        )

        let nextLaunch = makePresenter()
        nextLaunch.scanOnLaunch()

        XCTAssertEqual(nextLaunch.pendingReports.count, 1)
        XCTAssertEqual(nextLaunch.pendingReports.first?.exceptionType, "EXC_BAD_ACCESS")
    }

    func test_dismiss_advances_cursor_and_clears_pending() throws {
        let report = try writeIPS(
            named: "AppInspector-2099-01-01-090000.ips",
            timestamp: "2099-01-01 09:00:00.00 +0900"
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: report.path
        )
        // Pre-seed the cursor so the test report definitely shows.
        defaults.set(Date.distantPast, forKey: "CrashReportPresenter.lastScanDate")

        let presenter = makePresenter()
        presenter.scanOnLaunch()
        XCTAssertEqual(presenter.pendingReports.count, 1)

        let cursorBefore = defaults.object(forKey: "CrashReportPresenter.lastScanDate") as? Date
        presenter.dismiss()
        let cursorAfter = defaults.object(forKey: "CrashReportPresenter.lastScanDate") as? Date

        XCTAssertTrue(presenter.pendingReports.isEmpty)
        XCTAssertNotNil(cursorAfter)
        if let before = cursorBefore, let after = cursorAfter {
            XCTAssertGreaterThan(after, before, "dismiss should advance the cursor")
        }
    }

    func test_suppress_forever_disables_subsequent_scans() throws {
        let presenter = makePresenter()
        presenter.dismiss(suppressForever: true)
        XCTAssertTrue(presenter.isSuppressed)

        try writeIPS(
            named: "AppInspector-2099-01-01-090000.ips",
            timestamp: "2099-01-01 09:00:00.00 +0900"
        )

        let next = makePresenter()
        XCTAssertTrue(next.isSuppressed, "isSuppressed should hydrate from defaults")
        next.scanOnLaunch()

        XCTAssertTrue(next.pendingReports.isEmpty,
                      "suppressed flag should short-circuit scanning entirely")
    }

    func test_reenable_clears_flag_and_surfaces_pending_crashes() throws {
        // User suppressed earlier and a crash arrived in the meantime.
        defaults.set(Date.distantPast, forKey: "CrashReportPresenter.lastScanDate")
        defaults.set(true, forKey: "CrashReportPresenter.suppressed")
        let report = try writeIPS(
            named: "AppInspector-2099-01-01-090000.ips",
            timestamp: "2099-01-01 09:00:00.00 +0900"
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: report.path
        )

        let presenter = makePresenter()
        XCTAssertTrue(presenter.isSuppressed)
        presenter.scanOnLaunch()
        XCTAssertTrue(presenter.pendingReports.isEmpty,
                      "scan should be suppressed before reenable")

        presenter.reenable()

        XCTAssertFalse(presenter.isSuppressed)
        XCTAssertNil(defaults.object(forKey: "CrashReportPresenter.suppressed"))
        XCTAssertEqual(presenter.pendingReports.count, 1,
                       "reenable should immediately surface pending crashes")
    }

    func test_reenable_is_noop_when_not_suppressed() {
        let presenter = makePresenter()
        XCTAssertFalse(presenter.isSuppressed)
        presenter.reenable()
        XCTAssertFalse(presenter.isSuppressed)
        XCTAssertTrue(presenter.pendingReports.isEmpty)
    }

    func test_issueURL_includes_required_query_items() throws {
        let report = CrashReport(
            url: URL(fileURLWithPath: "/tmp/AppInspector.ips"),
            processName: "AppInspector",
            appVersion: "0.1.0",
            osVersion: "macOS 14.5",
            bundleID: "com.yuta24.swift-inspector",
            date: Date(timeIntervalSince1970: 1_745_572_014),
            exceptionType: "EXC_BAD_ACCESS",
            signal: "SIGSEGV",
            crashedThreadIndex: 0,
            rawContents: "raw bytes"
        )

        let presenter = makePresenter()
        let url = try XCTUnwrap(presenter.issueURL(for: report))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/yuta24/swift-inspector/issues/new")
        let names = Set((components.queryItems ?? []).map(\.name))
        XCTAssertEqual(names, ["title", "body", "labels"])

        let title = components.queryItems?.first { $0.name == "title" }?.value
        XCTAssertTrue(title?.contains("EXC_BAD_ACCESS") == true)
        XCTAssertTrue(title?.contains("0.1.0") == true)

        let body = components.queryItems?.first { $0.name == "body" }?.value ?? ""
        XCTAssertTrue(body.contains("EXC_BAD_ACCESS"))
        XCTAssertTrue(body.contains("SIGSEGV"))
        XCTAssertTrue(body.contains("macOS 14.5"))
    }

    // MARK: Fixtures

    private func makePresenter() -> CrashReportPresenter {
        CrashReportPresenter(
            defaults: defaults,
            processName: "AppInspector",
            bundleID: "com.yuta24.swift-inspector",
            repositoryURL: URL(string: "https://github.com/yuta24/swift-inspector")!,
            directoryOverride: tempDir
        )
    }

    @discardableResult
    private func writeIPS(named name: String, timestamp: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let header: [String: Any] = [
            "app_name": "AppInspector",
            "timestamp": timestamp,
            "app_version": "0.1.0",
            "bundleID": "com.yuta24.swift-inspector",
            "os_version": "macOS 14.5 (23F79)",
        ]
        let body: [String: Any] = [
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "faultingThread": 0,
        ]
        var combined = try JSONSerialization.data(withJSONObject: header, options: [])
        combined.append(0x0A)
        combined.append(try JSONSerialization.data(withJSONObject: body, options: .prettyPrinted))
        try combined.write(to: url)
        return url
    }
}
