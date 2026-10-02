//
//  NIfTISliceRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import Foundation

nonisolated enum NIfTISliceRenderer {
    static func image(
        for slice: NIfTISlice,
        window: NIfTIIntensityWindow,
        displayMode: NIfTIDisplayMode = .intensity
    ) -> CGImage? {
        guard slice.width > 0, slice.height > 0,
              slice.values.count == slice.width * slice.height else { return nil }
        if displayMode.isLabelMap {
            return labelImage(for: slice)
        }
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

    private static func labelImage(for slice: NIfTISlice) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: slice.values.count * 3)
        for outputY in 0..<slice.height {
            let sourceY = slice.height - outputY - 1
            for x in 0..<slice.width {
                let value = slice.values[sourceY * slice.width + x]
                let label = value.isFinite && abs(value) < 9e18 ? Int64(value.rounded()) : 0
                let color = color(forLabel: label)
                let offset = (outputY * slice.width + x) * 3
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: slice.width,
            height: slice.height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: slice.width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func color(forLabel label: Int64) -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard label != 0 else { return (0, 0, 0) }
        var hash = UInt64(bitPattern: label)
        hash ^= hash >> 30
        hash &*= 0xbf58476d1ce4e5b9
        hash ^= hash >> 27
        hash &*= 0x94d049bb133111eb
        hash ^= hash >> 31

        let hue = Double(hash & 0xffff) / 65_536
        let saturation = 0.66 + Double((hash >> 16) & 0xff) / 255 * 0.18
        let value = 0.82 + Double((hash >> 24) & 0xff) / 255 * 0.16
        return rgb(hue: hue, saturation: saturation, value: value)
    }

    private static func rgb(
        hue: Double,
        saturation: Double,
        value: Double
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let scaledHue = hue * 6
        let sector = Int(scaledHue.rounded(.down)) % 6
        let fraction = scaledHue - scaledHue.rounded(.down)
        let p = value * (1 - saturation)
        let q = value * (1 - fraction * saturation)
        let t = value * (1 - (1 - fraction) * saturation)
        let components: (Double, Double, Double)
        switch sector {
        case 0: components = (value, t, p)
        case 1: components = (q, value, p)
        case 2: components = (p, value, t)
        case 3: components = (p, q, value)
        case 4: components = (t, p, value)
        default: components = (value, p, q)
        }
        return (
            UInt8((components.0 * 255).rounded()),
            UInt8((components.1 * 255).rounded()),
            UInt8((components.2 * 255).rounded())
        )
    }
}
