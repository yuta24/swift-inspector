import SwiftUI
import InspectCore

struct HierarchyTreeView: View {
    let roots: [ViewNode]
    @Binding var selection: UUID?
    @Binding var filter: String

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(roots) { root in
                    OutlineGroup(root, children: \.optionalChildren) { node in
                        HierarchyNodeRow(node: node, highlight: filter)
                            .tag(node.id)
                    }
                }
            }
            .listStyle(.sidebar)
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
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        TextField("Filter classes…", text: $filter)
                            .textFieldStyle(.plain)
                            .font(.callout)
                        if !filter.isEmpty {
                            Button {
                                filter = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("\(nodeCount) nodes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(.bar)
            }
        }
    }

    private var nodeCount: Int {
        Self.countNodes(in: roots)
    }

    private static func countNodes(in nodes: [ViewNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countNodes(in: $1.children) }
    }
}

private extension ViewNode {
    var optionalChildren: [ViewNode]? {
        children.isEmpty ? nil : children
    }
}
