//
//  TrialDriftStatistics.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The statistics behind the trial-order plots: does a measure drift over the
//  run, how noisy is each split group, and when does the average stop moving?
//
//  Kept separate from the views so the numbers can be tested without a window —
//  see TRIALWISE.md, Phase 2.
//

import Foundation

nonisolated enum TrialDriftStatistics {

    // MARK: - Drift

    struct RankCorrelation: Sendable, Equatable {
        /// Spearman's ρ: the Pearson correlation of the ranks, so a steady drift
        /// registers even when the relationship is not linear.
        var rho: Double
        /// Two-tailed p for the null of no monotonic association.
        var p: Double
        var sampleCount: Int

        var isSignificant: Bool { p < 0.05 }
    }

    /// Spearman rank correlation of `values` against `order`, with ties given
    /// average ranks.
    ///
    /// Used for "does peak amplitude drift over the run" — pass trial index for
    /// ordinal position, or `sourceTimeSeconds` for wall-clock, which differ
    /// wherever the session had breaks.
    static func rankCorrelation(of values: [Double], against order: [Double]) -> RankCorrelation? {
        guard values.count == order.count, values.count > 2 else { return nil }
        let a = ranks(values)
        let b = ranks(order)
        guard let r = pearson(a, b) else { return nil }
        return RankCorrelation(rho: r, p: twoTailedP(r: r, n: values.count), sampleCount: values.count)
    }

    /// Average ranks, so tied values do not fabricate an ordering.
    static func ranks(_ values: [Double]) -> [Double] {
        let sorted = values.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: values.count)
        var index = 0
        while index < sorted.count {
            var last = index
            while last + 1 < sorted.count, sorted[last + 1].element == sorted[index].element {
                last += 1
            }
            let averageRank = Double(index + last) / 2 + 1
            for position in index ... last {
                result[sorted[position].offset] = averageRank
            }
            index = last + 1
        }
        return result
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for index in a.indices {
            let da = a[index] - meanA
            let db = b[index] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 1e-12, varianceB > 1e-12 else { return nil }
        return covariance / sqrt(varianceA * varianceB)
    }

    /// Two-tailed p for a correlation, via the usual t transform on n − 2
    /// degrees of freedom.
    static func twoTailedP(r: Double, n: Int) -> Double {
        guard n > 2 else { return 1 }
        let clamped = min(max(r, -0.999999999), 0.999999999)
        let df = Double(n - 2)
        let t = clamped * sqrt(df / (1 - clamped * clamped))
        return studentTTwoTailed(t: abs(t), df: df)
    }

    // MARK: - Trend

    struct Trend: Sendable, Equatable {
        var slopePerTrial: Double
        var intercept: Double

        func value(at x: Double) -> Double { intercept + slopePerTrial * x }
    }

    /// Ordinary least squares of `values` on `order` — the straight line drawn
    /// through a drift panel. Reported alongside ρ, never instead of it: the
    /// slope says how much, ρ says whether it is monotonic at all.
    static func linearTrend(of values: [Double], against order: [Double]) -> Trend? {
        guard values.count == order.count, values.count > 1 else { return nil }
        let n = Double(values.count)
        let meanX = order.reduce(0, +) / n
        let meanY = values.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for index in values.indices {
            let dx = order[index] - meanX
            covariance += dx * (values[index] - meanY)
            variance += dx * dx
        }
        guard variance > 1e-12 else { return nil }
        let slope = covariance / variance
        return Trend(slopePerTrial: slope, intercept: meanY - slope * meanX)
    }

    /// Median over a centred sliding window. Preferred to a moving mean for the
    /// trend line, because the outliers these panels exist to show would drag a
    /// mean toward themselves and flatten the very excursion being displayed.
    static func runningMedian(_ values: [Double], window: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let half = max(window, 1) / 2
        return values.indices.map { index in
            let lower = max(index - half, 0)
            let upper = min(index + half, values.count - 1)
            return median(Array(values[lower ... upper]))
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    // MARK: - Groups

    struct GroupSummary: Identifiable, Sendable, Equatable {
        var id: Int
        var label: String
        var count: Int
        var mean: Double
        /// Standard error of the mean — the bar to draw, since the question is
        /// whether the group means differ, not how spread the trials are.
        var standardError: Double
    }

    /// Splits `values` into `groupCount` contiguous chunks in the order given —
    /// the generalisation of split-half to thirds, quarters and beyond.
    static func groupSummaries(_ values: [Double], groupCount: Int) -> [GroupSummary] {
        guard groupCount > 0, !values.isEmpty else { return [] }
        let size = max(Int(ceil(Double(values.count) / Double(groupCount))), 1)
        var summaries: [GroupSummary] = []
        var start = 0
        var index = 0
        while start < values.count {
            let end = min(start + size, values.count)
            let slice = Array(values[start ..< end])
            let mean = slice.reduce(0, +) / Double(slice.count)
            summaries.append(
                GroupSummary(
                    id: index,
                    label: label(forGroup: index, of: groupCount),
                    count: slice.count,
                    mean: mean,
                    standardError: standardError(slice)
                )
            )
            start = end
            index += 1
        }
        return summaries
    }

    static func label(forGroup index: Int, of total: Int) -> String {
        switch total {
        case 2: return index == 0 ? "First half" : "Last half"
        case 3: return ["Early", "Middle", "Late"][min(index, 2)]
        default: return "Group \(index + 1)"
        }
    }

    static func standardError(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
        return sqrt(variance / n)
    }

    // MARK: - Convergence

    struct ConvergencePoint: Identifiable, Sendable, Equatable {
        var id: Int
        /// How many trials are in the running average at this point.
        var trialCount: Int
        /// Correlation between the running average and the final average.
        /// Shape only — correlation is scale-invariant, so an amplitude drift
        /// leaves this pinned near 1.
        var correlationWithFinal: Double
        /// RMS of (running − final) over the RMS of final. Catches the
        /// amplitude convergence that `correlationWithFinal` cannot see, and is
        /// the one to read first.
        var normalizedDistanceToFinal: Double
    }

    /// How quickly the average settles. Rises toward 1 by construction — the
    /// last point IS the final average — so read the shape, not the endpoint:
    /// a curve still climbing at the right edge means the ERP had not
    /// stabilised, and a late dip means the last trials moved it.
    static func convergence(trials: [[Double]]) -> [ConvergencePoint] {
        guard let sampleCount = trials.map(\.count).min(), sampleCount > 0, trials.count > 1 else { return [] }

        var final = [Double](repeating: 0, count: sampleCount)
        for trial in trials {
            for index in 0 ..< sampleCount { final[index] += trial[index] }
        }
        for index in final.indices { final[index] /= Double(trials.count) }

        var running = [Double](repeating: 0, count: sampleCount)
        var points: [ConvergencePoint] = []
        points.reserveCapacity(trials.count)

        for (position, trial) in trials.enumerated() {
            for index in 0 ..< sampleCount { running[index] += trial[index] }
            let count = position + 1
            let average = running.map { $0 / Double(count) }
            guard count > 1, let r = pearson(average, final) else { continue }
            points.append(
                ConvergencePoint(
                    id: position,
                    trialCount: count,
                    correlationWithFinal: r,
                    normalizedDistanceToFinal: normalizedDistance(average, final)
                )
            )
        }
        return points
    }

    static func normalizedDistance(_ values: [Double], _ reference: [Double]) -> Double {
        guard values.count == reference.count, !values.isEmpty else { return 0 }
        var difference = 0.0
        var scale = 0.0
        for index in values.indices {
            let d = values[index] - reference[index]
            difference += d * d
            scale += reference[index] * reference[index]
        }
        guard scale > 1e-12 else { return 0 }
        return sqrt(difference / scale)
    }

    // MARK: - Residuals

    /// `trial − reference` per sample, for the trial × time heatmap. Rows follow
    /// the order given, so the vertical axis reads as trial order.
    static func residuals(trials: [[Double]], reference: [Double]) -> [[Double]] {
        trials.map { trial in
            let count = min(trial.count, reference.count)
            return (0 ..< count).map { trial[$0] - reference[$0] }
        }
    }

    // MARK: - Student's t

    /// Two-tailed tail area of Student's t, via the regularised incomplete beta
    /// function. Written out rather than approximated because these p-values sit
    /// on a plot next to a claim about drift.
    static func studentTTwoTailed(t: Double, df: Double) -> Double {
        guard df > 0 else { return 1 }
        guard t.isFinite else { return 0 }
        let x = df / (df + t * t)
        return min(max(regularizedIncompleteBeta(a: df / 2, b: 0.5, x: x), 0), 1)
    }

    /// I_x(a, b), by the standard continued-fraction expansion with the
    /// symmetry transform that keeps it in its convergent range.
    static func regularizedIncompleteBeta(a: Double, b: Double, x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let logBeta: Double = lgamma(a + b) - lgamma(a) - lgamma(b)
        let logPowers: Double = a * log(x) + b * log(1 - x)
        let front: Double = exp(logBeta + logPowers)
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(a: a, b: b, x: x) / a
        }
        return 1 - front * betaContinuedFraction(a: b, b: a, x: 1 - x) / b
    }

    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double {
        let tiny = 1e-30
        let epsilon = 3e-12
        let qab = a + b
        let qap = a + 1
        let qam = a - 1

        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d

        for m in 1 ... 200 {
            let mDouble = Double(m)
            let m2 = 2 * mDouble

            var numerator = mDouble * (b - mDouble) * x / ((qam + m2) * (a + m2))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c

            numerator = -(a + mDouble) * (qab + mDouble) * x / ((a + m2) * (qap + m2))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta

            if abs(delta - 1) < epsilon { break }
        }
        return h
    }
}
