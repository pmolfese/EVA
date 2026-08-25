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
//  Similarity that survives a multi-peak ERP. TRIALWISE.md phase 4.
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
//   * affine alignment — fit `trial ≈ gain · average(t − lag) + offset`, then
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

    /// Fits `trial ≈ gain · reference(t − lag) + offset` by scanning lags and
    /// solving the two linear parameters in closed form at each.
    ///
    /// - Parameters:
    ///   - maxLagSamples: the search range. Keep it physiological — an
    ///     unconstrained search will always find *some* lag that fits, and the
    ///     residual stops meaning anything.
    ///   - lagToleranceSamples / gainTolerance: what counts as "no real
    ///     deformation", used only to scale the reported `deformation`.
    static func affineFit(
        trial: [Double],
        reference: [Double],
        maxLagSamples: Int,
        samplingRate: Double,
        lagToleranceSamples: Double = 25,
        gainTolerance: Double = 0.5
    ) -> AffineFit? {
        let length = min(trial.count, reference.count)
        guard length > 4, samplingRate > 0 else { return nil }
        let limit = max(0, min(maxLagSamples, length / 3))

        let unshifted = TrialSimilarityAnalyzer.normalizedResidualRMS(
            Array(trial[0 ..< length]),
            Array(reference[0 ..< length])
        )

        var best: (lag: Int, gain: Double, offset: Double, correlation: Double, residual: Double)?

        for lag in -limit ... limit {
            // Overlap only: no padding, so a large lag is not rewarded with
            // invented zeros that happen to match a flat baseline.
            let trialStart = max(lag, 0)
            let referenceStart = max(-lag, 0)
            let overlap = length - abs(lag)
            guard overlap > 4 else { continue }

            let trialSlice = Array(trial[trialStart ..< (trialStart + overlap)])
            let referenceSlice = Array(reference[referenceStart ..< (referenceStart + overlap)])

            let fit = TrialSimilarityAnalyzer.regression(of: trialSlice, on: referenceSlice)
            guard fit.slope != 0 || fit.correlation != 0 else { continue }

            let meanTrial = trialSlice.reduce(0, +) / Double(overlap)
            let meanReference = referenceSlice.reduce(0, +) / Double(overlap)
            let offset = meanTrial - fit.slope * meanReference

            // Residual of the FITTED model, not of the raw difference.
            var residual = 0.0
            var scale = 0.0
            for index in 0 ..< overlap {
                let predicted = fit.slope * referenceSlice[index] + offset
                let d = trialSlice[index] - predicted
                residual += d * d
                scale += trialSlice[index] * trialSlice[index]
            }
            guard scale > 1e-12 else { continue }
            let normalized = sqrt(residual / scale)

            if best == nil || normalized < best!.residual {
                best = (lag, fit.slope, offset, fit.correlation, normalized)
            }
        }

        guard let best else { return nil }

        let lagPenalty = abs(Double(best.lag)) / max(lagToleranceSamples, 1e-6)
        let gainPenalty = abs(best.gain - 1) / max(gainTolerance, 1e-6)

        return AffineFit(
            lagSamples: best.lag,
            lagMs: Double(best.lag) / samplingRate * 1000,
            gain: best.gain,
            offset: best.offset,
            correlation: best.correlation,
            residualBefore: unshifted,
            residualAfter: best.residual,
            deformation: sqrt(lagPenalty * lagPenalty + gainPenalty * gainPenalty)
        )
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
