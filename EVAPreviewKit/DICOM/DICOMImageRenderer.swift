//
//  DICOMImageRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import Foundation
import ImageIO

nonisolated enum DICOMImageRenderer {
    static func image(for pixelImage: DICOMPixelImage) -> CGImage? {
        switch pixelImage {
        case .grayscale(let width, let height, let values, let window, let inverted):
            guard width > 0, height > 0, values.count == width * height else { return nil }
            let range = max(window.maximum - window.minimum, Double.leastNonzeroMagnitude)
            var pixels = [UInt8](repeating: 0, count: values.count)
            for index in values.indices {
                let value = values[index]
                var normalized = value.isFinite ? (value - window.minimum) / range : 0
                normalized = min(max(normalized, 0), 1)
                if inverted { normalized = 1 - normalized }
                pixels[index] = UInt8((normalized * 255).rounded())
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        case .rgb(let width, let height, let bytes):
            guard width > 0, height > 0, bytes.count == width * height * 3,
                  let provider = CGDataProvider(data: bytes as CFData) else { return nil }
            return CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        case .encoded(_, _, let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }
}
