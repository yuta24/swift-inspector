#if DEBUG && canImport(UIKit)
import UIKit
import InspectCore

@MainActor
public enum HierarchyScanner {
    public static func captureAllWindows(captureScreenshots: Bool = true) -> [ViewNode] {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }

        return windows.map { window in
            buildNode(from: window, isRoot: true, captureScreenshots: captureScreenshots)
        }
    }

    static func buildNode(from view: UIView, isRoot: Bool, captureScreenshots: Bool) -> ViewNode {
        let screenshot: Data?
        if captureScreenshots && isRoot {
            screenshot = ScreenshotCapture.screenshot(of: view)
        } else {
            screenshot = nil
        }

        let children = view.subviews.map {
            buildNode(from: $0, isRoot: false, captureScreenshots: captureScreenshots)
        }

        return ViewNode(
            className: String(describing: type(of: view)),
            frame: view.frame,
            isHidden: view.isHidden,
            alpha: Double(view.alpha),
            backgroundColor: view.backgroundColor.flatMap(RGBAColor.init(uiColor:)),
            screenshot: screenshot,
            children: children
        )
    }
}
#endif
