import SwiftUI
import SceneKit
import InspectCore

struct SceneViewContainer: View {
    let roots: [ViewNode]

    var body: some View {
        SceneView(
            scene: Self.makeScene(from: roots),
            options: [.allowsCameraControl, .autoenablesDefaultLighting]
        )
    }

    private static func makeScene(from roots: [ViewNode]) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode

        var depth: Float = 0
        for node in roots {
            addNode(node, to: root, depth: &depth, z: 0)
        }

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 400
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 1000)
        root.addChildNode(cameraNode)

        return scene
    }

    private static func addNode(
        _ node: ViewNode,
        to parent: SCNNode,
        depth: inout Float,
        z: Float
    ) {
        let plane = SCNPlane(width: node.frame.size.width, height: node.frame.size.height)
        let material = SCNMaterial()
        if let color = node.backgroundColor {
            material.diffuse.contents = NSColor(
                srgbRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: 0.35
            )
        } else {
            material.diffuse.contents = NSColor(white: 1.0, alpha: 0.05)
        }
        material.isDoubleSided = true
        plane.materials = [material]

        let scn = SCNNode(geometry: plane)
        scn.position = SCNVector3(
            Float(node.frame.midX),
            Float(-node.frame.midY),
            z
        )
        parent.addChildNode(scn)

        depth = max(depth, z)
        for child in node.children {
            addNode(child, to: scn, depth: &depth, z: 10)
        }
    }
}
