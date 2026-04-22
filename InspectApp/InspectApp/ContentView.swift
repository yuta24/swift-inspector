import SwiftUI
import InspectCore

struct ContentView: View {
    @EnvironmentObject var model: InspectAppModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            DetailContentView(
                roots: model.roots,
                selectedNodeID: $model.selectedNodeID,
                measurementReferenceID: $model.measurementReferenceID,
                measurementHoverID: $model.measurementHoverID
            )
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(
                node: model.selectedNode,
                compareNode: model.measurementCompareNode,
                isHoveringCompare: model.measurementHoverID != nil,
                selectedNodeID: $model.selectedNodeID,
                measurementReferenceID: $model.measurementReferenceID
            )
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ActivityIndicator(
                    isConnecting: model.isConnecting,
                    isInflight: model.isInflight
                )
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
                LiveToolbarControl()
                    .environmentObject(model)
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

// MARK: - Activity Indicator

/// Small toolbar spinner that shows when the app is either establishing a
/// connection or waiting on a hierarchy response. Rendered as an empty view
/// when idle so it collapses out of the toolbar layout.
private struct ActivityIndicator: View {
    let isConnecting: Bool
    let isInflight: Bool

    var body: some View {
        if isConnecting || isInflight {
            ProgressView()
                .controlSize(.small)
                .help(isConnecting ? "Connecting…" : "Capturing hierarchy…")
        }
    }
}


// MARK: - Live Toolbar Control

/// Live mode toolbar button with a dropdown for picking the refresh interval.
/// Click toggles Live on/off (Cmd+L); the chevron opens the interval menu.
private struct LiveToolbarControl: View {
    @EnvironmentObject var model: InspectAppModel

    private static let intervalPresets: [TimeInterval] = [0.5, 1.0, 2.0, 3.0]

    var body: some View {
        Menu {
            Section("Interval") {
                ForEach(Self.intervalPresets, id: \.self) { interval in
                    Button {
                        model.setLiveInterval(interval)
                    } label: {
                        HStack {
                            Text("\(String(format: "%.1f", interval))s")
                            if model.liveInterval == interval {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isLiveMode ? "pause.circle.fill" : "play.circle")
                Text(model.isLiveMode ? "Pause Live" : "Live")
                if let badge = transportBadge {
                    Text(badge)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }
            }
        } primaryAction: {
            model.toggleLiveMode()
        }
        .disabled(!model.isConnected)
        .keyboardShortcut("l", modifiers: .command)
        .help(helpText)
    }

    private var transportBadge: String? {
        switch model.liveTransport {
        case .push: return "push"
        case .poll: return "poll"
        case .none: return nil
        }
    }

    private var helpText: String {
        guard model.isLiveMode else {
            return "Start auto-refreshing the hierarchy"
        }
        let transport: String
        switch model.liveTransport {
        case .push: transport = " via server push"
        case .poll: transport = " via client polling"
        case .none: transport = ""
        }
        return "Auto-refreshing every \(String(format: "%.1f", model.liveInterval))s\(transport) — click to pause"
    }
}

// MARK: - Detail Content

private struct DetailContentView: View {
    let roots: [ViewNode]
    @Binding var selectedNodeID: UUID?
    @Binding var measurementReferenceID: UUID?
    @Binding var measurementHoverID: UUID?

    var body: some View {
        ZStack {
            if roots.isEmpty {
                PlaceholderView(
                    title: "No Hierarchy",
                    systemImage: "cube.transparent",
                    message: "Connect to a device and capture a snapshot."
                )
            } else {
                SceneViewContainer(
                    roots: roots,
                    selectedNodeID: $selectedNodeID,
                    measurementReferenceID: $measurementReferenceID,
                    measurementHoverID: $measurementHoverID
                )
            }
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
                statusIndicator
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if model.isLiveMode, let badge = transportBadge {
                    Text(badge)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }
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

    @ViewBuilder
    private var statusIndicator: some View {
        if model.isConnecting {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        }
    }

    private var statusColor: Color {
        if model.isConnected { return .green }
        if model.status.hasPrefix("error") || model.status.hasPrefix("failed") {
            return .red
        }
        return .secondary
    }

    private var transportBadge: String? {
        switch model.liveTransport {
        case .push: return "push"
        case .poll: return "poll"
        case .none: return nil
        }
    }
}


// MARK: - Inspector

private struct InspectorView: View {
    let node: ViewNode?
    let compareNode: ViewNode?
    let isHoveringCompare: Bool
    @Binding var selectedNodeID: UUID?
    @Binding var measurementReferenceID: UUID?

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

                    ScreenshotSection(node: node)
                    FrameSection(frame: node.frame)
                    MeasurementSection(
                        selection: node,
                        compare: compareNode,
                        isHoveringCompare: isHoveringCompare,
                        measurementReferenceID: $measurementReferenceID,
                        onNavigate: { id in selectedNodeID = id }
                    )
                    AppearanceSection(node: node)
                    LayerSection(node: node)
                    InteractionSection(node: node)
                    AccessibilitySection(node: node)
                    ConstraintsSection(
                        node: node,
                        onNavigate: { id in selectedNodeID = id }
                    )
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

// MARK: - Screenshot Section

private struct ScreenshotSection: View {
    let node: ViewNode
    @State private var showSolo = false

    var body: some View {
        let data = showSolo ? node.soloScreenshot : node.screenshot
        if data != nil || node.soloScreenshot != nil {
            GroupBox {
                VStack(spacing: 8) {
                    if let data, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    } else {
                        Text("No image")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(height: 60)
                    }

                    if node.soloScreenshot != nil && node.screenshot != nil {
                        Picker("", selection: $showSolo) {
                            Text("Group").tag(false)
                            Text("Solo").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(4)
            } label: {
                SectionHeader("Screenshot", icon: "camera.viewfinder")
            }
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

// MARK: - Measurement Section

private struct MeasurementSection: View {
    let selection: ViewNode
    let compare: ViewNode?
    let isHoveringCompare: Bool
    @Binding var measurementReferenceID: UUID?
    let onNavigate: (UUID) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                hintRow
                pinButton
                if let compare, compare.id != selection.id {
                    compareRow(compare)
                    Divider()
                    MeasurementRows(
                        measurement: FrameMeasurement(
                            reference: selection.windowFrame,
                            target: compare.windowFrame
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            SectionHeader("Measurement", icon: "ruler")
        }
    }

    private var hintRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "option")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Text("Hold Option and hover a view to measure, or pin one below.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var pinButton: some View {
        let isPinned = measurementReferenceID == selection.id
        return Button {
            measurementReferenceID = isPinned ? nil : selection.id
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                Text(isPinned ? "Unpin this view" : "Pin this view as compare")
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
    }

    private func compareRow(_ compare: ViewNode) -> some View {
        HStack(spacing: 6) {
            PropertyLabel(isHoveringCompare ? "Hover" : "Compare")
            Button {
                onNavigate(compare.id)
            } label: {
                Text(compare.className)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Jump to \(compare.className)")
            Spacer(minLength: 4)
            if !isHoveringCompare {
                Button {
                    measurementReferenceID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear pinned compare")
            }
        }
    }
}

private struct MeasurementRows: View {
    let measurement: FrameMeasurement

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(
                "Δx",
                value: measurement.horizontalGap,
                descriptor: horizontalDescriptor,
                zeroCaption: "overlapping x"
            )
            row(
                "Δy",
                value: measurement.verticalGap,
                descriptor: verticalDescriptor,
                zeroCaption: "overlapping y"
            )
            HStack(spacing: 8) {
                PropertyLabel("Center")
                PropertyValue(format(measurement.centerDistance))
                Text("(Δ \(format(measurement.centerDelta.width)), \(format(measurement.centerDelta.height)))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                PropertyLabel("Relation")
                PropertyValue(describe(measurement.relationship))
            }
        }
    }

    @ViewBuilder
    private func row(
        _ label: String,
        value: CGFloat,
        descriptor: String,
        zeroCaption: String
    ) -> some View {
        HStack(spacing: 8) {
            PropertyLabel(label)
            PropertyValue(format(abs(value)))
            if value == 0 {
                Text(zeroCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(descriptor)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var horizontalDescriptor: String {
        measurement.horizontalGap > 0 ? "compare is right of selection"
            : "compare is left of selection"
    }

    private var verticalDescriptor: String {
        measurement.verticalGap > 0 ? "compare is below selection"
            : "compare is above selection"
    }

    private func format(_ v: CGFloat) -> String {
        if v == v.rounded() { return String(format: "%g pt", v) }
        return String(format: "%.2f pt", v)
    }

    private func describe(_ r: FrameMeasurement.Relationship) -> String {
        switch r {
        case .disjoint: return "disjoint"
        case .overlapping: return "overlapping"
        case .targetInsideReference: return "compare is inside selection"
        case .referenceInsideTarget: return "selection is inside compare"
        case .identical: return "identical"
        }
    }
}

// MARK: - Constraints Section

private struct ConstraintsSection: View {
    let node: ViewNode
    let onNavigate: (UUID) -> Void

    var body: some View {
        if !node.constraints.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(node.constraints.enumerated()), id: \.offset) { _, constraint in
                        ConstraintRow(
                            constraint: constraint,
                            selfID: node.id,
                            onNavigate: onNavigate
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                SectionHeader("Constraints (\(node.constraints.count))", icon: "ruler")
            }
        }
    }
}

private struct ConstraintRow: View {
    let constraint: LayoutConstraint
    let selfID: UUID
    let onNavigate: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if !constraint.isActive {
                    Image(systemName: "circle.dashed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("inactive")
                }
                anchorLabel(constraint.first)
                Text(LayoutConstraint.relationSymbol(constraint.relation))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let second = constraint.second {
                    anchorLabel(second)
                    if constraint.multiplier != 1.0 {
                        Text("× \(formatNumber(constraint.multiplier))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if constraint.constant != 0 {
                        Text(formatSignedConstant(constraint.constant))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(formatNumber(constraint.constant))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if constraint.priority < 1000 {
                    Text("@\(Int(constraint.priority))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            if let identifier = constraint.identifier, !identifier.isEmpty {
                Text(identifier)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func anchorLabel(_ anchor: LayoutConstraint.Anchor) -> some View {
        let name = displayName(for: anchor)
        let attr = LayoutConstraint.attributeName(anchor.attribute)
        let label = "\(name).\(attr)"

        if let id = anchor.ownerID, id != selfID {
            Button {
                onNavigate(id)
            } label: {
                Text(label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .help("Jump to \(name)")
        } else {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(anchor.ownerID == selfID ? .primary : .secondary)
        }
    }

    private func displayName(for anchor: LayoutConstraint.Anchor) -> String {
        if anchor.ownerID == selfID && !anchor.isLayoutGuide {
            return "self"
        }
        return anchor.description
    }

    private func formatNumber(_ v: Double) -> String {
        if v == v.rounded() {
            return String(format: "%g", v)
        }
        return String(format: "%.3g", v)
    }

    private func formatSignedConstant(_ v: Double) -> String {
        if v >= 0 {
            return "+ \(formatNumber(v))"
        }
        return "− \(formatNumber(-v))"
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
