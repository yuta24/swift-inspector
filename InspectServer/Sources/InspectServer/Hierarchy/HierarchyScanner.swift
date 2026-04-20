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
            let windowCapture: (CGImage, CGFloat)?
            if captureScreenshots {
                windowCapture = ScreenshotCapture.captureWindow(window)
            } else {
                windowCapture = nil
            }
            return buildNode(
                from: window,
                window: window,
                windowCapture: windowCapture,
                captureScreenshots: captureScreenshots
            )
        }
    }

    static func buildNode(
        from view: UIView,
        window: UIWindow,
        windowCapture: (CGImage, CGFloat)?,
        captureScreenshots: Bool
    ) -> ViewNode {
        let groupScreenshot: Data?
        let soloScreenshot: Data?

        if captureScreenshots {
            // Group screenshot: crop from window capture (includes subviews)
            if let (windowImage, scale) = windowCapture {
                groupScreenshot = ScreenshotCapture.crop(
                    from: windowImage,
                    scale: scale,
                    view: view,
                    window: window
                )
            } else {
                groupScreenshot = nil
            }

            // Solo screenshot: this layer only, sublayers hidden
            soloScreenshot = ScreenshotCapture.soloScreenshot(of: view)
        } else {
            groupScreenshot = nil
            soloScreenshot = nil
        }

        let children = view.subviews.map {
            buildNode(
                from: $0,
                window: window,
                windowCapture: windowCapture,
                captureScreenshots: captureScreenshots
            )
        }

        let accID = view.accessibilityIdentifier?.isEmpty == false ? view.accessibilityIdentifier : nil
        let accLabel: String? = {
            let label = view.accessibilityLabel
            return (label?.isEmpty == false) ? label : nil
        }()

        return ViewNode(
            className: String(describing: type(of: view)),
            frame: view.frame,
            isHidden: view.isHidden,
            alpha: Double(view.alpha),
            backgroundColor: view.backgroundColor.flatMap(RGBAColor.init(uiColor:)),
            accessibilityIdentifier: accID,
            accessibilityLabel: accLabel,
            screenshot: groupScreenshot,
            soloScreenshot: soloScreenshot,
            children: children
        )
    }
}
#endif
