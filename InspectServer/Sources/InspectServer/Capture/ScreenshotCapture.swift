#if DEBUG && canImport(UIKit)
import UIKit

public enum ScreenshotCapture {
    /// Capture the entire window as a CGImage for cropping individual views.
    @MainActor
    public static func captureWindow(_ window: UIWindow) -> (CGImage, CGFloat)? {
        let bounds = window.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = min(UIScreen.main.scale, 2)
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return nil }
        return (cgImage, format.scale)
    }

    /// Crop a region from a window-level CGImage for a specific view (group screenshot).
    @MainActor
    public static func crop(
        from windowImage: CGImage,
        scale: CGFloat,
        view: UIView,
        window: UIWindow
    ) -> Data? {
        let rectInWindow = view.convert(view.bounds, to: window)
        guard rectInWindow.width >= 1, rectInWindow.height >= 1 else { return nil }

        let cropRect = CGRect(
            x: rectInWindow.origin.x * scale,
            y: rectInWindow.origin.y * scale,
            width: rectInWindow.width * scale,
            height: rectInWindow.height * scale
        )

        guard let cropped = windowImage.cropping(to: cropRect) else { return nil }
        let uiImage = UIImage(cgImage: cropped, scale: scale, orientation: .up)
        return uiImage.jpegData(compressionQuality: 0.7)
    }

    /// Capture only this layer's own content, hiding sublayers (solo screenshot).
    /// Uses CALayer.render(in:) with sublayers temporarily hidden, similar to Lookin's approach.
    @MainActor
    public static func soloScreenshot(of view: UIView) -> Data? {
        let layer = view.layer
        let bounds = layer.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let scale = min(UIScreen.main.scale, 2)

        // Temporarily hide all sublayers to capture only this layer's own drawing
        let sublayerStates: [(CALayer, Bool)] = (layer.sublayers ?? []).map { ($0, $0.isHidden) }
        for sublayer in layer.sublayers ?? [] {
            sublayer.isHidden = true
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }

        // Restore sublayer visibility
        for (sublayer, wasHidden) in sublayerStates {
            sublayer.isHidden = wasHidden
        }

        // Skip if the image is completely empty/transparent
        guard let cgImage = image.cgImage else { return nil }
        if cgImage.alphaInfo == .alphaOnly { return nil }

        return image.jpegData(compressionQuality: 0.7)
    }
}
#endif
