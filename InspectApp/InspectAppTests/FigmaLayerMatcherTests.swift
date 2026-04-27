import XCTest
import InspectCore
@testable import AppInspector

final class FigmaLayerMatcherTests: XCTestCase {
    private let frame = FigmaNode(
        id: "frame",
        name: "iPhone",
        type: "FRAME",
        absoluteBoundingBox: .init(x: 0, y: 0, width: 393, height: 852),
        children: [
            FigmaNode(
                id: "header",
                name: "header-bar",
                type: "FRAME",
                absoluteBoundingBox: .init(x: 0, y: 0, width: 393, height: 64)
            ),
            FigmaNode(
                id: "title",
                name: "title-label",
                type: "TEXT",
                absoluteBoundingBox: .init(x: 24, y: 16, width: 200, height: 32),
                characters: "Welcome"
            ),
            FigmaNode(
                id: "cta",
                name: "primary-cta",
                type: "RECTANGLE",
                absoluteBoundingBox: .init(x: 24, y: 700, width: 345, height: 56),
                cornerRadius: 12
            ),
        ]
    )

    func testIdentifierNameMatchWins() {
        let viewNode = ViewNode(
            className: "UIButton",
            frame: .zero,
            accessibilityIdentifier: "primary-cta"
        )
        let match = FigmaLayerMatcher(frame: frame).match(viewNode: viewNode)
        XCTAssertEqual(match?.strategy, .identifierName)
        XCTAssertEqual(match?.layer.id, "cta")
        XCTAssertEqual(match?.confidence, .high)
    }

    func testTextContentMatchWhenNoIdentifier() {
        // No accessibilityIdentifier on the label → fall back to text.
        let viewNode = ViewNode(
            className: "UILabel",
            frame: .zero,
            properties: ["text": "Welcome"]
        )
        let match = FigmaLayerMatcher(frame: frame).match(viewNode: viewNode)
        XCTAssertEqual(match?.strategy, .textContent)
        XCTAssertEqual(match?.layer.id, "title")
    }

    func testBoundingBoxFallbackPicksClosest() {
        // Bare UIView with no identifier and no text — only its window
        // frame can pin it down.
        let viewNode = ViewNode(
            className: "UIView",
            frame: CGRect(x: 24, y: 700, width: 345, height: 56),
            windowFrame: CGRect(x: 24, y: 700, width: 345, height: 56)
        )
        let match = FigmaLayerMatcher(frame: frame).match(viewNode: viewNode)
        XCTAssertEqual(match?.strategy, .boundingBox)
        XCTAssertEqual(match?.layer.id, "cta")
        XCTAssertEqual(match?.confidence, .high)
    }

    func testBoundingBoxIgnoresNonOverlappingNodes() {
        // ViewNode positioned somewhere outside any Figma layer → no match
        // (we'd rather show "no counterpart" than a confidently-wrong one).
        let viewNode = ViewNode(
            className: "UIView",
            frame: .zero,
            windowFrame: CGRect(x: 9000, y: 9000, width: 10, height: 10)
        )
        let match = FigmaLayerMatcher(frame: frame).match(viewNode: viewNode)
        XCTAssertNil(match)
    }

    func testMatchAllVisitsDescendants() {
        let child = ViewNode(
            className: "UILabel",
            frame: .zero,
            accessibilityIdentifier: "title-label"
        )
        let root = ViewNode(
            className: "UIView",
            frame: .zero,
            accessibilityIdentifier: "header-bar",
            children: [child]
        )
        let map = FigmaLayerMatcher(frame: frame).matchAll(roots: [root])
        XCTAssertEqual(map[root.ident]?.layer.id, "header")
        XCTAssertEqual(map[child.ident]?.layer.id, "title")
    }

    func testFrameItselfIsNotAFallbackTarget() {
        // The root frame is a candidate name-wise (`name == "iPhone"`) but
        // bbox fallback excludes it explicitly so a leaf doesn't collapse
        // onto the canvas.
        let viewNode = ViewNode(
            className: "UIView",
            frame: .zero,
            windowFrame: CGRect(x: 0, y: 0, width: 393, height: 852)
        )
        let match = FigmaLayerMatcher(frame: frame).match(viewNode: viewNode)
        // bbox best score would otherwise be the frame; matcher should
        // either return the next-best (header) or nil. Either way, NOT
        // the frame itself.
        XCTAssertNotEqual(match?.layer.id, "frame")
    }

    func testIoUSanity() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(FigmaLayerMatcher.intersectionOverUnion(a, b), 1.0, accuracy: 0.001)

        let c = CGRect(x: 200, y: 200, width: 10, height: 10)
        XCTAssertEqual(FigmaLayerMatcher.intersectionOverUnion(a, c), 0)
    }
}
