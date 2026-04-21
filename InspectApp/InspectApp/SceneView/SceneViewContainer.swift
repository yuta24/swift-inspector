import SwiftUI
import SceneKit
import InspectCore

// MARK: - SwiftUI Container

struct SceneViewContainer: View {
    let roots: [ViewNode]
    @Binding var selectedNodeID: UUID?
    @State private var layerSpacing: Float = 30
    @State private var showLabels: Bool = true

    var body: some View {
        ZStack(alignment: .bottom) {
            SceneKitView(
                roots: roots,
                selectedNodeID: $selectedNodeID,
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
    let width: CGFloat
    let height: CGFloat
}

// MARK: - NSViewRepresentable

private struct SceneKitView: NSViewRepresentable {
    let roots: [ViewNode]
    @Binding var selectedNodeID: UUID?
    let layerSpacing: Float
    let showLabels: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedNodeID: $selectedNodeID)
    }

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
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

        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        let coord = context.coordinator
        coord.selectedNodeID = $selectedNodeID

        let rootsHash = roots.hashValue

        // Full rebuild only when hierarchy data changes
        if coord.lastRootsHash != rootsHash {
            rebuildScene(scnView: scnView, coord: coord)
            coord.lastRootsHash = rootsHash
            coord.lastLayerSpacing = layerSpacing
            coord.lastShowLabels = showLabels
            coord.lastSelectedNodeID = selectedNodeID
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
            // Remove old highlight
            if let oldID = coord.lastSelectedNodeID as? UUID,
               let oldEntry = coord.nodeMap[oldID] {
                oldEntry.snapshotNode.childNode(withName: "_highlight", recursively: false)?
                    .removeFromParentNode()
                updateBorderColor(oldEntry.snapshotNode, isSelected: false)
            }
            // Add new highlight
            if let newID = selectedNodeID,
               let newEntry = coord.nodeMap[newID] {
                addHighlight(to: newEntry.snapshotNode, width: newEntry.width, height: newEntry.height)
                updateBorderColor(newEntry.snapshotNode, isSelected: true)
            }
            coord.lastSelectedNodeID = selectedNodeID
        }
    }

    // MARK: - Full scene rebuild

    private func rebuildScene(scnView: SCNView, coord: Coordinator) {
        let scene = SCNScene()
        scene.background.contents = NSColor.windowBackgroundColor
        let rootNode = scene.rootNode

        coord.nodeMap.removeAll()

        guard let firstRoot = roots.first else {
            scnView.scene = scene
            return
        }

        let rootHeight = firstRoot.frame.size.height

        var traversalIndex = 0
        for root in roots {
            buildNodes(
                node: root,
                parentAbsOrigin: .zero,
                rootHeight: rootHeight,
                depth: 0,
                traversalIndex: &traversalIndex,
                sceneRoot: rootNode,
                coord: coord
            )
        }

        scnView.scene = scene
        scnView.allowsCameraControl = true
    }

    /// Recursively build SCNNodes for the view hierarchy.
    /// Uses InAppViewDebugger-style coordinate conversion:
    ///   sceneX = absUIKitX + width/2
    ///   sceneY = rootHeight - absUIKitY - height/2
    private func buildNodes(
        node: ViewNode,
        parentAbsOrigin: CGPoint,
        rootHeight: CGFloat,
        depth: Int,
        traversalIndex: inout Int,
        sceneRoot: SCNNode,
        coord: Coordinator
    ) {
        let w = node.frame.size.width
        let h = node.frame.size.height
        guard w >= 1, h >= 1 else { return }
        guard !node.isHidden else { return }

        let myIndex = traversalIndex
        traversalIndex += 1

        // Absolute position in UIKit coordinates
        let absX = parentAbsOrigin.x + node.frame.origin.x
        let absY = parentAbsOrigin.y + node.frame.origin.y

        // Convert to SceneKit: center of view, Y flipped relative to root height.
        // Add a tiny per-node Z offset (myIndex * epsilon) to break z-fighting
        // when siblings or overlapping CALayers sit at the same depth.
        let sceneX = Float(absX + w / 2)
        let sceneY = Float(rootHeight - absY - h / 2)
        let sceneZ = layerSpacing * Float(depth) + Float(myIndex) * 0.01

        let isSelected = node.id == selectedNodeID

        // Container node
        let containerNode = SCNNode()
        containerNode.name = node.id.uuidString
        containerNode.position = SCNVector3(sceneX, sceneY, sceneZ)
        // Enforce deterministic draw order for overlapping semi-transparent planes
        containerNode.renderingOrder = myIndex
        sceneRoot.addChildNode(containerNode)

        // Plane with screenshot texture
        let plane = SCNPlane(width: w, height: h)
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant

        // Prefer soloScreenshot (per-layer, PNG with transparency).
        // For leaf nodes, fall back to groupScreenshot (no children → no duplication).
        // For container nodes with no soloScreenshot, keep transparent to avoid
        // full-screen content being duplicated across multiple layers.
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

        // Border
        addBorder(to: containerNode, width: w, height: h, isSelected: isSelected)

        // Selection highlight
        if isSelected {
            addHighlight(to: containerNode, width: w, height: h)
        }

        // Label
        if w >= 20 && h >= 10 {
            let labelNode = makeLabel(node.className, width: w, height: h, isSelected: isSelected)
            labelNode.isHidden = !showLabels
            containerNode.addChildNode(labelNode)
        }

        // Register in node map for incremental updates
        coord.nodeMap[node.id] = NodeEntry(
            snapshotNode: containerNode,
            depth: depth,
            traversalIndex: myIndex,
            width: w,
            height: h
        )

        // Recurse children
        let childAbsOrigin = CGPoint(x: absX, y: absY)
        for child in node.children {
            buildNodes(
                node: child,
                parentAbsOrigin: childAbsOrigin,
                rootHeight: rootHeight,
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
        weak var scnView: SCNView?
        var nodeMap: [UUID: NodeEntry] = [:]
        var lastRootsHash: Int?
        var lastLayerSpacing: Float?
        var lastShowLabels: Bool?
        var lastSelectedNodeID: UUID??

        init(selectedNodeID: Binding<UUID?>) {
            self.selectedNodeID = selectedNodeID
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
