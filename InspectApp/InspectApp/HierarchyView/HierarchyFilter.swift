import Foundation
import InspectCore

struct HierarchyFilter: Equatable {
    var text: String = ""
    var showHidden: Bool = false
    var showZeroSize: Bool = false
    var showTransparent: Bool = false

    var isEmpty: Bool {
        text.isEmpty && !showHidden && !showZeroSize && !showTransparent
    }

    var hasPropertyFilter: Bool {
        showHidden || showZeroSize || showTransparent
    }

    /// Returns true if this node directly satisfies all active filter conditions.
    func matches(_ node: ViewNode) -> Bool {
        let textMatch = textMatches(node)
        let propertyMatch = propertyMatches(node)

        if !text.isEmpty && hasPropertyFilter {
            return textMatch && propertyMatch
        } else if !text.isEmpty {
            return textMatch
        } else if hasPropertyFilter {
            return propertyMatch
        }
        return true
    }

    private func textMatches(_ node: ViewNode) -> Bool {
        guard !text.isEmpty else { return true }
        if node.className.localizedCaseInsensitiveContains(text) { return true }
        if let id = node.accessibilityIdentifier,
           id.localizedCaseInsensitiveContains(text) { return true }
        if let label = node.accessibilityLabel,
           label.localizedCaseInsensitiveContains(text) { return true }
        return false
    }

    private func propertyMatches(_ node: ViewNode) -> Bool {
        if showHidden && node.isHidden { return true }
        if showZeroSize && (node.frame.width == 0 || node.frame.height == 0) { return true }
        if showTransparent && node.alpha == 0 { return true }
        return !hasPropertyFilter
    }

    /// Returns true if this node or any descendant matches the filter.
    func subtreeContainsMatch(_ node: ViewNode) -> Bool {
        if matches(node) { return true }
        return node.children.contains { subtreeContainsMatch($0) }
    }

    /// Count matching nodes in the tree.
    func countMatches(in nodes: [ViewNode]) -> Int {
        nodes.reduce(0) { total, node in
            let selfMatch = matches(node) ? 1 : 0
            return total + selfMatch + countMatches(in: node.children)
        }
    }
}
