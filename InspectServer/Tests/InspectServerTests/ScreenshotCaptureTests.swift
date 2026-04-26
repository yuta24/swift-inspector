#if canImport(UIKit)
import XCTest
import UIKit
@testable import InspectServer

@MainActor
final class ScreenshotCaptureTests: XCTestCase {
    // MARK: - Helpers

    /// Builds a solid-color CGImage of `size` for crop tests.
    private func makeCGImage(width: Int, height: Int, color: UIColor = .red) -> CGImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.cgImage!
    }

    // MARK: - cropImpl

    func test_crop_withZeroSizeRect_returnsNil() {
        let img = makeCGImage(width: 100, height: 100)
        let data = ScreenshotCapture.cropImpl(
            from: img,
            scale: 1,
            rectInWindow: CGRect(x: 10, y: 10, width: 0, height: 50),
            compressionQuality: 0.7
        )
        XCTAssertNil(data)
    }

    func test_crop_withRectFullyOutsideImage_returnsNil() {
        // Rect entirely outside the image bounds should clamp to empty and
        // return nil rather than crashing inside CGImage.cropping.
        let img = makeCGImage(width: 100, height: 100)
        let data = ScreenshotCapture.cropImpl(
            from: img,
            scale: 1,
            rectInWindow: CGRect(x: 200, y: 200, width: 50, height: 50),
            compressionQuality: 0.7
        )
        XCTAssertNil(data)
    }

    func test_crop_withRectPartiallyOutsideImage_clampsAndReturnsData() {
        // A view that extends past the window edge (common with status-bar
        // overlays or sheet animations) should be cropped to the visible part
        // rather than returning nil.
        let img = makeCGImage(width: 100, height: 100)
        let data = ScreenshotCapture.cropImpl(
            from: img,
            scale: 1,
            rectInWindow: CGRect(x: 80, y: 80, width: 50, height: 50),
            compressionQuality: 0.7
        )
        XCTAssertNotNil(data)
    }

    func test_crop_appliesScale() {
        // A 50x50 rect at scale=2 should sample a 100x100 region — verify by
        // requesting a region that's only valid at the scaled coordinates.
        let img = makeCGImage(width: 200, height: 200)
        let data = ScreenshotCapture.cropImpl(
            from: img,
            scale: 2,
            rectInWindow: CGRect(x: 25, y: 25, width: 50, height: 50),
            compressionQuality: 0.7
        )
        XCTAssertNotNil(data)
    }

    func test_crop_compressionQualityIsHonored() {
        // Higher quality should produce a larger (or equal) JPEG payload.
        let img = makeNoisyCGImage(width: 200, height: 200)
        let lo = ScreenshotCapture.cropImpl(
            from: img,
            scale: 1,
            rectInWindow: CGRect(x: 0, y: 0, width: 200, height: 200),
            compressionQuality: 0.1
        )
        let hi = ScreenshotCapture.cropImpl(
            from: img,
            scale: 1,
            rectInWindow: CGRect(x: 0, y: 0, width: 200, height: 200),
            compressionQuality: 0.95
        )
        XCTAssertNotNil(lo)
        XCTAssertNotNil(hi)
        XCTAssertGreaterThan(hi!.count, lo!.count)
    }

    // MARK: - soloScreenshot

    func test_soloScreenshot_returnsNilForZeroSizedView() {
        let view = UIView(frame: .zero)
        XCTAssertNil(ScreenshotCapture.soloScreenshot(of: view))
    }

    func test_soloScreenshot_capturesOpaqueColor() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        view.backgroundColor = .green
        let data = ScreenshotCapture.soloScreenshot(of: view)
        XCTAssertNotNil(data, "Opaque-colored view must round-trip to PNG")
    }

    func test_soloScreenshot_doesNotMutateSubviews() {
        // Sublayers are temporarily hidden during capture; their `isHidden`
        // state must be restored exactly afterward.
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        view.backgroundColor = .blue
        let inner = CALayer()
        inner.frame = CGRect(x: 4, y: 4, width: 8, height: 8)
        inner.backgroundColor = UIColor.black.cgColor
        let alreadyHidden = CALayer()
        alreadyHidden.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        alreadyHidden.isHidden = true
        view.layer.addSublayer(inner)
        view.layer.addSublayer(alreadyHidden)

        _ = ScreenshotCapture.soloScreenshot(of: view)

        XCTAssertFalse(inner.isHidden, "Visible sublayer must stay visible")
        XCTAssertTrue(alreadyHidden.isHidden, "Originally-hidden sublayer must stay hidden")
    }

    // MARK: - private helper

    /// Render gradient noise so JPEG compression actually has to work. A flat
    /// fill compresses identically at every quality level.
    private func makeNoisyCGImage(width: Int, height: Int) -> CGImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            for x in stride(from: 0, to: width, by: 4) {
                for y in stride(from: 0, to: height, by: 4) {
                    cg.setFillColor(
                        red: CGFloat((x * 7) % 255) / 255,
                        green: CGFloat((y * 11) % 255) / 255,
                        blue: CGFloat(((x + y) * 13) % 255) / 255,
                        alpha: 1
                    )
                    cg.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        return image.cgImage!
    }
}
#endif
