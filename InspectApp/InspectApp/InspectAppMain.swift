import SwiftUI
import Sparkle

@main
struct InspectAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = InspectAppModel()
    @StateObject private var crashPresenter = CrashReportPresenter()
    /// Sparkle の自動アップデート一式。`.app` バンドルから起動された場合
    /// だけ生成する — `swift run` のような executable 直実行では Info.plist
    /// (SUFeedURL / SUPublicEDKey / CFBundleIdentifier) が解決できず
    /// Sparkle が fatalError を出すため、開発時は丸ごと無効化する。
    ///
    /// controller と viewModel をここで持つのは、メニュー View が
    /// `@ObservedObject` で参照する ViewModel を View 再評価のたびに
    /// 作り直されないように、`App` のライフタイムに固定するため。
    private let updater: UpdaterStack? = makeUpdaterStack()

    var body: some Scene {
        WindowGroup("swift-inspector") {
            ContentView()
                .environmentObject(model)
                .environmentObject(crashPresenter)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    model.startBrowsing()
                    appDelegate.model = model
                    crashPresenter.scanOnLaunch()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .appInfo) {
                if let viewModel = updater?.viewModel {
                    CheckForUpdatesView(viewModel: viewModel)
                }
                ReenableCrashNotificationsView(presenter: crashPresenter)
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(model)
        }
    }
}

/// Sparkle の `SPUStandardUpdaterController` と、それを購読する
/// `CheckForUpdatesViewModel` のペアを束ねる入れ物。両方の生存期間を
/// `InspectAppMain` (＝プロセス) に揃えるためのバンドル。
private struct UpdaterStack {
    let controller: SPUStandardUpdaterController
    let viewModel: CheckForUpdatesViewModel
}

@MainActor
private func makeUpdaterStack() -> UpdaterStack? {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
    // Sparkle refuses to start when there's no EdDSA public key to verify
    // updates against, and surfaces a modal "updater failed to start"
    // alert. Local smoke builds (built without `SPARKLE_PUBLIC_KEY`) ship
    // with an empty key by design — skip the updater stack entirely so
    // those builds launch cleanly. Production CI builds always have the
    // key set, so this gate is invisible there.
    let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    guard let publicKey, !publicKey.isEmpty else { return nil }
    let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    return UpdaterStack(
        controller: controller,
        viewModel: CheckForUpdatesViewModel(updater: controller.updater)
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: InspectAppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ensure cleanup runs on MainActor synchronously before the process exits
        let model = self.model
        MainActor.assumeIsolated {
            model?.shutdown()
        }
    }
}

// MARK: - Check For Updates Menu Item

/// アプリメニュー下の「アップデートを確認…」項目。更新ダウンロード中などで
/// `canCheckForUpdates` が false の間はグレーアウトする。ViewModel は
/// `App` 側が保持し、View が再評価されても同じインスタンスを参照する。
private struct CheckForUpdatesView: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel

    var body: some View {
        Button("Check for Updates…") {
            viewModel.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

// MARK: - Re-enable Crash Notifications Menu Item

/// Recovery affordance for users who hit "クラッシュ通知をオフにする" on
/// the crash report sheet and later want notifications back. Always
/// visible in the menu so it's discoverable, disabled when notifications
/// are already on.
private struct ReenableCrashNotificationsView: View {
    @ObservedObject var presenter: CrashReportPresenter

    var body: some View {
        Button("Re-enable Crash Notifications") {
            presenter.reenable()
        }
        .disabled(!presenter.isSuppressed)
        .help(presenter.isSuppressed
              ? String(localized: "Re-enable crash notifications and surface any unseen reports immediately")
              : String(localized: "Crash notifications are currently enabled"))
    }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        // Sparkle の KVO は内部キューから emit されることがあるので、
        // `@Published` への書き込みは明示的にメインに寄せる。これが無いと
        // SwiftUI が "Publishing changes from background threads" 警告を出す。
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
