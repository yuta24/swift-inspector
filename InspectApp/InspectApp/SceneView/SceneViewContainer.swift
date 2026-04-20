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

            // Controls overlay
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

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        scnView.addGestureRecognizer(click)
        context.coordinator.scnView = scnView

        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        context.coordinator.selectedNodeID = $selectedNodeID
        let scene = SceneBuilder.buildScene(
            roots: roots,
            layerSpacing: layerSpacing,
            showLabels: showLabels,
            selectedNodeID: selectedNodeID
        )
        scnView.scene = scene
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var selectedNodeID: Binding<UUID?>
        weak var scnView: SCNView?

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

            // Find the first hit node that has a ViewNode UUID
            for hit in hits {
                if let uuid = findNodeUUID(in: hit.node) {
                    selectedNodeID.wrappedValue = uuid
                    return
                }
            }
            // Clicked empty space — deselect
            selectedNodeID.wrappedValue = nil
        }

        private func findNodeUUID(in node: SCNNode) -> UUID? {
            var current: SCNNode? = node
            while let n = current {
                if let uuidString = n.name, let uuid = UUID(uuidString: uuidString) {
                    return uuid
                }
                current = n.parent
            }
            return nil
        }
    }
}

// MARK: - Scene Builder

private enum SceneBuilder {
    static func buildScene(
        roots: [ViewNode],
        layerSpacing: Float,
        showLabels: Bool,
        selectedNodeID: UUID?
    ) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.windowBackgroundColor
        let root = scene.rootNode

        // Ambient light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 1000
        ambientLight.color = NSColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        root.addChildNode(ambientNode)

        var maxDepth: Float = 0
        for node in roots {
            addNode(
                node, to: root,
                maxDepth: &maxDepth, z: 0,
                layerSpacing: layerSpacing,
                showLabels: showLabels,
                selectedNodeID: selectedNodeID
            )
        }

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 500
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(200, -400, maxDepth + 800)
        cameraNode.look(at: SCNVector3(200, -400, maxDepth / 2))
        root.addChildNode(cameraNode)

        return scene
    }

    private static func addNode(
        _ node: ViewNode,
        to parent: SCNNode,
        maxDepth: inout Float,
        z: Float,
        layerSpacing: Float,
        showLabels: Bool,
        selectedNodeID: UUID?
    ) {
        let w = node.frame.size.width
        let h = node.frame.size.height
        guard w >= 1, h >= 1 else { return }
        guard !node.isHidden else { return }

        let isSelected = node.id == selectedNodeID

        // Container node — named with UUID for hit-test lookup
        let containerNode = SCNNode()
        containerNode.name = node.id.uuidString
        containerNode.position = SCNVector3(
            Float(node.frame.midX),
            Float(-node.frame.midY),
            z
        )
        parent.addChildNode(containerNode)

        // Snapshot plane
        let plane = SCNPlane(width: w, height: h)
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant

        if let soloData = node.soloScreenshot, let image = NSImage(data: soloData) {
            material.diffuse.contents = image
            material.transparency = CGFloat(node.alpha)
        } else if let groupData = node.screenshot, let image = NSImage(data: groupData),
                  node.children.isEmpty {
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
        containerNode.addChildNode(planeNode)

        // Selection highlight
        if isSelected {
            let highlightPlane = SCNPlane(width: w, height: h)
            let highlightMaterial = SCNMaterial()
            highlightMaterial.diffuse.contents = NSColor.controlAccentColor.withAlphaComponent(0.25)
            highlightMaterial.lightingModel = .constant
            highlightMaterial.isDoubleSided = true
            highlightPlane.materials = [highlightMaterial]
            let highlightNode = SCNNode(geometry: highlightPlane)
            highlightNode.position = SCNVector3(0, 0, 0.2)
            containerNode.addChildNode(highlightNode)
        }

        // Wireframe border
        addBorder(to: containerNode, width: w, height: h, isSelected: isSelected)

        // Label
        if showLabels && w >= 20 && h >= 10 {
            addLabel(node.className, to: containerNode, width: w, height: h, isSelected: isSelected)
        }

        maxDepth = max(maxDepth, z)
        for child in node.children {
            addNode(
                child, to: containerNode,
                maxDepth: &maxDepth, z: layerSpacing,
                layerSpacing: layerSpacing,
                showLabels: showLabels,
                selectedNodeID: selectedNodeID
            )
        }
    }

    private static func addBorder(
        to parent: SCNNode,
        width: CGFloat,
        height: CGFloat,
        isSelected: Bool
    ) {
        let hw = Float(width) / 2
        let hh = Float(height) / 2
        let corners: [SCNVector3] = [
            SCNVector3(-hw, -hh, 0),
            SCNVector3( hw, -hh, 0),
            SCNVector3( hw,  hh, 0),
            SCNVector3(-hw,  hh, 0),
        ]
        let edges: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (3, 0)]

        let borderColor: NSColor = isSelected
            ? .controlAccentColor.withAlphaComponent(0.9)
            : NSColor(white: 0.5, alpha: 0.5)
        let borderWidth: CGFloat = isSelected ? 1.0 : 0.5

        for (a, b) in edges {
            let p0 = corners[a]
            let p1 = corners[b]
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let length = sqrt(dx * dx + dy * dy)

            let edgePlane = SCNPlane(width: CGFloat(length), height: borderWidth)
            let edgeMaterial = SCNMaterial()
            edgeMaterial.diffuse.contents = borderColor
            edgeMaterial.lightingModel = .constant
            edgeMaterial.isDoubleSided = true
            edgePlane.materials = [edgeMaterial]

            let edgeNode = SCNNode(geometry: edgePlane)
            edgeNode.position = SCNVector3(
                (p0.x + p1.x) / 2,
                (p0.y + p1.y) / 2,
                0.1
            )
            edgeNode.eulerAngles.z = atan2(dy, dx)
            parent.addChildNode(edgeNode)
        }
    }

    private static func addLabel(
        _ text: String,
        to parent: SCNNode,
        width: CGFloat,
        height: CGFloat,
        isSelected: Bool
    ) {
        let scnText = SCNText(string: text, extrusionDepth: 0)
        scnText.font = NSFont.monospacedSystemFont(ofSize: 3, weight: .medium)
        scnText.flatness = 0.2
        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = isSelected
            ? NSColor.controlAccentColor
            : NSColor(white: 0.4, alpha: 0.8)
        textMaterial.lightingModel = .constant
        textMaterial.isDoubleSided = true
        scnText.materials = [textMaterial]

        let textNode = SCNNode(geometry: scnText)
        let (bbMin, bbMax) = textNode.boundingBox
        let textWidth = Float(bbMax.x - bbMin.x)
        let textHeight = Float(bbMax.y - bbMin.y)

        // Position label at top-left of the plane
        let hw = Float(width) / 2
        let hh = Float(height) / 2
        textNode.position = SCNVector3(
            -hw,
            hh + textHeight + 1,
            0.3
        )

        // Clamp label width to plane width
        let fw = Float(width)
        if textWidth > fw {
            let s = fw / textWidth
            textNode.scale = SCNVector3(s, s, 1)
        }

        parent.addChildNode(textNode)
    }
}
