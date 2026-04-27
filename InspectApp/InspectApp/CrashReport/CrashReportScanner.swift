import Foundation
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "crash-report")

/// Reads `~/Library/Logs/DiagnosticReports/` and returns recent crash
/// reports for our process. The directory is readable for non-sandboxed
/// apps without any special entitlement — AppInspector ships unsandboxed
/// so this works directly.
enum CrashReportScanner {
    /// Returns reports for `processName` (and matching `bundleID` when
    /// present in the report header) modified after `since`, sorted most
    /// recent first. `bundleID` filtering avoids surfacing unrelated
    /// processes that share a name prefix. `directory` is injectable for
    /// tests; production callers should leave it `nil` to use the
    /// per-user DiagnosticReports folder.
    static func scan(
        bundleID: String?,
        processName: String,
        since: Date,
        directory: URL? = nil
    ) -> [CrashReport] {
        let fm = FileManager.default
        let resolved = directory ?? fm.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        guard let dir = resolved, fm.fileExists(atPath: dir.path) else { return [] }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            logger.error("Failed to enumerate DiagnosticReports: \(error.localizedDescription, privacy: .public)")
            return []
        }

        return urls
            .filter { url in
                let ext = url.pathExtension.lowercased()
                guard ext == "ips" || ext == "crash" else { return false }
                return url.lastPathComponent.hasPrefix("\(processName)-")
            }
            .compactMap { url -> CrashReport? in
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard mod > since else { return nil }
                return parse(url: url, fallbackDate: mod, expectedBundleID: bundleID)
            }
            .sorted { $0.date > $1.date }
    }

    /// Parses one report file. `.ips` files are two concatenated JSON
    /// objects: a single-line header (app metadata) followed by a
    /// pretty-printed body (threads, exception, registers). Older `.crash`
    /// files are plain text — we keep them for `rawContents` but skip
    /// header/body parsing.
    private static func parse(url: URL, fallbackDate: Date, expectedBundleID: String?) -> CrashReport? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var header: [String: Any] = [:]
        var body: [String: Any] = [:]
        if url.pathExtension.lowercased() == "ips" {
            let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = parts.first, let h = jsonObject(from: String(first)) {
                header = h
            }
            if parts.count > 1, let b = jsonObject(from: String(parts[1])) {
                body = b
            }
        }

        // Don't surface another process that happens to share our prefix
        // (e.g. "AppInspector" vs "AppInspectorHelper") when we can verify the
        // bundle identifier.
        if let expected = expectedBundleID,
           let actual = header["bundleID"] as? String,
           actual != expected {
            return nil
        }

        let processName = (header["app_name"] as? String)
            ?? (header["procName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let date = (header["timestamp"] as? String).flatMap(parseTimestamp) ?? fallbackDate

        let exception = body["exception"] as? [String: Any]

        return CrashReport(
            url: url,
            processName: processName,
            appVersion: header["app_version"] as? String,
            osVersion: header["os_version"] as? String,
            bundleID: header["bundleID"] as? String,
            date: date,
            exceptionType: exception?["type"] as? String,
            signal: exception?["signal"] as? String,
            crashedThreadIndex: body["faultingThread"] as? Int,
            rawContents: raw
        )
    }

    private static func jsonObject(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `.ips` timestamps look like `"2026-04-25 13:26:54.00 +0900"` —
    /// space-separated, not strict ISO 8601. Try the fractional-second
    /// shape first, then plain seconds.
    private static func parseTimestamp(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}
