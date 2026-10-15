//
//  TrialAlignmentMetrics.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Similarity that survives a multi-peak ERP. See ROADMAP.md milestone TW-4.
//
//  A single correlation across a whole epoch is dominated by the largest
//  deflection: a trial with a textbook P1 and no P3 at all still scores well,
//  and a trial whose P3 is merely 60 ms late scores badly. Three answers, all
//  here:
//
//   * per-window scores — r and β computed inside named windows, so the number
//     refers to a component instead of an epoch;
//   * time-resolved r — a sliding correlation, which says WHERE a trial
//     diverges without having to guess windows first;
//   * affine alignment — fit
//     `trial ≈ gain · average(α · (t − anchor) + anchor − lag) + offset`, then
//     report what is LEFT OVER. Latency and amplitude become nuisance
//     parameters rather than reasons to fail a trial, and the residual after
//     the best fit is shape mismatch alone.
//
//  The affine residual is the one to reach for on a multi-peak ERP: a merely
//  late or merely small trial fits well and scores clean, so only genuinely
//  different shapes remain.
//

import Foundation

nonisolated enum TrialAlignmentMetrics {

    // MARK: - Windows

    /// A named span of the epoch, in milliseconds relative to stimulus onset.
    /// Free-form and user-editable — unlike RIDE's fixed S/C/R, a diagnostics
    /// window exists to point at whichever peak is being investigated.
    struct AnalysisWindow: Identifiable, Sendable, Equatable, Hashable {
        var id: UUID = UUID()
        var name: String
        var startMs: Double
        var endMs: Double

        var durationMs: Double { max(endMs - startMs, 0) }

        func sampleRange(stimulusOffsetSamples: Int, samplingRate: Double, length: Int) -> Range<Int>? {
            SingleTrialAnalyzer.sampleRange(
                startMs: startMs, endMs: endMs,
                stimulusOffsetSamples: stimulusOffsetSamples,
                samplingRate: samplingRate, length: length
            )
        }
    }

    struct WindowScore: Sendable, Equatable {
        var windowID: UUID
        var windowName: String
        var correlation: Double
        var slope: Double
        var normalizedResidualRMS: Double
    }

    /// r and β inside each window separately. Overlapping windows each see the
    /// full shared variance — see `componentRegression` for the version that
    /// splits it instead of double counting.
    static func windowScores(
        trial: [Double],
        reference: [Double],
        windows: [AnalysisWindow],
        stimulusOffsetSamples: Int,
        samplingRate: Double
    ) -> [WindowScore] {
        windows.compactMap { window in
            guard let range = window.sampleRange(
                stimulusOffsetSamples: stimulusOffsetSamples,
                samplingRate: samplingRate,
                length: min(trial.count, reference.count)
            ), range.count > 2 else { return nil }

            let trialSlice = Array(trial[range])
            let referenceSlice = Array(reference[range])
            let fit = TrialSimilarityAnalyzer.regression(of: trialSlice, on: referenceSlice)
            return WindowScore(
                windowID: window.id,
                windowName: window.name,
                correlation: fit.correlation,
                slope: fit.slope,
                normalizedResidualRMS: TrialSimilarityAnalyzer.normalizedResidualRMS(trialSlice, referenceSlice)
            )
        }
    }

    // MARK: - Time-resolved correlation

    struct TimeResolvedPoint: Identifiable, Sendable, Equatable {
        var id: Int
        var centerSample: Int
        var centerMs: Double
        var correlation: Double
    }

    /// Correlation inside a sliding window, one point per step.
    ///
    /// Good for choosing windows rather than guessing them: a trial that is fine
    /// early and falls apart late shows exactly where, and doing this across all
    /// trials makes a heatmap that says which part of the epoch is unstable.
    ///
    /// The window has to be long enough to hold a correlation at all — a few
    /// samples of a smooth waveform correlate near 1 with anything smooth.
    static func timeResolvedCorrelation(
        trial: [Double],
        reference: [Double],
        windowSamples: Int,
        stepSamples: Int = 1,
        stimulusOffsetSamples: Int,
        samplingRate: Double
    ) -> [TimeResolvedPoint] {
        let length = min(trial.count, reference.count)
        let width = max(windowSamples, 3)
        let step = max(stepSamples, 1)
        guard length > width, samplingRate > 0 else { return [] }

        var points: [TimeResolvedPoint] = []
        var start = 0
        var index = 0
        while start + width <= length {
            let range = start ..< (start + width)
            let fit = TrialSimilarityAnalyzer.regression(
                of: Array(trial[range]),
                on: Array(reference[range])
            )
            let center = start + width / 2
            points.append(
                TimeResolvedPoint(
                    id: index,
                    centerSample: center,
                    centerMs: Double(center - stimulusOffsetSamples) / samplingRate * 1000,
                    correlation: fit.correlation
                )
            )
            start += step
            index += 1
        }
        return points
    }

    // MARK: - Affine alignment

    struct AffineFit: Sendable, Equatable {
        /// Samples the average had to move to best match this trial. Positive
        /// means the trial is LATE.
        var lagSamples: Int
        var lagMs: Double
        /// Amplitude scaling. 1 means the trial matched the average's size.
        var gain: Double
        /// Additive offset — residual baseline the epoch's own correction left.
        var offset: Double
        /// Uniform time scaling (α). Values below 1 stretch/slacken the
        /// reference in the trial; values above 1 compress it. Scaling is
        /// anchored at stimulus onset by the diagnostics caller.
        var timeScale: Double
        /// Correlation at the best lag.
        var correlation: Double
        /// Normalised residual BEFORE any alignment: what plain similarity sees.
        var residualBefore: Double
        /// Normalised residual AFTER the best shift and scale. This is shape
        /// mismatch with latency and amplitude removed, and is the number worth
        /// ranking trials by on a multi-peak ERP.
        var residualAfter: Double

        /// How much bending the fit required: the latency shift and the gain
        /// departure, each relative to its own tolerance, combined.
        ///
        /// Reported beside `residualAfter` and never instead of it. A trial can
        /// fit beautifully after being dragged 80 ms and halved, and that is a
        /// finding, not a clean bill of health.
        var deformation: Double

        /// How much of the original mismatch the alignment explained, 0...1.
        var explainedByAlignment: Double {
            guard residualBefore > 1e-12 else { return 0 }
            return max(0, min(1, 1 - residualAfter / residualBefore))
        }
    }

    /// Fits
    /// `trial ≈ gain · reference(α · (t − anchor) + anchor − lag) + offset`
    /// by scanning bounded lag/time-scale pairs and solving gain and offset in
    /// closed form at each. Fractional reference samples use linear
    /// interpolation; only real overlap is scored.
    ///
    /// - Parameters:
    ///   - maxLagSamples: the search range. Keep it physiological — an
    ///     unconstrained search will always find *some* lag that fits, and the
    ///     residual stops meaning anything.
    ///   - maxTimeScaleDeviation: symmetric bound around α = 1. A value of 0.1
    ///     permits 0.9 ... 1.1. It is clamped to 0.25 so this diagnostic cannot
    ///     become an unconstrained warper.
    ///   - timeScaleAnchorSample: the fixed point for dilation. Pass stimulus
    ///     onset so pre/post-stimulus time does not drift together.
    ///   - lagToleranceSamples / gainTolerance / timeScaleTolerance: what
    ///     counts as "no real deformation", used only to scale the reported
    ///     `deformation`.
    static func affineFit(
        trial: [Double],
        reference: [Double],
        maxLagSamples: Int,
        samplingRate: Double,
        maxTimeScaleDeviation: Double = 0,
        timeScaleStep: Double = 0.01,
        timeScaleAnchorSample: Double? = nil,
        lagToleranceSamples: Double = 25,
        gainTolerance: Double = 0.5,
        timeScaleTolerance: Double = 0.05
    ) -> AffineFit? {
        let length = min(trial.count, reference.count)
        guard length > 4, samplingRate > 0 else { return nil }
        let limit = max(0, min(maxLagSamples, length / 3))
        let dilationLimit = min(max(abs(maxTimeScaleDeviation), 0), 0.25)
        let anchor = timeScaleAnchorSample ?? Double(length - 1) / 2
        let timeScales = timeScaleCandidates(limit: dilationLimit, step: timeScaleStep)

        let unshifted = TrialSimilarityAnalyzer.normalizedResidualRMS(
            Array(trial[0 ..< length]),
            Array(reference[0 ..< length])
        )

        var best: (
            lag: Int,
            gain: Double,
            offset: Double,
            timeScale: Double,
            correlation: Double,
            residual: Double,
            deformation: Double
        )?

        for timeScale in timeScales {
            for lag in -limit ... limit {
                // Sufficient statistics avoid allocating a pair of arrays for
                // every grid point. Samples outside the real reference are
                // skipped: no padding, and therefore no invented agreement.
                var count = 0
                var sumReference = 0.0
                var sumTrial = 0.0
                var sumReferenceSquared = 0.0
                var sumTrialSquared = 0.0
                var sumCross = 0.0

                for trialIndex in 0 ..< length {
                    let source = anchor
                        + timeScale * (Double(trialIndex) - anchor)
                        - Double(lag)
                    guard source >= 0, source <= Double(length - 1) else { continue }
                    let lower = Int(source.rounded(.down))
                    let upper = min(lower + 1, length - 1)
                    let fraction = source - Double(lower)
                    let referenceValue = reference[lower]
                        + fraction * (reference[upper] - reference[lower])
                    let trialValue = trial[trialIndex]

                    count += 1
                    sumReference += referenceValue
                    sumTrial += trialValue
                    sumReferenceSquared += referenceValue * referenceValue
                    sumTrialSquared += trialValue * trialValue
                    sumCross += referenceValue * trialValue
                }

                guard count > 4, sumTrialSquared > 1e-12 else { continue }
                let n = Double(count)
                let referenceVariance = sumReferenceSquared - sumReference * sumReference / n
                let trialVariance = sumTrialSquared - sumTrial * sumTrial / n
                let covariance = sumCross - sumReference * sumTrial / n
                guard referenceVariance > 1e-12, trialVariance > 1e-12 else { continue }

                let gain = covariance / referenceVariance
                let correlation = covariance / sqrt(referenceVariance * trialVariance)
                let offset = sumTrial / n - gain * sumReference / n
                let residualSum = max(trialVariance - covariance * covariance / referenceVariance, 0)
                let normalized = sqrt(residualSum / sumTrialSquared)

                let lagPenalty = abs(Double(lag)) / max(lagToleranceSamples, 1e-6)
                let gainPenalty = abs(gain - 1) / max(gainTolerance, 1e-6)
                let timeScalePenalty = abs(timeScale - 1) / max(timeScaleTolerance, 1e-6)
                let deformation = sqrt(
                    lagPenalty * lagPenalty
                        + gainPenalty * gainPenalty
                        + timeScalePenalty * timeScalePenalty
                )

                if best == nil
                    || normalized < best!.residual - 1e-12
                    || (abs(normalized - best!.residual) <= 1e-12 && deformation < best!.deformation) {
                    best = (lag, gain, offset, timeScale, correlation, normalized, deformation)
                }
            }
        }

        guard let best else { return nil }

        return AffineFit(
            lagSamples: best.lag,
            lagMs: Double(best.lag) / samplingRate * 1000,
            gain: best.gain,
            offset: best.offset,
            timeScale: best.timeScale,
            correlation: best.correlation,
            residualBefore: unshifted,
            residualAfter: best.residual,
            deformation: best.deformation
        )
    }

    /// Symmetric deterministic grid with both bounds and α = 1 represented
    /// exactly, even when `step` does not divide the requested limit.
    private static func timeScaleCandidates(limit: Double, step: Double) -> [Double] {
        guard limit > 1e-12 else { return [1] }
        let increment = min(max(abs(step), 0.001), limit)
        var values = [1 - limit, 1, 1 + limit]
        var offset = increment
        while offset < limit - 1e-12 {
            values.append(1 - offset)
            values.append(1 + offset)
            offset += increment
        }
        return Array(Set(values)).sorted()
    }

    // MARK: - Simultaneous component regression

    struct ComponentFit: Sendable, Equatable {
        /// One weight per regressor, in the order supplied.
        var weights: [Double]
        var normalizedResidualRMS: Double
    }

    /// Regresses a trial on several component regressors AT ONCE, rather than
    /// one window at a time.
    ///
    /// Adjacent ERP components overlap in time, so per-window scores each claim
    /// the whole of the shared variance and a trial can look large on both. A
    /// joint fit splits it, and the weights are what each component actually
    /// contributed once the others are accounted for.
    ///
    /// Solved by normal equations with a small ridge term, because component
    /// regressors built from neighbouring windows are correlated by
    /// construction and the unregularised system is often near-singular.
    static func componentRegression(
        trial: [Double],
        regressors: [[Double]],
        ridge: Double = 1e-6
    ) -> ComponentFit? {
        guard !regressors.isEmpty else { return nil }
        let length = min(trial.count, regressors.map(\.count).min() ?? 0)
        guard length > regressors.count + 1 else { return nil }

        let count = regressors.count
        var gram = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        var projection = [Double](repeating: 0, count: count)

        for row in 0 ..< count {
            for column in row ..< count {
                var sum = 0.0
                for index in 0 ..< length { sum += regressors[row][index] * regressors[column][index] }
                gram[row][column] = sum
                gram[column][row] = sum
            }
            var sum = 0.0
            for index in 0 ..< length { sum += regressors[row][index] * trial[index] }
            projection[row] = sum
        }

        // Ridge scaled to the problem, so it regularises without biasing a
        // well-conditioned fit.
        let trace = (0 ..< count).reduce(0.0) { $0 + gram[$1][$1] }
        let lambda = ridge * max(trace / Double(count), 1e-12)
        for index in 0 ..< count { gram[index][index] += lambda }

        guard let weights = solveSymmetric(gram, projection) else { return nil }

        var residual = 0.0
        var scale = 0.0
        for index in 0 ..< length {
            var predicted = 0.0
            for component in 0 ..< count { predicted += weights[component] * regressors[component][index] }
            let d = trial[index] - predicted
            residual += d * d
            scale += trial[index] * trial[index]
        }
        guard scale > 1e-12 else { return nil }

        return ComponentFit(weights: weights, normalizedResidualRMS: sqrt(residual / scale))
    }

    /// Gaussian elimination with partial pivoting. The systems here are a
    /// handful of components square, so there is nothing to gain from anything
    /// cleverer.
    private static func solveSymmetric(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let n = vector.count
        var a = matrix
        var b = vector

        for pivot in 0 ..< n {
            var maxRow = pivot
            for row in (pivot + 1) ..< n where abs(a[row][pivot]) > abs(a[maxRow][pivot]) {
                maxRow = row
            }
            guard abs(a[maxRow][pivot]) > 1e-12 else { return nil }
            if maxRow != pivot {
                a.swapAt(pivot, maxRow)
                b.swapAt(pivot, maxRow)
            }
            for row in (pivot + 1) ..< n {
                let factor = a[row][pivot] / a[pivot][pivot]
                guard factor != 0 else { continue }
                for column in pivot ..< n { a[row][column] -= factor * a[pivot][column] }
                b[row] -= factor * b[pivot]
            }
        }

        var solution = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for column in (row + 1) ..< n { sum -= a[row][column] * solution[column] }
            solution[row] = sum / a[row][row]
        }
        return solution
    }
}
