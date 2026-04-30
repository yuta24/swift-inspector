import XCTest
@testable import InspectCore

final class ViewNodeTests: XCTestCase {
    func testCodableRoundtrip() throws {
        let child = ViewNode(
            className: "UILabel",
            frame: CGRect(x: 0, y: 0, width: 100, height: 20),
            isHidden: false,
            alpha: 1.0,
            backgroundColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            screenshot: nil,
            soloScreenshot: nil,
            children: []
        )
        let parent = ViewNode(
            className: "UIView",
            frame: CGRect(x: 0, y: 0, width: 300, height: 200),
            isHidden: true,
            alpha: 0.5,
            backgroundColor: nil,
            screenshot: Data([0x01, 0x02, 0x03]),
            soloScreenshot: Data([0x04, 0x05]),
            children: [child]
        )

        let serializer = JSONMessageSerializer()
        let data = try serializer.encode(.hierarchy(roots: [parent]))
        let decoded = try serializer.decode(data)
        guard case let .hierarchy(roots) = decoded else {
            XCTFail("expected hierarchy case")
            return
        }
        XCTAssertEqual(roots, [parent])
    }

    func testNaNSanitization() throws {
        let node = ViewNode(
            className: "UIView",
            frame: CGRect(x: Double.nan, y: .infinity, width: -.infinity, height: 100),
            alpha: .nan,
            cornerRadius: .nan,
            borderWidth: .infinity
        )
        // NaN/Infinity should be replaced with 0, negative width clamped to 0
        XCTAssertEqual(node.frame.origin.x, 0)
        XCTAssertEqual(node.frame.origin.y, 0)
        XCTAssertEqual(node.frame.size.width, 0)
        XCTAssertEqual(node.frame.size.height, 100)
        XCTAssertEqual(node.alpha, 0)
        XCTAssertEqual(node.cornerRadius, 0)
        XCTAssertEqual(node.borderWidth, 0)

        // Must encode without throwing
        let serializer = JSONMessageSerializer()
        let data = try serializer.encode(.hierarchy(roots: [node]))
        let decoded = try serializer.decode(data)
        guard case let .hierarchy(roots) = decoded else {
            XCTFail("expected hierarchy case")
            return
        }
        XCTAssertEqual(roots.first?.cornerRadius, 0)
    }

    func testRGBAColorNaNSanitization() {
        let color = RGBAColor(red: .nan, green: .infinity, blue: -.infinity, alpha: 0.5)
        XCTAssertEqual(color.red, 0)
        XCTAssertEqual(color.green, 0)
        XCTAssertEqual(color.blue, 0)
        XCTAssertEqual(color.alpha, 0.5)
    }

    func testGeometryExtrasSanitization() {
        let node = ViewNode(
            className: "UIView",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            boundsSize: CGSize(width: Double.nan, height: -Double.infinity),
            cornersInWindow: [
                CGPoint(x: Double.nan, y: 0),
                CGPoint(x: 100, y: Double.infinity),
                CGPoint(x: 0, y: 100),
                CGPoint(x: 100, y: 100),
            ]
        )
        XCTAssertEqual(node.boundsSize?.width, 0)
        XCTAssertEqual(node.boundsSize?.height, 0)
        let corners = node.cornersInWindow!
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(corners[1], CGPoint(x: 100, y: 0))
        XCTAssertEqual(corners[2], CGPoint(x: 0, y: 100))
        XCTAssertEqual(corners[3], CGPoint(x: 100, y: 100))
    }

    func testLegacyDecodeWithoutGeometryExtras() throws {
        // Simulates an older server that doesn't send `boundsSize` or
        // `cornersInWindow`. We encode a full ViewNode, strip the new keys,
        // and decode again. Missing fields must decode to nil without
        // failing.
        let node = ViewNode(
            className: "UILabel",
            frame: CGRect(x: 0, y: 0, width: 100, height: 20),
            boundsSize: CGSize(width: 100, height: 20),
            cornersInWindow: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 100, y: 0),
                CGPoint(x: 0, y: 20),
                CGPoint(x: 100, y: 20),
            ]
        )
        let encoder = JSONEncoder()
        let full = try encoder.encode(node)
        var json = try JSONSerialization.jsonObject(with: full) as! [String: Any]
        json.removeValue(forKey: "boundsSize")
        json.removeValue(forKey: "cornersInWindow")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ViewNode.self, from: stripped)
        XCTAssertEqual(decoded.className, "UILabel")
        XCTAssertNil(decoded.boundsSize)
        XCTAssertNil(decoded.cornersInWindow)
        XCTAssertEqual(decoded.frame.size.width, 100)
    }

    func testLayoutConstraintRoundtrip() throws {
        let first = LayoutConstraint.Anchor(
            ownerID: UUID(),
            description: "UILabel",
            isLayoutGuide: false,
            attribute: 5 // leading
        )
        let second = LayoutConstraint.Anchor(
            ownerID: UUID(),
            description: "UIView.safeAreaLayoutGuide",
            isLayoutGuide: true,
            attribute: 5
        )
        let constraint = LayoutConstraint(
            identifier: "label-leading",
            first: first,
            second: second,
            relation: 0,
            multiplier: 1.0,
            constant: 16.0,
            priority: 1000,
            isActive: true
        )
        let node = ViewNode(
            className: "UILabel",
            frame: CGRect(x: 0, y: 0, width: 100, height: 20),
            constraints: [constraint]
        )
        let serializer = JSONMessageSerializer()
        let data = try serializer.encode(.hierarchy(roots: [node]))
        let decoded = try serializer.decode(data)
        guard case let .hierarchy(roots) = decoded else {
            XCTFail("expected hierarchy case")
            return
        }
        XCTAssertEqual(roots.first?.constraints, [constraint])
    }

    func testConstraintNaNSanitization() {
        let first = LayoutConstraint.Anchor(
            ownerID: nil, description: "UIView",
            isLayoutGuide: false, attribute: 7
        )
        let constraint = LayoutConstraint(
            identifier: nil,
            first: first,
            second: nil,
            relation: 0,
            multiplier: Double.nan,
            constant: Double.infinity,
            priority: Float.nan,
            isActive: true
        )
        XCTAssertEqual(constraint.multiplier, 0)
        XCTAssertEqual(constraint.constant, 0)
        XCTAssertEqual(constraint.priority, 0)
    }

    func testLegacyDecodeWithoutConstraints() throws {
        // Older servers don't send the `constraints` key. Missing should
        // decode as empty array, not fail.
        let node = ViewNode(
            className: "UIView",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(node)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "constraints")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ViewNode.self, from: stripped)
        XCTAssertEqual(decoded.constraints, [])
    }

    func testAttributeAndRelationNames() {
        XCTAssertEqual(LayoutConstraint.attributeName(5), "leading")
        XCTAssertEqual(LayoutConstraint.attributeName(7), "width")
        XCTAssertEqual(LayoutConstraint.attributeName(999), "attr(999)")
        XCTAssertEqual(LayoutConstraint.relationSymbol(-1), "≤")
        XCTAssertEqual(LayoutConstraint.relationSymbol(0), "=")
        XCTAssertEqual(LayoutConstraint.relationSymbol(1), "≥")
    }

    func testFramingRoundtrip() throws {
        let payload = Data("hello".utf8)
        let framed = try Framing.frame(payload)
        XCTAssertEqual(framed.count, Framing.headerSize + payload.count)

        let header = framed.prefix(Framing.headerSize)
        XCTAssertEqual(Framing.parseLength(header), payload.count)
    }

    func testFramingRejectsOversizedPayload() {
        let oversized = Data(count: Framing.maxPayloadBytes + 1)
        XCTAssertThrowsError(try Framing.frame(oversized)) { error in
            guard case Framing.FramingError.payloadTooLarge = error else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
        }
    }

    func testTypographyRoundtrip() throws {
        let typography = Typography(
            fontName: "SFUI-Semibold",
            familyName: "SF UI",
            pointSize: 17,
            weight: 0.3,
            weightName: "semibold",
            isBold: false,
            isItalic: false,
            textColor: RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1),
            alignment: "center",
            numberOfLines: 2,
            lineHeight: 20.5,
            ascender: 16.0,
            descender: -4.0
        )
        let node = ViewNode(
            className: "UILabel",
            frame: CGRect(x: 0, y: 0, width: 100, height: 20),
            typography: typography
        )
        let serializer = JSONMessageSerializer()
        let data = try serializer.encode(.hierarchy(roots: [node]))
        let decoded = try serializer.decode(data)
        guard case let .hierarchy(roots) = decoded else {
            XCTFail("expected hierarchy case")
            return
        }
        XCTAssertEqual(roots.first?.typography, typography)
    }

    func testLegacyDecodeWithoutTypography() throws {
        // Older servers don't send the `typography` key. Missing should
        // decode as nil, not fail.
        let node = ViewNode(
            className: "UILabel",
            frame: CGRect(x: 0, y: 0, width: 100, height: 20)
        )
        let encoded = try JSONEncoder().encode(node)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "typography")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ViewNode.self, from: stripped)
        XCTAssertNil(decoded.typography)
    }

    func testTypographyNaNSanitization() {
        let typography = Typography(
            fontName: "X",
            pointSize: .nan,
            weight: .infinity,
            lineHeight: -.infinity,
            ascender: .nan,
            descender: .nan
        )
        XCTAssertEqual(typography.pointSize, 0)
        XCTAssertEqual(typography.weight, 0)
        XCTAssertEqual(typography.lineHeight, 0)
        XCTAssertEqual(typography.ascender, 0)
        XCTAssertEqual(typography.descender, 0)
    }

    func testSafeAreaInsetsRoundtrip() throws {
        let insets = EdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
        let node = ViewNode(
            className: "UIWindow",
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            safeAreaInsets: insets
        )
        let serializer = JSONMessageSerializer()
        let data = try serializer.encode(.hierarchy(roots: [node]))
        let decoded = try serializer.decode(data)
        guard case let .hierarchy(roots) = decoded else {
            XCTFail("expected hierarchy case")
            return
        }
        XCTAssertEqual(roots.first?.safeAreaInsets, insets)
    }

    func testLegacyDecodeWithoutSafeAreaInsets() throws {
        // Older servers don't ship `safeAreaInsets`. Missing must decode as
        // nil rather than failing.
        let node = ViewNode(
            className: "UIView",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let encoded = try JSONEncoder().encode(node)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "safeAreaInsets")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ViewNode.self, from: stripped)
        XCTAssertNil(decoded.safeAreaInsets)
    }

    func testEdgeInsetsNaNSanitization() {
        let insets = EdgeInsets(top: .nan, left: .infinity, bottom: -.infinity, right: 8)
        XCTAssertEqual(insets.top, 0)
        XCTAssertEqual(insets.left, 0)
        XCTAssertEqual(insets.bottom, 0)
        XCTAssertEqual(insets.right, 8)
    }

    func testRGBAColorHexFormats() {
        let opaque = RGBAColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        XCTAssertEqual(opaque.hexRGB, "#FF8000")
        XCTAssertEqual(opaque.hexRGBA, "#FF8000FF")

        let translucent = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        XCTAssertEqual(translucent.hexRGB, "#000000")
        XCTAssertEqual(translucent.hexRGBA, "#00000080")

        // Wide-gamut channel (>1) clamps rather than overflowing the byte.
        let wide = RGBAColor(red: 1.2, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(wide.hexRGB, "#FF0000")
    }
}
