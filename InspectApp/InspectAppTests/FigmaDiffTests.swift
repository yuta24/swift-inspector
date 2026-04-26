import XCTest
import InspectCore
@testable import InspectApp

final class FigmaDiffTests: XCTestCase {
    func testSizeDifferenceMarkedAsDiffer() {
        let viewNode = ViewNode(
            className: "UIView",
            frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 50)
        )
        let figma = FigmaNode(
            id: "1", name: "card", type: "RECTANGLE",
            absoluteBoundingBox: .init(x: 0, y: 0, width: 120, height: 50)
        )
        let diff = FigmaDiffEngine.diff(viewNode: viewNode, figmaLayer: figma)
        let widthItem = diff.items.first { $0.label == "Width" }
        XCTAssertEqual(widthItem?.status, .differ)
        XCTAssertEqual(widthItem?.figma, "120")
        XCTAssertEqual(widthItem?.device, "100")
        // Heights agree, so the diff isn't drowning in noise.
        let heightItem = diff.items.first { $0.label == "Height" }
        XCTAssertEqual(heightItem?.status, .match)
    }

    func testSizeMatchWithinTolerance() {
        // Half-point slack covers subpixel rounding without hiding real
        // 1pt mistakes.
        let viewNode = ViewNode(
            className: "UIView",
            frame: .zero,
            windowFrame: CGRect(x: 0, y: 0, width: 100.4, height: 50)
        )
        let figma = FigmaNode(
            id: "1", name: "card", type: "RECTANGLE",
            absoluteBoundingBox: .init(x: 0, y: 0, width: 100, height: 50)
        )
        let diff = FigmaDiffEngine.diff(viewNode: viewNode, figmaLayer: figma)
        XCTAssertEqual(diff.items.first { $0.label == "Width" }?.status, .match)
    }

    func testSolidFillMatchAndDiffer() {
        let blueDevice = ViewNode(
            className: "UIView",
            frame: .zero,
            backgroundColor: RGBAColor(red: 0.121, green: 0.561, blue: 1, alpha: 1)
        )
        let blueFigma = FigmaNode(
            id: "1", name: "x", type: "RECTANGLE",
            fills: [
                FigmaNode.Paint(
                    type: "SOLID",
                    color: FigmaNode.Color(r: 0.121, g: 0.561, b: 1, a: 1),
                    opacity: 1, visible: true
                )
            ]
        )
        let match = FigmaDiffEngine.diff(viewNode: blueDevice, figmaLayer: blueFigma)
        XCTAssertEqual(match.items.first { $0.label == "Fill" }?.status, .match)

        let redFigma = FigmaNode(
            id: "1", name: "x", type: "RECTANGLE",
            fills: [
                FigmaNode.Paint(
                    type: "SOLID",
                    color: FigmaNode.Color(r: 1, g: 0, b: 0, a: 1),
                    opacity: 1, visible: true
                )
            ]
        )
        let differ = FigmaDiffEngine.diff(viewNode: blueDevice, figmaLayer: redFigma)
        XCTAssertEqual(differ.items.first { $0.label == "Fill" }?.status, .differ)
        XCTAssertTrue(differ.hasDifference)
    }

    func testGradientFillMarkedAsUnavailable() {
        // Figma carries a gradient — comparing against UIKit's solid
        // backgroundColor isn't meaningful, so we surface "unavailable".
        let device = ViewNode(
            className: "UIView", frame: .zero,
            backgroundColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let figma = FigmaNode(
            id: "1", name: "x", type: "RECTANGLE",
            fills: [
                FigmaNode.Paint(type: "GRADIENT_LINEAR", color: nil, opacity: 1, visible: true)
            ]
        )
        let diff = FigmaDiffEngine.diff(viewNode: device, figmaLayer: figma)
        let fill = diff.items.first { $0.label == "Fill" }
        XCTAssertEqual(fill?.status, .unavailable)
        XCTAssertEqual(fill?.figma, "Gradient")
    }

    func testCornerRadiusUsesPerCornerMaximum() {
        let device = ViewNode(className: "UIView", frame: .zero, cornerRadius: 12)
        let figma = FigmaNode(
            id: "1", name: "x", type: "RECTANGLE",
            cornerRadius: 4,  // ignored when per-corner is set
            rectangleCornerRadii: [12, 4, 4, 12]
        )
        let item = FigmaDiffEngine.diff(viewNode: device, figmaLayer: figma)
            .items.first { $0.label == "Corner radius" }
        XCTAssertEqual(item?.status, .match)
    }

    func testTypographyDiffersOnFontSize() {
        let device = ViewNode(
            className: "UILabel",
            frame: .zero,
            typography: Typography(
                fontName: "SFPro-Semibold",
                familyName: "SF Pro",
                pointSize: 15,
                weight: 0.3,
                weightName: "semibold"
            )
        )
        let figma = FigmaNode(
            id: "1", name: "x", type: "TEXT",
            style: FigmaNode.TextStyle(
                fontFamily: "SF Pro",
                fontPostScriptName: "SFPro-Semibold",
                fontWeight: 600,
                fontSize: 17,
                lineHeightPx: nil,
                lineHeightPercent: nil,
                lineHeightUnit: nil,
                letterSpacing: nil,
                textAlignHorizontal: nil
            ),
            characters: "x"
        )
        let diff = FigmaDiffEngine.diff(viewNode: device, figmaLayer: figma)
        let fontSize = diff.items.first { $0.label == "Font size" }
        XCTAssertEqual(fontSize?.status, .differ)
        XCTAssertEqual(fontSize?.figma, "17pt")
        XCTAssertEqual(fontSize?.device, "15pt")
        // Family matches even though casing of input doesn't matter.
        XCTAssertEqual(diff.items.first { $0.label == "Font family" }?.status, .match)
        // Weight: 0.3 (semibold) ↔ 600 should match within 50-unit slack.
        XCTAssertEqual(diff.items.first { $0.label == "Font weight" }?.status, .match)
    }

    func testNonTextNodeOmitsTypographyItems() {
        // No typography on either side → no typography rows in the diff.
        let device = ViewNode(className: "UIView", frame: .zero)
        let figma = FigmaNode(id: "1", name: "x", type: "RECTANGLE")
        let diff = FigmaDiffEngine.diff(viewNode: device, figmaLayer: figma)
        XCTAssertTrue(diff.items.allSatisfy { $0.category != .typography })
    }
}

