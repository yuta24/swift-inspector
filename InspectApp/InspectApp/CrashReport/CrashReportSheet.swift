import SwiftUI

/// Modal shown on launch when one or more crash reports for AppInspector
/// have been written since the last time the user dismissed the sheet.
/// Designer-facing wording — avoids "stack trace" / "exception" jargon
/// in the primary copy and keeps technical detail behind a disclosure.
struct CrashReportSheet: View {
    let reports: [CrashReport]
    let onSkip: () -> Void
    let onSuppress: () -> Void
    let onReport: (CrashReport) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(reports) { report in
                        CrashReportCard(report: report) {
                            onReport(report)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Crashes detected since last launch")
                    .font(.headline)
            }
            Text("\(reports.count) report(s) found. Sharing them on GitHub helps us fix issues.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Turn off crash notifications") {
                onSuppress()
            }
            .buttonStyle(.borderless)
            .help("Suppress this sheet for future crashes. You can re-enable it from the menu.")
            Spacer()
            Button("Close") {
                onSkip()
            }
            .keyboardShortcut(.cancelAction)
            .help("Dismiss this sheet. You will be notified again on future crashes.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct CrashReportCard: View {
    let report: CrashReport
    let onReport: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headlineText)
                        .font(.body.weight(.medium))
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onReport()
                } label: {
                    Label("Report on GitHub", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .help("Copy the full report to the clipboard and open the new-issue page in your browser")
            }
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    Text(report.rawContents)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } label: {
                Text(isExpanded ? "Hide details" : "Show details")
                    .font(.caption)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var headlineText: String {
        // Exception type comes from `.ips` payloads (e.g. "EXC_BAD_ACCESS") —
        // raw symbolic data, not user copy. Use the localized fallback for
        // missing values.
        report.exceptionType ?? String(localized: "Crash")
    }

    private var subtitleText: String {
        // Honour the user's current locale rather than pinning to ja_JP —
        // RelativeDateTimeFormatter falls back to the current locale when
        // none is set, which is what we want.
        let formatter = RelativeDateTimeFormatter()
        let relative = formatter.localizedString(for: report.date, relativeTo: Date())
        if let version = report.appVersion {
            return "\(relative) · v\(version)"
        }
        return relative
    }
}
