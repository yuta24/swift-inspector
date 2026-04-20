import SwiftUI
import InspectCore

struct HierarchyNodeRow: View {
    let node: ViewNode

    var body: some View {
        HStack(spacing: 6) {
            swatch
            Text(node.className)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(node.isHidden ? .secondary : .primary)
            Spacer(minLength: 4)
            Text(frameDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var swatch: some View {
        Group {
            if let color = node.backgroundColor {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.swiftUIColor)
                    .frame(width: 10, height: 10)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.quaternary, lineWidth: 0.5))
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(.quaternary, lineWidth: 0.5)
                    .frame(width: 10, height: 10)
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
