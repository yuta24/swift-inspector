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
            NodeCopyMenu(node: node, stablePath: stablePath)
        }
    }

    @ViewBuilder
    private var classNameView: some View {
        let textHighlight = !isDimmed && !filter.text.isEmpty
            && node.className.localizedCaseInsensitiveContains(filter.text)
        Text(node.className)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(textHighlight ? .yellow : (node.isHidden ? .secondary : .primary))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(node.className)
    }

    @ViewBuilder
    private var accessibilityBadge: some View {
        if let accID = node.accessibilityIdentifier {
            let textHighlight = !isDimmed && !filter.text.isEmpty
                && accID.localizedCaseInsensitiveContains(filter.text)
            Text(accID)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(textHighlight ? Color.yellow.opacity(0.3) : Color.blue.opacity(0.15))
                .cornerRadius(3)
                .foregroundStyle(textHighlight ? .primary : .secondary)
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

private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
