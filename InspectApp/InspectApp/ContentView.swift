import SwiftUI
import InspectCore

struct ContentView: View {
    @EnvironmentObject var model: InspectAppModel

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 220, idealWidth: 240)
            HierarchyTreeView(
                roots: model.roots,
                selection: $model.selectedNodeID
            )
            .frame(minWidth: 280, idealWidth: 340)
            DetailView(node: model.selectedNode)
                .frame(minWidth: 320)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestHierarchy()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isConnected)
            }
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject var model: InspectAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Devices")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            List(selection: $model.selectedEndpointID) {
                ForEach(model.discovered) { endpoint in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.name)
                            .font(.body)
                        Text(endpoint.isConnected ? "connected" : "available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(endpoint.id)
                    .contextMenu {
                        Button("Connect") { model.connect(to: endpoint) }
                        Button("Disconnect") { model.disconnect() }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            StatusBar()
                .padding(8)
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject var model: InspectAppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
