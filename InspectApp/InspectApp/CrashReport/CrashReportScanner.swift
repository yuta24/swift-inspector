import Foundation
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "crash-report")

/// Reads `~/Library/Logs/DiagnosticReports/` and returns recent crash
/// reports for our process. The directory is readable for non-sandboxed
/// apps without any special entitlement — AppInspector ships unsandboxed
/// so this works directly.
enum CrashReportScanner {
    /// Hard cap on how much of a single `.ips`/`.crash` file we read
    /// into memory. Real-world Apple diagnostic reports are ~50–500 KB,
    /// but pathological cases (spindump-style, repeat-fault) can exceed
    /// 5 MB. Reading the whole file then handing it to a SwiftUI `Text`
    /// view in the launch sheet would freeze AppInspector startup for
    /// seconds. 512 KB keeps the typical report fully intact while
    /// bounding the worst case.
    static let maxRawBytes: Int = 512 * 1024

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
        guard let raw = readCappedUTF8(at: url) else { return nil }

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

    /// Reads up to `maxRawBytes` from a diagnostic report. For oversized
    /// files we keep the head (which contains the JSON header + the
    /// crashed-thread frames the user cares about) and append a marker
    /// so the issue body isn't silently truncated. The header parse
    /// below is robust to a body that's been cut mid-line because it
    /// only inspects the first newline-delimited JSON object.
    private static func readCappedUTF8(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxRawBytes) else { return nil }
        // Truncation detection by *bytes read*, not by `.fileSizeKey`.
        // The latter falls back to `data.count` on failure, which would
        // silently misreport an oversized file as fully-loaded — exactly
        // the case where we most need the marker. False-positive at
        // exactly `maxRawBytes` is acceptable; the user just sees the
        // marker on a file that happened to land on the boundary.
        let wasTruncated = data.count >= maxRawBytes
        let lossyText: String = String(data: data, encoding: .utf8)
            // Fall back to lossy decode rather than dropping the report
            // entirely — we'd rather surface a partially-mangled payload
            // (UTF-8 multi-byte sequence cut at the cap boundary, etc.)
            // than swallow a real crash on the first launch after one.
            ?? String(decoding: data, as: UTF8.self)
        guard wasTruncated else { return lossyText }
        let originalKB = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count) / 1024
        return lossyText + "\n\n… (truncated at \(maxRawBytes / 1024) KB; original \(originalKB) KB)"
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
