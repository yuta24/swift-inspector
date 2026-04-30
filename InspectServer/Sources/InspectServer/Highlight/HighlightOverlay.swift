#if (DEBUG || SWIFT_INSPECTOR_ENABLED) && canImport(UIKit)
import UIKit
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "highlight")

@MainActor
enum HighlightOverlay {
    private static var overlayWindow: UIWindow?
    private static var overlayView: HighlightView?
    /// Scene the overlay window is currently parented under. Tracked
    /// weakly because the scene's lifetime is owned by UIKit; we only
    /// need it to compare incoming `didDisconnectNotification` payloads.
    private static weak var overlayScene: UIWindowScene?
    private static var sceneObserver: NSObjectProtocol?

    static func highlight(viewWithIdent ident: UUID) {
        guard let (view, scene) = findView(ident: ident) else {
            logger.warning("Highlight target not found: \(ident.uuidString, privacy: .public)")
            clear()
            return
        }

        let frame = view.convert(view.bounds, to: nil)
        logger.debug("Highlighting view at \(String(describing: frame), privacy: .public)")

        // Re-create the overlay window when the target moved to a
        // different scene (multi-window iPad / Stage Manager) — the
        // existing window is bound to the old scene and would render
        // on the wrong display.
        if overlayWindow == nil || overlayScene !== scene {
            tearDownOverlay()
            let window = PassthroughWindow(windowScene: scene)
            window.windowLevel = .statusBar + 100
            window.backgroundColor = .clear
            window.isHidden = false

            let highlightView = HighlightView()
            window.addSubview(highlightView)
            overlayWindow = window
            overlayView = highlightView
            overlayScene = scene
            installSceneObserverIfNeeded()
        }

        overlayView?.frame = frame
    }

    static func clear() {
        tearDownOverlay()
    }

    /// Drops every reference to the current overlay window so ARC can
    /// collect it and the underlying `UIWindowScene` is no longer pinned
    /// by us. Idempotent; safe to call when nothing is up.
    private static func tearDownOverlay() {
        overlayWindow?.isHidden = true
        // Detach from the scene explicitly: setting `windowScene = nil`
        // breaks the scene's strong list of windows so a scene that's
        // about to disconnect doesn't keep this window alive in its
        // `windows` array.
        overlayWindow?.windowScene = nil
        overlayView?.removeFromSuperview()
        overlayWindow = nil
        overlayView = nil
        overlayScene = nil
    }

    /// Installs a single process-wide observer for `UIScene` disconnects.
    /// Without this, the static `overlayWindow` would pin a scene's
    /// `UIWindow` past `didDisconnectNotification` and block the scene's
    /// teardown — observable as a stuck Stage Manager tile or a leaked
    /// scene in Instruments after closing a multi-window iPad workspace.
    private static func installSceneObserverIfNeeded() {
        guard sceneObserver == nil else { return }
        sceneObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { notification in
            // The notification fires on the main queue; hop into the
            // MainActor isolation domain so we can touch our static
            // state without a Sendable warning.
            MainActor.assumeIsolated {
                guard let scene = notification.object as? UIWindowScene,
                      scene === overlayScene else { return }
                tearDownOverlay()
            }
        }
    }

    private static func findView(ident: UUID) -> (UIView, UIWindowScene)? {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if window === overlayWindow { continue }
                if let found = findView(ident: ident, in: window) {
                    return (found, scene)
                }
            }
        }
        return nil
    }

    private static func findView(ident: UUID, in view: UIView) -> UIView? {
        // We need to match by building the same UUID as during hierarchy capture.
        // Since ViewNode uses a fresh UUID each capture, we match by traversal order
        // using the ident stored during the last capture.
        if ViewIdentRegistry.shared.ident(for: view) == ident {
            return view
        }
        for subview in view.subviews {
            if let found = findView(ident: ident, in: subview) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Passthrough Window

private class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}

// MARK: - Highlight View

private class HighlightView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 2
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
