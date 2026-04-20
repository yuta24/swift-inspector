import SwiftUI
import InspectCore

struct ContentView: View {
    @EnvironmentObject var model: InspectAppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } content: {
            HierarchyTreeView(
                roots: model.roots,
                selection: $model.selectedNodeID,
                filter: $model.hierarchyFilter
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 360)
        } detail: {
            DetailView(node: model.selectedNode, roots: model.roots)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if model.isConnected {
                    HStack(spacing: 6) {
                        Image(systemName: "iphone")
                            .foregroundStyle(.secondary)
                        Text(model.connectedDeviceName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestHierarchy()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isConnected)
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .disabled(!model.isConnected)
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var model: InspectAppModel

    var body: some View {
        List(selection: $model.selectedEndpointID) {
            Section {
                ForEach(model.discovered) { endpoint in
                    DeviceRow(endpoint: endpoint)
                        .tag(endpoint.id)
                }
            } header: {
                Label("Devices", systemImage: "wifi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar()
        }
        .onChange(of: model.selectedEndpointID) { newID in
            guard let newID,
                  let endpoint = model.discovered.first(where: { $0.id == newID }),
                  !endpoint.isConnected else { return }
            model.connect(to: endpoint)
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let endpoint: InspectEndpoint

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(endpoint.isConnected ? .blue : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(endpoint.isConnected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(endpoint.isConnected ? "Connected" : "Available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Status Bar

private struct StatusBar: View {
    @EnvironmentObject var model: InspectAppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var statusColor: Color {
        if model.isConnected { return .green }
        if model.status.hasPrefix("connecting") { return .orange }
        return .secondary
    }
}
