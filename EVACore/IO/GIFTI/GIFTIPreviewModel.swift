//
//  GIFTIPreviewModel.swift
//  EVAPreviewKit
//

import Foundation

nonisolated struct GIFTIPoint: Sendable, Equatable {
    var x: Float
    var y: Float
    var z: Float
}

nonisolated struct GIFTITriangle: Sendable, Equatable {
    let a: UInt32
    let b: UInt32
    let c: UInt32
}

nonisolated struct GIFTILabel: Sendable, Equatable {
    let key: Int
    let name: String
    let red: Float?
    let green: Float?
    let blue: Float?
    let alpha: Float?
}

nonisolated struct GIFTIDataArraySummary: Sendable, Equatable {
    let intent: String
    let dataType: String
    let dimensions: [Int]
    let encoding: String
    let metadata: [String: String]

    var dimensionsText: String {
        dimensions.map(String.init).joined(separator: " × ")
    }

    var intentDisplayName: String {
        intent
            .replacingOccurrences(of: "NIFTI_INTENT_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

nonisolated struct GIFTIScalarOverlay: Sendable {
    let name: String
    let intent: String
    let values: [Double]
    let window: ClosedRange<Double>?
}

nonisolated struct GIFTIPreviewModel: Sendable {
    let url: URL
    let version: String
    let metadata: [String: String]
    let arrays: [GIFTIDataArraySummary]
    let labels: [Int: GIFTILabel]
    let vertices: [GIFTIPoint]
    let triangles: [GIFTITriangle]
    let overlays: [GIFTIScalarOverlay]
    let sharedOverlayWindow: ClosedRange<Double>?
    let coordinateSpace: String?
    let byteSize: Int64
    let companionSurfaceName: String?

    var displayName: String { url.lastPathComponent }
    var vertexCount: Int { vertices.count }
    var triangleCount: Int { triangles.count }
    var hasRenderableGeometry: Bool { !vertices.isEmpty }
    var overlay: GIFTIScalarOverlay? { overlays.first }

    func displayOverlay(at index: Int) -> GIFTIScalarOverlay? {
        guard overlays.indices.contains(index) else { return overlay }
        let selected = overlays[index]
        guard let sharedOverlayWindow,
              selected.intent == "NIFTI_INTENT_TIME_SERIES" else {
            return selected
        }
        return selected.using(window: sharedOverlayWindow)
    }

    var fileKind: String {
        if companionSurfaceName != nil {
            if arrays.contains(where: { $0.intent == "NIFTI_INTENT_TIME_SERIES" }) { return "Functional Overlay" }
            if arrays.contains(where: { $0.intent == "NIFTI_INTENT_LABEL" }) { return "Label Overlay" }
            if arrays.contains(where: { $0.intent == "NIFTI_INTENT_SHAPE" }) { return "Shape Overlay" }
            return "Surface Overlay"
        }
        if !vertices.isEmpty && !triangles.isEmpty { return "Surface" }
        if !vertices.isEmpty { return "Coordinates" }
        if arrays.contains(where: { $0.intent == "NIFTI_INTENT_LABEL" }) { return "Labels" }
        if arrays.contains(where: { $0.intent == "NIFTI_INTENT_SHAPE" }) { return "Shape" }
        if arrays.contains(where: { $0.intent == "NIFTI_INTENT_TIME_SERIES" }) { return "Time Series" }
        if !triangles.isEmpty { return "Topology" }
        return "Surface Data"
    }

    var anatomicalStructure: String? {
        arrays.first(where: { $0.intent == "NIFTI_INTENT_POINTSET" })?
            .metadata["AnatomicalStructurePrimary"]
    }

    func attachingGeometry(from surface: GIFTIPreviewModel) -> GIFTIPreviewModel {
        GIFTIPreviewModel(
            url: url,
            version: version,
            metadata: metadata,
            arrays: arrays,
            labels: labels,
            vertices: surface.vertices,
            triangles: surface.triangles,
            overlays: overlays,
            sharedOverlayWindow: sharedOverlayWindow,
            coordinateSpace: surface.coordinateSpace,
            byteSize: byteSize,
            companionSurfaceName: surface.displayName
        )
    }

    var geometricType: String? {
        arrays.first(where: { $0.intent == "NIFTI_INTENT_POINTSET" })?
            .metadata["GeometricType"]
            ?? arrays.first(where: { $0.intent == "NIFTI_INTENT_POINTSET" })?
                .metadata["AnatomicalStructureSecondary"]
    }

    var boundsText: String? {
        guard let first = vertices.first else { return nil }
        var minimum = first
        var maximum = first
        for point in vertices.dropFirst() {
            minimum.x = min(minimum.x, point.x)
            minimum.y = min(minimum.y, point.y)
            minimum.z = min(minimum.z, point.z)
            maximum.x = max(maximum.x, point.x)
            maximum.y = max(maximum.y, point.y)
            maximum.z = max(maximum.z, point.z)
        }
        let x = Double(maximum.x - minimum.x).formatted(.number.precision(.fractionLength(0...1)))
        let y = Double(maximum.y - minimum.y).formatted(.number.precision(.fractionLength(0...1)))
        let z = Double(maximum.z - minimum.z).formatted(.number.precision(.fractionLength(0...1)))
        return "\(x) × \(y) × \(z) mm"
    }
}

nonisolated extension GIFTIScalarOverlay {
    static func make(name: String, intent: String, values: [Double]) -> GIFTIScalarOverlay {
        GIFTIScalarOverlay(name: name, intent: intent, values: values, window: robustWindow(values))
    }

    static func sharedWindow(for overlays: [GIFTIScalarOverlay]) -> ClosedRange<Double>? {
        guard overlays.count > 1,
              overlays.allSatisfy({ $0.intent == "NIFTI_INTENT_TIME_SERIES" }) else {
            return nil
        }
        return robustWindow(overlays.flatMap(\.values))
    }

    func using(window: ClosedRange<Double>) -> GIFTIScalarOverlay {
        GIFTIScalarOverlay(name: name, intent: intent, values: values, window: window)
    }

    private static func robustWindow(_ values: [Double]) -> ClosedRange<Double>? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else {
            return nil
        }
        let sampleLimit = 100_000
        let sample: [Double]
        if finite.count <= sampleLimit {
            sample = finite
        } else {
            let step = Double(finite.count - 1) / Double(sampleLimit - 1)
            sample = (0..<sampleLimit).map { finite[Int(Double($0) * step)] }
        }
        let sorted = sample.sorted()
        let low = sorted[Int(Double(sorted.count - 1) * 0.02)]
        let high = sorted[Int(Double(sorted.count - 1) * 0.98)]
        return high > low ? low...high : (low - 0.5)...(high + 0.5)
    }
}
