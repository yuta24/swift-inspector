#if (DEBUG || SWIFT_INSPECTOR_ENABLED) && canImport(UIKit)
import UIKit

enum ScreenshotCapture {
    /// JPEG compression quality used for group (and layer-group) screenshots.
    /// Set by the listener whenever the client sends `setOptions`. The default
    /// (0.7) is balanced for the device-→Mac wire — visibly fine, ~3× smaller
    /// than 0.95. Allowed range is 0.1…1.0; values outside that are ignored
    /// by the listener before they reach this point.
    @MainActor static var jpegQuality: CGFloat = 0.7

    /// Capture the entire window as a CGImage for cropping individual views.
    @MainActor
    static func captureWindow(_ window: UIWindow) -> (CGImage, CGFloat)? {
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
    static func crop(
        from windowImage: CGImage,
        scale: CGFloat,
        view: UIView,
        window: UIWindow,
        compressionQuality: CGFloat? = nil
    ) -> Data? {
        let rectInWindow = view.convert(view.bounds, to: window)
        return cropImpl(
            from: windowImage,
            scale: scale,
            rectInWindow: rectInWindow,
            compressionQuality: compressionQuality ?? jpegQuality
        )
    }

    /// Capture only this layer's own content, hiding sublayers (solo screenshot).
    /// Uses CALayer.render(in:) with sublayers temporarily hidden.
    /// Returns PNG data to preserve transparency for 3D layer compositing.
    @MainActor
    static func soloScreenshot(of view: UIView) -> Data? {
        let layer = view.layer
        let bounds = layer.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let scale = min(UIScreen.main.scale, 2)

        // Temporarily hide sublayers at the CALayer level only.
        // Avoid touching view.isHidden — it has broader side effects
        // (layout, accessibility, animations) that can corrupt the live UI.
        let sublayerStates: [(CALayer, Bool)] = (layer.sublayers ?? []).map { ($0, $0.isHidden) }
        for sublayer in layer.sublayers ?? [] {
            sublayer.isHidden = true
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
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
        if isFullyTransparent(cgImage) { return nil }

        return image.pngData()
    }

    /// Crop a region from a window-level CGImage for a specific CALayer (group screenshot).
    @MainActor
    static func cropLayer(
        from windowImage: CGImage,
        scale: CGFloat,
        layer: CALayer,
        window: UIWindow,
        compressionQuality: CGFloat? = nil
    ) -> Data? {
        let rectInWindow = layer.convert(layer.bounds, to: window.layer)
        return cropImpl(
            from: windowImage,
            scale: scale,
            rectInWindow: rectInWindow,
            compressionQuality: compressionQuality ?? jpegQuality
        )
    }

    /// Shared crop logic with safe clamping. Pulled out so view/layer crops
    /// stay in sync and unit tests can exercise the boundary math directly.
    static func cropImpl(
        from windowImage: CGImage,
        scale: CGFloat,
        rectInWindow: CGRect,
        compressionQuality: CGFloat
    ) -> Data? {
        guard rectInWindow.width >= 1, rectInWindow.height >= 1 else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: windowImage.width, height: windowImage.height)
        let cropRect = CGRect(
            x: rectInWindow.origin.x * scale,
            y: rectInWindow.origin.y * scale,
            width: rectInWindow.width * scale,
            height: rectInWindow.height * scale
        ).integral.intersection(imageBounds)
        guard cropRect.width >= 1, cropRect.height >= 1 else { return nil }

        guard let cropped = windowImage.cropping(to: cropRect) else { return nil }
        let uiImage = UIImage(cgImage: cropped, scale: scale, orientation: .up)
        return uiImage.jpegData(compressionQuality: compressionQuality)
    }

    /// Capture a CALayer's own drawing with its sublayers hidden (solo screenshot).
    /// Safe because we only toggle CALayer.isHidden, not UIView.isHidden.
    @MainActor
    static func soloScreenshotOfLayer(_ layer: CALayer) -> Data? {
        let bounds = layer.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let scale = min(UIScreen.main.scale, 2)

        let sublayerStates: [(CALayer, Bool)] = (layer.sublayers ?? []).map { ($0, $0.isHidden) }
        for sublayer in layer.sublayers ?? [] {
            sublayer.isHidden = true
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }

        for (sublayer, wasHidden) in sublayerStates {
            sublayer.isHidden = wasHidden
        }

        guard let cgImage = image.cgImage else { return nil }
        if isFullyTransparent(cgImage) { return nil }

        return image.pngData()
    }

    /// Check if a CGImage has no visible pixels.
    private static func isFullyTransparent(_ image: CGImage) -> Bool {
        guard let alphaInfo = CGImageAlphaInfo(rawValue: image.alphaInfo.rawValue),
              alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast else {
            return false
        }
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else {
            return true
        }
        let byteCount = CFDataGetLength(data)
        guard byteCount > 0 else { return true }
        let ptr = CFDataGetBytePtr(data)!
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else { return false }

        // Sample pixels to check for non-transparent content
        let totalPixels = byteCount / bytesPerPixel
        let step = max(1, totalPixels / 256)
        let alphaOffset: Int
        switch alphaInfo {
        case .premultipliedFirst, .first:
            alphaOffset = 0
        default:
            alphaOffset = bytesPerPixel - 1
        }
        for i in stride(from: 0, to: totalPixels, by: step) {
            if ptr[i * bytesPerPixel + alphaOffset] > 0 {
                return false
            }
        }
        return true
    }
}
#endif
