#if canImport(UIKit)
import XCTest
import UIKit
import InspectCore
@testable import InspectServer

@MainActor
final class HierarchyScannerTests: XCTestCase {
    // MARK: - Helpers

    private func makeWindow(size: CGSize = CGSize(width: 320, height: 480)) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.isHidden = false
        return window
    }

    /// Calls the same builder `captureAllWindows` uses, but on a constructed
    /// window so the test owns the hierarchy.
    private func build(_ root: UIView, in window: UIWindow) -> ViewNode {
        ViewIdentRegistry.shared.clear()
        return HierarchyScanner.buildNode(
            from: root,
            window: window,
            windowCapture: nil,
            captureScreenshots: false,
            depth: 0
        )
    }

    // MARK: - Basic structure

    func test_buildNode_capturesUIViewSubviews() {
        let window = makeWindow()
        let root = UIView(frame: window.bounds)
        let a = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = UIView(frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        root.addSubview(a)
        root.addSubview(b)
        window.addSubview(root)

        let node = build(root, in: window)
        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.children[0].frame.width, 100)
        XCTAssertEqual(node.children[1].frame.origin.x, 100)
    }

    func test_buildNode_includesUnbackedCALayerChildren() {
        // CALayer.sublayers that are NOT backing layers of any UIView subview
        // should appear as ViewNode children — this is what lets the inspector
        // show e.g. a CAShapeLayer added directly to view.layer.
        let window = makeWindow()
        let root = UIView(frame: window.bounds)
        let extra = CAShapeLayer()
        extra.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
        root.layer.addSublayer(extra)
        window.addSubview(root)

        let node = build(root, in: window)
        XCTAssertEqual(node.children.count, 1)
        XCTAssertTrue(node.children[0].className.contains("CAShapeLayer"))
    }

    func test_buildNode_skipsBackingLayersOfSubviews() {
        // The subview's own backing layer must not be reported as a sublayer
        // child — otherwise every UIView would double-emit.
        let window = makeWindow()
        let root = UIView(frame: window.bounds)
        let child = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        root.addSubview(child)
        window.addSubview(root)

        let node = build(root, in: window)
        XCTAssertEqual(node.children.count, 1)
        XCTAssertFalse(node.children[0].className.contains("CALayer"))
    }

    // MARK: - Depth limit

    func test_buildNode_truncatesAtMaxDepth() {
        // Build a chain deeper than the cap and verify we stop, mark the cut
        // point, and don't crash.
        let window = makeWindow()
        let root = UIView(frame: window.bounds)
        var current: UIView = root
        let chainLength = HierarchyScanner.maxDepth + 50
        for _ in 0..<chainLength {
            let next = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            current.addSubview(next)
            current = next
        }
        window.addSubview(root)

        let rootNode = build(root, in: window)

        // Walk down counting how many levels we got back, and look for the marker.
        var depth = 0
        var node: ViewNode? = rootNode
        var foundTruncationMarker = false
        while let n = node {
            if n.properties["_truncated"] != nil {
                foundTruncationMarker = true
            }
            node = n.children.first
            depth += 1
        }
        XCTAssertLessThanOrEqual(depth, HierarchyScanner.maxDepth + 1)
        XCTAssertTrue(foundTruncationMarker, "Expected a _truncated marker at the cut point")
    }

    func test_buildNode_doesNotMarkTruncationOnLeaves() {
        let window = makeWindow()
        let leaf = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        window.addSubview(leaf)
        let node = build(leaf, in: window)
        XCTAssertNil(node.properties["_truncated"])
        XCTAssertTrue(node.children.isEmpty)
    }

    // MARK: - Constraints

    func test_buildNode_filtersSystemConstraints() {
        // A view with translatesAutoresizingMaskIntoConstraints = true gets
        // four NSAutoresizingMaskLayoutConstraint entries from UIKit. Those
        // must be filtered out so designer-authored constraints aren't drowned.
        let window = makeWindow()
        let root = UIView(frame: window.bounds)
        let child = UIView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        // Default: translatesAutoresizingMaskIntoConstraints == true.
        root.addSubview(child)
        window.addSubview(root)
        // Force layout so UIKit materialises the implicit constraints.
        root.layoutIfNeeded()

        let node = build(root, in: window)
        let childNode = node.children[0]
        // No constraints authored explicitly → all should have been filtered.
        XCTAssertTrue(childNode.constraints.isEmpty,
                      "Implicit autoresizing constraints leaked through filter")
    }

    func test_buildNode_keepsUserAuthoredConstraints() {
        let window = makeWindow()
        let root = UIView(frame: window.bounds)
        let child = UIView()
        child.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(child)
        window.addSubview(root)

        let widthConstraint = child.widthAnchor.constraint(equalToConstant: 42)
        widthConstraint.identifier = "test-width"
        widthConstraint.isActive = true

        let node = build(root, in: window)
        let childNode = node.children[0]
        let constraints = childNode.constraints
        let found = constraints.first { $0.identifier == "test-width" }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.constant, 42)
        // width-as-constant has only a first anchor.
        XCTAssertNil(found?.second)
    }

    // MARK: - Property extraction

    func test_buildNode_extractsLabelProperties() {
        let window = makeWindow()
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        label.text = "hello"
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .red
        label.textAlignment = .center
        label.numberOfLines = 3
        window.addSubview(label)

        let node = build(label, in: window)
        XCTAssertEqual(node.properties["text"], "hello")
        XCTAssertEqual(node.typography?.pointSize, 17)
        XCTAssertEqual(node.typography?.weightName, "semibold")
        XCTAssertEqual(node.typography?.alignment, "center")
        XCTAssertEqual(node.typography?.numberOfLines, 3)
    }

    func test_buildNode_extractsScrollViewProperties() {
        let window = makeWindow()
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: 600, height: 1200)
        scroll.isPagingEnabled = true
        window.addSubview(scroll)

        let node = build(scroll, in: window)
        XCTAssertEqual(node.properties["contentSize"], "600x1200")
        XCTAssertEqual(node.properties["isPagingEnabled"], "true")
        // contentOffset is dumped — exact value depends on UIKit's adjusted
        // content insets, so just confirm the key is present.
        XCTAssertNotNil(node.properties["contentOffset"])
    }

    func test_buildNode_extractsStackViewProperties() {
        let window = makeWindow()
        let stack = UIStackView(arrangedSubviews: [UIView(), UIView()])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        window.addSubview(stack)

        let node = build(stack, in: window)
        XCTAssertEqual(node.properties["axis"], "horizontal")
        XCTAssertEqual(node.properties["spacing"], "8")
        XCTAssertEqual(node.properties["alignment"], "center")
        XCTAssertEqual(node.properties["distribution"], "fillEqually")
    }

    // MARK: - Geometry

    func test_buildNode_recordsCornersInWindow() {
        let window = makeWindow()
        let root = UIView(frame: CGRect(x: 30, y: 50, width: 100, height: 80))
        window.addSubview(root)

        let node = build(root, in: window)
        let corners = node.cornersInWindow
        XCTAssertEqual(corners?.count, 4)
        XCTAssertEqual(corners?[0], CGPoint(x: 30, y: 50))
        XCTAssertEqual(corners?[3], CGPoint(x: 130, y: 130))
    }

    // MARK: - Layer-only branch

    func test_buildLayerNode_truncatesAtMaxDepth() {
        let window = makeWindow()
        let root = CALayer()
        root.frame = window.bounds
        window.layer.addSublayer(root)

        var current = root
        for _ in 0..<(HierarchyScanner.maxDepth + 10) {
            let next = CALayer()
            next.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
            current.addSublayer(next)
            current = next
        }

        ViewIdentRegistry.shared.clear()
        let node = HierarchyScanner.buildNode(
            fromLayer: root,
            window: window,
            windowCapture: nil,
            captureScreenshots: false,
            depth: 0
        )

        var depth = 0
        var n: ViewNode? = node
        var truncatedMarker = false
        while let cur = n {
            if cur.properties["_truncated"] != nil { truncatedMarker = true }
            n = cur.children.first
            depth += 1
        }
        XCTAssertLessThanOrEqual(depth, HierarchyScanner.maxDepth + 1)
        XCTAssertTrue(truncatedMarker)
    }
}
#endif
