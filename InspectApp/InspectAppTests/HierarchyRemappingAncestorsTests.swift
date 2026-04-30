import XCTest
import InspectCore
@testable import AppInspector

final class HierarchyRemappingAncestorsTests: XCTestCase {
    func test_ancestors_returns_empty_for_top_level_root() {
        let root = ViewNode(className: "UIWindow", frame: .zero)
        XCTAssertEqual(
            HierarchyRemapping.ancestors(of: root.id, in: [root]).map(\.id),
            []
        )
    }

    func test_ancestors_returns_empty_for_unknown_id() {
        let root = ViewNode(className: "UIWindow", frame: .zero)
        let unknown = UUID()
        XCTAssertEqual(
            HierarchyRemapping.ancestors(of: unknown, in: [root]).map(\.id),
            []
        )
    }

    func test_ancestors_returns_ordered_chain_from_root_to_parent() {
        let leaf = ViewNode(className: "UILabel", frame: .zero)
        let middle = ViewNode(className: "UIStackView", frame: .zero, children: [leaf])
        let root = ViewNode(className: "UIWindow", frame: .zero, children: [middle])

        let chain = HierarchyRemapping.ancestors(of: leaf.id, in: [root])
        XCTAssertEqual(chain.map(\.id), [root.id, middle.id])
    }

    func test_ancestors_finds_chain_in_second_root_with_backtrack() {
        // First root is a sibling tree that does NOT contain the target —
        // exercises the `trail.removeLast()` backtrack path before moving
        // on to the second root.
        let unrelatedDeep = ViewNode(className: "UIView", frame: .zero)
        let unrelatedMid = ViewNode(className: "UIStackView", frame: .zero, children: [unrelatedDeep])
        let unrelatedRoot = ViewNode(className: "UIWindow", frame: .zero, children: [unrelatedMid])

        let target = ViewNode(className: "UIButton", frame: .zero)
        let secondRoot = ViewNode(className: "UIWindow", frame: .zero, children: [target])

        let chain = HierarchyRemapping.ancestors(
            of: target.id,
            in: [unrelatedRoot, secondRoot]
        )
        XCTAssertEqual(chain.map(\.id), [secondRoot.id])
    }
}
