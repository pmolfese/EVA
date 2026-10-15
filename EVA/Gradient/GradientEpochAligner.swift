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
//  Two properties of a real gradient artifact shape how the search is bounded
//  and how the sub-sample offset is estimated:
//
//  - A volume's artifact is a train of near-identical slice artifacts. Shifted
//    by one slice period it correlates with itself almost as well as it does
//    unshifted, and with a non-integer slice period the neighbouring slice can
//    even win on sub-sample phase. The default search radius is therefore kept
//    below half the lag at which the waveform first resembles itself again, so
//    an epoch can never lock onto its neighbouring slice.
//  - The artifact is sharp at EEG sampling rates, so the correlation peak spans
//    only a sample or two and a parabola through three integer lags is a biased
//    estimate of where it sits. The sub-sample offset is instead read from the
//    cross-correlation interpolated with the same windowed-sinc kernel the
//    corrector later shifts the epoch with.
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

    /// A lag at which the reference correlates with itself at least this well,
    /// once its central peak has fallen below it, counts as the artifact
    /// repeating — a slice period on volume epochs.
    static let repeatCorrelationThreshold = 0.5

    /// Resolution of the grid the interpolated cross-correlation is searched on,
    /// in steps per sample, before a final parabolic polish.
    private static let subSampleGridSteps = 32

    /// The period-only bound on the search radius: 5% of the artifact period,
    /// capped so the search stays cheap and cannot wander into the neighbouring
    /// artifact.
    static func defaultSearchRadius(period: Int) -> Int {
        max(1, min(64, period / 20))
    }

    /// The search radius used when the caller does not specify one.
    ///
    /// Starts from the period-only bound, then keeps the radius below half the
    /// lag at which the artifact first repeats (`repeatLag`). On slice-level
    /// epochs that lag is past the period bound and changes nothing. On volume
    /// epochs it is the slice period — 36.6 samples for 41 slices in a 3 s TR at
    /// 500 Hz, against a period bound of 64 — and without the cap the search
    /// reaches the neighbouring slice.
    static func defaultSearchRadius(referenceSignal: [Float], layout: GradientEpochLayout) -> Int {
        let bound = defaultSearchRadius(period: layout.period)
        guard let start = (0..<layout.count).lazy
            .compactMap({ layout.windowStart(of: $0) })
            .first,
              let lag = repeatLag(
                of: Array(referenceSignal[start..<(start + layout.length)]),
                maximumLag: 2 * bound + 1
              )
        else { return bound }
        return max(1, min(bound, (lag - 1) / 2))
    }

    /// The smallest lag at which `window` correlates with itself at least
    /// `repeatCorrelationThreshold` well after the central peak has dropped
    /// below that level, or nil when it does not repeat within `maximumLag`.
    ///
    /// The lag returned is a local maximum of the correlation, so it names where
    /// the repeat peaks rather than where it first crosses the threshold.
    static func repeatLag(of window: [Float], maximumLag: Int) -> Int? {
        let count = window.count
        let limit = min(maximumLag, count / 2)
        guard limit >= 2 else { return nil }

        var correlations = [Double](repeating: 1, count: limit + 2)
        window.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for lag in 1...min(limit + 1, count - 2) {
                correlations[lag] = GradientDonorSelection.pearsonCorrelation(
                    base, base + lag, count: count - lag
                )
            }
        }

        var leftCentralPeak = false
        for lag in 1...limit {
            let value = correlations[lag]
            if !leftCentralPeak {
                if value < repeatCorrelationThreshold { leftCentralPeak = true }
                continue
            }
            if value >= repeatCorrelationThreshold,
               value >= correlations[lag - 1],
               value >= correlations[lag + 1] {
                return lag
            }
        }
        return nil
    }

    /// Estimates per-epoch alignment against a reference artifact shape.
    ///
    /// Two passes: the first aligns every epoch to the earliest in-bounds epoch,
    /// then the reference is rebuilt as the average of the aligned early epochs
    /// and every epoch is aligned again. Averaging the reference makes the
    /// estimate robust to the first epoch happening to be atypical. When
    /// sub-sample offsets are estimated, the rebuilt reference is assembled from
    /// epochs moved onto their sub-sample phase too, so it stays as sharp as a
    /// single epoch instead of blurring over the spread of phases.
    ///
    /// The integer shift maximizes Pearson correlation of mean-removed windows,
    /// per the functional spec. The sub-sample offset is the peak of the
    /// cross-correlation between the epoch and the (mean-removed) reference,
    /// interpolated between integer lags with the fractional-delay kernel, which
    /// is exactly the correlation of the reference with the epoch shifted by that
    /// kernel. A parabola through the three Pearson values around the best
    /// integer shift is the fallback for a window too short to interpolate in.
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
                var fraction = 0.0
                if estimatesSubSample {
                    if let start = layout.windowStart(of: epoch, shift: bestShift),
                       let offset = interpolatedPeakOffset(
                        referenceSignal: referenceSignal,
                        reference: reference,
                        start: start
                       ) {
                        fraction = offset
                        // The interpolated peak may sit more than half a sample
                        // from the integer Pearson winner; hand the whole sample
                        // to the integer shift when that shift is allowed.
                        let step = offset > 0.5 ? 1 : (offset < -0.5 ? -1 : 0)
                        if step != 0,
                           abs(bestShift + step) <= searchRadius,
                           layout.windowStart(of: epoch, shift: bestShift + step) != nil {
                            bestShift += step
                            fraction -= Double(step)
                        }
                        fraction = min(max(fraction, -0.5), 0.5)
                    } else {
                        fraction = subSampleOffset(
                            before: scores[bestShift - 1],
                            peak: scores[bestShift],
                            after: scores[bestShift + 1]
                        )
                    }
                }
                integerShifts[epoch] = bestShift
                fractionalShifts[epoch] = fraction
            }

            // Rebuild the reference from the epochs as now aligned.
            var accumulator = [Double](repeating: 0, count: length)
            var used = 0
            for epoch in 0..<epochCount {
                guard used < referenceEpochCap else { break }
                guard let start = layout.windowStart(of: epoch, shift: integerShifts[epoch]) else { continue }
                var window = Array(referenceSignal[start..<(start + length)])
                if abs(fractionalShifts[epoch]) > 1e-9 {
                    window = GradientSincResampler.fractionalDelay(window, by: -fractionalShifts[epoch])
                }
                var total = 0.0
                for value in window { total += Double(value) }
                let mean = total / Double(length)
                for index in 0..<length { accumulator[index] += Double(window[index]) - mean }
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

    /// Where, relative to the window starting at `start`, the cross-correlation
    /// between the signal and `reference` peaks, searched over one sample either
    /// side. Nil when the window is too short to leave an interior.
    ///
    /// Only the window's interior — `delayLobes + 1` samples in from each end —
    /// enters the cross products, so every lag the interpolation kernel needs
    /// reads inside the window itself. That keeps the estimate available for an
    /// epoch at the very start or end of the recording, where the neighbouring
    /// lags have no data. `reference` must be mean-removed; the signal's own
    /// mean then drops out of every cross product, so no per-lag re-centring is
    /// needed.
    static func interpolatedPeakOffset(
        referenceSignal: [Float],
        reference: [Float],
        start: Int
    ) -> Double? {
        let lobes = GradientSincResampler.delayLobes
        let length = reference.count
        let margin = lobes + 1
        guard length > 2 * margin + 2,
              start >= 0, start + length <= referenceSignal.count
        else { return nil }

        // products[k] is the cross product at lag k - lobes, for lags
        // -lobes...lobes + 1: every tap interpolation over [-1, 1] touches.
        var products = [Double](repeating: 0, count: 2 * lobes + 2)
        for slot in products.indices {
            let base = start + slot - lobes
            var total = 0.0
            for index in margin..<(length - margin) {
                total += Double(referenceSignal[base + index]) * Double(reference[index])
            }
            products[slot] = total
        }

        // Cross-correlation at offset `tau`, interpolated from the integer lags
        // with the same normalized kernel the fractional delay uses.
        func interpolated(_ tau: Double) -> Double {
            let base = Int(tau.rounded(.down))
            var total = 0.0
            var weights = 0.0
            for lag in (base - lobes + 1)...(base + lobes) {
                let weight = GradientSincResampler.kernel(tau - Double(lag), lobes: lobes)
                total += weight * products[lag + lobes]
                weights += weight
            }
            return abs(weights) > 1e-12 ? total / weights : total
        }

        let steps = subSampleGridSteps
        var values = [Double](repeating: 0, count: 2 * steps + 1)
        var best = 0
        for k in 0...(2 * steps) {
            values[k] = interpolated(Double(k - steps) / Double(steps))
            if values[k] > values[best] { best = k }
        }
        var offset = Double(best - steps) / Double(steps)
        if best > 0, best < 2 * steps {
            offset += subSampleOffset(
                before: values[best - 1], peak: values[best], after: values[best + 1]
            ) / Double(steps)
        }
        return offset.isFinite ? offset : nil
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
