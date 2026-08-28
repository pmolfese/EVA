//
//  GradientEpochAligner.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Independent implementation written from EVA's own functional specification
//  (docs/provenance/fastr-functional-spec.md) under the clean-room process
//  described in docs/provenance/README.md. No third-party artifact-correction source
//  was consulted.
//
//  Scanner triggers do not always land on the same sample of the artifact they
//  mark. Averaging misaligned epochs blurs the template and leaves residual
//  artifact behind, so each epoch gets a small integer shift — and optionally a
//  sub-sample offset — that maximizes its similarity to a common reference
//  artifact shape.
//
//  Alignment is estimated once from a single representative channel and applied
//  to every channel, which preserves cross-channel timing.
//

import Foundation

nonisolated struct GradientEpochAlignment: Sendable {
    /// Per-epoch integer shift, in upsampled samples.
    let integerShifts: [Int]
    /// Per-epoch residual sub-sample offset in (-0.5, 0.5). Zero unless
    /// sub-sample alignment was requested.
    let fractionalShifts: [Double]

    static func identity(epochCount: Int) -> GradientEpochAlignment {
        GradientEpochAlignment(
            integerShifts: [Int](repeating: 0, count: epochCount),
            fractionalShifts: [Double](repeating: 0, count: epochCount)
        )
    }
}

nonisolated enum GradientEpochAligner {

    /// Epochs contributing to the rebuilt reference shape after each pass.
    private static let referenceEpochCap = 16

    /// A sensible search radius when the caller does not specify one: 5% of the
    /// artifact period, bounded so the search stays cheap and cannot wander into
    /// the neighboring artifact.
    static func defaultSearchRadius(period: Int) -> Int {
        max(1, min(64, period / 20))
    }

    /// Estimates per-epoch alignment against a reference artifact shape.
    ///
    /// Two passes: the first aligns every epoch to the earliest in-bounds epoch,
    /// then the reference is rebuilt as the average of the aligned early epochs
    /// and every epoch is aligned again. Averaging the reference makes the
    /// estimate robust to the first epoch happening to be atypical.
    ///
    /// Similarity is Pearson correlation of mean-removed windows, per the
    /// functional spec. The sub-sample offset comes from fitting a parabola to
    /// the correlation values on either side of the best integer shift.
    static func align(
        referenceSignal: [Float],
        layout: GradientEpochLayout,
        searchRadius: Int,
        estimatesSubSample: Bool,
        passes: Int = 2
    ) -> GradientEpochAlignment {
        let epochCount = layout.count
        var integerShifts = [Int](repeating: 0, count: epochCount)
        var fractionalShifts = [Double](repeating: 0, count: epochCount)
        guard searchRadius > 0, epochCount > 0 else {
            return GradientEpochAlignment(
                integerShifts: integerShifts,
                fractionalShifts: fractionalShifts
            )
        }

        let length = layout.length

        func meanRemovedWindow(at start: Int) -> [Float] {
            var window = Array(referenceSignal[start..<(start + length)])
            var total = 0.0
            for value in window { total += Double(value) }
            let mean = Float(total / Double(length))
            for index in window.indices { window[index] -= mean }
            return window
        }

        guard let firstStart = (0..<epochCount).lazy
            .compactMap({ layout.windowStart(of: $0) })
            .first
        else {
            return GradientEpochAlignment(
                integerShifts: integerShifts,
                fractionalShifts: fractionalShifts
            )
        }
        var reference = meanRemovedWindow(at: firstStart)

        for _ in 0..<max(1, passes) {
            for epoch in 0..<epochCount {
                var scores: [Int: Double] = [:]
                var bestShift = 0
                var bestScore = -Double.infinity

                for shift in -searchRadius...searchRadius {
                    guard let start = layout.windowStart(of: epoch, shift: shift) else { continue }
                    let score = GradientDonorSelection.pearsonCorrelation(
                        meanRemovedWindow(at: start),
                        reference
                    )
                    scores[shift] = score
                    if score > bestScore {
                        bestScore = score
                        bestShift = shift
                    }
                }

                guard bestScore > -Double.infinity else {
                    integerShifts[epoch] = 0
                    fractionalShifts[epoch] = 0
                    continue
                }
                integerShifts[epoch] = bestShift
                fractionalShifts[epoch] = estimatesSubSample
                    ? subSampleOffset(
                        before: scores[bestShift - 1],
                        peak: scores[bestShift],
                        after: scores[bestShift + 1]
                    )
                    : 0
            }

            // Rebuild the reference from the epochs as now aligned.
            var accumulator = [Double](repeating: 0, count: length)
            var used = 0
            for epoch in 0..<epochCount {
                guard used < referenceEpochCap else { break }
                guard let start = layout.windowStart(of: epoch, shift: integerShifts[epoch]) else { continue }
                let window = meanRemovedWindow(at: start)
                for index in 0..<length { accumulator[index] += Double(window[index]) }
                used += 1
            }
            if used > 0 {
                reference = accumulator.map { Float($0 / Double(used)) }
            }
        }

        return GradientEpochAlignment(
            integerShifts: integerShifts,
            fractionalShifts: fractionalShifts
        )
    }

    /// Vertex of the parabola through three correlation values one sample apart,
    /// clamped to half a sample. Returns 0 when a neighbor is missing (the peak
    /// sat at the edge of the search range) or the three points are collinear.
    static func subSampleOffset(before: Double?, peak: Double?, after: Double?) -> Double {
        guard let before, let peak, let after else { return 0 }
        let curvature = before - 2 * peak + after
        guard abs(curvature) > 1e-12 else { return 0 }
        let offset = 0.5 * (before - after) / curvature
        guard offset.isFinite else { return 0 }
        return min(max(offset, -0.5), 0.5)
    }
}
