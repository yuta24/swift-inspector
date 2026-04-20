#if DEBUG && canImport(UIKit)
import UIKit
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "highlight")

@MainActor
enum HighlightOverlay {
    private static var overlayWindow: UIWindow?
    private static var overlayView: HighlightView?

    static func highlight(viewWithIdent ident: UUID) {
        guard let (view, scene) = findView(ident: ident) else {
            logger.warning("Highlight target not found: \(ident.uuidString, privacy: .public)")
            clear()
            return
        }

        let frame = view.convert(view.bounds, to: nil)
        logger.debug("Highlighting view at \(String(describing: frame), privacy: .public)")

        if overlayWindow == nil {
            let window = PassthroughWindow(windowScene: scene)
            window.windowLevel = .statusBar + 100
            window.backgroundColor = .clear
            window.isHidden = false

            let highlightView = HighlightView()
            window.addSubview(highlightView)
            overlayWindow = window
            overlayView = highlightView
        }

        overlayView?.frame = frame
    }

    static func clear() {
        overlayWindow?.isHidden = true
        overlayWindow = nil
        overlayView = nil
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
