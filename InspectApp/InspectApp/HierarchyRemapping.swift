import Foundation
import InspectCore

/// Pure functions used by `InspectAppModel` to keep selection, focus, and
/// screenshots stable across hierarchy snapshots. Every capture by
/// `HierarchyScanner` assigns fresh UUIDs, so we can't compare ids across
/// snapshots — instead we project each tracked node to a *stable path*
/// (accessibility-identifier or class-and-sibling-index chain) and look the
/// same path up in the new tree.
enum HierarchyRemapping {
    static func countNodes(in nodes: [ViewNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countNodes(in: $1.children) }
    }

    static func findNode(id: UUID, in nodes: [ViewNode]) -> ViewNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNode(id: id, in: node.children) { return found }
        }
        return nil
    }

    /// Re-maps an id from the previous snapshot onto the new one using a
    /// path-based fingerprint. Returns nil when the path doesn't exist in
    /// the new tree (e.g. the view was removed).
    static func remap(
        id: UUID?,
        oldRoots: [ViewNode],
        newRoots: [ViewNode]
    ) -> UUID? {
        guard let id else { return nil }
        guard let path = stablePath(for: id, in: oldRoots) else { return nil }
        return findNode(byPath: path, in: newRoots)?.id
    }

    /// Walks the tree to find the stable path (list of sibling-index or
    /// accessibility-identifier segments) that uniquely locates a node with
    /// the given id. Uses `ViewNode.stablePathSegment` for per-node segments
    /// so SceneKit diffing and selection preservation agree on the same
    /// identity scheme.
    static func stablePath(for id: UUID, in roots: [ViewNode]) -> [String]? {
        for (index, root) in roots.enumerated() {
            if let path = path(to: id, in: root, prefix: [root.stablePathSegment(siblingIndex: index)]) {
                return path
            }
        }
        return nil
    }

    static func findNode(byPath path: [String], in roots: [ViewNode]) -> ViewNode? {
        guard let first = path.first else { return nil }
        for (index, root) in roots.enumerated() {
            if root.stablePathSegment(siblingIndex: index) == first {
                return resolve(path: Array(path.dropFirst()), in: root)
            }
        }
        return nil
    }

    /// For live mode: the server omits screenshot payloads to keep captures
    /// cheap. We reattach images from the previous snapshot by matching nodes
    /// along the same stable path. A node that existed before keeps its old
    /// image until the next full refresh; newly-added nodes stay blank until
    /// the user triggers a full refresh (Cmd+R).
    static func carryingScreenshots(into newRoots: [ViewNode], from oldRoots: [ViewNode]) -> [ViewNode] {
        var cache: [String: (Data?, Data?)] = [:]
        collectImages(from: oldRoots, prefix: [], into: &cache)
        if cache.isEmpty { return newRoots }
        return newRoots.enumerated().map { index, root in
            rebuild(
                node: root,
                path: [root.stablePathSegment(siblingIndex: index)],
                cache: cache
            )
        }
    }

    // MARK: - Private helpers

    private static func path(
        to id: UUID,
        in node: ViewNode,
        prefix: [String]
    ) -> [String]? {
        if node.id == id { return prefix }
        for (index, child) in node.children.enumerated() {
            let next = prefix + [child.stablePathSegment(siblingIndex: index)]
            if let found = path(to: id, in: child, prefix: next) { return found }
        }
        return nil
    }

    private static func resolve(path: [String], in node: ViewNode) -> ViewNode? {
        guard let first = path.first else { return node }
        for (index, child) in node.children.enumerated() {
            if child.stablePathSegment(siblingIndex: index) == first {
                return resolve(path: Array(path.dropFirst()), in: child)
            }
        }
        return nil
    }

    private static func collectImages(
        from nodes: [ViewNode],
        prefix: [String],
        into cache: inout [String: (Data?, Data?)]
    ) {
        for (index, node) in nodes.enumerated() {
            let path = prefix + [node.stablePathSegment(siblingIndex: index)]
            if node.screenshot != nil || node.soloScreenshot != nil {
                cache[path.joined(separator: "/")] = (node.screenshot, node.soloScreenshot)
            }
            collectImages(from: node.children, prefix: path, into: &cache)
        }
    }

    private static func rebuild(
        node: ViewNode,
        path: [String],
        cache: [String: (Data?, Data?)]
    ) -> ViewNode {
        let rebuiltChildren = node.children.enumerated().map { index, child in
            rebuild(
                node: child,
                path: path + [child.stablePathSegment(siblingIndex: index)],
                cache: cache
            )
        }

        // Only borrow images when the new node didn't carry any itself
        // (i.e. this was a lite capture, not a fresh full capture).
        if node.screenshot == nil && node.soloScreenshot == nil,
           let (oldScreenshot, oldSolo) = cache[path.joined(separator: "/")] {
            return node
                .replacingChildren(rebuiltChildren)
                .replacingImages(screenshot: oldScreenshot, soloScreenshot: oldSolo)
        }
        return node.replacingChildren(rebuiltChildren)
    }
}
