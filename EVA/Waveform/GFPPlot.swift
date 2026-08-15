//
//  GFPPlot.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Global Field Power: the across-channel standard deviation at each time
//  point, i.e. "how much is happening" independent of scalp location — the
//  standard summary trace shown under a butterfly plot. One `GFPStripView`
//  draws one trace per segment, same x-axis mapping as `OverlayButterflyPlot`
//  (no left margin, linear over the epoch), so it lines up underneath it.
//

import SwiftUI

nonisolated enum GFPMath {
    /// One GFP value per sample of `segment`'s epoch window: the population
    /// standard deviation across channels at that sample.
    static func series(data: [[Float]], segment: EpochSegment) -> [Float] {
        let epochLength = max(segment.endSample - segment.startSample + 1, 1)
        guard epochLength > 1, !data.isEmpty else { return [] }
        var result = [Float](repeating: 0, count: epochLength)
        for localSample in 0..<epochLength {
            let sample = segment.startSample + localSample
            var sum: Float = 0
            var sumSquares: Float = 0
            var count = 0
            for channel in data {
                guard sample >= 0, sample < channel.count else { continue }
                let value = channel[sample]
                sum += value
                sumSquares += value * value
                count += 1
            }
            guard count > 0 else { continue }
            let mean = sum / Float(count)
            let variance = max(sumSquares / Float(count) - mean * mean, 0)
            result[localSample] = variance.squareRoot()
        }
        return result
    }
}

/// GFP trace(s) for one or more segments, sharing one y-scale (0 at the
/// bottom — GFP is non-negative) so multiple conditions are comparable.
struct GFPStripView: View {
    let data: [[Float]]
    let segments: [EpochSegment]
    let colors: [Color]

    var body: some View {
        Canvas { context, size in
            guard let first = segments.first else { return }
            let epochLength = max(first.endSample - first.startSample + 1, 1)
            guard epochLength > 1 else { return }
            let xScale = size.width / CGFloat(epochLength - 1)

            let series = segments.map { GFPMath.series(data: data, segment: $0) }
            let maxGFP = series.flatMap { $0 }.max() ?? 0
            guard maxGFP > 0 else { return }
            let yScale = (size.height * 0.92) / CGFloat(maxGFP)

            let stimulusX = CGFloat(first.stimulusOffsetSamples) * xScale
            var stimulus = Path()
            stimulus.move(to: CGPoint(x: stimulusX, y: 0))
            stimulus.addLine(to: CGPoint(x: stimulusX, y: size.height))
            context.stroke(stimulus, with: .color(.green.opacity(0.5)), lineWidth: 1)

            for (index, values) in series.enumerated() {
                guard !values.isEmpty else { continue }
                let color = index < colors.count ? colors[index] : .accentColor
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height - CGFloat(values[0]) * yScale))
                for sampleIndex in values.indices {
                    path.addLine(to: CGPoint(
                        x: CGFloat(sampleIndex) * xScale,
                        y: size.height - CGFloat(values[sampleIndex]) * yScale
                    ))
                }
                context.stroke(path, with: .color(color), lineWidth: 1.3)
            }
        }
        .overlay(alignment: .topLeading) {
            Text("GFP")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 2)
        }
    }
}
