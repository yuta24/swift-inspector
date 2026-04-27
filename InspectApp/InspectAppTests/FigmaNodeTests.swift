import XCTest
@testable import AppInspector

final class FigmaNodeTests: XCTestCase {
    func testDecodeFrameWithChildren() throws {
        let json = #"""
        {
          "id": "1:2",
          "name": "iPhone 15 Pro",
          "type": "FRAME",
          "absoluteBoundingBox": { "x": 0, "y": 0, "width": 393, "height": 852 },
          "fills": [
            { "type": "SOLID", "color": { "r": 1, "g": 1, "b": 1, "a": 1 }, "opacity": 1 }
          ],
          "children": [
            {
              "id": "1:3",
              "name": "Header",
              "type": "FRAME",
              "absoluteBoundingBox": { "x": 0, "y": 0, "width": 393, "height": 64 },
              "cornerRadius": 12
            },
            {
              "id": "1:4",
              "name": "primary-cta",
              "type": "TEXT",
              "absoluteBoundingBox": { "x": 24, "y": 200, "width": 345, "height": 20 },
              "characters": "Continue",
              "style": {
                "fontFamily": "SF Pro",
                "fontPostScriptName": "SFPro-Semibold",
                "fontWeight": 600,
                "fontSize": 17,
                "lineHeightPx": 22,
                "lineHeightUnit": "PIXELS",
                "textAlignHorizontal": "CENTER"
              }
            }
          ]
        }
        """#
        let node = try JSONDecoder().decode(FigmaNode.self, from: Data(json.utf8))

        XCTAssertEqual(node.id, "1:2")
        XCTAssertEqual(node.name, "iPhone 15 Pro")
        XCTAssertEqual(node.type, "FRAME")
        XCTAssertEqual(node.absoluteBoundingBox?.width, 393)
        XCTAssertEqual(node.children.count, 2)

        let header = node.children[0]
        XCTAssertEqual(header.cornerRadius, 12)
        XCTAssertEqual(header.children, [])

        let cta = node.children[1]
        XCTAssertEqual(cta.style?.fontSize, 17)
        XCTAssertEqual(cta.style?.fontWeight, 600)
        XCTAssertEqual(cta.style?.textAlignHorizontal, "CENTER")
        XCTAssertEqual(cta.characters, "Continue")
    }

    func testDecodeWithoutOptionalFields() throws {
        // Many leaf nodes ship only id/name/type. Decoder must accept that.
        let json = #"""
        { "id": "1:5", "name": "Group", "type": "GROUP" }
        """#
        let node = try JSONDecoder().decode(FigmaNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.id, "1:5")
        XCTAssertNil(node.absoluteBoundingBox)
        XCTAssertNil(node.fills)
        XCTAssertEqual(node.children, [])
    }

    func testEffectiveCornerRadiusUsesPerCornerMax() {
        let node = FigmaNode(
            id: "x", name: "y", type: "RECTANGLE",
            cornerRadius: 4,
            rectangleCornerRadii: [8, 4, 4, 8]
        )
        // Per-corner overrides uniform when present, returning the largest.
        XCTAssertEqual(node.effectiveCornerRadius, 8)
    }

    func testEffectiveCornerRadiusFallsBackToUniform() {
        let node = FigmaNode(
            id: "x", name: "y", type: "RECTANGLE",
            cornerRadius: 6
        )
        XCTAssertEqual(node.effectiveCornerRadius, 6)
    }

    func testPrimarySolidFillSkipsHiddenAndNonSolid() {
        let node = FigmaNode(
            id: "x", name: "y", type: "RECTANGLE",
            fills: [
                FigmaNode.Paint(type: "GRADIENT_LINEAR", color: nil, opacity: 1, visible: true),
                FigmaNode.Paint(
                    type: "SOLID",
                    color: FigmaNode.Color(r: 1, g: 0, b: 0, a: 1),
                    opacity: 1,
                    visible: false
                ),
                FigmaNode.Paint(
                    type: "SOLID",
                    color: FigmaNode.Color(r: 0, g: 1, b: 0, a: 1),
                    opacity: 0.5,
                    visible: true
                ),
            ]
        )
        XCTAssertEqual(node.primarySolidFill?.color?.g, 1)
    }

    func testFlattenedPreOrder() {
        let leaf1 = FigmaNode(id: "1", name: "leaf1", type: "RECTANGLE")
        let leaf2 = FigmaNode(id: "2", name: "leaf2", type: "RECTANGLE")
        let parent = FigmaNode(
            id: "p", name: "parent", type: "FRAME",
            children: [leaf1, leaf2]
        )
        XCTAssertEqual(parent.flattened().map(\.id), ["p", "1", "2"])
    }
}

