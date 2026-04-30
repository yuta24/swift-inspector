import Foundation
import InspectCore

struct HierarchyFilter: Equatable {
    var text: String = ""
    var showHidden: Bool = false
    var showZeroSize: Bool = false
    var showTransparent: Bool = false
    /// "Differing only" — keep nodes whose attributes diverge from their
    /// matched Figma layer. The actual id set is supplied per-call by the
    /// caller (typically `figmaModel.differingNodeIDs`) so this struct
    /// stays a pure user-config snapshot rather than carrying potentially-
    /// large transient state.
    var showOnlyDiffering: Bool = false

    var isEmpty: Bool {
        text.isEmpty && !showHidden && !showZeroSize && !showTransparent && !showOnlyDiffering
    }

    var hasPropertyFilter: Bool {
        showHidden || showZeroSize || showTransparent || showOnlyDiffering
    }

    /// Returns true if this node directly satisfies all active filter conditions.
    /// `differingIDs` is consulted only when `showOnlyDiffering` is set.
    func matches(_ node: ViewNode, differingIDs: Set<UUID> = []) -> Bool {
        let textMatch = textMatches(node)
        let propertyMatch = propertyMatches(node, differingIDs: differingIDs)

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

    private func propertyMatches(_ node: ViewNode, differingIDs: Set<UUID>) -> Bool {
        if showHidden && node.isHidden { return true }
        if showZeroSize && (node.frame.width == 0 || node.frame.height == 0) { return true }
        if showTransparent && node.alpha == 0 { return true }
        if showOnlyDiffering && differingIDs.contains(node.ident) { return true }
        return !hasPropertyFilter
    }

    /// Returns true if this node or any descendant matches the filter.
    func subtreeContainsMatch(_ node: ViewNode, differingIDs: Set<UUID> = []) -> Bool {
        if matches(node, differingIDs: differingIDs) { return true }
        return node.children.contains { subtreeContainsMatch($0, differingIDs: differingIDs) }
    }

    /// Count matching nodes in the tree.
    func countMatches(in nodes: [ViewNode], differingIDs: Set<UUID> = []) -> Int {
        nodes.reduce(0) { total, node in
            let selfMatch = matches(node, differingIDs: differingIDs) ? 1 : 0
            return total + selfMatch + countMatches(in: node.children, differingIDs: differingIDs)
        }
    }
}
