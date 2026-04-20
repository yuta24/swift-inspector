import SwiftUI
import InspectCore

struct HierarchyTreeView: View {
    let roots: [ViewNode]
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(roots) { root in
                OutlineGroup(root, children: \.optionalChildren) { node in
                    HierarchyNodeRow(node: node)
                        .tag(node.id)
                }
            }
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

private extension ViewNode {
    var optionalChildren: [ViewNode]? {
        children.isEmpty ? nil : children
    }
}
