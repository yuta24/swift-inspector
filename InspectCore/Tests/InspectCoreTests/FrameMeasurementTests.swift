import XCTest
@testable import InspectCore

final class FrameMeasurementTests: XCTestCase {
    func testDisjointRightBelow() {
        let m = FrameMeasurement(
            reference: CGRect(x: 0, y: 0, width: 100, height: 50),
            target: CGRect(x: 150, y: 100, width: 40, height: 40)
        )
        XCTAssertEqual(m.horizontalGap, 50, "target right edge 150 vs reference right edge 100 → 50pt gap")
        XCTAssertEqual(m.verticalGap, 50, "target top edge 100 vs reference bottom edge 50 → 50pt gap")
        XCTAssertEqual(m.relationship, .disjoint)
    }

    func testDisjointLeftAboveIsSigned() {
        let m = FrameMeasurement(
            reference: CGRect(x: 100, y: 100, width: 50, height: 50),
            target: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
        XCTAssertEqual(m.horizontalGap, -60, "target's right edge 40 is 60pt before reference's left edge 100")
        XCTAssertEqual(m.verticalGap, -60)
        XCTAssertEqual(m.relationship, .disjoint)
    }

    func testOverlapGapIsZero() {
        let m = FrameMeasurement(
            reference: CGRect(x: 0, y: 0, width: 100, height: 100),
            target: CGRect(x: 50, y: 50, width: 100, height: 100)
        )
        XCTAssertEqual(m.horizontalGap, 0)
        XCTAssertEqual(m.verticalGap, 0)
        XCTAssertEqual(m.relationship, .overlapping)
    }

    func testTargetInsideReference() {
        let m = FrameMeasurement(
            reference: CGRect(x: 0, y: 0, width: 200, height: 200),
            target: CGRect(x: 50, y: 50, width: 30, height: 30)
        )
        XCTAssertEqual(m.horizontalGap, 0)
        XCTAssertEqual(m.verticalGap, 0)
        XCTAssertEqual(m.relationship, .targetInsideReference)
    }

    func testIdenticalRects() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let m = FrameMeasurement(reference: rect, target: rect)
        XCTAssertEqual(m.relationship, .identical)
        XCTAssertEqual(m.centerDistance, 0)
    }

    func testCenterDistanceAndDelta() {
        let m = FrameMeasurement(
            reference: CGRect(x: 0, y: 0, width: 10, height: 10),
            target: CGRect(x: 30, y: 40, width: 10, height: 10)
        )
        // Reference center = (5, 5), target center = (35, 45) → delta (30, 40), distance 50.
        XCTAssertEqual(m.centerDelta.width, 30)
        XCTAssertEqual(m.centerDelta.height, 40)
        XCTAssertEqual(m.centerDistance, 50)
    }
}
