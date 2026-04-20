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

    func testFramingRoundtrip() {
        let payload = Data("hello".utf8)
        let framed = Framing.frame(payload)
        XCTAssertEqual(framed.count, Framing.headerSize + payload.count)

        let header = framed.prefix(Framing.headerSize)
        XCTAssertEqual(Framing.parseLength(header), payload.count)
    }
}
