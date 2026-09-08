//
//  CoregistrationSceneView.swift
//  EVA Resolve
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SceneKit view of the coregistration: the scalp mesh (semi-transparent),
//  electrodes as spheres coloured by their distance to the scalp, MRI fiducials
//  (yellow) and the electrode set's own fiducials after the transform (orange).
//  Rebuilt from the controller's state on every change; camera is free-orbit.
//

import AppKit
import SceneKit
import SwiftUI
import simd

struct CoregistrationSceneView: View {
    @Bindable var controller: HeadModelController

    var body: some View {
        SceneView(scene: makeScene(), options: [.allowsCameraControl, .autoenablesDefaultLighting])
            .background(Color.black)
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedWhite: 0.06, alpha: 1)
        // Work in millimetres so SceneKit's default camera distances behave.
        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        var centre = SIMD3<Double>(0, 0, 0)
        var radius = 100.0
        if let scalp = controller.scalp {
            centre = scalp.centroid * 1000
            let (lo, hi) = scalp.boundingBox
            radius = simd_length(hi - lo) * 1000 / 2
            root.addChildNode(scalpNode(scalp))
        } else if !controller.electrodesInMRI.isEmpty {
            let e = controller.electrodesInMRI
            centre = e.reduce(.zero, +) / Double(e.count) * 1000
            radius = e.map { simd_length($0 * 1000 - centre) }.max() ?? 100
        }

        let residuals = controller.residuals
        for (n, e) in controller.electrodesInMRI.enumerated() {
            let r = residuals?[n] ?? 0
            let color: NSColor = residuals == nil ? .systemBlue : (r < 0.003 ? .systemGreen : (r < 0.008 ? .systemOrange : .systemRed))
            root.addChildNode(sphere(at: e * 1000, radius: 3, color: color))
        }
        for (kind, f) in controller.mriFiducials {
            root.addChildNode(sphere(at: f * 1000, radius: 4, color: .systemYellow, name: kind.label))
        }
        for (_, f) in controller.electrodeFiducialsInMRI {
            root.addChildNode(sphere(at: f * 1000, radius: 3.2, color: .systemOrange))
        }
        root.addChildNode(axes(at: centre, length: radius * 0.6))

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 1
        camera.camera?.zFar = 5000
        camera.position = SCNVector3(centre.x + radius * 2.6, centre.y - radius * 2.2, centre.z + radius * 1.2)
        camera.look(at: SCNVector3(centre.x, centre.y, centre.z))
        scene.rootNode.addChildNode(camera)
        return scene
    }

    private func scalpNode(_ mesh: TriangleMesh) -> SCNNode {
        let vertices = mesh.vertices.map { SCNVector3($0.x * 1000, $0.y * 1000, $0.z * 1000) }
        let normals = mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) }
        var indices: [Int32] = []
        indices.reserveCapacity(mesh.triangles.count * 3)
        for t in mesh.triangles { indices.append(t.x); indices.append(t.y); indices.append(t.z) }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.85, green: 0.72, blue: 0.62, alpha: 0.55)
        material.isDoubleSided = true
        material.lightingModel = .lambert
        material.transparencyMode = .dualLayer
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 1
        return node
    }

    private func sphere(at p: SIMD3<Double>, radius: Double, color: NSColor, name: String? = nil) -> SCNNode {
        let geometry = SCNSphere(radius: radius)
        geometry.segmentCount = 12
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.35)
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(p.x, p.y, p.z)
        node.name = name
        return node
    }

    private func axes(at centre: SIMD3<Double>, length: Double) -> SCNNode {
        let node = SCNNode()
        for (dir, color) in [(SIMD3<Double>(1, 0, 0), NSColor.systemRed), (SIMD3<Double>(0, 1, 0), .systemGreen), (SIMD3<Double>(0, 0, 1), .systemBlue)] {
            let end = centre + dir * length
            let source = SCNGeometrySource(vertices: [SCNVector3(centre.x, centre.y, centre.z), SCNVector3(end.x, end.y, end.z)])
            let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = color
            geometry.materials = [material]
            node.addChildNode(SCNNode(geometry: geometry))
        }
        return node
    }
}
