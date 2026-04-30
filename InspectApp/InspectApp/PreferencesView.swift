import SwiftUI

/// Macアプリの「環境設定」ウィンドウ本体。今は画質スライダー1つだけだが、
/// 後から増えても自然に並ぶよう `Form` + `Section` 構造にしておく。
struct PreferencesView: View {
    @EnvironmentObject var model: AppInspectorModel
    @AppStorage(UserPreferences.Keys.screenshotJPEGQuality)
    private var screenshotJPEGQuality: Double = 0.7
    @State private var figmaToken: String = FigmaTokenStore.load() ?? ""
    @State private var figmaTokenSaveStatus: FigmaTokenSaveStatus = .idle

    private enum FigmaTokenSaveStatus {
        case idle
        case saved
        case failed
    }

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

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Personal Access Token", text: $figmaToken)
                        .textFieldStyle(.roundedBorder)
                        // Clear the success/failure label as soon as the user
                        // edits the field — leaving "Saved" beside a now-
                        // different value, or a red "Couldn't save" beside a
                        // freshly-typed token, both mislead about state.
                        .onChange(of: figmaToken) { _, _ in
                            figmaTokenSaveStatus = .idle
                        }
                    HStack {
                        Button("Save") {
                            figmaTokenSaveStatus = FigmaTokenStore.save(figmaToken)
                                ? .saved
                                : .failed
                        }
                        .disabled(figmaToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Clear") {
                            figmaToken = ""
                            FigmaTokenStore.delete()
                            figmaTokenSaveStatus = .idle
                        }
                        // Stays enabled while a token is stored even if the
                        // input field is empty — otherwise users have no way
                        // to remove a previously-saved token from Keychain.
                        Spacer()
                        switch figmaTokenSaveStatus {
                        case .idle:
                            EmptyView()
                        case .saved:
                            Text("Saved to Keychain")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .failed:
                            Text("Couldn't save to Keychain. Unlock Keychain Access and try again.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Text("Issue a token at Figma → Settings → Security → Personal access tokens. `file_content:read` is enough. Saved to Keychain.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Figma")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }
}
