//
//  NIfTIPreviewModel.swift
//  EVAPreviewKit
//

import Foundation

nonisolated struct NIfTISlice: Sendable, Identifiable {
    enum Plane: String, Sendable {
        case axial = "Axial"
        case coronal = "Coronal"
        case sagittal = "Sagittal"
    }

    let plane: Plane
    let width: Int
    let height: Int
    let horizontalSpacing: Double
    let verticalSpacing: Double
    let values: [Double]
    let leftLabel: String
    let rightLabel: String
    let topLabel: String
    let bottomLabel: String

    var id: Plane { plane }

    var physicalAspectRatio: Double {
        let widthMM = Double(width) * max(abs(horizontalSpacing), 1e-9)
        let heightMM = Double(height) * max(abs(verticalSpacing), 1e-9)
        guard widthMM.isFinite, heightMM.isFinite, heightMM > 0 else {
            return Double(width) / Double(max(height, 1))
        }
        return widthMM / heightMM
    }
}

nonisolated struct NIfTIIntensityWindow: Sendable {
    let minimum: Double
    let maximum: Double

    static func make(header: NIfTIHeader, slices: [NIfTISlice]) -> NIfTIIntensityWindow {
        if let minimum = header.calibrationMinimum,
           let maximum = header.calibrationMaximum,
           minimum.isFinite, maximum.isFinite, maximum > minimum {
            return NIfTIIntensityWindow(minimum: minimum, maximum: maximum)
        }

        return make(slices: slices)
    }

    static func make(slices: [NIfTISlice]) -> NIfTIIntensityWindow {
        let finite = slices.flatMap(\.values).filter(\.isFinite)
        guard !finite.isEmpty else { return NIfTIIntensityWindow(minimum: 0, maximum: 1) }
        let sampleLimit = 100_000
        let sample: [Double]
        if finite.count <= sampleLimit { sample = finite }
        else {
            let step = Double(finite.count - 1) / Double(sampleLimit - 1)
            sample = (0..<sampleLimit).map { finite[Int((Double($0) * step).rounded(.down))] }
        }
        let sorted = sample.sorted()
        let low = sorted[Int(Double(sorted.count - 1) * 0.02)]
        let high = sorted[Int(Double(sorted.count - 1) * 0.98)]
        if high > low { return NIfTIIntensityWindow(minimum: low, maximum: high) }
        let padding = max(abs(low) * 0.01, 0.5)
        return NIfTIIntensityWindow(minimum: low - padding, maximum: high + padding)
    }
}

nonisolated struct NIfTIPreviewModel: Sendable {
    let url: URL
    let header: NIfTIHeader
    let slices: [NIfTISlice]
    let intensityWindow: NIfTIIntensityWindow
    let byteSize: Int64
    let isCompressed: Bool

    var displayName: String { url.lastPathComponent }

    var dimensionsText: String {
        var values = [header.width, header.height, header.depth]
        if header.volumeCount > 1 { values.append(header.volumeCount) }
        return values.map(String.init).joined(separator: " × ")
    }

    var voxelSizeText: String {
        let values = (1...3).map { index -> String in
            let value = abs(header.pixelDimensions[safe: index] ?? 1)
            return value.formatted(.number.precision(.fractionLength(0...3)))
        }
        let unit = header.spatialUnit.map { " \($0)" } ?? ""
        return values.joined(separator: " × ") + unit
    }

    var timeResolutionText: String? {
        guard header.volumeCount > 1,
              let value = header.pixelDimensions[safe: 4], value.isFinite, value != 0 else { return nil }
        let unit = header.temporalUnit.map { " \($0)" } ?? ""
        return abs(value).formatted(.number.precision(.fractionLength(0...4))) + unit
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
