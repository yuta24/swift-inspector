import SwiftUI
import SceneKit
import AppKit
import InspectCore

// MARK: - SwiftUI Container

struct SceneViewContainer: View {
    let roots: [ViewNode]
    @Binding var selectedNodeID: UUID?
    @Binding var measurementReferenceID: UUID?
    @Binding var measurementHoverID: UUID?
    @State private var layerSpacing: Float = 30
    @State private var showLabels: Bool = true

    var body: some View {
        ZStack(alignment: .bottom) {
            SceneKitView(
                roots: roots,
                selectedNodeID: $selectedNodeID,
                measurementReferenceID: $measurementReferenceID,
                measurementHoverID: $measurementHoverID,
                layerSpacing: layerSpacing,
                showLabels: showLabels
            )

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $layerSpacing, in: 0...80, step: 1)
                        .frame(width: 120)
                    Text("\(Int(layerSpacing))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
                Toggle(isOn: $showLabels) {
                    Image(systemName: "tag")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
    }
}

// MARK: - Node entry stored per view node

private struct NodeEntry {
    let snapshotNode: SCNNode
    let depth: Int
    let traversalIndex: Int
    /// Plane width in SceneKit space, matches `view.bounds.size.width`.
    let width: CGFloat
    /// Plane height in SceneKit space, matches `view.bounds.size.height`.
    let height: CGFloat
    /// Absolute origin in the window (root) coordinate space. Kept so the
    /// Hyperion-style overlay can reason about edges without re-walking the
    /// hierarchy.
    let windowOrigin: CGPoint
}

// MARK: - NSViewRepresentable

private struct SceneKitView: NSViewRepresentable {
    let roots: [ViewNode]
    @Binding var selectedNodeID: UUID?
    @Binding var measurementReferenceID: UUID?
    @Binding var measurementHoverID: UUID?
    let layerSpacing: Float
    let showLabels: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedNodeID: $selectedNodeID,
            measurementHoverID: $measurementHoverID
        )
    }

    func makeNSView(context: Context) -> InspectSCNView {
        let scnView = InspectSCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = .windowBackgroundColor
        scnView.antialiasingMode = .multisampling4X
        scnView.scene = SCNScene()
        scnView.scene?.background.contents = NSColor.windowBackgroundColor

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        scnView.addGestureRecognizer(click)
        context.coordinator.scnView = scnView
        scnView.hoverHandler = { [weak coord = context.coordinator] uuid in
            coord?.measurementHoverID.wrappedValue = uuid
        }

        return scnView
    }

    func updateNSView(_ scnView: InspectSCNView, context: Context) {
        let coord = context.coordinator
        coord.selectedNodeID = $selectedNodeID
        coord.measurementHoverID = $measurementHoverID

        let rootsHash = roots.hashValue
        let compareID = measurementHoverID ?? measurementReferenceID

        // Full rebuild only when hierarchy data changes
        if coord.lastRootsHash != rootsHash {
            rebuildScene(scnView: scnView, coord: coord)
            coord.lastRootsHash = rootsHash
            coord.lastLayerSpacing = layerSpacing
            coord.lastShowLabels = showLabels
            coord.lastSelectedNodeID = selectedNodeID
            coord.lastCompareID = compareID
            refreshMeasurementOverlay(coord: coord, compareID: compareID)
            return
        }

        // Spacing change: only update z-positions
        if coord.lastLayerSpacing != layerSpacing {
            for (_, entry) in coord.nodeMap {
                var pos = entry.snapshotNode.position
                pos.z = CGFloat(layerSpacing * Float(entry.depth) + Float(entry.traversalIndex) * 0.01)
                entry.snapshotNode.position = pos
            }
            coord.lastLayerSpacing = layerSpacing
            refreshMeasurementOverlay(coord: coord, compareID: compareID)
        }

        // Label visibility change
        if coord.lastShowLabels != showLabels {
            for (_, entry) in coord.nodeMap {
                entry.snapshotNode.childNode(withName: "_label", recursively: false)?.isHidden = !showLabels
            }
            coord.lastShowLabels = showLabels
        }

        // Selection change: toggle highlights
        if coord.lastSelectedNodeID != selectedNodeID {
            if let oldID = coord.lastSelectedNodeID as? UUID,
               let oldEntry = coord.nodeMap[oldID] {
                oldEntry.snapshotNode.childNode(withName: "_highlight", recursively: false)?
                    .removeFromParentNode()
                updateBorderColor(oldEntry.snapshotNode, isSelected: false)
            }
            if let newID = selectedNodeID,
               let newEntry = coord.nodeMap[newID] {
                addHighlight(to: newEntry.snapshotNode, width: newEntry.width, height: newEntry.height)
                updateBorderColor(newEntry.snapshotNode, isSelected: true)
            }
            coord.lastSelectedNodeID = selectedNodeID
            refreshMeasurementOverlay(coord: coord, compareID: compareID)
        }

        // Compare (hover or pinned reference) change
        if coord.lastCompareID != compareID {
            coord.lastCompareID = compareID
            refreshMeasurementOverlay(coord: coord, compareID: compareID)
        }
    }

    // MARK: - Measurement overlay (Hyperion-style)

    private func refreshMeasurementOverlay(coord: Coordinator, compareID: UUID?) {
        coord.measurementNode?.removeFromParentNode()
        coord.measurementNode = nil

        guard
            let selID = selectedNodeID,
            let compareID,
            compareID != selID,
            let anchorEntry = coord.nodeMap[selID],
            let compareEntry = coord.nodeMap[compareID],
            let sceneRoot = coord.scnView?.scene?.rootNode
        else { return }

        let anchorRect = CGRect(origin: anchorEntry.windowOrigin,
                                size: CGSize(width: anchorEntry.width, height: anchorEntry.height))
        let compareRect = CGRect(origin: compareEntry.windowOrigin,
                                 size: CGSize(width: compareEntry.width, height: compareEntry.height))

        // Overlay sits slightly above both endpoints so it stays on top of
        // whichever plane is furthest forward in the stacked layout.
        let overlayZ = max(anchorEntry.snapshotNode.position.z,
                           compareEntry.snapshotNode.position.z) + 1.0

        let overlay = MeasurementOverlayBuilder.build(
            anchorRect: anchorRect,
            compareRect: compareRect,
            rootHeight: coord.rootHeight,
            screenArea: coord.screenArea,
            overlayZ: overlayZ
        )
        sceneRoot.addChildNode(overlay)
        coord.measurementNode = overlay
    }

    // MARK: - Full scene rebuild

    private func rebuildScene(scnView: SCNView, coord: Coordinator) {
        let scene = SCNScene()
        scene.background.contents = NSColor.windowBackgroundColor
        let rootNode = scene.rootNode

        coord.nodeMap.removeAll()

        guard !roots.isEmpty else {
            scnView.scene = scene
            coord.rootHeight = 0
            coord.screenArea = .zero
            return
        }

        // Y-flip reference and culling area both come from the union of all
        // root window frames. Using only the first root's height breaks when
        // multiple windows (keyboard, alert) have different heights.
        let screenArea = roots.map(\.windowFrame).reduce(CGRect.null) { $0.union($1) }
        let rootHeight = screenArea.height
        coord.rootHeight = rootHeight
        coord.screenArea = screenArea

        var traversalIndex = 0
        for root in roots {
            buildNodes(
                node: root,
                parentAbsoluteOrigin: nil,
                parentBoundsOrigin: .zero,
                rootHeight: rootHeight,
                screenArea: screenArea,
                depth: 0,
                traversalIndex: &traversalIndex,
                sceneRoot: rootNode,
                coord: coord
            )
        }

        scnView.scene = scene
        scnView.allowsCameraControl = true
    }

    /// Recursively build SCNNodes. Absolute origin in root (window) space is
    /// computed LookIn-style:
    ///   abs.x = frame.origin.x - parent.bounds.origin.x + parent.abs.x
    ///   abs.y = frame.origin.y - parent.bounds.origin.y + parent.abs.y
    ///
    /// This makes scroll offsets (= parent `bounds.origin`) explicit at every
    /// step and avoids relying on a server-side AABB that can drift when a
    /// view has a non-identity transform.
    ///
    /// Plane size uses `frame.size` — for a view with a non-identity
    /// transform UIKit returns the AABB here, which matches what the user
    /// sees on device. The solo screenshot (rendered at `bounds.size`) will
    /// be stretched to fill the AABB; we accept the texture distortion
    /// because matching the visible footprint is more important for a
    /// 3D inspector than pixel-accurate content. `boundsSize` is kept in
    /// the wire format for a future matrix-based renderer.
    private func buildNodes(
        node: ViewNode,
        parentAbsoluteOrigin: CGPoint?,
        parentBoundsOrigin: CGPoint,
        rootHeight: CGFloat,
        screenArea: CGRect,
        depth: Int,
        traversalIndex: inout Int,
        sceneRoot: SCNNode,
        coord: Coordinator
    ) {
        let w = node.frame.size.width
        let h = node.frame.size.height
        guard w >= 1, h >= 1 else { return }
        guard !node.isHidden else { return }
        if node.alpha <= 0.001, !node.children.isEmpty { return }

        let absoluteOrigin: CGPoint = {
            guard let parent = parentAbsoluteOrigin else {
                return node.frame.origin
            }
            return CGPoint(
                x: node.frame.origin.x - parentBoundsOrigin.x + parent.x,
                y: node.frame.origin.y - parentBoundsOrigin.y + parent.y
            )
        }()
        let absoluteFrame = CGRect(origin: absoluteOrigin, size: CGSize(width: w, height: h))

        let cullReference = node.windowFrame == .zero ? absoluteFrame : node.windowFrame
        let margin: CGFloat = 50
        let expanded = screenArea.insetBy(dx: -margin, dy: -margin)
        if !expanded.intersects(cullReference) { return }

        let myIndex = traversalIndex
        traversalIndex += 1

        let sceneX = Float(absoluteOrigin.x + w / 2)
        let sceneY = Float(rootHeight - (absoluteOrigin.y + h / 2))
        let sceneZ = layerSpacing * Float(depth) + Float(myIndex) * 0.01

        let isSelected = node.id == selectedNodeID

        let containerNode = SCNNode()
        containerNode.name = node.id.uuidString
        containerNode.position = SCNVector3(sceneX, sceneY, sceneZ)
        containerNode.renderingOrder = myIndex
        sceneRoot.addChildNode(containerNode)

        let plane = SCNPlane(width: w, height: h)
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant

        if let soloData = node.soloScreenshot, let image = NSImage(data: soloData) {
            material.diffuse.contents = image
            material.transparency = CGFloat(node.alpha)
            material.transparencyMode = .aOne
        } else if node.children.isEmpty, let groupData = node.screenshot,
                  let image = NSImage(data: groupData) {
            material.diffuse.contents = image
            material.transparency = CGFloat(node.alpha)
        } else if let color = node.backgroundColor {
            material.diffuse.contents = NSColor(
                srgbRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha * node.alpha
            )
        } else {
            material.diffuse.contents = NSColor(white: 1.0, alpha: 0.02)
        }

        plane.materials = [material]
        let planeNode = SCNNode(geometry: plane)
        planeNode.name = "_plane"
        containerNode.addChildNode(planeNode)

        addBorder(to: containerNode, width: w, height: h, isSelected: isSelected)

        if isSelected {
            addHighlight(to: containerNode, width: w, height: h)
        }

        if w >= 20 && h >= 10 {
            let labelNode = makeLabel(node.className, width: w, height: h, isSelected: isSelected)
            labelNode.isHidden = !showLabels
            containerNode.addChildNode(labelNode)
        }

        coord.nodeMap[node.id] = NodeEntry(
            snapshotNode: containerNode,
            depth: depth,
            traversalIndex: myIndex,
            width: w,
            height: h,
            windowOrigin: absoluteOrigin
        )

        let parentBounds = node.boundsOrigin
        for child in node.children {
            buildNodes(
                node: child,
                parentAbsoluteOrigin: absoluteOrigin,
                parentBoundsOrigin: parentBounds,
                rootHeight: rootHeight,
                screenArea: screenArea,
                depth: depth + 1,
                traversalIndex: &traversalIndex,
                sceneRoot: sceneRoot,
                coord: coord
            )
        }
    }

    // MARK: - Highlight

    private func addHighlight(to parent: SCNNode, width: CGFloat, height: CGFloat) {
        let highlightPlane = SCNPlane(width: width, height: height)
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor.controlAccentColor.withAlphaComponent(0.25)
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        highlightPlane.materials = [mat]
        let node = SCNNode(geometry: highlightPlane)
        node.name = "_highlight"
        node.position = SCNVector3(0, 0, 0.2)
        parent.addChildNode(node)
    }

    private func updateBorderColor(_ container: SCNNode, isSelected: Bool) {
        guard let borderGroup = container.childNode(withName: "_border", recursively: false) else { return }
        let color: NSColor = isSelected
            ? .controlAccentColor.withAlphaComponent(0.9)
            : NSColor(white: 0.5, alpha: 0.5)
        for edge in borderGroup.childNodes {
            edge.geometry?.firstMaterial?.diffuse.contents = color
        }
    }

    // MARK: - Border

    private func addBorder(to parent: SCNNode, width: CGFloat, height: CGFloat, isSelected: Bool) {
        let hw = Float(width) / 2
        let hh = Float(height) / 2
        let corners: [SCNVector3] = [
            SCNVector3(-hw, -hh, 0), SCNVector3(hw, -hh, 0),
            SCNVector3(hw, hh, 0), SCNVector3(-hw, hh, 0),
        ]
        let edges: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (3, 0)]
        let borderColor: NSColor = isSelected
            ? .controlAccentColor.withAlphaComponent(0.9)
            : NSColor(white: 0.5, alpha: 0.5)

        let borderGroup = SCNNode()
        borderGroup.name = "_border"
        for (a, b) in edges {
            let p0 = corners[a], p1 = corners[b]
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let length = sqrt(dx * dx + dy * dy)

            let edgePlane = SCNPlane(width: CGFloat(length), height: isSelected ? 1.0 : 0.5)
            let mat = SCNMaterial()
            mat.diffuse.contents = borderColor
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            edgePlane.materials = [mat]

            let edgeNode = SCNNode(geometry: edgePlane)
            edgeNode.position = SCNVector3((p0.x + p1.x) / 2, (p0.y + p1.y) / 2, 0.1)
            edgeNode.eulerAngles.z = atan2(dy, dx)
            borderGroup.addChildNode(edgeNode)
        }
        parent.addChildNode(borderGroup)
    }

    // MARK: - Label

    private func makeLabel(_ text: String, width: CGFloat, height: CGFloat, isSelected: Bool) -> SCNNode {
        let scnText = SCNText(string: text, extrusionDepth: 0)
        scnText.font = NSFont.monospacedSystemFont(ofSize: 3, weight: .medium)
        scnText.flatness = 0.2
        let mat = SCNMaterial()
        mat.diffuse.contents = isSelected ? NSColor.controlAccentColor : NSColor(white: 0.4, alpha: 0.8)
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        scnText.materials = [mat]

        let textNode = SCNNode(geometry: scnText)
        textNode.name = "_label"
        let (_, bbMax) = textNode.boundingBox
        let textWidth = Float(bbMax.x)
        let textHeight = Float(bbMax.y)

        textNode.position = SCNVector3(
            -Float(width) / 2,
            Float(height) / 2 + textHeight + 1,
            0.3
        )
        if textWidth > Float(width) {
            let s = Float(width) / textWidth
            textNode.scale = SCNVector3(s, s, 1)
        }
        return textNode
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var selectedNodeID: Binding<UUID?>
        var measurementHoverID: Binding<UUID?>
        weak var scnView: InspectSCNView?
        var nodeMap: [UUID: NodeEntry] = [:]
        var lastRootsHash: Int?
        var lastLayerSpacing: Float?
        var lastShowLabels: Bool?
        var lastSelectedNodeID: UUID??
        var lastCompareID: UUID?
        /// Root SCNNode for the Hyperion-style measurement overlay. Nil when
        /// the tool is idle (no compare node resolved).
        var measurementNode: SCNNode?
        /// Cached from the last rebuild — lets the overlay builder convert
        /// window-frame geometry to scene coordinates without re-walking the
        /// hierarchy.
        var rootHeight: CGFloat = 0
        var screenArea: CGRect = .zero

        init(
            selectedNodeID: Binding<UUID?>,
            measurementHoverID: Binding<UUID?>
        ) {
            self.selectedNodeID = selectedNodeID
            self.measurementHoverID = measurementHoverID
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scnView else { return }
            let location = gesture.location(in: scnView)
            let hits = scnView.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .sortResults: true,
            ])
            for hit in hits {
                if let uuid = findNodeUUID(in: hit.node) {
                    selectedNodeID.wrappedValue = uuid
                    return
                }
            }
            selectedNodeID.wrappedValue = nil
        }

        private func findNodeUUID(in node: SCNNode) -> UUID? {
            var current: SCNNode? = node
            while let n = current {
                if let name = n.name, let uuid = UUID(uuidString: name) {
                    return uuid
                }
                current = n.parent
            }
            return nil
        }
    }
}

// MARK: - SCNView subclass with Option-hover hit-testing

/// Extends `SCNView` with LookIn-style distance measurement input: while the
/// Option key is held, the view under the cursor streams out via
/// `hoverHandler`. Releasing Option clears the hover so any pinned compare
/// node returns to the foreground.
final class InspectSCNView: SCNView {
    var hoverHandler: ((UUID?) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var optionHeld: Bool = false
    private var lastHoverID: UUID?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Re-derive from the event so the hover state self-corrects when
        // Option was toggled while our window lacked focus (flagsChanged
        // only fires on the currently-focused responder chain).
        let hasOption = event.modifierFlags.contains(.option)
        optionHeld = hasOption
        if hasOption {
            let point = convert(event.locationInWindow, from: nil)
            updateHover(at: point)
        } else {
            publishHover(nil)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        let hasOption = event.modifierFlags.contains(.option)
        optionHeld = hasOption
        if hasOption {
            let point = convert(event.locationInWindow, from: nil)
            updateHover(at: point)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        publishHover(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let newOption = event.modifierFlags.contains(.option)
        guard newOption != optionHeld else { return }
        optionHeld = newOption
        if newOption {
            // Snap to whatever is already under the cursor the instant Option
            // is pressed — matches LookIn's feel of "hold to measure."
            if let window {
                let windowPoint = window.mouseLocationOutsideOfEventStream
                let point = convert(windowPoint, from: nil)
                if bounds.contains(point) {
                    updateHover(at: point)
                }
            }
        } else {
            publishHover(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving a window with Option still logically down would otherwise
        // leak the last hover. Reset on every window transition.
        optionHeld = false
        publishHover(nil)
    }

    private func updateHover(at point: CGPoint) {
        let hits = hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .sortResults: true,
        ])
        for hit in hits {
            if let uuid = findNodeUUID(in: hit.node) {
                publishHover(uuid)
                return
            }
        }
        publishHover(nil)
    }

    private func publishHover(_ uuid: UUID?) {
        guard uuid != lastHoverID else { return }
        lastHoverID = uuid
        hoverHandler?(uuid)
    }

    private func findNodeUUID(in node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name, let uuid = UUID(uuidString: name) {
                return uuid
            }
            current = n.parent
        }
        return nil
    }
}

// MARK: - Hyperion-style overlay builder

/// Builds a SceneKit overlay that mirrors Hyperion's measurements plugin
/// visuals: primary-colored dashed extension guides along the anchor's axes,
/// solid dimension lines with T-serifs at each measured edge, and rounded
/// pill labels reporting the per-edge distance in points. The compare view
/// gets a dashed secondary outline so it reads as "the thing being measured
/// to" rather than a second selection.
///
/// All geometry is in scene coordinates. Window-frame math (like Hyperion's
/// original UIKit version) happens first; the final conversion to scene
/// coordinates applies a Y flip against `rootHeight`.
private enum MeasurementOverlayBuilder {
    static let primaryColor = NSColor(srgbRed: 43.0/255.0, green: 87.0/255.0, blue: 244.0/255.0, alpha: 1.0)
    static let secondaryColor = NSColor(srgbRed: 199.0/255.0, green: 199.0/255.0, blue: 204.0/255.0, alpha: 1.0)

    /// Lazily-built repeating textures. Scene units are "pt" so these match
    /// the sizes used by Hyperion's CAShapeLayer dash patterns.
    private static let extensionDashTexture = dashTexture(
        color: primaryColor, dash: 3, gap: 8, thicknessPx: 2
    )
    private static let compareDashTexture = dashTexture(
        color: secondaryColor, dash: 4, gap: 4, thicknessPx: 2
    )

    static func build(
        anchorRect: CGRect,
        compareRect: CGRect,
        rootHeight: CGFloat,
        screenArea: CGRect,
        overlayZ: CGFloat
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "_measurement"

        addCompareDashedBorder(rect: compareRect,
                               rootHeight: rootHeight,
                               overlayZ: overlayZ,
                               into: root)
        addExtensionGuides(anchor: anchorRect,
                           screenArea: screenArea,
                           rootHeight: rootHeight,
                           overlayZ: overlayZ,
                           into: root)
        addDimensionLines(anchor: anchorRect,
                          compare: compareRect,
                          rootHeight: rootHeight,
                          overlayZ: overlayZ,
                          into: root)

        // Draw the whole overlay on top of planes and their borders; anything
        // using a renderingOrder of 0..few-hundred lives below.
        applyRenderingOrder(10_000, to: root)
        return root
    }

    // MARK: - Borders and guides

    private static func addCompareDashedBorder(
        rect: CGRect,
        rootHeight: CGFloat,
        overlayZ: CGFloat,
        into parent: SCNNode
    ) {
        // 4 edges of the compare rect, dashed secondary color. Z sits
        // fractionally behind the dimension lines so labels can overlap the
        // border without a depth-fight stripe.
        let tl = CGPoint(x: rect.minX, y: rect.minY)
        let tr = CGPoint(x: rect.maxX, y: rect.minY)
        let bl = CGPoint(x: rect.minX, y: rect.maxY)
        let br = CGPoint(x: rect.maxX, y: rect.maxY)
        let edges: [(CGPoint, CGPoint)] = [(tl, tr), (tr, br), (br, bl), (bl, tl)]
        for (start, end) in edges {
            let node = makeDashedLine(
                from: scenePoint(start, rootHeight: rootHeight, z: overlayZ - 0.2),
                to: scenePoint(end, rootHeight: rootHeight, z: overlayZ - 0.2),
                texture: compareDashTexture.image,
                patternWidth: compareDashTexture.patternWidth,
                thickness: 1.0
            )
            parent.addChildNode(node)
        }
    }

    private static func addExtensionGuides(
        anchor: CGRect,
        screenArea: CGRect,
        rootHeight: CGFloat,
        overlayZ: CGFloat,
        into parent: SCNNode
    ) {
        // Extend slightly beyond screenArea so users can follow the guide out
        // past the content area when the camera orbits.
        let pad: CGFloat = 40
        let topY = min(anchor.minY, screenArea.minY - pad)
        let bottomY = max(anchor.maxY, screenArea.maxY + pad)
        let leftX = min(anchor.minX, screenArea.minX - pad)
        let rightX = max(anchor.maxX, screenArea.maxX + pad)

        let verticalLeft: [(CGPoint, CGPoint)] = [
            (CGPoint(x: anchor.minX, y: topY), CGPoint(x: anchor.minX, y: bottomY)),
            (CGPoint(x: anchor.maxX, y: topY), CGPoint(x: anchor.maxX, y: bottomY)),
        ]
        let horizontalPairs: [(CGPoint, CGPoint)] = [
            (CGPoint(x: leftX, y: anchor.minY), CGPoint(x: rightX, y: anchor.minY)),
            (CGPoint(x: leftX, y: anchor.maxY), CGPoint(x: rightX, y: anchor.maxY)),
        ]

        for (start, end) in verticalLeft + horizontalPairs {
            let node = makeDashedLine(
                from: scenePoint(start, rootHeight: rootHeight, z: overlayZ - 0.1),
                to: scenePoint(end, rootHeight: rootHeight, z: overlayZ - 0.1),
                texture: extensionDashTexture.image,
                patternWidth: extensionDashTexture.patternWidth,
                thickness: 0.6
            )
            parent.addChildNode(node)
        }
    }

    // MARK: - Dimension lines + labels

    /// Mirrors Hyperion's `displayMeasurementViewsForView:comparedToView:`:
    /// when anchor is inside compare we draw 4 inset distances; otherwise we
    /// draw only the side(s) where a positive gap exists, using Hyperion's
    /// "swap and re-measure the gap" convention so labels always read
    /// positively.
    private static func addDimensionLines(
        anchor: CGRect,
        compare: CGRect,
        rootHeight: CGFloat,
        overlayZ: CGFloat,
        into parent: SCNNode
    ) {
        let anchorInsideCompare = compare.contains(anchor)

        if anchorInsideCompare {
            placeTop(primary: anchor, secondary: compare, inside: true,
                     rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
            placeBottom(primary: anchor, secondary: compare, inside: true,
                        rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
            placeLeft(primary: anchor, secondary: compare, inside: true,
                      rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
            placeRight(primary: anchor, secondary: compare, inside: true,
                       rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        } else {
            // Hyperion's trick: pretend compare is the "primary" for the
            // purposes of `placeTop/...` so the comparison becomes compare-top
            // vs anchor-below-it. Each `place*` method checks whether a
            // measurable gap exists in its direction and emits nothing if not.
            placeTop(primary: compare, secondary: anchor, inside: false,
                     rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
            placeBottom(primary: compare, secondary: anchor, inside: false,
                        rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
            placeLeft(primary: compare, secondary: anchor, inside: false,
                      rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
            placeRight(primary: compare, secondary: anchor, inside: false,
                       rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        }
    }

    private static func placeTop(
        primary: CGRect, secondary: CGRect, inside: Bool,
        rootHeight: CGFloat, overlayZ: CGFloat, into parent: SCNNode
    ) {
        let topPrimary = CGPoint(x: primary.midX, y: primary.minY)
        if inside {
            let topSecondary = CGPoint(x: primary.midX, y: secondary.minY)
            emitDimension(from: topSecondary, to: topPrimary,
                          rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        } else if primary.minY >= secondary.maxY {
            let endpoint = CGPoint(x: topPrimary.x, y: secondary.maxY)
            emitDimension(from: endpoint, to: topPrimary,
                          rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        }
    }

    private static func placeBottom(
        primary: CGRect, secondary: CGRect, inside: Bool,
        rootHeight: CGFloat, overlayZ: CGFloat, into parent: SCNNode
    ) {
        let bottomPrimary = CGPoint(x: primary.midX, y: primary.maxY)
        if inside {
            let bottomSecondary = CGPoint(x: primary.midX, y: secondary.maxY)
            emitDimension(from: bottomPrimary, to: bottomSecondary,
                          rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        } else if bottomPrimary.y <= secondary.minY {
            let endpoint = CGPoint(x: bottomPrimary.x, y: secondary.minY)
            emitDimension(from: bottomPrimary, to: endpoint,
                          rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        }
    }

    private static func placeLeft(
        primary: CGRect, secondary: CGRect, inside: Bool,
        rootHeight: CGFloat, overlayZ: CGFloat, into parent: SCNNode
    ) {
        let leftPrimary = CGPoint(x: primary.minX, y: primary.midY)
        if inside {
            let leftSecondary = CGPoint(x: secondary.minX, y: primary.midY)
            emitDimension(from: leftSecondary, to: leftPrimary,
                          rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        } else if leftPrimary.x >= secondary.maxX {
            let endpoint = CGPoint(x: secondary.maxX, y: leftPrimary.y)
            emitDimension(from: endpoint, to: leftPrimary,
                          rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        }
    }

    private static func placeRight(
        primary: CGRect, secondary: CGRect, inside: Bool,
        rootHeight: CGFloat, overlayZ: CGFloat, into parent: SCNNode
    ) {
        let rightPrimary = CGPoint(x: primary.maxX, y: primary.midY)
        if inside {
            let rightSecondary = CGPoint(x: secondary.maxX, y: primary.midY)
            emitDimension(from: rightPrimary, to: rightSecondary,
                          rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        } else if rightPrimary.x <= secondary.minX {
            let endpoint = CGPoint(x: secondary.minX, y: rightPrimary.y)
            emitDimension(from: rightPrimary, to: endpoint,
                          rootHeight: rootHeight, overlayZ: overlayZ, into: parent)
        }
    }

    private static func emitDimension(
        from start: CGPoint, to end: CGPoint,
        rootHeight: CGFloat, overlayZ: CGFloat, into parent: SCNNode
    ) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.5 else { return }

        let sceneStart = scenePoint(start, rootHeight: rootHeight, z: overlayZ)
        let sceneEnd = scenePoint(end, rootHeight: rootHeight, z: overlayZ)

        parent.addChildNode(makeSolidLine(from: sceneStart, to: sceneEnd,
                                          color: primaryColor, thickness: 0.8))
        parent.addChildNode(makeSerif(at: sceneStart, along: sceneEnd,
                                      color: primaryColor))
        parent.addChildNode(makeSerif(at: sceneEnd, along: sceneStart,
                                      color: primaryColor))

        let labelText = formatPt(length)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let labelCenter = scenePoint(mid, rootHeight: rootHeight, z: overlayZ + 0.2)
        parent.addChildNode(makeLabel(text: labelText, at: labelCenter))
    }

    // MARK: - Line primitives

    private static func makeSolidLine(
        from start: SCNVector3, to end: SCNVector3,
        color: NSColor, thickness: CGFloat
    ) -> SCNNode {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        let plane = SCNPlane(width: CGFloat(length), height: thickness)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.position = SCNVector3((start.x + end.x) / 2, (start.y + end.y) / 2, start.z)
        node.eulerAngles.z = atan2(dy, dx)
        return node
    }

    /// T-serif at one endpoint of a dimension line — perpendicular to the
    /// line, matching Hyperion's ±5pt cap tick.
    private static func makeSerif(at endpoint: SCNVector3, along other: SCNVector3, color: NSColor) -> SCNNode {
        let dx = other.x - endpoint.x
        let dy = other.y - endpoint.y
        let lineAngle = atan2(dy, dx)
        let serifLength: CGFloat = 8
        let plane = SCNPlane(width: serifLength, height: 0.8)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.position = endpoint
        // Rotate 90° off the line so the serif crosses it orthogonally.
        node.eulerAngles.z = lineAngle + .pi / 2
        return node
    }

    // MARK: - Dashed line via tiled texture

    private struct DashTexture {
        let image: NSImage
        let patternWidth: CGFloat
    }

    private static func dashTexture(color: NSColor, dash: CGFloat, gap: CGFloat, thicknessPx: CGFloat) -> DashTexture {
        let patternWidth = dash + gap
        // Backing bitmap at a super-sampled pixel size — SceneKit otherwise
        // samples the NSImage at its logical pt size and the dashes get
        // jaggy once the camera zooms in.
        let scale: CGFloat = 8
        let pixelW = max(1, Int((patternWidth * scale).rounded()))
        let pixelH = max(1, Int((thicknessPx * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            // Fallback: an opaque image of the solid color — better than
            // crashing if the bitmap rep can't be allocated.
            let fallback = NSImage(size: NSSize(width: patternWidth, height: thicknessPx))
            fallback.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: patternWidth, height: thicknessPx).fill()
            fallback.unlockFocus()
            return DashTexture(image: fallback, patternWidth: patternWidth)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH)).fill(using: .copy)
        color.setFill()
        NSRect(x: 0, y: 0, width: dash * scale, height: CGFloat(pixelH)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: patternWidth, height: thicknessPx))
        image.addRepresentation(rep)
        return DashTexture(image: image, patternWidth: patternWidth)
    }

    private static func makeDashedLine(
        from start: SCNVector3, to end: SCNVector3,
        texture: NSImage, patternWidth: CGFloat, thickness: CGFloat
    ) -> SCNNode {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        let plane = SCNPlane(width: CGFloat(length), height: thickness)
        let mat = SCNMaterial()
        mat.diffuse.contents = texture
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .clamp
        mat.diffuse.minificationFilter = .nearest
        mat.diffuse.magnificationFilter = .nearest
        // Scale U so one full dash+gap pattern spans `patternWidth` scene units.
        let repeats = max(1.0, CGFloat(length) / patternWidth)
        mat.diffuse.contentsTransform = SCNMatrix4MakeScale(repeats, 1, 1)
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.position = SCNVector3((start.x + end.x) / 2, (start.y + end.y) / 2, start.z)
        node.eulerAngles.z = atan2(dy, dx)
        return node
    }

    // MARK: - Rounded pill label

    private static func makeLabel(text: String, at center: SCNVector3) -> SCNNode {
        let image = labelImage(text)
        let w = image.size.width
        let h = image.size.height
        let plane = SCNPlane(width: w, height: h)
        let mat = SCNMaterial()
        mat.diffuse.contents = image
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.position = center
        return node
    }

    private static func labelImage(_ text: String) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: primaryColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let textSize = attributed.size()
        let padH: CGFloat = 7
        let padV: CGFloat = 3
        let size = NSSize(
            width: ceil(textSize.width) + padH * 2,
            height: ceil(textSize.height) + padV * 2
        )
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        path.fill()
        primaryColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        attributed.draw(at: NSPoint(x: padH, y: padV))
        return image
    }

    // MARK: - Helpers

    private static func scenePoint(_ p: CGPoint, rootHeight: CGFloat, z: CGFloat) -> SCNVector3 {
        SCNVector3(p.x, rootHeight - p.y, z)
    }

    private static func formatPt(_ v: CGFloat) -> String {
        if v == v.rounded() { return String(format: "%g pt", v) }
        return String(format: "%.1f pt", v)
    }

    private static func applyRenderingOrder(_ order: Int, to node: SCNNode) {
        node.renderingOrder = order
        for child in node.childNodes {
            applyRenderingOrder(order, to: child)
        }
    }
}
