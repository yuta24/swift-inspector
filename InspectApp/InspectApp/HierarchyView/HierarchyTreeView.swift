import SwiftUI
import InspectCore

struct HierarchyTreeView: View {
    let roots: [ViewNode]
    @Binding var selection: UUID?
    @Binding var filter: HierarchyFilter

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(roots) { root in
                    if filter.isEmpty {
                        OutlineGroup(root, children: \.optionalChildren) { node in
                            HierarchyNodeRow(node: node, filter: filter)
                                .tag(node.id)
                        }
                    } else {
                        FilteredOutlineGroup(root: root, filter: filter)
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

            if !roots.isEmpty {
                FilterBar(filter: $filter, roots: roots)
            }
        }
    }
}

// MARK: - Filtered Outline Group
//
// Xcode View Debugger style filtering:
//   - Branches with no matching descendants are pruned (hidden entirely)
//   - Non-matching ancestor nodes are shown but dimmed
//   - Matching nodes are highlighted

private struct FilteredOutlineGroup: View {
    let root: ViewNode
    let filter: HierarchyFilter

    var body: some View {
        if filter.subtreeContainsMatch(root) {
            let filteredChildren = root.children.filter { filter.subtreeContainsMatch($0) }
            let isDimmed = !filter.matches(root)
            if filteredChildren.isEmpty {
                HierarchyNodeRow(node: root, filter: filter, isDimmed: isDimmed)
                    .tag(root.id)
            } else {
                DisclosureGroup {
                    ForEach(filteredChildren) { child in
                        FilteredOutlineGroup(root: child, filter: filter)
                    }
                } label: {
                    HierarchyNodeRow(node: root, filter: filter, isDimmed: isDimmed)
                        .tag(root.id)
                }
            }
        }
    }
}

// MARK: - Filter Bar

private struct FilterBar: View {
    @Binding var filter: HierarchyFilter
    let roots: [ViewNode]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
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
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
        filter.countMatches(in: roots)
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

private extension ViewNode {
    var optionalChildren: [ViewNode]? {
        children.isEmpty ? nil : children
    }
}
