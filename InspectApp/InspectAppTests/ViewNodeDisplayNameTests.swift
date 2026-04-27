import XCTest
import InspectCore
@testable import AppInspector

final class ViewNodeDisplayNameTests: XCTestCase {
    func test_displayName_prefers_text_property() {
        let node = ViewNode(
            className: "UILabel",
            frame: .zero,
            accessibilityLabel: "Greeting",
            properties: ["text": "Hello, world"]
        )
        XCTAssertEqual(node.displayName, "Hello, world")
    }

    func test_displayName_falls_back_to_title_then_accessibilityLabel() {
        let titleNode = ViewNode(
            className: "UIButton",
            frame: .zero,
            accessibilityLabel: "Submit",
            properties: ["title": "OK"]
        )
        XCTAssertEqual(titleNode.displayName, "OK")

        let labelNode = ViewNode(
            className: "UIView",
            frame: .zero,
            accessibilityLabel: "Greeting"
        )
        XCTAssertEqual(labelNode.displayName, "Greeting")
    }

    func test_displayName_trims_whitespace_and_skips_empty() {
        let node = ViewNode(
            className: "UILabel",
            frame: .zero,
            accessibilityLabel: "fallback",
            properties: ["text": "   "]
        )
        XCTAssertEqual(node.displayName, "fallback")
    }

    func test_displayName_is_nil_when_no_hint() {
        let node = ViewNode(className: "UIView", frame: .zero)
        XCTAssertNil(node.displayName)
    }

    func test_shortClassName_strips_module_prefix() {
        let node = ViewNode(className: "SwiftUI.VStack", frame: .zero)
        XCTAssertEqual(node.shortClassName, "VStack")
    }

    func test_shortClassName_strips_generic_parameters() {
        let node = ViewNode(
            className: "SwiftUI.VStack<TupleView<(Text, Text)>>",
            frame: .zero
        )
        XCTAssertEqual(node.shortClassName, "VStack")
    }

    func test_shortClassName_passes_plain_uikit_names_through() {
        let node = ViewNode(className: "UIButton", frame: .zero)
        XCTAssertEqual(node.shortClassName, "UIButton")
    }
}
