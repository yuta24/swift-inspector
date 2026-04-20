import SwiftUI
import InspectCore

struct HierarchyNodeRow: View {
    let node: ViewNode
    var highlight: String = ""

    var body: some View {
        HStack(spacing: 6) {
            swatch
            classNameView
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
            Spacer(minLength: 4)
            Text(frameDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .opacity(node.isHidden ? 0.5 : 1.0)
    }

    @ViewBuilder
    private var classNameView: some View {
        if !highlight.isEmpty,
           node.className.localizedCaseInsensitiveContains(highlight) {
            Text(node.className)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.yellow)
        } else {
            Text(node.className)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(node.isHidden ? .secondary : .primary)
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

    private var frameDescription: String {
        let f = node.frame
        return String(
            format: "(%g, %g, %g, %g)",
            f.origin.x, f.origin.y, f.size.width, f.size.height
        )
    }
}
