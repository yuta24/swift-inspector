#if canImport(UIKit)
import XCTest
import UIKit
import InspectCore
@testable import InspectServer

/// Coarse perf baseline for the server's main hot paths. Runs against
/// synthetic hierarchies sized to roughly bracket what real iOS apps
/// produce: ~1k nodes is "rich" UIKit, ~5k nodes is "stress" — the kind
/// of tree that a card-based feed or Auto Layout-heavy form might emit.
///
/// These aren't strict assertions — XCTest captures a baseline and only
/// flags regressions when a future run drifts > 25% on the configured
/// tolerance. The goal is to catch order-of-magnitude regressions
/// (someone accidentally re-rendering screenshots in a loop, say), not
/// to police small frame-time wobble.
@MainActor
final class PerformanceTests: XCTestCase {
    // MARK: - Tree builders

    /// Wide-and-shallow tree: one root with `width^depth` total leaf views.
    /// Approximates the shape of a typical scroll feed (a stack of cards).
    private func buildWideTree(branching width: Int, depth: Int) -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        addChildren(to: root, width: width, depth: depth, leafSize: 20)
        return (window, root)
    }

    private func addChildren(to parent: UIView, width: Int, depth: Int, leafSize: CGFloat) {
        guard depth > 0 else { return }
        for i in 0..<width {
            let v = UIView(frame: CGRect(
                x: CGFloat(i) * (leafSize + 2),
                y: 0,
                width: leafSize,
                height: leafSize
            ))
            parent.addSubview(v)
            addChildren(to: v, width: width, depth: depth - 1, leafSize: leafSize)
        }
    }

    private func nodeCount(_ node: ViewNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount($1) }
    }

    private func collectAllViews(_ root: UIView) -> [UIView] {
        var result: [UIView] = [root]
        var i = 0
        while i < result.count {
            result.append(contentsOf: result[i].subviews)
            i += 1
        }
        return result
    }

    // MARK: - Baselines

    /// ~256 nodes (4-wide × 4-deep). Should be sub-millisecond — anything
    /// slower means buildNode picked up a per-node heavyweight call.
    func test_perf_buildNode_smallTree_noScreenshots() {
        let (window, root) = buildWideTree(branching: 4, depth: 4)

        // Sanity check the test setup before running the timed block —
        // measure() repeats and a wrong shape would silently distort the baseline.
        ViewIdentRegistry.shared.clear()
        let probe = HierarchyScanner.buildNode(
            from: root,
            window: window,
            windowCapture: nil,
            captureScreenshots: false
        )
        XCTAssertGreaterThan(nodeCount(probe), 200)

        measure {
            ViewIdentRegistry.shared.clear()
            _ = HierarchyScanner.buildNode(
                from: root,
                window: window,
                windowCapture: nil,
                captureScreenshots: false
            )
        }
    }

    /// ~1296 nodes (6-wide × 4-deep). The "rich app" baseline.
    func test_perf_buildNode_mediumTree_noScreenshots() {
        let (window, root) = buildWideTree(branching: 6, depth: 4)
        measure {
            ViewIdentRegistry.shared.clear()
            _ = HierarchyScanner.buildNode(
                from: root,
                window: window,
                windowCapture: nil,
                captureScreenshots: false
            )
        }
    }

    /// Deep chain at the depth cap. Verifies the truncation guard keeps
    /// pathological depth O(maxDepth) rather than O(actual depth).
    func test_perf_buildNode_atDepthCap() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        var current: UIView = root
        for _ in 0..<(HierarchyScanner.maxDepth + 50) {
            let next = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            current.addSubview(next)
            current = next
        }

        measure {
            ViewIdentRegistry.shared.clear()
            _ = HierarchyScanner.buildNode(
                from: root,
                window: window,
                windowCapture: nil,
                captureScreenshots: false
            )
        }
    }

    // MARK: - HierarchyChangeMonitor fingerprint
    //
    // The monitor recomputes its FNV-1a fingerprint over every attached
    // window tree on each `.beforeWaiting` tick (≈60Hz). At ~1k+ nodes this
    // is a continuous main-thread cost, so it gets its own baseline.

    func test_perf_changeMonitor_hash_smallTree() {
        let (_, root) = buildWideTree(branching: 4, depth: 4)
        measure {
            _ = HierarchyChangeMonitor._hashTreesForTesting([root])
        }
    }

    func test_perf_changeMonitor_hash_mediumTree() {
        let (_, root) = buildWideTree(branching: 6, depth: 4)
        measure {
            _ = HierarchyChangeMonitor._hashTreesForTesting([root])
        }
    }

    /// ~5k nodes — the "stress" baseline. If this gets slow, the .beforeWaiting
    /// observer will start eating frames in apps with dense feeds.
    func test_perf_changeMonitor_hash_largeTree() {
        let (_, root) = buildWideTree(branching: 8, depth: 4)
        measure {
            _ = HierarchyChangeMonitor._hashTreesForTesting([root])
        }
    }

    // MARK: - Per-extractor decomposition
    //
    // buildNode at 1296 nodes lands at ~7ms. These tests break that down so
    // we can see which extractor is dominant before optimizing further.
    // Each measure block runs the extractor across all ~1296 views once.

    func test_perf_extract_classNameDescription_mediumTree() {
        let (_, root) = buildWideTree(branching: 6, depth: 4)
        let allViews = collectAllViews(root)
        XCTAssertGreaterThan(allViews.count, 1000)
        measure {
            for v in allViews {
                _ = String(describing: type(of: v))
            }
        }
    }

    func test_perf_extract_properties_mediumTree() {
        let (_, root) = buildWideTree(branching: 6, depth: 4)
        let allViews = collectAllViews(root)
        measure {
            for v in allViews {
                _ = HierarchyScanner._extractPropertiesForTesting(v)
            }
        }
    }

    func test_perf_extract_typography_mediumTree() {
        let (_, root) = buildWideTree(branching: 6, depth: 4)
        let allViews = collectAllViews(root)
        measure {
            for v in allViews {
                _ = HierarchyScanner._extractTypographyForTesting(v)
            }
        }
    }

    func test_perf_extract_constraints_mediumTree() {
        let (_, root) = buildWideTree(branching: 6, depth: 4)
        let allViews = collectAllViews(root)
        measure {
            for v in allViews {
                _ = HierarchyScanner._extractConstraintsForTesting(v)
            }
        }
    }

    /// Cropping cost should scale with output bytes, not source image size —
    /// guards against accidentally re-encoding the whole window per crop.
    func test_perf_screenshotCrop() {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 800, height: 1200),
            format: format
        )
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
        }
        guard let cgImage = image.cgImage else {
            XCTFail("Could not create test image")
            return
        }

        measure {
            for i in 0..<200 {
                _ = ScreenshotCapture.cropImpl(
                    from: cgImage,
                    scale: 2,
                    rectInWindow: CGRect(
                        x: CGFloat(i % 100),
                        y: CGFloat((i * 3) % 100),
                        width: 100,
                        height: 100
                    ),
                    compressionQuality: 0.7
                )
            }
        }
    }
}
#endif
