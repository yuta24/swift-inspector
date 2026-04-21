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

    func testFramingRoundtrip() {
        let payload = Data("hello".utf8)
        let framed = Framing.frame(payload)
        XCTAssertEqual(framed.count, Framing.headerSize + payload.count)

        let header = framed.prefix(Framing.headerSize)
        XCTAssertEqual(Framing.parseLength(header), payload.count)
    }
}
