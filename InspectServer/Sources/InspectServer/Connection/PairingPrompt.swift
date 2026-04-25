#if (DEBUG || SWIFT_INSPECTOR_ENABLED) && canImport(UIKit)
import UIKit
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "pairing")

/// User's response to the device-side approval dialog.
enum PairingDecision {
    /// Approve this connection and remember the Mac so future sessions are
    /// automatic.
    case alwaysAllow
    /// Approve this single connection only; the next session will prompt
    /// again.
    case allowOnce
    /// Refuse the connection.
    case deny
}

/// Presents the "Mac '...' から接続要求" dialog on the device. We host the
/// alert inside a dedicated UIWindow so the host app doesn't need to expose
/// any view-controller hook — the prompt overlays whatever the user is
/// currently doing, in the same way HighlightOverlay overlays inspection
/// highlights.
///
/// Concurrent requests (two Macs trying to pair at the same time) are
/// queued and presented one after the other. UIAlertController is modal and
/// stacking two simultaneous dialogs would either obscure the first or
/// orphan its window, so serialization is the only safe option.
@MainActor
enum PairingPrompt {
    private struct Pending {
        let clientName: String
        let completion: @MainActor (PairingDecision) -> Void
    }

    private static var promptWindow: UIWindow?
    private static var queue: [Pending] = []

    /// `clientName` is shown verbatim in the dialog body. The completion
    /// runs on the main actor with the user's choice; if no UIWindowScene
    /// is available (extension contexts, very early launch), the call
    /// completes with `.deny` and a logged warning instead of hanging.
    static func ask(
        clientName: String,
        completion: @escaping @MainActor (PairingDecision) -> Void
    ) {
        let pending = Pending(clientName: clientName, completion: completion)
        if promptWindow != nil {
            logger.info("Queueing pair prompt while another is visible: \(clientName, privacy: .public)")
            queue.append(pending)
            return
        }
        present(pending)
    }

    private static func present(_ pending: Pending) {
        guard let scene = activeScene() else {
            logger.warning("Pairing prompt requested without an active UIWindowScene; auto-denying")
            pending.completion(.deny)
            drainNext()
            return
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIViewController()
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.makeKeyAndVisible()
        promptWindow = window

        let alert = UIAlertController(
            title: "swift-inspector への接続要求",
            message: "Mac \"\(pending.clientName)\" がこのアプリの View 階層を取得しようとしています。",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "常に許可", style: .default) { _ in
            finish(pending: pending, decision: .alwaysAllow)
        })
        alert.addAction(UIAlertAction(title: "今回だけ許可", style: .default) { _ in
            finish(pending: pending, decision: .allowOnce)
        })
        alert.addAction(UIAlertAction(title: "拒否", style: .cancel) { _ in
            finish(pending: pending, decision: .deny)
        })

        host.present(alert, animated: true)
    }

    private static func finish(pending: Pending, decision: PairingDecision) {
        tearDown()
        pending.completion(decision)
        drainNext()
    }

    private static func drainNext() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        present(next)
    }

    private static func tearDown() {
        promptWindow?.isHidden = true
        promptWindow = nil
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let foreground = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return foreground
        }
        return scenes.first
    }
}
#endif
