import SwiftUI
import AppKit
import InspectCore

/// Floating control strip that lives at the top of the 2D canvas. Owns the
/// Figma frame URL input, the comparison-mode picker, the overlay opacity
/// slider, the status-bar mask toggle, the size-mismatch banner, and the
/// structured error banner.
///
/// Pulled out of the inspector (where it used to be `FigmaCompareSection`)
/// because Figma comparison is fundamentally a screen-wide concern — the
/// 320pt inspector column can't show the rendered overlay at a useful
/// resolution. The per-node attribute diff (`FigmaDiffSection`) still lives
/// in the inspector since it is selection-bound.
struct Figma2DToolbar: View {
    @EnvironmentObject var figmaModel: FigmaComparisonModel
    @EnvironmentObject var model: AppInspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            urlRow
            statusRow
            controlRow
            diffSummaryRow
            if let warning = figmaModel.sizeWarning, figmaModel.image != nil {
                sizeMismatchBanner(warning)
            }
            if case .error(let serviceError) = figmaModel.status {
                Figma2DErrorBanner(
                    error: serviceError,
                    onRetry: { figmaModel.fetch() },
                    onOpenPreferences: Self.openPreferences
                )
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 720, alignment: .leading)
        .onAppear {
            recomputeWarning()
        }
        // Width-mismatch warning re-evaluates only when an input to the
        // comparison changes — a fresh image, or the user picking a node on
        // a different-width root window. Hierarchy churn that keeps the
        // root width identical is not interesting here. The match table
        // is refreshed by `ContentView` so it stays current even in 3D
        // mode where this toolbar is not rendered.
        .onChange(of: figmaModel.image) { _, _ in recomputeWarning() }
        .onChange(of: model.selectedNodeID) { _, _ in recomputeWarning() }
    }

    // MARK: - URL row

    private var urlRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Paste Figma frame URL to compare…", text: $figmaModel.frameURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { figmaModel.fetch() }
            urlActions
        }
    }

    @ViewBuilder
    private var urlActions: some View {
        if case .fetching = figmaModel.status {
            ProgressView().controlSize(.small)
            Button {
                figmaModel.cancel()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Cancel fetch")
        } else {
            Button {
                figmaModel.fetch()
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(figmaModel.frameURL.isEmpty)
            .help("Fetch the frame from Figma")
            if figmaModel.image != nil {
                Button {
                    figmaModel.clear()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Clear the loaded Figma frame")
            }
        }
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        switch figmaModel.status {
        case .fetching:
            HStack(spacing: 6) {
                Text("Fetching from Figma…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        case .loaded(cached: true):
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("Loaded from cache")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption)
        default:
            EmptyView()
        }
    }

    // MARK: - Mode + opacity controls

    @ViewBuilder
    private var controlRow: some View {
        if figmaModel.image != nil {
            HStack(spacing: 12) {
                modePicker
                if figmaModel.displayMode == .overlay {
                    opacitySlider
                        .frame(maxWidth: 200)
                }
                Toggle("Mask status bar", isOn: $figmaModel.maskStatusBar)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 0)
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $figmaModel.displayMode) {
            ForEach(FigmaComparisonModel.DisplayMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var opacitySlider: some View {
        HStack(spacing: 6) {
            Text("Opacity")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $figmaModel.overlayOpacity, in: 0...1)
            Text(verbatim: String(format: "%.0f%%", figmaModel.overlayOpacity * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Diff summary + walkthrough

    /// Headline of the comparison: "Diff M of N" with chevron buttons that
    /// step through differing nodes (⌘[ / ⌘]). Hidden until the matcher has
    /// found at least one ViewNode → Figma layer pairing — that's the
    /// earliest moment the verdict (match / differ) can be trusted. The
    /// list of differences is taken from `model.displayRoots` so a focused
    /// subtree narrows both the count and the navigation; clearing focus
    /// re-exposes the full hierarchy.
    @ViewBuilder
    private var diffSummaryRow: some View {
        if figmaModel.image != nil, !figmaModel.matches.isEmpty {
            let ordered = orderedDifferingIDs()
            if ordered.isEmpty {
                allMatchRow
            } else {
                differencesRow(ordered: ordered)
            }
        }
    }

    private var allMatchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
            Text(focusActiveSuffix("Matches Figma"))
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
    }

    private func differencesRow(ordered: [UUID]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.orange)
            Text(verbatim: differenceCountLabel(ordered: ordered))
                .font(.caption.weight(.semibold))
                .help(walkthroughHelp(ordered: ordered))
            Spacer(minLength: 0)
            Button {
                jumpToDiff(direction: .previous, ordered: ordered)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: .command)
            .help("Previous difference (⌘[)")
            Button {
                jumpToDiff(direction: .next, ordered: ordered)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("]", modifiers: .command)
            .help("Next difference (⌘])")
        }
    }

    /// "Diff M of N" when the selected node is one of the diffs;
    /// otherwise "N differences" (or the singular form). The "M of N"
    /// form anchors the user to the walkthrough position so the chevrons
    /// don't feel like they're pointing into nothing.
    private func differenceCountLabel(ordered: [UUID]) -> String {
        let total = ordered.count
        if let selectedID = model.selectedNodeID,
           let idx = ordered.firstIndex(of: selectedID) {
            return focusActiveSuffix(
                String(format: String(localized: "Diff %d of %d"), idx + 1, total)
            )
        }
        if total == 1 {
            return focusActiveSuffix(String(localized: "1 difference"))
        }
        return focusActiveSuffix(
            String(format: String(localized: "%d differences"), total)
        )
    }

    /// Adds " (in focus)" when the diff scope is constrained to a focused
    /// subtree. Designers asked us to make scope visible in the headline
    /// because "12 differences" looks like a global statement.
    private func focusActiveSuffix(_ base: String) -> String {
        guard model.focusedNodeID != nil else { return base }
        return base + " " + String(localized: "(in focus)")
    }

    private func walkthroughHelp(ordered: [UUID]) -> String {
        if model.focusedNodeID != nil {
            return String(localized: "Walk through the differences within the focused subtree")
        }
        return String(localized: "Walk through every node whose attributes differ from Figma")
    }

    private enum DiffNavDirection { case next, previous }

    /// Steps the selection through `ordered`. Wraps at both ends so the
    /// walkthrough has no dead-end. The first invocation when nothing is
    /// selected jumps to either the first (next) or the last (previous)
    /// entry, so a fresh user can press ⌘] without thinking.
    private func jumpToDiff(direction: DiffNavDirection, ordered: [UUID]) {
        guard !ordered.isEmpty else { return }
        let currentIndex = model.selectedNodeID.flatMap { ordered.firstIndex(of: $0) }
        let nextIndex: Int = {
            switch direction {
            case .next:
                if let i = currentIndex { return (i + 1) % ordered.count }
                return 0
            case .previous:
                if let i = currentIndex { return (i - 1 + ordered.count) % ordered.count }
                return ordered.count - 1
            }
        }()
        model.selectedNodeID = ordered[nextIndex]
    }

    /// Pre-order walk over `displayRoots` that returns every differing
    /// node id in tree order. Visible-scope only: when focus is active
    /// `displayRoots` is just the focused subtree, so the walkthrough
    /// stays inside what the user can actually see.
    private func orderedDifferingIDs() -> [UUID] {
        let differing = figmaModel.differingNodeIDs
        guard !differing.isEmpty else { return [] }
        var output: [UUID] = []
        var stack: [ViewNode] = Array(model.displayRoots.reversed())
        while let node = stack.popLast() {
            if differing.contains(node.ident) {
                output.append(node.ident)
            }
            for child in node.children.reversed() {
                stack.append(child)
            }
        }
        return output
    }

    // MARK: - Size mismatch banner

    private func sizeMismatchBanner(_ warning: FigmaComparisonModel.SizeWarning) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Width doesn't match")
                    .font(.caption.weight(.semibold))
                Text(verbatim: String(
                    format: String(localized: "Figma %.0fpt / device %.0fpt — fitted to short edge"),
                    warning.figmaPoints,
                    warning.devicePoints
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func recomputeWarning() {
        // Use the window root's frame so the warning is anchored to the
        // device's actual screen width regardless of which sub-node the
        // user has selected. Falls back to the selection only when there
        // is no captured root yet.
        let width: CGFloat = {
            if let root = model.roots.first { return root.windowFrame.width }
            return model.selectedNode?.windowFrame.width ?? 0
        }()
        figmaModel.updateSizeWarning(deviceWindowWidth: Double(width))
    }

    /// Opens the app's Settings window. The selector renamed in macOS 14
    /// (`showSettingsWindow:`) from the macOS 13 spelling
    /// (`showPreferencesWindow:`); both are stringified to avoid the
    /// "unknown selector" compile-time check on the unavailable side.
    private static func openPreferences() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

// MARK: - Error banner

/// Structured presentation of a `FigmaImageService.ServiceError`. Pulled
/// out so both the toolbar (live errors) and any future surfaces can drop
/// it in without redefining the icon / severity / remediation mapping.
struct Figma2DErrorBanner: View {
    let error: FigmaImageService.ServiceError
    let onRetry: () -> Void
    let onOpenPreferences: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: spec.icon)
                .foregroundStyle(spec.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.title)
                    .font(.caption.weight(.semibold))
                Text(spec.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = spec.action {
                    Button(action.label) {
                        switch action.kind {
                        case .openPreferences: onOpenPreferences()
                        case .retry: onRetry()
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(spec.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(spec.color.opacity(0.3), lineWidth: 1)
        )
    }

    private struct Spec {
        let icon: String
        let color: Color
        let title: LocalizedStringKey
        let description: String
        let action: Action?
    }

    private struct Action {
        enum Kind { case openPreferences, retry }
        let label: LocalizedStringKey
        let kind: Kind
    }

    private var spec: Spec {
        switch error {
        case .invalidURL:
            return Spec(
                icon: "link",
                color: .orange,
                title: "Invalid frame URL",
                description: String(localized: "Paste a Figma frame share link that includes a node-id, e.g. figma.com/file/.../...?node-id=12-34"),
                action: nil
            )
        case .missingToken:
            return Spec(
                icon: "key",
                color: .orange,
                title: "Personal Access Token required",
                description: String(localized: "Figma needs a token to fetch frames. Save one in Preferences."),
                action: Action(label: "Open Preferences", kind: .openPreferences)
            )
        case .unauthorized:
            return Spec(
                icon: "lock.slash",
                color: .red,
                title: "Figma rejected the token",
                description: String(localized: "The saved token is no longer valid. Update it in Preferences."),
                action: Action(label: "Open Preferences", kind: .openPreferences)
            )
        case .rateLimited(let retryAfter):
            let description: String = {
                if let retryAfter, retryAfter > 0 {
                    return String(
                        format: String(localized: "Hit the Figma rate limit. Try again in %.0f seconds."),
                        retryAfter
                    )
                }
                return String(localized: "Hit the Figma rate limit. Wait a moment and try again.")
            }()
            return Spec(
                icon: "clock",
                color: .orange,
                title: "Rate limited",
                description: description,
                action: Action(label: "Retry", kind: .retry)
            )
        case .nodeNotFound:
            return Spec(
                icon: "questionmark.circle",
                color: .red,
                title: "Frame not found",
                description: String(localized: "Couldn't find that frame. Make sure the URL points to a frame, not just the file root."),
                action: Action(label: "Retry", kind: .retry)
            )
        case .network(let underlying):
            return Spec(
                icon: "wifi.slash",
                color: .red,
                title: "Network error",
                description: underlying.localizedDescription,
                action: Action(label: "Retry", kind: .retry)
            )
        case .unexpectedStatus(let code):
            return Spec(
                icon: "exclamationmark.triangle",
                color: .red,
                title: "Figma returned an error",
                description: String(format: String(localized: "Figma responded with HTTP %d."), code),
                action: Action(label: "Retry", kind: .retry)
            )
        case .decoding:
            return Spec(
                icon: "exclamationmark.bubble",
                color: .red,
                title: "Couldn't read response",
                description: String(localized: "Figma returned data we couldn't decode."),
                action: Action(label: "Retry", kind: .retry)
            )
        }
    }
}
