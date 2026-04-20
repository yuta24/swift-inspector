import SwiftUI
import InspectCore

struct HierarchyNodeRow: View {
    let node: ViewNode
    var filter = HierarchyFilter()
    var isDimmed: Bool = false

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
