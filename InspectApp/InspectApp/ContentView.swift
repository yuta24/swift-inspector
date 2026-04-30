import SwiftUI
import AppKit
import InspectCore

struct ContentView: View {
    @EnvironmentObject var model: AppInspectorModel
    @EnvironmentObject var crashPresenter: CrashReportPresenter
    @EnvironmentObject var figmaModel: FigmaComparisonModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            DetailContentView(
                roots: model.displayRoots,
                selectedNodeID: $model.selectedNodeID,
                measurementReferenceID: $model.measurementReferenceID,
                measurementHoverID: $model.measurementHoverID
            )
        }
        // Keep Figma diff state in sync with the device hierarchy regardless
        // of which canvas mode (or whether the inspector is visible) is
        // currently rendered. The 2D toolbar and the inspector's diff
        // section both read from `figmaModel.diffs` / `differingNodeIDs`,
        // and they would go stale on root churn if the trigger lived in a
        // surface that can be hidden.
        .onChange(of: model.roots.map(\.ident)) { _, _ in
            figmaModel.updateRoots(model.roots)
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
        .sheet(isPresented: crashSheetBinding) {
            CrashReportSheet(
                reports: crashPresenter.pendingReports,
                onSkip: { crashPresenter.dismiss() },
                onSuppress: { crashPresenter.dismiss(suppressForever: true) },
                onReport: { report in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(report.rawContents, forType: .string)
                    if let url = crashPresenter.issueURL(for: report) {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                ActivityIndicator(
                    isConnecting: model.isConnecting,
                    isAwaitingPair: model.isAwaitingPairApproval,
                    isInflight: model.isInflight
                )
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

    /// Drives `.sheet(isPresented:)` from the presenter's pending list. The
    /// setter only reacts to a `false` write — the sheet itself never sets
    /// it back to `true`, and dismissals always go through one of the
    /// presenter's explicit dismiss callbacks.
    private var crashSheetBinding: Binding<Bool> {
        Binding(
            get: { !crashPresenter.pendingReports.isEmpty },
            set: { isShown in
                if !isShown && !crashPresenter.pendingReports.isEmpty {
                    crashPresenter.dismiss()
                }
            }
        )
    }
}

// MARK: - Activity Indicator

/// Small toolbar spinner that shows when the app is either establishing a
/// connection or waiting on a hierarchy response. Rendered as an empty view
/// when idle so it collapses out of the toolbar layout.
private struct ActivityIndicator: View {
    let isConnecting: Bool
    let isAwaitingPair: Bool
    let isInflight: Bool

    var body: some View {
        if isConnecting || isAwaitingPair || isInflight {
            ProgressView()
                .controlSize(.small)
                .help(tooltip)
        }
    }

    private var tooltip: String {
        if isConnecting { return String(localized: "Connecting…") }
        if isAwaitingPair { return String(localized: "Awaiting approval on the device…") }
        return String(localized: "Capturing hierarchy…")
    }
}


// MARK: - Live Toolbar Control

/// Live mode toolbar button with a dropdown for picking the refresh interval.
/// Click toggles Live on/off (Cmd+L); the chevron opens the interval menu.
private struct LiveToolbarControl: View {
    @EnvironmentObject var model: AppInspectorModel

    private static let intervalPresets: [TimeInterval] = [0.5, 1.0, 2.0, 3.0]

    var body: some View {
        Menu {
            Section("Interval") {
                ForEach(Self.intervalPresets, id: \.self) { interval in
                    Button {
                        model.setLiveInterval(interval)
                    } label: {
                        HStack {
                            // Verbatim — the formatted number is data, not UI copy.
                            Text(verbatim: "\(String(format: "%.1f", interval))s")
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
            return String(localized: "Start auto-refreshing the hierarchy")
        }
        let interval = String(format: "%.1f", model.liveInterval)
        switch model.liveTransport {
        case .push:
            return String(localized: "Auto-refreshing every \(interval)s via server push — click to pause")
        case .poll:
            return String(localized: "Auto-refreshing every \(interval)s via client polling — click to pause")
        case .none:
            return String(localized: "Auto-refreshing every \(interval)s — click to pause")
        }
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
    @EnvironmentObject var model: AppInspectorModel
    @EnvironmentObject var figmaModel: FigmaComparisonModel

    var body: some View {
        VStack(spacing: 0) {
            DevicePickerBar()
            SidebarActionsBar()
            Divider()
            if let focused = model.focusedNode {
                FocusBar(node: focused) {
                    model.clearFocus()
                }
                Divider()
            }
            HierarchyTreeView(
                roots: model.displayRoots,
                selection: $model.selectedNodeID,
                filter: $model.hierarchyFilter,
                expandedPaths: $model.expandedPaths,
                differingIDs: figmaModel.differingNodeIDs
            )
        }
    }
}

// MARK: - Sidebar Actions Bar

/// Hierarchy-fetch and focus controls grouped with the device picker.
/// Lives in the sidebar (not the window toolbar) because Refresh and Live
/// drive what flows into the tree, while the inspector only displays the
/// already-fetched node — putting them above the inspector implied a
/// scope they didn't have.
private struct SidebarActionsBar: View {
    @EnvironmentObject var model: AppInspectorModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.requestHierarchy()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!model.isConnected)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh hierarchy (⌘R)")

            LiveToolbarControl()

            Spacer(minLength: 4)

            Button {
                guard let id = model.selectedNodeID else { return }
                model.focus(on: id)
            } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.borderless)
            // Disabled while a focus is already active so the matching
            // ⌘⇧F keyboard shortcut routes to FocusBar's exit button
            // instead — toggle behavior preserved across two views.
            .disabled(model.selectedNodeID == nil || model.focusedNodeID != nil)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Focus on selected (⌘⇧F)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Focus Bar

/// Shown above the tree while a focus is active. Tells the user *why* the
/// tree is suddenly short and gives a single-click exit. Kept in the sidebar
/// (not the toolbar) so it's right next to the truncated tree it's explaining.
private struct FocusBar: View {
    let node: ViewNode
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.caption)
                .foregroundStyle(.tint)
            Text("Focused on")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let display = node.displayName {
                Text(verbatim: display)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(node.className)
            } else {
                Text(verbatim: node.shortClassName)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.className)
            }
            Spacer(minLength: 4)
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            // Re-binds ⌘⇧F to "exit" while focus is active so the
            // shortcut continues to toggle, mirroring the enter-side
            // binding in SidebarActionsBar.
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Exit focus (⌘⇧F)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
    }
}

// MARK: - Device Picker

private struct DevicePickerBar: View {
    @EnvironmentObject var model: AppInspectorModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .foregroundStyle(model.isConnected ? .blue : .secondary)
                Picker("Device", selection: selectedBinding) {
                    Text("No Device")
                        .tag(nil as String?)
                    ForEach(model.discovered) { endpoint in
                        // Verbatim — endpoint name is data (Bonjour service name).
                        Text(verbatim: endpoint.name)
                            .tag(endpoint.id as String?)
                    }
                }
                .labelsHidden()
                .disabled(model.isConnecting)
                ConnectionActionButton()
                    .environmentObject(model)
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
                // Staging only — connection lifecycle is driven by the
                // adjacent ConnectionActionButton. Stale Retry state for the
                // previous target is cleared here so switching devices after
                // a failure doesn't surface "Retry for the old one".
                if newID != model.selectedEndpointID {
                    model.connectionError = nil
                }
                model.selectedEndpointID = newID
            }
        )
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if model.isConnecting || model.isAwaitingPairApproval {
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
        if model.isAwaitingPairApproval { return .orange }
        if model.isConnected { return .green }
        if model.status.hasPrefix("error") || model.status.hasPrefix("failed")
            || model.status.hasPrefix("rejected") || model.status.hasPrefix("pair timeout") {
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

// MARK: - Connection Action Button

/// Unified Connect / Cancel / Disconnect / Switch / Retry affordance.
/// Renders nothing when there is nothing to act on (no selection, not
/// connected, no error) — keeps the Picker row uncluttered in the idle state.
private struct ConnectionActionButton: View {
    @EnvironmentObject var model: AppInspectorModel

    var body: some View {
        if let action = resolvedAction {
            // The two button styles (plain for Disconnect, bordered for
            // everything else) differ in return type under `.buttonStyle`,
            // so we branch at the view level rather than picking the style
            // value dynamically.
            if action == .disconnect {
                Button(role: .cancel) {
                    perform(action)
                } label: {
                    label(for: action)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help(tooltip(for: action))
            } else {
                Button(role: action.role) {
                    perform(action)
                } label: {
                    label(for: action)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(tooltip(for: action))
            }
        }
    }

    private enum Action {
        case connect
        case cancel
        case disconnect
        case switchDevice
        case retry

        var role: ButtonRole? {
            switch self {
            case .cancel: return .cancel
            case .connect, .retry, .switchDevice, .disconnect: return nil
            }
        }
    }

    private var resolvedAction: Action? {
        if model.isConnecting { return .cancel }
        // While the device-side approval prompt is open the TCP socket
        // already says `.ready` (so `isConnected` is true), but the user's
        // intent for the button is still "cancel this in-flight attempt"
        // rather than "tear down a working session". Surface Cancel so the
        // affordance matches the mental model.
        if model.isAwaitingPairApproval { return .cancel }
        if model.isConnected {
            if let selected = model.selectedEndpointID,
               selected != model.connectedEndpointID {
                return .switchDevice
            }
            return .disconnect
        }
        guard model.selectedEndpointID != nil else { return nil }
        if model.connectionError != nil { return .retry }
        return .connect
    }

    @ViewBuilder
    private func label(for action: Action) -> some View {
        switch action {
        case .connect:
            Label("Connect", systemImage: "bolt.horizontal.circle")
        case .cancel:
            Label("Cancel", systemImage: "stop.circle")
        case .disconnect:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        case .switchDevice:
            Label("Switch", systemImage: "arrow.triangle.2.circlepath")
        case .retry:
            Label("Retry", systemImage: "arrow.clockwise")
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .connect, .retry, .switchDevice:
            guard let id = model.selectedEndpointID,
                  let endpoint = model.discovered.first(where: { $0.id == id }) else {
                return
            }
            model.connect(to: endpoint)
        case .cancel, .disconnect:
            model.disconnect()
        }
    }

    private func tooltip(for action: Action) -> String {
        switch action {
        case .connect: return String(localized: "Connect to the selected device")
        case .cancel: return String(localized: "Cancel this connection attempt")
        case .disconnect: return String(localized: "Disconnect")
        case .switchDevice:
            let name = model.discovered
                .first(where: { $0.id == model.selectedEndpointID })?.name
                ?? String(localized: "the selected device")
            return String(localized: "Disconnect and connect to \(name)")
        case .retry:
            if let error = model.connectionError {
                return String(localized: "Retry — last attempt failed: \(error)")
            }
            return String(localized: "Retry the connection")
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
                        if let display = node.displayName {
                            Text(display)
                                .font(.headline)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text(node.className)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text(node.className)
                                .font(.headline.monospaced())
                                .textSelection(.enabled)
                        }
                        Text(node.ident.uuidString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        NodeFocusMenu(nodeID: node.id)
                        Divider()
                        NodeCopyMenu(node: node)
                    }

                    // Designer-first ordering: visual essentials (what does
                    // it look like? where is it? what color/type is it?)
                    // come above the developer-oriented sections (raw
                    // interaction flags, Auto Layout constraints, runtime
                    // property dumps).
                    //
                    // Whole-screen Figma comparison (image overlay, mode
                    // picker, opacity, etc.) is rendered in the 2D canvas
                    // instead of here — the 320pt inspector column can't
                    // show the rendered overlay at a useful resolution.
                    // The selection-bound diff table stays in the inspector.
                    ScreenshotSection(node: node)
                    FigmaDiffSection(node: node)
                    FrameSection(frame: node.frame, safeAreaInsets: node.safeAreaInsets)
                    AppearanceSection(node: node)
                    if let typography = node.typography {
                        TypographySection(typography: typography)
                    }
                    LayerSection(node: node)
                    MeasurementSection(
                        selection: node,
                        compare: compareNode,
                        isHoveringCompare: isHoveringCompare,
                        measurementReferenceID: $measurementReferenceID,
                        onNavigate: { id in selectedNodeID = id }
                    )
                    AccessibilitySection(node: node)

                    // Developer-oriented sections.
                    InteractionSection(node: node)
                    ConstraintsSection(
                        node: node,
                        onNavigate: { id in selectedNodeID = id }
                    )
                    TypePropertiesSection(properties: node.properties)
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
            CollapsibleSection(id: "screenshot", title: "Screenshot", icon: "camera.viewfinder") {
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

                    HStack(spacing: 8) {
                        if node.soloScreenshot != nil && node.screenshot != nil {
                            Picker("", selection: $showSolo) {
                                Text("Group").tag(false)
                                Text("Solo").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        Spacer(minLength: 0)
                        if let data {
                            Button {
                                ScreenshotExport.save(
                                    data: data,
                                    className: node.className,
                                    variant: showSolo ? "solo" : "group"
                                )
                            } label: {
                                Label("Save PNG", systemImage: "square.and.arrow.down")
                            }
                            .controlSize(.small)
                            .help("Save this screenshot as a PNG")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(4)
            }
        }
    }
}

// MARK: - Figma Diff Section

/// Spec-vs-implementation diff for the currently-selected ViewNode. Hidden
/// when no Figma frame has been fetched or when the matcher couldn't pin
/// the selection to a layer. Designers see two flavors of dot:
/// green = matches Figma, red = differs. Unavailable rows are greyed out.
private struct FigmaDiffSection: View {
    let node: ViewNode
    @EnvironmentObject var figmaModel: FigmaComparisonModel

    var body: some View {
        if let match = figmaModel.match(for: node), let diff = figmaModel.diff(for: node) {
            CollapsibleSection(id: "figmaDiff", title: "Figma Diff", icon: "arrow.triangle.branch") {
                VStack(alignment: .leading, spacing: 6) {
                    matchHeader(match: match)
                    if diff.items.isEmpty {
                        Text("No comparable attributes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Divider()
                        ForEach(diff.items.indices, id: \.self) { index in
                            row(diff.items[index])
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    @ViewBuilder
    private func matchHeader(match: FigmaLayerMatcher.Match) -> some View {
        HStack(spacing: 6) {
            Text(match.layer.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(verbatim: confidenceLabel(match))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(confidenceColor(match.confidence).opacity(0.18))
                .foregroundStyle(confidenceColor(match.confidence))
                .clipShape(Capsule())
        }
    }

    private func confidenceLabel(_ match: FigmaLayerMatcher.Match) -> String {
        switch match.strategy {
        case .identifierName: return String(localized: "Name match")
        case .textContent: return String(localized: "Text match")
        case .boundingBox:
            switch match.confidence {
            case .high: return String(localized: "Layout match (strong)")
            case .medium: return String(localized: "Layout match (weak)")
            case .low: return String(localized: "Layout match (low)")
            }
        }
    }

    private func confidenceColor(_ c: FigmaLayerMatcher.Match.Confidence) -> Color {
        switch c {
        case .high: return .green
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    @ViewBuilder
    private func row(_ item: FigmaDiff.Item) -> some View {
        HStack(spacing: 8) {
            statusDot(item.status)
            // `item.label` is built by FigmaDiffEngine via String(localized:),
            // so it's already user-facing copy — pass through verbatim.
            PropertyLabel(verbatim: item.label)
            PropertyValue(item.figma ?? "—")
                .foregroundStyle(item.status == .differ ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            PropertyValue(item.device ?? "—")
                .foregroundStyle(item.status == .differ ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statusDot(_ status: FigmaDiff.Status) -> some View {
        let color: Color = {
            switch status {
            case .match: return .green
            case .differ: return .red
            case .unavailable: return .secondary
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

// MARK: - Screenshot Export

/// Writes an encoded screenshot (JPEG for group, PNG for solo) to disk as a
/// lossless PNG via `NSSavePanel`. Re-encodes through `NSBitmapImageRep` so
/// the file on disk is always PNG regardless of the source format.
private enum ScreenshotExport {
    static func save(data: Data, className: String, variant: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(className)-\(variant).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pngData: Data? = {
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                return nil
            }
            return rep.representation(using: .png, properties: [:])
        }()

        if let pngData {
            try? pngData.write(to: url)
        } else {
            // Fall back to the raw bytes so the user always gets a file, even
            // if re-encoding fails for some reason.
            try? data.write(to: url)
        }
    }
}

// MARK: - Frame Section

private struct FrameSection: View {
    let frame: CGRect
    let safeAreaInsets: InspectCore.EdgeInsets?

    var body: some View {
        CollapsibleSection(id: "frame", title: "Frame", icon: "rectangle.dashed") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    fieldPair(label: "X", value: frame.origin.x)
                    fieldPair(label: "Y", value: frame.origin.y)
                }
                HStack(spacing: 12) {
                    fieldPair(label: "Width", value: frame.size.width)
                    fieldPair(label: "Height", value: frame.size.height)
                }
                if let safeAreaInsets {
                    Divider()
                    HStack(spacing: 12) {
                        fieldPair(label: "Safe T", value: CGFloat(safeAreaInsets.top))
                        fieldPair(label: "Safe B", value: CGFloat(safeAreaInsets.bottom))
                    }
                    HStack(spacing: 12) {
                        fieldPair(label: "Safe L", value: CGFloat(safeAreaInsets.left))
                        fieldPair(label: "Safe R", value: CGFloat(safeAreaInsets.right))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// Two pairs share the inspector width via a 50/50 split (both pairs
    /// use `.frame(maxWidth: .infinity)` inside an HStack). Within a pair
    /// the label is left-anchored and the value right-anchored so X/Width
    /// stack into the same vertical rail and Y/Height into another —
    /// easier to scan than a four-column grid for designers.
    ///
    /// Avoids the shared `PropertyLabel`/`PropertyValue` because the
    /// former's `minWidth: 100` consumes most of the half-pair, pushing
    /// long values (e.g. "-1163.5") past the inspector edge.
    private func fieldPair(label: String, value: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(String(format: "%g", value))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Appearance Section

private struct AppearanceSection: View {
    let node: ViewNode

    var body: some View {
        CollapsibleSection(id: "appearance", title: "Appearance", icon: "paintbrush") {
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
                        ColorSwatch(color: color)
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
        }
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
            CollapsibleSection(id: "layer", title: "Layer", icon: "square.stack.3d.up") {
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
                            ColorSwatch(color: color)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}

// MARK: - Interaction Section

private struct InteractionSection: View {
    let node: ViewNode

    var body: some View {
        CollapsibleSection(id: "interaction", title: "Interaction", icon: "hand.tap") {
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
        }
    }
}

// MARK: - Type-Specific Properties Section

private struct TypePropertiesSection: View {
    let properties: [String: String]

    var body: some View {
        if !properties.isEmpty {
            CollapsibleSection(id: "properties", title: "Properties", icon: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(properties.keys.sorted(), id: \.self) { key in
                        HStack(spacing: 8) {
                            // Property keys are runtime-derived UIKit names
                            // (`isHidden`, `clipsToBounds`, etc.); they're
                            // identifiers, not user-facing copy.
                            PropertyLabel(verbatim: key)
                            PropertyValue(properties[key] ?? "")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}

// MARK: - Accessibility Section

private struct AccessibilitySection: View {
    let node: ViewNode

    var body: some View {
        if node.accessibilityIdentifier != nil || node.accessibilityLabel != nil {
            CollapsibleSection(id: "accessibility", title: "Accessibility", icon: "accessibility") {
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
        CollapsibleSection(id: "measurement", title: "Measurement", icon: "ruler") {
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
        let buttonLabel = compare.displayName ?? compare.shortClassName
        let usesDisplayName = compare.displayName != nil
        return HStack(spacing: 6) {
            PropertyLabel(isHoveringCompare ? "Hover" : "Compare")
            Button {
                onNavigate(compare.id)
            } label: {
                Text(verbatim: buttonLabel)
                    .font(usesDisplayName ? .caption : .caption.monospaced())
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Jump to \(compare.className)"))
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
                zeroCaption: String(localized: "overlapping x")
            )
            row(
                "Δy",
                value: measurement.verticalGap,
                descriptor: verticalDescriptor,
                zeroCaption: String(localized: "overlapping y")
            )
            HStack(spacing: 8) {
                PropertyLabel("Center")
                PropertyValue(format(measurement.centerDistance))
                Text(verbatim: "(Δ \(format(measurement.centerDelta.width)), \(format(measurement.centerDelta.height)))")
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
        _ symbol: String,
        value: CGFloat,
        descriptor: String,
        zeroCaption: String
    ) -> some View {
        HStack(spacing: 8) {
            PropertyLabel(verbatim: symbol)
            PropertyValue(format(abs(value)))
            if value == 0 {
                Text(verbatim: zeroCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(verbatim: descriptor)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var horizontalDescriptor: String {
        measurement.horizontalGap > 0
            ? String(localized: "compare is right of selection")
            : String(localized: "compare is left of selection")
    }

    private var verticalDescriptor: String {
        measurement.verticalGap > 0
            ? String(localized: "compare is below selection")
            : String(localized: "compare is above selection")
    }

    private func format(_ v: CGFloat) -> String {
        if v == v.rounded() { return String(format: "%g pt", v) }
        return String(format: "%.2f pt", v)
    }

    private func describe(_ r: FrameMeasurement.Relationship) -> String {
        switch r {
        case .disjoint: return String(localized: "disjoint")
        case .overlapping: return String(localized: "overlapping")
        case .targetInsideReference: return String(localized: "compare is inside selection")
        case .referenceInsideTarget: return String(localized: "selection is inside compare")
        case .identical: return String(localized: "identical")
        }
    }
}

// MARK: - Constraints Section

private struct ConstraintsSection: View {
    let node: ViewNode
    let onNavigate: (UUID) -> Void

    var body: some View {
        if !node.constraints.isEmpty {
            CollapsibleSection(
                id: "constraints",
                title: "Constraints (\(node.constraints.count))",
                icon: "ruler"
            ) {
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
            .help(String(localized: "Jump to \(name)"))
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

// MARK: - Typography Section

private struct TypographySection: View {
    let typography: Typography

    var body: some View {
        CollapsibleSection(id: "typography", title: "Typography", icon: "textformat") {
            VStack(alignment: .leading, spacing: 6) {
                fontRow
                metricsGrid
                if let color = typography.textColor {
                    HStack(spacing: 8) {
                        PropertyLabel("textColor")
                        ColorSwatch(color: color)
                    }
                }
                if let alignment = typography.alignment {
                    HStack(spacing: 8) {
                        PropertyLabel("alignment")
                        PropertyValue(alignment)
                    }
                }
                if let lines = typography.numberOfLines {
                    HStack(spacing: 8) {
                        PropertyLabel("numberOfLines")
                        PropertyValue(
                            lines == 0
                                ? String(localized: "0 (unlimited)")
                                : "\(lines)"
                        )
                    }
                }
                if typography.isBold || typography.isItalic {
                    HStack(spacing: 4) {
                        if typography.isBold { traitBadge("Bold", italic: false) }
                        if typography.isItalic { traitBadge("Italic", italic: true) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var fontRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PropertyLabel("font")
            VStack(alignment: .leading, spacing: 1) {
                Text(typography.fontName)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy Font Name") {
                            copyToPasteboard(typography.fontName)
                        }
                        if let family = typography.familyName {
                            Button("Copy Family Name") {
                                copyToPasteboard(family)
                            }
                        }
                    }
                if let family = typography.familyName, family != typography.fontName {
                    Text(family)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var metricsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                PropertyLabel("size")
                PropertyValue("\(formatPt(typography.pointSize))")
                if let name = typography.weightName {
                    PropertyLabel("weight")
                    PropertyValue(name)
                } else if let weight = typography.weight {
                    PropertyLabel("weight")
                    PropertyValue(String(format: "%.2f", weight))
                }
            }
            if let lineHeight = typography.lineHeight, lineHeight > 0 {
                GridRow {
                    PropertyLabel("lineHeight")
                    PropertyValue(formatPt(lineHeight))
                }
            }
        }
    }

    private func traitBadge(_ label: String, italic: Bool) -> some View {
        Text(label)
            .font(italic ? .caption2.italic() : .caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
            )
    }

    private func formatPt(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%g pt", value)
        }
        return String(format: "%.2f pt", value)
    }
}

// MARK: - Color Swatch

/// Displays a color as a filled square + a HEX label, with a context menu for
/// copying the color in several formats. Designers primarily want HEX, so that
/// is the default displayed form; engineer-focused formats (UIColor / SwiftUI
/// literals, rgba) are available via right-click.
private struct ColorSwatch: View {
    let color: RGBAColor

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.swiftUIColor)
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.quaternary, lineWidth: 0.5)
                )
            Text(labelText)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .help(rgbaString)
        }
        .contextMenu {
            Button("Copy HEX  \(color.hexRGB)") {
                copyToPasteboard(color.hexRGB)
            }
            if color.alpha < 0.999 {
                Button("Copy HEX + Alpha  \(color.hexRGBA)") {
                    copyToPasteboard(color.hexRGBA)
                }
            }
            Divider()
            Button("Copy rgba(…)") { copyToPasteboard(rgbaString) }
            Button("Copy UIColor(…)") { copyToPasteboard(color.uiColorLiteral) }
            Button("Copy SwiftUI Color") { copyToPasteboard(color.swiftUIColorLiteral) }
        }
    }

    private var labelText: String {
        if color.alpha < 0.999 {
            let percent = Int((color.alpha * 100).rounded())
            return "\(color.hexRGB) · \(percent)%"
        }
        return color.hexRGB
    }

    private var rgbaString: String {
        String(
            format: "rgba(%.2f, %.2f, %.2f, %.2f)",
            color.red, color.green, color.blue, color.alpha
        )
    }
}

// MARK: - Helpers

/// Collapsible inspector section. Replaces the bare `GroupBox` + label
/// pattern used to live here with a tappable header that toggles the
/// content visibility, persisting expanded state per section so the
/// designer / engineer that prefers a different layout doesn't have to
/// re-curate the inspector on every relaunch.
///
/// `id` is the storage key suffix — passed verbatim into UserDefaults via
/// `@AppStorage("inspector.section.<id>.expanded")`. Pick a stable, short
/// snake_case identifier; renaming it later resets every existing user's
/// preference for that section, so don't churn it.
private struct CollapsibleSection<Content: View>: View {
    @AppStorage private var isExpanded: Bool
    private let title: LocalizedStringKey
    private let icon: String
    private let content: () -> Content

    init(
        id: String,
        title: LocalizedStringKey,
        icon: String,
        defaultExpanded: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.content = content
        self._isExpanded = AppStorage(
            wrappedValue: defaultExpanded,
            "inspector.section.\(id).expanded"
        )
    }

    var body: some View {
        GroupBox {
            // GroupBox always reserves room for content; emitting an
            // EmptyView when collapsed lets the box shrink to just its
            // label height instead of leaving a hollow padding band.
            if isExpanded {
                content()
            }
        } label: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Label(title, systemImage: icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PropertyLabel: View {
    private enum Source {
        case localized(LocalizedStringKey)
        case verbatim(String)
    }
    private let source: Source

    init(_ text: LocalizedStringKey) { self.source = .localized(text) }
    /// Use for math symbols (Δx, Δy) and for runtime-derived labels that
    /// are not user-facing copy — bypasses the localization table.
    init(verbatim text: String) { self.source = .verbatim(text) }

    var body: some View {
        Group {
            switch source {
            case .localized(let key): Text(key)
            case .verbatim(let s): Text(verbatim: s)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minWidth: 100, alignment: .leading)
    }
}

/// Property *values* are user data (text contents, frame numbers, identifiers,
/// runtime API names like "isHidden") — they must NOT pass through the
/// localization table. `Text(verbatim:)` keeps the string as-is.
private struct PropertyValue: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
    }
}
