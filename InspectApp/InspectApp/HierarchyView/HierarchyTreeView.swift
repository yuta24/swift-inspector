import SwiftUI
import InspectCore

struct HierarchyTreeView: View {
    let roots: [ViewNode]
    @Binding var selection: UUID?
    @Binding var filter: HierarchyFilter
    @Binding var expandedPaths: Set<String>
    /// View-node ids whose attributes diverge from the matched Figma layer.
    /// Threaded through from the parent so the tree can offer a "Differing
    /// only" filter toggle and so the filter struct itself can stay free of
    /// transient comparison state.
    var differingIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Filter sits above the tree to match Spotlight / Xcode / Finder
            // conventions: the user types into the search field and then
            // scans the results downward, instead of hopping back up after
            // typing.
            if !roots.isEmpty {
                FilterBar(filter: $filter, roots: roots, differingIDs: differingIDs)
            }
            List(selection: $selection) {
                ForEach(Array(roots.enumerated()), id: \.element.id) { index, root in
                    let rootPath = [root.stablePathSegment(siblingIndex: index)]
                    if filter.isEmpty {
                        PersistentOutlineNode(
                            node: root,
                            path: rootPath,
                            expandedPaths: $expandedPaths,
                            filter: filter
                        )
                    } else {
                        FilteredOutlineGroup(
                            root: root,
                            path: rootPath,
                            expandedPaths: $expandedPaths,
                            filter: filter,
                            differingIDs: differingIDs
                        )
                    }
                }
            }
            .listStyle(.sidebar)
            .onKeyPress(.escape) {
                selection = nil
                return .handled
            }
            .overlay {
                if roots.isEmpty {
                    PlaceholderView(
                        title: "No Hierarchy",
                        systemImage: "rectangle.3.group",
                        message: "Connect to a device and request a snapshot."
                    )
                }
            }
        }
    }
}

// MARK: - Persistent Outline Node
//
// Manual DisclosureGroup recursion backed by a stable-path-keyed `Set`, so
// the expanded/collapsed state survives live-mode captures that regenerate
// every node's `ident`. Replaces `OutlineGroup`, whose internal state is
// keyed by identity and therefore collapses on every refresh.

private struct PersistentOutlineNode: View {
    let node: ViewNode
    let path: [String]
    @Binding var expandedPaths: Set<String>
    let filter: HierarchyFilter

    var body: some View {
        let pathKey = path.joined(separator: "/")
        if node.children.isEmpty {
            HierarchyNodeRow(node: node, filter: filter, stablePath: pathKey)
                .tag(node.id)
        } else {
            DisclosureGroup(isExpanded: expandedBinding(for: pathKey)) {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                    PersistentOutlineNode(
                        node: child,
                        path: path + [child.stablePathSegment(siblingIndex: index)],
                        expandedPaths: $expandedPaths,
                        filter: filter
                    )
                }
            } label: {
                HierarchyNodeRow(node: node, filter: filter, stablePath: pathKey)
                    .tag(node.id)
            }
        }
    }

    private func expandedBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expandedPaths.contains(key) },
            set: { newValue in
                if newValue {
                    expandedPaths.insert(key)
                } else {
                    expandedPaths.remove(key)
                }
            }
        )
    }
}

// MARK: - Filtered Outline Group
//
// Xcode View Debugger style filtering:
//   - Branches with no matching descendants are pruned (hidden entirely)
//   - Non-matching ancestor nodes are shown but dimmed
//   - Matching nodes are highlighted
//
// Shares the unfiltered tree's `expandedPaths` so:
//   - Manual expand/collapse during filtering survives clearing the filter.
//   - Ancestor nodes with matching descendants auto-expand without polluting
//     `expandedPaths` (the auto-expansion is a *display* override, not a
//     stored state), so when the filter is cleared the tree returns to the
//     pre-filter shape with any deliberate user changes preserved.

private struct FilteredOutlineGroup: View {
    let root: ViewNode
    let path: [String]
    @Binding var expandedPaths: Set<String>
    let filter: HierarchyFilter
    let differingIDs: Set<UUID>

    var body: some View {
        if filter.subtreeContainsMatch(root, differingIDs: differingIDs) {
            let pathKey = path.joined(separator: "/")
            let indexedChildren = Array(root.children.enumerated())
            let filteredChildren = indexedChildren.filter { _, child in
                filter.subtreeContainsMatch(child, differingIDs: differingIDs)
            }
            let isDimmed = !filter.matches(root, differingIDs: differingIDs)
            if filteredChildren.isEmpty {
                HierarchyNodeRow(
                    node: root,
                    filter: filter,
                    isDimmed: isDimmed,
                    stablePath: pathKey
                )
                .tag(root.id)
            } else {
                DisclosureGroup(isExpanded: expandedBinding(for: pathKey)) {
                    ForEach(filteredChildren, id: \.element.id) { index, child in
                        FilteredOutlineGroup(
                            root: child,
                            path: path + [child.stablePathSegment(siblingIndex: index)],
                            expandedPaths: $expandedPaths,
                            filter: filter,
                            differingIDs: differingIDs
                        )
                    }
                } label: {
                    HierarchyNodeRow(
                        node: root,
                        filter: filter,
                        isDimmed: isDimmed,
                        stablePath: pathKey
                    )
                    .tag(root.id)
                }
            }
        }
    }

    private func expandedBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                // Auto-expand any node that has matching descendants —
                // including nodes that match the filter themselves. The
                // earlier "only non-matching ancestors" rule made sense
                // for text search (the user drills down to one match)
                // but hid the children when both parent and child satisfy
                // the same filter — visible specifically with the
                // Differing toggle, where parent + child often both differ
                // and the walkthrough wants every diff in view at once.
                // Persisted `expandedPaths` still wins so a user who
                // explicitly opens or closes a row during filtering keeps
                // that intent.
                if expandedPaths.contains(key) { return true }
                return root.children.contains {
                    filter.subtreeContainsMatch($0, differingIDs: differingIDs)
                }
            },
            set: { newValue in
                if newValue {
                    expandedPaths.insert(key)
                } else {
                    expandedPaths.remove(key)
                }
            }
        )
    }
}

// MARK: - Filter Bar

private struct FilterBar: View {
    @Binding var filter: HierarchyFilter
    let roots: [ViewNode]
    let differingIDs: Set<UUID>

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter…", text: $filter.text)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !filter.text.isEmpty {
                        Button {
                            filter.text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(countLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                HStack(spacing: 4) {
                    FilterToggle(
                        "Hidden",
                        systemImage: "eye.slash",
                        isOn: $filter.showHidden
                    )
                    FilterToggle(
                        "Zero Size",
                        systemImage: "rectangle.dashed",
                        isOn: $filter.showZeroSize
                    )
                    FilterToggle(
                        "Transparent",
                        systemImage: "circle.dotted",
                        isOn: $filter.showTransparent
                    )
                    // Show the Differing toggle only when there's actually
                    // diff data to act on, OR when the user already has it
                    // enabled (so it doesn't disappear out from under them
                    // mid-session if a refresh transiently empties the set).
                    if !differingIDs.isEmpty || filter.showOnlyDiffering {
                        FilterToggle(
                            "Differing",
                            systemImage: "arrow.triangle.branch",
                            isOn: $filter.showOnlyDiffering
                        )
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // Divider sits at the bottom now that the bar lives above the
            // tree — it visually separates the search controls from the
            // results list below.
            Divider()
        }
        .background(.bar)
    }

    private var countLabel: String {
        if filter.isEmpty {
            return "\(totalCount) nodes"
        }
        return "\(matchCount)/\(totalCount)"
    }

    private var totalCount: Int {
        Self.countAll(in: roots)
    }

    private var matchCount: Int {
        filter.countMatches(in: roots, differingIDs: differingIDs)
    }

    private static func countAll(in nodes: [ViewNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countAll(in: $1.children) }
    }
}

// MARK: - Filter Toggle

private struct FilterToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    init(_ title: String, systemImage: String, isOn: Binding<Bool>) {
        self.title = title
        self.systemImage = systemImage
        self._isOn = isOn
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(4)
                .foregroundStyle(isOn ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
