import SwiftUI
import InspectCore

struct ContentView: View {
    @EnvironmentObject var model: InspectAppModel
    @State private var showInspector = true
    @State private var contentMode: ContentMode = .screenshot

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            MainContentView(
                node: model.selectedNode,
                roots: model.roots,
                contentMode: $contentMode,
                selectedNodeID: $model.selectedNodeID
            )
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(node: model.selectedNode)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar {
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
                Picker("View", selection: $contentMode) {
                    ForEach(ContentMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
    }
}

// MARK: - Content Mode

enum ContentMode: String, CaseIterable, Identifiable {
    case screenshot
    case threeD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .threeD: return "3D"
        }
    }

    var icon: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .threeD: return "cube"
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var model: InspectAppModel

    var body: some View {
        VStack(spacing: 0) {
            DevicePickerBar()
            Divider()
            HierarchyTreeView(
                roots: model.roots,
                selection: $model.selectedNodeID,
                filter: $model.hierarchyFilter
            )
        }
    }
}

// MARK: - Device Picker

private struct DevicePickerBar: View {
    @EnvironmentObject var model: InspectAppModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .foregroundStyle(model.isConnected ? .blue : .secondary)
                Picker("Device", selection: selectedBinding) {
                    Text("No Device")
                        .tag(nil as String?)
                    ForEach(model.discovered) { endpoint in
                        Text(endpoint.name)
                            .tag(endpoint.id as String?)
                    }
                }
                .labelsHidden()
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectedBinding: Binding<String?> {
        Binding(
            get: { model.selectedEndpointID },
            set: { newID in
                model.selectedEndpointID = newID
                if let newID,
                   let endpoint = model.discovered.first(where: { $0.id == newID }) {
                    model.connect(to: endpoint)
                } else if newID == nil {
                    model.disconnect()
                }
            }
        )
    }

    private var statusColor: Color {
        if model.isConnected { return .green }
        if model.status.hasPrefix("connecting") { return .orange }
        return .secondary
    }
}

// MARK: - Main Content

private struct MainContentView: View {
    let node: ViewNode?
    let roots: [ViewNode]
    @Binding var contentMode: ContentMode
    @Binding var selectedNodeID: UUID?

    var body: some View {
        switch contentMode {
        case .screenshot:
            ScreenshotContentView(node: node)
        case .threeD:
            if roots.isEmpty {
                PlaceholderView(
                    title: "No Hierarchy",
                    systemImage: "cube.transparent",
                    message: "Connect to a device and capture a snapshot."
                )
            } else {
                SceneViewContainer(
                    roots: roots,
                    selectedNodeID: $selectedNodeID
                )
            }
        }
    }
}

private struct ScreenshotContentView: View {
    let node: ViewNode?

    var body: some View {
        if let node, let screenshot = node.screenshot, let image = NSImage(data: screenshot) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 600)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.background.secondary)
        } else {
            PlaceholderView(
                title: "No Screenshot",
                systemImage: "camera.viewfinder",
                message: "Select a node with a screenshot to preview it here."
            )
        }
    }
}

// MARK: - Inspector

private struct InspectorView: View {
    let node: ViewNode?

    var body: some View {
        if let node {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.className)
                            .font(.headline.monospaced())
                        Text(node.ident.uuidString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }

                    FrameSection(frame: node.frame)
                    AppearanceSection(node: node)
                    LayerSection(node: node)
                    InteractionSection(node: node)
                    AccessibilitySection(node: node)
                    TypePropertiesSection(properties: node.properties)
                    ChildrenSection(count: node.children.count)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            PlaceholderView(
                title: "No Selection",
                systemImage: "sidebar.squares.right",
                message: "Select a node to inspect its attributes."
            )
        }
    }
}

// MARK: - Frame Section

private struct FrameSection: View {
    let frame: CGRect

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    PropertyLabel("X")
                    PropertyValue(String(format: "%g", frame.origin.x))
                    PropertyLabel("Y")
                    PropertyValue(String(format: "%g", frame.origin.y))
                }
                GridRow {
                    PropertyLabel("Width")
                    PropertyValue(String(format: "%g", frame.size.width))
                    PropertyLabel("Height")
                    PropertyValue(String(format: "%g", frame.size.height))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            SectionHeader("Frame", icon: "rectangle.dashed")
        }
    }
}

// MARK: - Appearance Section

private struct AppearanceSection: View {
    let node: ViewNode

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PropertyLabel("isHidden")
                    HStack(spacing: 4) {
                        Circle()
                            .fill(node.isHidden ? Color.red : Color.green)
                            .frame(width: 6, height: 6)
                        PropertyValue(node.isHidden ? "true" : "false")
                    }
                }
                HStack(spacing: 8) {
                    PropertyLabel("alpha")
                    PropertyValue(String(format: "%.2f", node.alpha))
                    AlphaBar(alpha: node.alpha)
                        .frame(width: 60, height: 4)
                }
                HStack(spacing: 8) {
                    PropertyLabel("backgroundColor")
                    if let color = node.backgroundColor {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.swiftUIColor)
                            .frame(width: 14, height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(.quaternary, lineWidth: 0.5)
                            )
                        PropertyValue(colorString(color))
                    } else {
                        PropertyValue("nil")
                    }
                }
                if let modeName = node.contentModeName {
                    HStack(spacing: 8) {
                        PropertyLabel("contentMode")
                        PropertyValue(modeName)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            SectionHeader("Appearance", icon: "paintbrush")
        }
    }

    private func colorString(_ color: RGBAColor) -> String {
        String(
            format: "rgba(%.2f, %.2f, %.2f, %.2f)",
            color.red, color.green, color.blue, color.alpha
        )
    }
}

// MARK: - Alpha Bar

private struct AlphaBar: View {
    let alpha: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tint)
                    .frame(width: proxy.size.width * alpha)
            }
        }
    }
}

// MARK: - Layer Section

private struct LayerSection: View {
    let node: ViewNode

    var body: some View {
        let hasContent = node.clipsToBounds || node.cornerRadius > 0
            || node.borderWidth > 0 || node.borderColor != nil
        if hasContent {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        PropertyLabel("clipsToBounds")
                        PropertyValue("\(node.clipsToBounds)")
                    }
                    if node.cornerRadius > 0 {
                        HStack(spacing: 8) {
                            PropertyLabel("cornerRadius")
                            PropertyValue(String(format: "%g", node.cornerRadius))
                        }
                    }
                    if node.borderWidth > 0 {
                        HStack(spacing: 8) {
                            PropertyLabel("borderWidth")
                            PropertyValue(String(format: "%g", node.borderWidth))
                        }
                    }
                    if let color = node.borderColor {
                        HStack(spacing: 8) {
                            PropertyLabel("borderColor")
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color.swiftUIColor)
                                .frame(width: 14, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(.quaternary, lineWidth: 0.5)
                                )
                            PropertyValue(String(
                                format: "rgba(%.2f, %.2f, %.2f, %.2f)",
                                color.red, color.green, color.blue, color.alpha
                            ))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                SectionHeader("Layer", icon: "square.stack.3d.up")
            }
        }
    }
}

// MARK: - Interaction Section

private struct InteractionSection: View {
    let node: ViewNode

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PropertyLabel("userInteraction")
                    HStack(spacing: 4) {
                        Circle()
                            .fill(node.isUserInteractionEnabled ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        PropertyValue(node.isUserInteractionEnabled ? "true" : "false")
                    }
                }
                if let isEnabled = node.isEnabled {
                    HStack(spacing: 8) {
                        PropertyLabel("isEnabled")
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isEnabled ? Color.green : Color.red)
                                .frame(width: 6, height: 6)
                            PropertyValue(isEnabled ? "true" : "false")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            SectionHeader("Interaction", icon: "hand.tap")
        }
    }
}

// MARK: - Type-Specific Properties Section

private struct TypePropertiesSection: View {
    let properties: [String: String]

    var body: some View {
        if !properties.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(properties.keys.sorted(), id: \.self) { key in
                        HStack(spacing: 8) {
                            PropertyLabel(key)
                            PropertyValue(properties[key] ?? "")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                SectionHeader("Properties", icon: "list.bullet.rectangle")
            }
        }
    }
}

// MARK: - Accessibility Section

private struct AccessibilitySection: View {
    let node: ViewNode

    var body: some View {
        if node.accessibilityIdentifier != nil || node.accessibilityLabel != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if let identifier = node.accessibilityIdentifier {
                        HStack(spacing: 8) {
                            PropertyLabel("identifier")
                            PropertyValue(identifier)
                        }
                    }
                    if let label = node.accessibilityLabel {
                        HStack(spacing: 8) {
                            PropertyLabel("label")
                            PropertyValue(label)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                SectionHeader("Accessibility", icon: "accessibility")
            }
        }
    }
}

// MARK: - Children Section

private struct ChildrenSection: View {
    let count: Int

    var body: some View {
        GroupBox {
            HStack(spacing: 8) {
                PropertyLabel("count")
                PropertyValue("\(count)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            SectionHeader("Children", icon: "rectangle.3.group")
        }
    }
}

// MARK: - Helpers

private struct SectionHeader: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct PropertyLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(minWidth: 100, alignment: .leading)
    }
}

private struct PropertyValue: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
    }
}
