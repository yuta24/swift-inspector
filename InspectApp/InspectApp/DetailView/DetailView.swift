import SwiftUI
import InspectCore

struct DetailView: View {
    let node: ViewNode?

    var body: some View {
        if let node {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(node.className)
                        .font(.title2.monospaced())

                    ScreenshotPanel(screenshot: node.screenshot)

                    attributesSection(for: node)
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

    @ViewBuilder
    private func attributesSection(for node: ViewNode) -> some View {
        GroupBox("Attributes") {
            VStack(alignment: .leading, spacing: 6) {
                attributeRow("ident", node.ident.uuidString)
                attributeRow("frame", frameString(node.frame))
                attributeRow("isHidden", node.isHidden ? "true" : "false")
                attributeRow("alpha", String(format: "%.2f", node.alpha))
                attributeRow(
                    "backgroundColor",
                    node.backgroundColor.map(colorString) ?? "nil"
                )
                attributeRow("children", "\(node.children.count)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func attributeRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func frameString(_ rect: CGRect) -> String {
        String(
            format: "x: %g, y: %g, w: %g, h: %g",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
        )
    }

    private func colorString(_ color: RGBAColor) -> String {
        String(
            format: "r:%.2f g:%.2f b:%.2f a:%.2f",
            color.red, color.green, color.blue, color.alpha
        )
    }
}

private struct ScreenshotPanel: View {
    let screenshot: Data?

    var body: some View {
        GroupBox("Screenshot") {
            if let screenshot, let image = NSImage(data: screenshot) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Text("No screenshot captured for this node.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
    }
}
