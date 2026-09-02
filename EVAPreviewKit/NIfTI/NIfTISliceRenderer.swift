//
//  NIfTISliceRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import Foundation

nonisolated enum NIfTISliceRenderer {
    static func image(for slice: NIfTISlice, window: NIfTIIntensityWindow) -> CGImage? {
        guard slice.width > 0, slice.height > 0,
              slice.values.count == slice.width * slice.height else { return nil }
        let range = max(window.maximum - window.minimum, Double.leastNonzeroMagnitude)
        var pixels = [UInt8](repeating: 0, count: slice.values.count)

        // Reader output is canonical RAS+: row indices increase toward anterior
        // or superior, while raster rows increase downward. Reverse once here so
        // anatomical positive is at the top for every consumer.
        for outputY in 0..<slice.height {
            let sourceY = slice.height - outputY - 1
            for x in 0..<slice.width {
                let value = slice.values[sourceY * slice.width + x]
                let normalized = value.isFinite ? (value - window.minimum) / range : 0
                pixels[outputY * slice.width + x] = UInt8(
                    (min(max(normalized, 0), 1) * 255).rounded()
                )
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: slice.width,
            height: slice.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: slice.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
