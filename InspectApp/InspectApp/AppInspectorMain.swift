import SwiftUI
import AppKit
import InspectCore
import Sparkle
import os.log

private let mainLogger = Logger(subsystem: "swift-inspector", category: "main")

@main
struct AppInspectorMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppInspectorModel()
    @StateObject private var crashPresenter = CrashReportPresenter()
    @StateObject private var figmaModel = FigmaComparisonModel()
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
        WindowGroup("AppInspector") {
            ContentView()
                .environmentObject(model)
                .environmentObject(crashPresenter)
                .environmentObject(figmaModel)
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
            // File menu — the SPM build has no document-based plumbing,
            // so there's no "New" to keep. Replace it with the bug-bundle
            // workflow: Open / Export / Close-when-offline. Disabled
            // states are bound to model state so the menu silently
            // greys out at moments when the action would be a no-op.
            CommandGroup(replacing: .newItem) {
                BugBundleCommands(model: model)
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(model)
                .environmentObject(figmaModel)
        }
    }
}

/// Sparkle の `SPUStandardUpdaterController` と、それを購読する
/// `CheckForUpdatesViewModel` のペアを束ねる入れ物。両方の生存期間を
/// `AppInspectorMain` (＝プロセス) に揃えるためのバンドル。
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
    var model: AppInspectorModel?

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

// MARK: - Bug Bundle Menu Items

/// File-menu commands for the bug-bundle workflow: Open a `.swiftinspector`
/// file (replaces "New"), Export the current snapshot, and Close the
/// offline bundle when one is loaded. Bound directly to `AppInspectorModel`
/// because the items' enabled state depends on connection / offline-mode
/// transitions, and the file dialogs route their result back through the
/// model's `loadOfflineBundle` / `currentBugBundle` helpers.
private struct BugBundleCommands: View {
    @ObservedObject var model: AppInspectorModel

    var body: some View {
        Button("Open Bug Bundle…") {
            openBundle()
        }
        .keyboardShortcut("o", modifiers: .command)

        Divider()

        Button("Export Bug Bundle…") {
            exportBundle()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        // Enabled whenever there's a hierarchy to export, regardless of
        // whether `roots` came from a live device or a loaded bundle.
        // The QA-handoff loop ("open a bundle, type repro steps in the
        // notes field, save to a new path") relies on the offline
        // case being writable too — `currentBugBundle()` is happy with
        // either source because it reads from `roots` directly.
        .disabled(model.roots.isEmpty)

        if model.isOfflineMode {
            Button("Close Bug Bundle") {
                model.closeOfflineBundle()
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }

    private func exportBundle() {
        guard let bundle = model.currentBugBundle() else { return }
        let defaultName = BugBundleService.defaultFileName(deviceName: model.lastHandshake?.deviceName)
        do {
            if let url = try BugBundleService.presentSavePanel(for: bundle, defaultName: defaultName) {
                // Reveal in Finder so the user immediately sees where
                // the bundle ended up — most exports are followed by
                // "drag this into Slack/Jira" and pre-selecting the
                // file shaves a step.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            mainLogger.error("Bug-bundle export failed: \(error.localizedDescription, privacy: .public)")
            presentError(title: String(localized: "Couldn't export bundle"), error: error)
        }
    }

    private func openBundle() {
        do {
            if let result = try BugBundleService.presentOpenPanel() {
                model.loadOfflineBundle(result.bundle, from: result.url)
            }
        } catch {
            mainLogger.error("Bug-bundle open failed: \(error.localizedDescription, privacy: .public)")
            presentError(title: String(localized: "Couldn't open bundle"), error: error)
        }
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
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
