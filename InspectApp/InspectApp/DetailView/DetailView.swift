import SwiftUI
import InspectCore

struct DetailView: View {
    let node: ViewNode?
    let roots: [ViewNode]

    @State private var selectedTab: DetailTab = .attributes

    var body: some View {
        if let node {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.className)
                            .font(.title3.monospaced().weight(.medium))
                        Text(node.ident.uuidString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(DetailTab.allCases) { tab in
                            Button {
                                selectedTab = tab
                            } label: {
                                Label(tab.title, systemImage: tab.icon)
                                    .labelStyle(.iconOnly)
                                    .font(.callout)
                                    .frame(width: 28, height: 24)
                                    .background(
                                        selectedTab == tab
                                            ? AnyShapeStyle(.tint.opacity(0.15))
                                            : AnyShapeStyle(.clear)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                // Content
                switch selectedTab {
                case .attributes:
                    AttributesTabView(node: node)
                case .threeD:
                    SceneViewContainer(roots: roots)
                }
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

// MARK: - Tab

private enum DetailTab: String, CaseIterable, Identifiable {
    case attributes
    case threeD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attributes: return "Attributes"
        case .threeD: return "3D View"
        }
    }

    var icon: String {
        switch self {
        case .attributes: return "list.bullet.rectangle"
        case .threeD: return "cube"
        }
    }
}

// MARK: - Attributes Tab

private struct AttributesTabView: View {
    let node: ViewNode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenshotPanel(screenshot: node.screenshot)
                FrameSection(frame: node.frame)
                AppearanceSection(node: node)
                ChildrenSection(count: node.children.count)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Screenshot Panel

private struct ScreenshotPanel: View {
    let screenshot: Data?

    var body: some View {
        if let screenshot, let image = NSImage(data: screenshot) {
            GroupBox {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } label: {
                SectionHeader("Screenshot", icon: "camera.viewfinder")
            }
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
