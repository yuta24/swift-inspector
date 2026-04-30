import SwiftUI
import AppKit
import InspectCore

struct HierarchyNodeRow: View {
    let node: ViewNode
    var filter = HierarchyFilter()
    var isDimmed: Bool = false
    /// Joined stable-path fingerprint for this row's position in the tree.
    /// Nil when the caller can't cheaply compute it (e.g. legacy callers);
    /// the "Copy Stable Path" menu item is suppressed in that case.
    var stablePath: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            swatch
            classNameView
            accessibilityBadge
            if node.isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if node.alpha < 1.0 {
                Text(String(format: "%.0f%%", node.alpha * 100))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .opacity(isDimmed ? 0.4 : (node.isHidden ? 0.5 : 1.0))
        .contextMenu {
            NodeFocusMenu(nodeID: node.id)
            Divider()
            NodeCopyMenu(node: node, stablePath: stablePath)
        }
    }

    @ViewBuilder
    private var classNameView: some View {
        if let display = node.displayName {
            HStack(spacing: 4) {
                Text(display)
                    .font(.callout)
                    .foregroundStyle(primaryHighlight ? .yellow : (node.isHidden ? .secondary : .primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(node.shortClassName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .help(node.className)
        } else {
            Text(node.shortClassName)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(classNameHighlight ? .yellow : (node.isHidden ? .secondary : .primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(node.className)
        }
    }

    /// True when filter matches the primary string we're rendering: the
    /// `displayName` (when present) plus className/accessibilityLabel that
    /// would have produced it.
    private var primaryHighlight: Bool {
        guard !isDimmed, !filter.text.isEmpty else { return false }
        if let display = node.displayName,
           display.localizedCaseInsensitiveContains(filter.text) {
            return true
        }
        return node.className.localizedCaseInsensitiveContains(filter.text)
    }

    private var classNameHighlight: Bool {
        guard !isDimmed, !filter.text.isEmpty else { return false }
        return node.className.localizedCaseInsensitiveContains(filter.text)
    }

    @ViewBuilder
    private var accessibilityBadge: some View {
        if let accID = node.accessibilityIdentifier {
            let textHighlight = !isDimmed && !filter.text.isEmpty
                && accID.localizedCaseInsensitiveContains(filter.text)
            Text(accID)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(textHighlight ? Color.yellow.opacity(0.35) : Color.accentColor.opacity(0.14))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            textHighlight ? Color.yellow.opacity(0.45) : Color.accentColor.opacity(0.22),
                            lineWidth: 0.5
                        )
                )
                .foregroundStyle(textHighlight ? .primary : Color.accentColor)
                .lineLimit(1)
                .help("accessibilityIdentifier: \(accID)")
        }
    }

    private var swatch: some View {
        Group {
            if let color = node.backgroundColor {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.swiftUIColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(.quaternary, lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.quaternary, lineWidth: 0.5)
                    .frame(width: 12, height: 12)
            }
        }
    }
}

// MARK: - Focus Menu

/// Context menu fragment for toggling subtree focus. Placed in a separate
/// view so both the sidebar row and the inspector header can drop it in
/// without each duplicating the model lookup.
struct NodeFocusMenu: View {
    @EnvironmentObject var model: AppInspectorModel
    let nodeID: UUID

    var body: some View {
        if model.focusedNodeID == nodeID {
            Button("Exit Focus") {
                model.clearFocus()
            }
        } else {
            Button("Focus on This View") {
                model.focus(on: nodeID)
            }
        }
    }
}

// MARK: - Copy Menu

/// Context menu fragment for copying node identity bits to the pasteboard.
/// Shared between the sidebar tree row and the inspector header so both
/// surfaces offer the same vocabulary.
struct NodeCopyMenu: View {
    let node: ViewNode
    var stablePath: String? = nil

    var body: some View {
        Button("Copy Class Name") {
            copyToPasteboard(node.className)
        }
        if let id = node.accessibilityIdentifier, !id.isEmpty {
            Button("Copy Accessibility Identifier") {
                copyToPasteboard(id)
            }
        }
        if let label = node.accessibilityLabel, !label.isEmpty {
            Button("Copy Accessibility Label") {
                copyToPasteboard(label)
            }
        }
        if let stablePath {
            Divider()
            Button("Copy Stable Path") {
                copyToPasteboard(stablePath)
            }
        }
        Button("Copy UUID") {
            copyToPasteboard(node.ident.uuidString)
        }
    }
}

/// Writes a plain-text string to the general pasteboard. Shared across the
/// Inspector sections and the sidebar's context menus.
func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
