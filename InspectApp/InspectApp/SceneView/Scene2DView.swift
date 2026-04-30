import SwiftUI
import AppKit
import InspectCore

/// Flat, screen-faithful canvas for the captured hierarchy. Pairs with
/// ``SceneKitView`` (3D mode) under the same `SceneViewContainer`. Renders
/// the device screenshot, optionally combined with a Figma frame in any of
/// the comparison modes, and converts clicks into a depth-first ViewNode
/// selection so the inspector follows the user's pointer.
///
/// Designer-first: this is the default canvas mode. The Figma URL input
/// and mode controls float on top of this view (see `Figma2DToolbar`),
/// while the per-node attribute diff stays on the right inspector.
struct Scene2DView: View {
    let roots: [ViewNode]
    @Binding var selectedNodeID: UUID?
    @Binding var measurementReferenceID: UUID?
    @Binding var measurementHoverID: UUID?
    @EnvironmentObject var figmaModel: FigmaComparisonModel

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, Self.topInset)
                .padding(.bottom, Self.bottomInset)
            Figma2DToolbar()
                .padding(.horizontal, 16)
                .padding(.top, 12)
        }
    }

    /// Reserved space at the top of the canvas for the floating Figma
    /// toolbar. Approximated rather than measured so the device image can
    /// commit to a static aspect-fit area instead of reshaping every time
    /// the toolbar changes height (e.g. an error banner appears).
    private static let topInset: CGFloat = 96
    /// Mirrors the bottom-toolbar height inside `SceneViewContainer` so the
    /// 2D image isn't clipped by the segmented control + mode controls.
    private static let bottomInset: CGFloat = 64

    @ViewBuilder
    private var canvas: some View {
        if roots.isEmpty {
            placeholder
        } else {
            comparisonCanvas
        }
    }

    private var placeholder: some View {
        PlaceholderView(
            title: "No Hierarchy",
            systemImage: "cube.transparent",
            message: "Connect to a device and capture a snapshot."
        )
    }

    /// Window-rooted device image. Always uses the topmost root's
    /// screenshot — the 2D canvas is "what the device is showing", not
    /// "what the selected node is showing".
    private var deviceImage: NSImage? {
        guard let root = roots.first, let data = root.screenshot else { return nil }
        return NSImage(data: data)
    }

    private var windowRoot: ViewNode? { roots.first }

    private var statusBarHeight: CGFloat {
        CGFloat(windowRoot?.safeAreaInsets?.top ?? 0)
    }

    @ViewBuilder
    private var comparisonCanvas: some View {
        let mode = figmaModel.image == nil ? FigmaComparisonModel.DisplayMode.deviceOnly : figmaModel.displayMode
        switch mode {
        case .deviceOnly:
            deviceCanvas(showDiffOutlines: false)
        case .figmaOnly:
            figmaOnlyCanvas
        case .sideBySide:
            HStack(spacing: 8) {
                deviceCanvas(showDiffOutlines: false)
                figmaOnlyCanvas
            }
        case .overlay, .difference:
            overlayCanvas(mode: mode)
        case .heatmap:
            deviceCanvas(showDiffOutlines: true)
        }
    }

    @ViewBuilder
    private func deviceCanvas(showDiffOutlines: Bool) -> some View {
        if let image = deviceImage {
            interactiveDevice(
                image: image,
                figmaImage: nil,
                opacity: 1,
                blendMode: .normal,
                showDiffOutlines: showDiffOutlines
            )
        } else {
            noImagePlaceholder
        }
    }

    @ViewBuilder
    private func overlayCanvas(mode: FigmaComparisonModel.DisplayMode) -> some View {
        if let image = deviceImage, let figma = figmaModel.image {
            interactiveDevice(
                image: image,
                figmaImage: figma,
                opacity: mode == .overlay ? figmaModel.overlayOpacity : 1,
                blendMode: mode == .difference ? .difference : .normal,
                showDiffOutlines: false
            )
        } else if let image = deviceImage {
            interactiveDevice(
                image: image,
                figmaImage: nil,
                opacity: 1,
                blendMode: .normal,
                showDiffOutlines: false
            )
        } else if let figma = figmaModel.image {
            // Device hasn't captured yet but Figma is loaded — show the
            // Figma frame at full opacity so the canvas doesn't feel empty.
            staticImage(figma)
        } else {
            noImagePlaceholder
        }
    }

    @ViewBuilder
    private var figmaOnlyCanvas: some View {
        if let figma = figmaModel.image {
            staticImage(figma)
        } else {
            noImagePlaceholder
        }
    }

    @ViewBuilder
    private func staticImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var noImagePlaceholder: some View {
        Text("No image")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Renders the device image with all overlays — Figma overlay, status
    /// bar mask, diff outlines, selection highlight — and translates clicks
    /// into ViewNode selections.
    @ViewBuilder
    private func interactiveDevice(
        image: NSImage,
        figmaImage: NSImage?,
        opacity: Double,
        blendMode: BlendMode,
        showDiffOutlines: Bool
    ) -> some View {
        GeometryReader { proxy in
            let layout = ImageLayout(image: image, container: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                if let figmaImage {
                    Image(nsImage: figmaImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(opacity)
                        .blendMode(blendMode)
                        .allowsHitTesting(false)
                }

                if showDiffOutlines {
                    diffOutlines(layout: layout)
                }

                if let id = selectedNodeID,
                   let node = HierarchyRemapping.findNode(id: id, in: roots) {
                    selectionOutline(node: node, layout: layout)
                }

                if figmaModel.maskStatusBar, statusBarHeight > 0 {
                    Rectangle()
                        .fill(.black)
                        .frame(width: layout.imageSize.width,
                               height: statusBarHeight * layout.scale)
                        .offset(x: layout.origin.x, y: layout.origin.y)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(clickGesture(layout: layout))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func diffOutlines(layout: ImageLayout) -> some View {
        let pointToImage = layout.pointToImage(windowWidth: windowRoot?.windowFrame.width ?? 0)
        if pointToImage > 0 {
            ForEach(differingFrames(), id: \.0) { item in
                let rect = item.1
                Rectangle()
                    .strokeBorder(.red, lineWidth: 1.5)
                    .frame(
                        width: max(2, rect.width * pointToImage),
                        height: max(2, rect.height * pointToImage)
                    )
                    .offset(
                        x: layout.origin.x + rect.minX * pointToImage,
                        y: layout.origin.y + rect.minY * pointToImage
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func selectionOutline(node: ViewNode, layout: ImageLayout) -> some View {
        let pointToImage = layout.pointToImage(windowWidth: windowRoot?.windowFrame.width ?? 0)
        if pointToImage > 0 {
            let rect = node.windowFrame
            if rect.width > 0, rect.height > 0 {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(
                        width: max(2, rect.width * pointToImage),
                        height: max(2, rect.height * pointToImage)
                    )
                    .offset(
                        x: layout.origin.x + rect.minX * pointToImage,
                        y: layout.origin.y + rect.minY * pointToImage
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private func differingFrames() -> [(UUID, CGRect)] {
        var output: [(UUID, CGRect)] = []
        var stack = roots
        while let node = stack.popLast() {
            if figmaModel.differingNodeIDs.contains(node.ident),
               node.windowFrame.width > 0, node.windowFrame.height > 0 {
                output.append((node.ident, node.windowFrame))
            }
            stack.append(contentsOf: node.children)
        }
        return output
    }

    /// `SpatialTapGesture` reports the click location in the gesture's
    /// containing coordinate space. Preferred over `DragGesture(min:0)`
    /// because it doesn't fire on press-and-drag, so trackpad scroll or
    /// future drag-to-pan gestures stay separable.
    private func clickGesture(layout: ImageLayout) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                handleClick(at: value.location, layout: layout)
            }
    }

    private func handleClick(at point: CGPoint, layout: ImageLayout) {
        guard let windowRoot, windowRoot.windowFrame.width > 0 else { return }
        let pointToImage = layout.pointToImage(windowWidth: windowRoot.windowFrame.width)
        guard pointToImage > 0 else { return }

        let imageX = point.x - layout.origin.x
        let imageY = point.y - layout.origin.y
        guard imageX >= 0, imageY >= 0,
              imageX <= layout.imageSize.width,
              imageY <= layout.imageSize.height else {
            // Click landed outside the device image (e.g. side-by-side
            // empty area). Don't disturb the existing selection.
            return
        }
        let windowPoint = CGPoint(
            x: imageX / pointToImage,
            y: imageY / pointToImage
        )

        if let hit = deepestNode(containing: windowPoint, in: roots) {
            selectedNodeID = hit.id
        } else {
            selectedNodeID = nil
        }
    }

    /// Depth-first walk that returns the deepest visible node whose
    /// `windowFrame` contains the given point. `isHidden`, ~zero alpha,
    /// and zero-sized nodes are skipped so a transparent overlay doesn't
    /// steal the hit — mirrors UIKit's own hit-test exclusions
    /// (`alpha < 0.01` is the threshold UIKit uses internally).
    /// `isUserInteractionEnabled` is intentionally NOT consulted because
    /// inspection wants to surface UILabel and similar non-interactive
    /// views, not skip them.
    private func deepestNode(containing point: CGPoint, in nodes: [ViewNode]) -> ViewNode? {
        var match: ViewNode?
        for node in nodes {
            guard !node.isHidden,
                  node.alpha > 0.01,
                  node.windowFrame.contains(point) else { continue }
            match = node
            if let deeper = deepestNode(containing: point, in: node.children) {
                match = deeper
            }
        }
        return match
    }
}

// MARK: - Image Layout

/// Aspect-fit geometry for an image rendered inside an arbitrary container.
/// Centralises the math used by the click hit-test, the diff outlines, and
/// the selection highlight so they always agree.
struct ImageLayout {
    let imageSize: CGSize
    let origin: CGPoint
    let scale: CGFloat

    init(image: NSImage, container: CGSize) {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0,
              container.width > 0, container.height > 0 else {
            self.imageSize = .zero
            self.origin = .zero
            self.scale = 1
            return
        }
        let s = min(container.width / imgSize.width, container.height / imgSize.height)
        let w = imgSize.width * s
        let h = imgSize.height * s
        self.imageSize = CGSize(width: w, height: h)
        self.origin = CGPoint(
            x: max(0, (container.width - w) / 2),
            y: max(0, (container.height - h) / 2)
        )
        self.scale = s
    }

    /// Multiplier that converts a length in device window points to a
    /// length on the rendered image, accounting for both the capture's
    /// pixels-per-point ratio and the aspect-fit scale.
    func pointToImage(windowWidth: CGFloat) -> CGFloat {
        guard windowWidth > 0, imageSize.width > 0 else { return 0 }
        // pixels-per-point inferred from "rendered image points width / window points width".
        let pixelsPerPoint = imageSize.width / windowWidth
        return pixelsPerPoint
    }
}
