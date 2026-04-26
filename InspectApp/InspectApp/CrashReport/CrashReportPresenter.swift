import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "crash-presenter")

/// Owns the lifecycle of the crash-report prompt: scans on launch, holds
/// the pending list for the sheet, and remembers a "last seen" cursor in
/// `UserDefaults` so the same reports aren't shown twice.
@MainActor
final class CrashReportPresenter: ObservableObject {
    @Published private(set) var pendingReports: [CrashReport] = []
    /// Mirrors the `suppressed` flag in UserDefaults. Published so the
    /// "Re-enable crash notifications" menu item can react to changes
    /// without polling.
    @Published private(set) var isSuppressed: Bool

    private let defaults: UserDefaults
    private let processName: String
    private let bundleID: String?
    private let repositoryURL: URL
    private let directoryOverride: URL?

    private static let lastScanKey = "CrashReportPresenter.lastScanDate"
    private static let suppressedKey = "CrashReportPresenter.suppressed"

    init(
        defaults: UserDefaults = .standard,
        processName: String = ProcessInfo.processInfo.processName,
        bundleID: String? = Bundle.main.bundleIdentifier,
        repositoryURL: URL = URL(string: "https://github.com/yuta24/swift-inspector")!,
        directoryOverride: URL? = nil
    ) {
        self.defaults = defaults
        self.processName = processName
        self.bundleID = bundleID
        self.repositoryURL = repositoryURL
        self.directoryOverride = directoryOverride
        self.isSuppressed = defaults.bool(forKey: Self.suppressedKey)
    }

    func scanOnLaunch() {
        if isSuppressed { return }
        let since = lastScanDate ?? installSeed()
        let reports = CrashReportScanner.scan(
            bundleID: bundleID,
            processName: processName,
            since: since,
            directory: directoryOverride
        )
        if !reports.isEmpty {
            logger.info("Detected \(reports.count) crash report(s) since \(since, privacy: .public)")
            pendingReports = reports
        }
    }

    /// Closes the sheet and advances the cursor so subsequent launches
    /// only surface fresh crashes. `Date()` (rather than the latest
    /// report's timestamp) avoids ever rewinding the cursor backwards on
    /// a future-clock skew.
    func dismiss(suppressForever: Bool = false) {
        defaults.set(Date(), forKey: Self.lastScanKey)
        if suppressForever {
            defaults.set(true, forKey: Self.suppressedKey)
            isSuppressed = true
        }
        pendingReports = []
    }

    /// Clears the suppressed flag and re-runs the scan immediately, so a
    /// crash that happened while notifications were off can still surface
    /// without waiting for a relaunch. No-op when notifications are
    /// already enabled.
    func reenable() {
        guard isSuppressed else { return }
        defaults.removeObject(forKey: Self.suppressedKey)
        isSuppressed = false
        scanOnLaunch()
    }

    /// Pre-fills a GitHub Issue with a short summary. The full report is
    /// expected to be on the user's pasteboard at the same time, since the
    /// raw text easily exceeds the practical query-string length limit.
    func issueURL(for report: CrashReport) -> URL? {
        var components = URLComponents(
            url: repositoryURL.appendingPathComponent("issues/new"),
            resolvingAgainstBaseURL: false
        )
        // Issue title and body are written in English so they can be filed
        // against any GitHub repo without depending on the maintainer's locale.
        // Headings/labels are localized so the user sees their language while
        // composing, while the structural keywords (Environment, Steps) stay
        // grep-able for the maintainer.
        let title = "Crash: \(report.exceptionType ?? "unknown") (\(report.appVersion ?? "?"))"
        let signalSuffix = report.signal.map { " / \($0)" } ?? ""
        let situation = String(localized: "Situation")
        let situationHint = String(localized: "What were you doing when the crash happened? Steps to reproduce, if any, are appreciated.")
        let environment = String(localized: "Environment")
        let exceptionLabel = String(localized: "Exception")
        let occurredLabel = String(localized: "Occurred at")
        let crashReportHeading = String(localized: "Crash report")
        let pasteHint = String(localized: "The full report has been copied to the clipboard. Paste it into the code block below.")
        let pastePlaceholder = String(localized: "(paste here)")
        let body = """
        ## \(situation)

        <!-- \(situationHint) -->

        ## \(environment)

        - swift-inspector: \(report.appVersion ?? "?")
        - macOS: \(report.osVersion ?? "?")
        - \(exceptionLabel): \(report.exceptionType ?? "?")\(signalSuffix)
        - \(occurredLabel): \(formattedDate(report.date))

        ## \(crashReportHeading)

        <!-- \(pasteHint) -->

        ```
        \(pastePlaceholder)
        ```
        """
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "crash"),
        ]
        return components?.url
    }

    private var lastScanDate: Date? {
        defaults.object(forKey: Self.lastScanKey) as? Date
    }

    /// First launch with this feature: anchor the cursor at "now" instead
    /// of surfacing months of pre-existing reports. The user only sees
    /// crashes that happen from this point forward.
    private func installSeed() -> Date {
        let now = Date()
        defaults.set(now, forKey: Self.lastScanKey)
        return now
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
