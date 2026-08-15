//
//  ScalpTopography3DView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Sensor-space EEG topography rendered on a synthetic translucent head. This is
//  intentionally a scalp visualization: colors are interpolated from electrodes
//  on the head surface and are not a source-localized brain activation estimate.
//

import SceneKit
import SwiftUI
import simd

struct ScalpTopography3DView: View {
    let geometry: ElectrodeGeometry?
    let layout: SensorLayout?
    let values: [Double]
    let timeSeconds: Double
    let fixedScale: Double?
    let channelName: (Int) -> String

    var body: some View {
        VStack(spacing: 10) {
            ScalpTopographySceneView(
                electrodePositions: ScalpTopography3DLayout.positions(
                    geometry: geometry,
                    layout: layout,
                    channelCount: values.count
                ),
                values: values,
                fixedScale: fixedScale,
                channelName: channelName
            )
            .frame(minHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.cyan.opacity(0.25)))

            HStack {
                Text(String(format: "t = %.3f s", timeSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Sensor-space scalp field")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(16)
    }
}

enum ScalpTopography3DLayout {
    static func positions(
        geometry: ElectrodeGeometry?,
        layout: SensorLayout?,
        channelCount: Int
    ) -> [Int: SIMD3<Double>] {
        if let geometry, !geometry.positions.isEmpty {
            return geometry.positions.filter { $0.key < channelCount }
        }

        if let layout, !layout.positions.isEmpty {
            let lifted = Dictionary(uniqueKeysWithValues: layout.positions
                .filter { $0.channelIndex < channelCount }
                .map { ($0.channelIndex, lift(projected: $0)) })
            if !lifted.isEmpty { return lifted }
        }

        return syntheticEGI128(channelCount: max(channelCount, 128))
            .filter { $0.key < channelCount || channelCount == 0 }
    }

    private static func lift(projected sensor: SensorPosition) -> SIMD3<Double> {
        let x = sensor.x
        let y = sensor.y
        let r = min(hypot(x, y), 1)
        let z = sqrt(max(0.0, 1.0 - r * r))
        let v = SIMD3<Double>(x, y, z)
        let length = simd_length(v)
        return length > 0 ? v / length : SIMD3<Double>(0, 0, 1)
    }

    /// A deterministic HydroCel-like dense net for empty/synthetic previews. It
    /// is not a manufacturer coordinate table; it gives EVA a plausible EGI-style
    /// default distribution until a recording supplies coordinates.xml.
    private static func syntheticEGI128(channelCount: Int) -> [Int: SIMD3<Double>] {
        let count = min(max(channelCount, 1), 256)
        let goldenAngle = Double.pi * (3.0 - sqrt(5.0))
        var positions: [Int: SIMD3<Double>] = [:]

        for index in 0..<count {
            let fraction = (Double(index) + 0.5) / Double(count)
            let z = 1.0 - fraction * 1.72
            let ring = sqrt(max(0.0, 1.0 - z * z))
            let theta = Double(index) * goldenAngle
            let lateral = cos(theta) * ring
            let anterior = sin(theta) * ring
            let v = SIMD3<Double>(lateral, anterior, z)
            let length = simd_length(v)
            positions[index] = length > 0 ? v / length : SIMD3<Double>(0, 0, 1)
        }

        return positions
    }
}

private struct ScalpTopographySceneView: NSViewRepresentable {
    let electrodePositions: [Int: SIMD3<Double>]
    let values: [Double]
    let fixedScale: Double?
    let channelName: (Int) -> String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = context.coordinator.scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = NSColor(calibratedRed: 0.015, green: 0.025, blue: 0.035, alpha: 1)
        view.rendersContinuously = true
        context.coordinator.installBaseScene()
        context.coordinator.update(electrodePositions: electrodePositions, values: values, fixedScale: fixedScale, channelName: channelName)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.update(electrodePositions: electrodePositions, values: values, fixedScale: fixedScale, channelName: channelName)
    }

    final class Coordinator {
        let scene = SCNScene()
        private let scalpNode = SCNNode()
        private let electrodesNode = SCNNode()
        private var lastKey = ""

        func installBaseScene() {
            guard scene.rootNode.childNode(withName: "camera", recursively: false) == nil else { return }

            let cameraNode = SCNNode()
            cameraNode.name = "camera"
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.fieldOfView = 36
            cameraNode.position = SCNVector3(0, 0.12, 4.25)
            scene.rootNode.addChildNode(cameraNode)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.intensity = 650
            key.position = SCNVector3(-1.5, 2.0, 2.6)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .ambient
            fill.light?.color = NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.9, alpha: 1)
            fill.light?.intensity = 240
            scene.rootNode.addChildNode(fill)

            scene.rootNode.addChildNode(holographicHeadShell())
            scene.rootNode.addChildNode(scalpNode)
            scene.rootNode.addChildNode(electrodesNode)
        }

        func update(
            electrodePositions: [Int: SIMD3<Double>],
            values: [Double],
            fixedScale: Double?,
            channelName: (Int) -> String
        ) {
            let valueKey = values.map { String(format: "%.3f", $0) }.joined(separator: ",")
            let positionKey = electrodePositions.keys.sorted().map(String.init).joined(separator: ",")
            let key = "\(positionKey)|\(valueKey)|\(fixedScale ?? -1)"
            guard key != lastKey else { return }
            lastKey = key

            let sensors = electrodePositions
                .filter { $0.key < values.count }
                .map { (channel: $0.key, position: $0.value, value: values[$0.key]) }
                .sorted { $0.channel < $1.channel }

            scalpNode.geometry = scalpGeometry(sensors: sensors, fixedScale: fixedScale)
            rebuildElectrodes(sensors: sensors, fixedScale: fixedScale, channelName: channelName)
        }

        private func holographicHeadShell() -> SCNNode {
            let root = SCNNode()
            root.name = "holographic-head"

            let shell = SCNSphere(radius: 1.0)
            shell.segmentCount = 72
            let shellMaterial = SCNMaterial()
            shellMaterial.diffuse.contents = NSColor(calibratedRed: 0.22, green: 0.88, blue: 1.0, alpha: 0.10)
            shellMaterial.emission.contents = NSColor(calibratedRed: 0.03, green: 0.32, blue: 0.42, alpha: 0.35)
            shellMaterial.transparency = 0.24
            shellMaterial.isDoubleSided = true
            shellMaterial.fillMode = .lines
            shell.materials = [shellMaterial]

            let shellNode = SCNNode(geometry: shell)
            shellNode.scale = SCNVector3(0.92, 1.14, 0.98)
            root.addChildNode(shellNode)

            let face = SCNNode(geometry: SCNSphere(radius: 0.42))
            face.scale = SCNVector3(0.72, 0.92, 0.36)
            face.position = SCNVector3(0, -0.16, 0.82)
            face.geometry?.materials = [softCyanMaterial(alpha: 0.08)]
            root.addChildNode(face)

            let neck = SCNNode(geometry: SCNCylinder(radius: 0.22, height: 0.62))
            neck.position = SCNVector3(0, -1.18, 0)
            neck.geometry?.materials = [softCyanMaterial(alpha: 0.09)]
            root.addChildNode(neck)

            let shoulders = SCNNode(geometry: SCNSphere(radius: 1.0))
            shoulders.scale = SCNVector3(1.42, 0.22, 0.46)
            shoulders.position = SCNVector3(0, -1.55, -0.02)
            shoulders.geometry?.materials = [softCyanMaterial(alpha: 0.07)]
            root.addChildNode(shoulders)

            return root
        }

        private func scalpGeometry(
            sensors: [(channel: Int, position: SIMD3<Double>, value: Double)],
            fixedScale: Double?
        ) -> SCNGeometry {
            let latSteps = 38
            let lonSteps = 76
            let scale = colorScale(values: sensors.map(\.value), fixedScale: fixedScale)
            var vertices: [SCNVector3] = []
            var normals: [SCNVector3] = []
            var triangleBins = Array(repeating: [Int32](), count: 33)

            for lat in 0...latSteps {
                let theta = Double(lat) / Double(latSteps) * Double.pi
                for lon in 0...lonSteps {
                    let phi = Double(lon) / Double(lonSteps) * Double.pi * 2
                    let unit = SIMD3<Double>(
                        sin(theta) * cos(phi),
                        sin(theta) * sin(phi),
                        cos(theta)
                    )
                    vertices.append(scenePoint(for: unit, radiusOffset: 0.018))
                    normals.append(SCNVector3(Float(unit.x), Float(unit.z), Float(unit.y)))
                }
            }

            for lat in 0..<latSteps {
                for lon in 0..<lonSteps {
                    let a = Int32(lat * (lonSteps + 1) + lon)
                    let b = Int32((lat + 1) * (lonSteps + 1) + lon)
                    let c = Int32((lat + 1) * (lonSteps + 1) + lon + 1)
                    let d = Int32(lat * (lonSteps + 1) + lon + 1)

                    let centerUnit = unitVector(lat: Double(lat) + 0.5, lon: Double(lon) + 0.5, latSteps: latSteps, lonSteps: lonSteps)
                    let value = interpolatedValue(at: centerUnit, sensors: sensors)
                    let bin = colorBin(normalized: normalized(value, scale: scale))
                    triangleBins[bin].append(contentsOf: [a, b, c, a, c, d])
                }
            }

            let elements = triangleBins.map { indices in
                SCNGeometryElement(indices: indices, primitiveType: .triangles)
            }
            let geometry = SCNGeometry(
                sources: [
                    SCNGeometrySource(vertices: vertices),
                    SCNGeometrySource(normals: normals)
                ],
                elements: elements
            )
            geometry.materials = (0..<triangleBins.count).map { index in
                let t = (Double(index) / Double(triangleBins.count - 1)) * 2 - 1
                let material = SCNMaterial()
                material.diffuse.contents = nsColor(for: t).withAlphaComponent(0.82)
                material.emission.contents = nsColor(for: t).withAlphaComponent(0.10)
                material.transparency = 0.82
                material.isDoubleSided = true
                return material
            }
            return geometry
        }

        private func rebuildElectrodes(
            sensors: [(channel: Int, position: SIMD3<Double>, value: Double)],
            fixedScale: Double?,
            channelName: (Int) -> String
        ) {
            electrodesNode.childNodes.forEach { $0.removeFromParentNode() }
            let scale = colorScale(values: sensors.map(\.value), fixedScale: fixedScale)

            for sensor in sensors {
                let sphere = SCNSphere(radius: 0.018)
                sphere.segmentCount = 12
                let material = SCNMaterial()
                material.diffuse.contents = NSColor(calibratedRed: 0.70, green: 0.98, blue: 1.0, alpha: 1)
                material.emission.contents = nsColor(for: normalized(sensor.value, scale: scale)).withAlphaComponent(0.55)
                sphere.materials = [material]

                let node = SCNNode(geometry: sphere)
                node.name = channelName(sensor.channel)
                node.position = scenePoint(for: sensor.position, radiusOffset: 0.055)
                electrodesNode.addChildNode(node)
            }
        }

        private func colorScale(values: [Double], fixedScale: Double?) -> Double {
            if let fixedScale, fixedScale > 0 { return fixedScale }
            let maxAbs = values.map(abs).max() ?? 1
            return max(maxAbs, 1)
        }

        private func normalized(_ value: Double, scale: Double) -> Double {
            guard value.isFinite, scale > 0 else { return 0 }
            return max(-1, min(1, value / scale))
        }

        private func interpolatedValue(
            at location: SIMD3<Double>,
            sensors: [(channel: Int, position: SIMD3<Double>, value: Double)]
        ) -> Double {
            guard !sensors.isEmpty else { return 0 }
            var weightedSum = 0.0
            var weightTotal = 0.0

            for sensor in sensors {
                let distance = max(1e-4, simd_distance(location, sensor.position))
                if distance < 0.035 { return sensor.value }
                let weight = 1.0 / pow(distance, 3.0)
                weightedSum += sensor.value * weight
                weightTotal += weight
            }

            return weightTotal > 0 ? weightedSum / weightTotal : 0
        }

        private func unitVector(lat: Double, lon: Double, latSteps: Int, lonSteps: Int) -> SIMD3<Double> {
            let theta = lat / Double(latSteps) * Double.pi
            let phi = lon / Double(lonSteps) * Double.pi * 2
            return SIMD3<Double>(
                sin(theta) * cos(phi),
                sin(theta) * sin(phi),
                cos(theta)
            )
        }

        private func scenePoint(for unit: SIMD3<Double>, radiusOffset: Double) -> SCNVector3 {
            SCNVector3(
                Float(unit.x * (0.92 + radiusOffset)),
                Float(unit.z * (1.14 + radiusOffset)),
                Float(unit.y * (0.98 + radiusOffset))
            )
        }

        private func colorBin(normalized: Double) -> Int {
            let clamped = max(-1, min(1, normalized))
            return Int(((clamped + 1) / 2 * 32).rounded())
        }

        private func nsColor(for normalized: Double) -> NSColor {
            let t = max(-1, min(1, normalized))
            let cold = SIMD3<Double>(0.16, 0.45, 0.95)
            let mid = SIMD3<Double>(0.90, 0.98, 1.00)
            let warm = SIMD3<Double>(1.00, 0.24, 0.18)
            let rgb: SIMD3<Double>
            if t < 0 {
                rgb = cold + (mid - cold) * (t + 1)
            } else {
                rgb = mid + (warm - mid) * t
            }
            return NSColor(calibratedRed: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
        }

        private func softCyanMaterial(alpha: CGFloat) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedRed: 0.20, green: 0.86, blue: 1.0, alpha: alpha)
            material.emission.contents = NSColor(calibratedRed: 0.02, green: 0.24, blue: 0.34, alpha: alpha)
            material.transparency = alpha
            material.isDoubleSided = true
            return material
        }
    }
}
