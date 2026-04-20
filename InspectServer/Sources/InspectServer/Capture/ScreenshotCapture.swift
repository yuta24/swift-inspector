#if DEBUG && canImport(UIKit)
import UIKit

public enum ScreenshotCapture {
    @MainActor
    public static func screenshot(of view: UIView) -> Data? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return image.pngData()
    }
}
#endif
