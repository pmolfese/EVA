//
//  CIFTIMatrixRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import Foundation

nonisolated enum CIFTIMatrixRenderer {
    static func image(for model: CIFTIPreviewModel) -> CGImage? {
        let sample = model.sample
        guard sample.width > 0, sample.height > 0,
              sample.values.count == sample.width * sample.height else { return nil }
        var pixels = [UInt8](repeating: 0, count: sample.values.count * 4)

        for row in 0..<sample.height {
            for column in 0..<sample.width {
                let value = sample.values[row * sample.width + column]
                let color = model.isLabelData
                    ? labelColor(value: value, column: column, model: model)
                    : continuousColor(value: value, window: sample.window)
                let offset = (row * sample.width + column) * 4
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: sample.width,
            height: sample.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: sample.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func continuousColor(
        value: Double,
        window: ClosedRange<Double>
    ) -> (UInt8, UInt8, UInt8) {
        guard value.isFinite else { return (54, 58, 61) }
        let span = max(window.upperBound - window.lowerBound, Double.leastNonzeroMagnitude)
        let t = min(max((value - window.lowerBound) / span, 0), 1)
        if window.lowerBound < 0, window.upperBound > 0 {
            let zero = min(max(-window.lowerBound / span, 0), 1)
            if t <= zero {
                let p = zero > 0 ? t / zero : 1
                return rgb(
                    0.10 + 0.80 * p,
                    0.26 + 0.64 * p,
                    0.78 + 0.12 * p
                )
            }
            let p = zero < 1 ? (t - zero) / (1 - zero) : 1
            return rgb(0.90 + 0.08 * p, 0.90 - 0.70 * p, 0.90 - 0.76 * p)
        }
        // Compact viridis-like ramp that stays legible on the dark canvas.
        let stops: [(Double, Double, Double)] = [
            (0.12, 0.07, 0.33), (0.12, 0.35, 0.54),
            (0.18, 0.59, 0.49), (0.55, 0.78, 0.30), (0.98, 0.90, 0.14)
        ]
        let position = t * Double(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        let fraction = position - Double(index)
        let a = stops[index], b = stops[index + 1]
        return rgb(
            a.0 + (b.0 - a.0) * fraction,
            a.1 + (b.1 - a.1) * fraction,
            a.2 + (b.2 - a.2) * fraction
        )
    }

    private static func labelColor(
        value: Double,
        column: Int,
        model: CIFTIPreviewModel
    ) -> (UInt8, UInt8, UInt8) {
        guard value.isFinite else { return (54, 58, 61) }
        let key = Int(value.rounded())
        if model.mapping(for: 0)?.type == .labels,
           model.sample.sourceColumns.indices.contains(column) {
            let mapIndex = model.sample.sourceColumns[column]
            if model.labelMaps.indices.contains(mapIndex),
               let label = model.labelMaps[mapIndex].labels.first(where: { $0.key == key }),
               let red = label.red, let green = label.green, let blue = label.blue {
                return rgb(red, green, blue)
            }
        }
        // Deterministic categorical color when a label table/color is absent.
        let hue = Double(UInt64(bitPattern: Int64(key)) &* 2_654_435_761 % 360) / 360
        return hsv(hue: hue, saturation: 0.62, value: key == 0 ? 0.22 : 0.90)
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> (UInt8, UInt8, UInt8) {
        let h = hue * 6
        let sector = Int(floor(h)) % 6
        let fraction = h - floor(h)
        let p = value * (1 - saturation)
        let q = value * (1 - fraction * saturation)
        let t = value * (1 - (1 - fraction) * saturation)
        switch sector {
        case 0: return rgb(value, t, p)
        case 1: return rgb(q, value, p)
        case 2: return rgb(p, value, t)
        case 3: return rgb(p, q, value)
        case 4: return rgb(t, p, value)
        default: return rgb(value, p, q)
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> (UInt8, UInt8, UInt8) {
        func channel(_ value: Double) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        return (channel(red), channel(green), channel(blue))
    }
}
