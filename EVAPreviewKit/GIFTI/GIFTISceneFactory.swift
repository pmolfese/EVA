//
//  GIFTISceneFactory.swift
//  EVAPreviewKit
//

import AppKit
import SceneKit

struct GIFTISceneBundle {
    let scene: SCNScene
    let camera: SCNNode
}

enum GIFTISceneFactory {
    static func make(
        model: GIFTIPreviewModel,
        overlay: GIFTIScalarOverlay? = nil,
        showsNormals: Bool = false
    ) -> GIFTISceneBundle {
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedRed: 0.012, green: 0.019, blue: 0.018, alpha: 1)

        let centered = centeredVertices(model.vertices)
        let vertexNormals = model.triangles.isEmpty
            ? [] : normals(vertices: centered.points, triangles: model.triangles)
        let geometryNode = SCNNode(geometry: geometry(
            vertices: centered.points,
            triangles: model.triangles,
            normals: vertexNormals,
            overlay: overlay ?? model.overlay,
            labels: model.labels
        ))
        scene.rootNode.addChildNode(geometryNode)

        let radius = max(centered.radius, 1)
        if showsNormals, !vertexNormals.isEmpty,
           let normalGeometry = normalVisualization(
               vertices: centered.points,
               normals: vertexNormals,
               radius: radius
           ) {
            let normalNode = SCNNode(geometry: normalGeometry)
            normalNode.renderingOrder = 2
            scene.rootNode.addChildNode(normalNode)
        }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 31
        camera.camera?.zNear = Double(radius) * 0.01
        camera.camera?.zFar = Double(radius) * 20
        camera.position = SCNVector3(radius * 2.8, -radius * 0.62, radius * 0.52)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)

        // Sumaru-style studio lighting: one camera-relative headlight plus two
        // broad side lights preserves folds without burying either side of a
        // double-sided cortical mesh in shadow.
        let headlight = SCNNode()
        headlight.light = directionalLight(intensity: 520, color: .white)
        camera.addChildNode(headlight)

        addDirectionalLight(
            to: scene,
            target: geometryNode,
            position: SCNVector3(radius * 2.2, radius * 1.6, radius * 2.8),
            intensity: 560,
            color: NSColor(calibratedRed: 0.94, green: 1.0, blue: 0.98, alpha: 1)
        )
        addDirectionalLight(
            to: scene,
            target: geometryNode,
            position: SCNVector3(-radius * 2.0, -radius * 1.2, radius * 0.8),
            intensity: 310,
            color: NSColor(calibratedRed: 0.72, green: 0.82, blue: 1.0, alpha: 1)
        )

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 330
        fill.light?.color = NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.83, alpha: 1)
        scene.rootNode.addChildNode(fill)

        return GIFTISceneBundle(scene: scene, camera: camera)
    }

    private static func geometry(
        vertices: [SCNVector3],
        triangles: [GIFTITriangle],
        normals: [SCNVector3],
        overlay: GIFTIScalarOverlay?,
        labels: [Int: GIFTILabel]
    ) -> SCNGeometry? {
        guard !vertices.isEmpty else { return nil }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        var sources = [vertexSource]

        if normals.count == vertices.count {
            sources.append(SCNGeometrySource(normals: normals))
        }
        if let overlay, overlay.values.count == vertices.count {
            sources.append(colorSource(overlay: overlay, labels: labels))
        }

        let element: SCNGeometryElement
        if triangles.isEmpty {
            let indices = (0..<vertices.count).map(UInt32.init)
            element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = 2.5
            element.minimumPointScreenSpaceRadius = 1
            element.maximumPointScreenSpaceRadius = 5
        } else {
            let indices = triangles.flatMap { [$0.a, $0.b, $0.c] }
            element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        }

        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        let hasVertexColors = overlay?.values.count == vertices.count
        material.diffuse.contents = hasVertexColors
            ? NSColor.white
            : NSColor(calibratedRed: 0.76, green: 0.79, blue: 0.75, alpha: 1)
        material.lightingModel = triangles.isEmpty ? .constant : .physicallyBased
        material.roughness.contents = 0.72
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    private static func centeredVertices(_ points: [GIFTIPoint]) -> (points: [SCNVector3], radius: CGFloat) {
        guard let first = points.first else { return ([], 1) }
        var minimum = first
        var maximum = first
        for point in points.dropFirst() {
            minimum.x = min(minimum.x, point.x)
            minimum.y = min(minimum.y, point.y)
            minimum.z = min(minimum.z, point.z)
            maximum.x = max(maximum.x, point.x)
            maximum.y = max(maximum.y, point.y)
            maximum.z = max(maximum.z, point.z)
        }
        let center = GIFTIPoint(
            x: (minimum.x + maximum.x) / 2,
            y: (minimum.y + maximum.y) / 2,
            z: (minimum.z + maximum.z) / 2
        )
        var radius: CGFloat = 0
        let vertices = points.map { point -> SCNVector3 in
            let result = SCNVector3(point.x - center.x, point.y - center.y, point.z - center.z)
            let squaredXY = result.x * result.x + result.y * result.y
            let squaredLength = squaredXY + result.z * result.z
            let distance = sqrt(squaredLength)
            radius = max(radius, distance)
            return result
        }
        return (vertices, radius)
    }

    private static func normals(vertices: [SCNVector3], triangles: [GIFTITriangle]) -> [SCNVector3] {
        var result = [SCNVector3](repeating: SCNVector3Zero, count: vertices.count)
        for triangle in triangles {
            let a = Int(triangle.a), b = Int(triangle.b), c = Int(triangle.c)
            guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
            let ab = subtract(vertices[b], vertices[a])
            let ac = subtract(vertices[c], vertices[a])
            let normal = cross(ab, ac)
            result[a] = add(result[a], normal)
            result[b] = add(result[b], normal)
            result[c] = add(result[c], normal)
        }
        var normalized = result.map { value in
            let length = sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
            return length > 1e-12 ? SCNVector3(value.x / length, value.y / length, value.z / length) : SCNVector3(0, 0, 1)
        }
        let outwardScore = zip(vertices, normalized).reduce(CGFloat.zero) { score, pair in
            score + pair.0.x * pair.1.x + pair.0.y * pair.1.y + pair.0.z * pair.1.z
        }
        if outwardScore < 0 {
            normalized = normalized.map { SCNVector3(-$0.x, -$0.y, -$0.z) }
        }
        return normalized
    }

    private static func normalVisualization(
        vertices: [SCNVector3],
        normals: [SCNVector3],
        radius: CGFloat
    ) -> SCNGeometry? {
        guard vertices.count == normals.count, !vertices.isEmpty else { return nil }
        let maximumGlyphs = 1_500
        let step = max(vertices.count / maximumGlyphs, 1)
        var points: [SCNVector3] = []
        points.reserveCapacity(min(vertices.count, maximumGlyphs) * 2)
        let length = radius * 0.045
        for index in Swift.stride(from: 0, to: vertices.count, by: step) {
            let point = vertices[index]
            let normal = normals[index]
            points.append(point)
            points.append(SCNVector3(
                point.x + normal.x * length,
                point.y + normal.y * length,
                point.z + normal.z * length
            ))
        }
        let source = SCNGeometrySource(vertices: points)
        let indices = (0..<points.count).map(UInt32.init)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(calibratedRed: 0.32, green: 0.9, blue: 0.82, alpha: 0.72)
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    private static func directionalLight(intensity: CGFloat, color: NSColor) -> SCNLight {
        let light = SCNLight()
        light.type = .directional
        light.intensity = intensity
        light.color = color
        return light
    }

    private static func addDirectionalLight(
        to scene: SCNScene,
        target: SCNNode,
        position: SCNVector3,
        intensity: CGFloat,
        color: NSColor
    ) {
        let node = SCNNode()
        node.light = directionalLight(intensity: intensity, color: color)
        node.position = position
        let constraint = SCNLookAtConstraint(target: target)
        constraint.isGimbalLockEnabled = true
        node.constraints = [constraint]
        scene.rootNode.addChildNode(node)
    }

    private static func colorSource(
        overlay: GIFTIScalarOverlay,
        labels: [Int: GIFTILabel]
    ) -> SCNGeometrySource {
        var components: [Float] = []
        components.reserveCapacity(overlay.values.count * 4)
        for value in overlay.values {
            let color = color(value: value, overlay: overlay, labels: labels)
            components.append(contentsOf: [color.0, color.1, color.2, color.3])
        }
        let data = components.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(
            data: data,
            semantic: .color,
            vectorCount: overlay.values.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )
    }

    private static func color(
        value: Double,
        overlay: GIFTIScalarOverlay,
        labels: [Int: GIFTILabel]
    ) -> (Float, Float, Float, Float) {
        if overlay.intent == "NIFTI_INTENT_LABEL",
           let label = labels[Int(value.rounded())] {
            return (label.red ?? 0.55, label.green ?? 0.55, label.blue ?? 0.55, label.alpha ?? 1)
        }
        guard value.isFinite, let window = overlay.window else { return (0.35, 0.7, 0.6, 1) }
        let normalized = Float(min(max((value - window.lowerBound) / (window.upperBound - window.lowerBound), 0), 1))
        if window.lowerBound < 0, window.upperBound > 0 {
            let zero = Float(-window.lowerBound / (window.upperBound - window.lowerBound))
            if normalized < zero {
                let t = zero > 0 ? normalized / zero : 0
                return (0.16 + 0.72 * t, 0.37 + 0.51 * t, 0.92, 1)
            }
            let t = zero < 1 ? (normalized - zero) / (1 - zero) : 1
            return (0.92, 0.88 - 0.66 * t, 0.88 - 0.70 * t, 1)
        }
        return (0.12 + 0.83 * normalized, 0.36 + 0.52 * normalized, 0.72 - 0.52 * normalized, 1)
    }

    private static func subtract(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    private static func add(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    private static func cross(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }
}
