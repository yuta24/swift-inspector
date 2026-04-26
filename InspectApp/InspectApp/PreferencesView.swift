import SwiftUI

/// Macアプリの「環境設定」ウィンドウ本体。今は画質スライダー1つだけだが、
/// 後から増えても自然に並ぶよう `Form` + `Section` 構造にしておく。
struct PreferencesView: View {
    @EnvironmentObject var model: InspectAppModel
    @AppStorage(UserPreferences.Keys.screenshotJPEGQuality)
    private var screenshotJPEGQuality: Double = 0.7

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Quality")
                        Spacer()
                        // Verbatim — pure number, not localizable copy.
                        Text(verbatim: String(format: "%.0f%%", screenshotJPEGQuality * 100))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $screenshotJPEGQuality,
                        in: 0.1...1.0,
                        step: 0.05
                    ) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Low")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("High")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: screenshotJPEGQuality) { _, _ in
                        // 接続中ならその場でデバイスに反映。次回以降の取得から
                        // 新しい品質で送られてくる。プロトコル v5 未満のサーバ
                        // にはモデル側で no-op になる。
                        model.sendCurrentOptionsIfSupported()
                    }
                    Text("Quality used when JPEG-compressing group screenshots on the device. Higher means sharper but larger payloads. Ignored when the server doesn't support it (protocol < 5).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Screenshot")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 240)
    }
}
