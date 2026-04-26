import XCTest
@testable import InspectApp

final class FigmaImageServiceTests: XCTestCase {
    func testParseDesignURL() {
        let raw = "https://www.figma.com/design/ABC123/MyFile?node-id=5-12&t=abc"
        let ref = FigmaImageService.parse(raw)
        XCTAssertEqual(ref?.fileKey, "ABC123")
        // Hyphen in the URL is the share-link form; REST API uses colons.
        XCTAssertEqual(ref?.nodeId, "5:12")
    }

    func testParseLegacyFileURL() {
        // Older share URLs use /file/. Figma 301-redirects them to /design/
        // in the browser, but designers still copy this form from older
        // tabs / Slack threads.
        let raw = "https://www.figma.com/file/XYZ789/Old-File?node-id=1-1"
        let ref = FigmaImageService.parse(raw)
        XCTAssertEqual(ref?.fileKey, "XYZ789")
        XCTAssertEqual(ref?.nodeId, "1:1")
    }

    func testParsePercentEncodedNodeID() {
        // Some integrations percent-encode `:` to `%3A` so URLComponents
        // decodes it back. We should accept the decoded form too.
        let raw = "https://www.figma.com/design/ABC123/Name?node-id=4%3A18"
        let ref = FigmaImageService.parse(raw)
        XCTAssertEqual(ref?.fileKey, "ABC123")
        XCTAssertEqual(ref?.nodeId, "4:18")
    }

    func testParseRejectsNonFigma() {
        XCTAssertNil(FigmaImageService.parse("https://example.com/file/ABC?node-id=1-1"))
    }

    func testParseRejectsMissingNodeID() {
        XCTAssertNil(FigmaImageService.parse("https://www.figma.com/design/ABC/Name"))
    }

    func testParseRejectsEmpty() {
        XCTAssertNil(FigmaImageService.parse(""))
        XCTAssertNil(FigmaImageService.parse("   "))
    }

    func testParseRejectsUnknownPath() {
        // /community/ is a real Figma path but we don't support it as a
        // frame source for the inspector — surface as an invalid URL so
        // designers know to grab a regular share link instead.
        XCTAssertNil(FigmaImageService.parse("https://www.figma.com/community/file/ABC?node-id=1-1"))
    }

    func testParseTrimsWhitespace() {
        let raw = "  https://www.figma.com/design/ABC123/Name?node-id=1-1  \n"
        XCTAssertEqual(FigmaImageService.parse(raw)?.fileKey, "ABC123")
    }
}
