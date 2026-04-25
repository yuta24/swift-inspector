import SwiftUI

/// Modal shown on launch when one or more crash reports for InspectApp
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
                Text("前回起動以降にクラッシュを検出しました")
                    .font(.headline)
            }
            Text("\(reports.count) 件のレポートが見つかりました。GitHub に共有していただけると修正に役立ちます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("クラッシュ通知をオフにする") {
                onSuppress()
            }
            .buttonStyle(.borderless)
            .help("今後クラッシュが起きてもこのシートを出しません。再度有効にするには設定が必要です。")
            Spacer()
            Button("閉じる") {
                onSkip()
            }
            .keyboardShortcut(.cancelAction)
            .help("このシートを閉じます。今後クラッシュが起きたら再度通知します。")
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
                    Label("GitHub で報告", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .help("レポート全文をクリップボードにコピーし、ブラウザで Issue 作成画面を開きます")
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
                Text(isExpanded ? "詳細を隠す" : "詳細を表示")
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
        report.exceptionType ?? "クラッシュ"
    }

    private var subtitleText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        let relative = formatter.localizedString(for: report.date, relativeTo: Date())
        if let version = report.appVersion {
            return "\(relative) · v\(version)"
        }
        return relative
    }
}
