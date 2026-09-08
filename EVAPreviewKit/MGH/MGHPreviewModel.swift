//
//  MGHPreviewModel.swift
//  EVAPreviewKit
//

import Foundation

nonisolated struct MGHPreviewModel: Sendable {
    let url: URL
    let header: MGHHeader
    let slices: [NIfTISlice]
    let intensityWindow: NIfTIIntensityWindow
    let byteSize: Int64
    let isCompressed: Bool

    var displayName: String { url.lastPathComponent }
    var dimensionsText: String {
        var dimensions = [header.width, header.height, header.depth]
        if header.frameCount > 1 { dimensions.append(header.frameCount) }
        return dimensions.map(String.init).joined(separator: " × ")
    }
    var voxelSizeText: String {
        header.voxelSizes.map {
            $0.formatted(.number.precision(.fractionLength(0...3)))
        }.joined(separator: " × ") + " mm"
    }
}
