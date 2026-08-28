//
//  TrialSimilarityAnalyzer.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  How much does each trial look like its category's average, and in what way
//  does it differ?
//
//  `SingleTrialAnalyzer` answers "how big and how late" per trial. This answers
//  "how similar", which separates failure modes that a single amplitude number
//  cannot:
//
//    shape (r)   magnitude (β)   reading
//    high        ≈ 1             an ordinary trial
//    high        ≈ 0             the response is absent — inattention
//    low         any             noise or an artifact
//    high        negative        inverted — a mislabel, or a reference problem
//
//  Every score is leave-one-out: a trial is compared against the average of the
//  OTHER trials in its category. Comparing a trial to an average that contains
//  it inflates the correlation by roughly 1/n, which is worst in exactly the
//  small-N categories where the answer matters most.
//
//  These thresholds and classifications are heuristics, not established
//  criteria. They are meant to triage trials for a human to look at, and the
//  cross-category match below is the only one that makes a directly checkable
//  claim. See ROADMAP.md, Trial-wise similarity, drift, and reviewed exclusion.
//

import Foundation

nonisolated enum TrialSimilarityAnalyzer {

    // MARK: - Inputs

    /// One category's trials, already channel-resolved the same way
    /// `SingleTrialAnalyzer.TrialInput` is (single channel, or an ROI average).
    struct CategoryInput: Sendable {
        var name: String
        var trials: [SingleTrialAnalyzer.TrialInput]
        /// Sample offset of "0 ms" in this category's own average, when it
        /// differs from the trials'. Defaults to the first trial's.
        var averageStimulusOffsetSamples: Int?
        /// Categories a match to which is NOT a mislabel, because they pool the
        /// same trials. `nil` derives them from the trials themselves.
        var pooledWith: Set<String>?

        init(
            name: String,
            trials: [SingleTrialAnalyzer.TrialInput],
            averageStimulusOffsetSamples: Int? = nil,
            pooledWith: Set<String>? = nil
        ) {
            self.name = name
            self.trials = trials
            self.averageStimulusOffsetSamples = averageStimulusOffsetSamples
            self.pooledWith = pooledWith
        }
    }

    /// Which categories share trials with which.
    ///
    /// A pooled category ("correct") is built from the very trials of its
    /// members ("LC++", "RC++"), so a member's trial resembles its own
    /// sub-category average more than the pool's — the pool is diluted by the
    /// other condition. Left unaccounted for, every pooled category flags
    /// almost all of its trials as mislabelled.
    ///
    /// Matching is therefore hierarchical: an LC++ trial that looks like RC++
    /// is "not LC++, but still correct", and only a match landing OUTSIDE the
    /// pool — LC++ looking like LI++ — is a labelling claim.
    ///
    /// Derived rather than declared, because pooling shows up in the data:
    /// overlapping categories literally contain the same epochs, at the same
    /// `sourceTimeSeconds`.
    ///
    /// This rests on distinct categories having distinct trial times, which
    /// holds because a category's trials come from events and one event cannot
    /// occur twice. Callers who would rather state the grouping outright can
    /// set `CategoryInput.pooledWith`.
    static func pooledRelations(_ categories: [CategoryInput]) -> [String: Set<String>] {
        var timesByCategory: [String: Set<Int64>] = [:]
        for category in categories {
            // Microsecond keys: these come from the same segments, but they are
            // Doubles and exact equality is not something to rely on.
            timesByCategory[category.name] = Set(
                category.trials.map { Int64(($0.sourceTimeSeconds * 1_000_000).rounded()) }
            )
        }

        var relations: [String: Set<String>] = [:]
        for category in categories {
            if let declared = category.pooledWith {
                relations[category.name] = declared
                continue
            }
            guard let mine = timesByCategory[category.name], !mine.isEmpty else {
                relations[category.name] = []
                continue
            }
            var related: Set<String> = []
            for other in categories where other.name != category.name {
                guard let theirs = timesByCategory[other.name], !theirs.isEmpty else { continue }
                // Containment, not mere overlap. Pooling is a superset relation
                // — "correct" holds every LC++ trial — so one side's epochs are
                // wholly inside the other's. Partial overlap is not pooling and
                // should not silence a labelling claim.
                if mine.isSubset(of: theirs) || theirs.isSubset(of: mine) {
                    related.insert(other.name)
                }
            }
            relations[category.name] = related
        }
        return relations
    }

    /// What a trial is compared against.
    ///
    /// `.mean` is leave-one-out per trial. The robust references are not: a
    /// median or trimmed mean is by construction almost unmoved by any single
    /// trial, which is the whole reason to use one, so the leave-one-out
    /// correction it would receive is negligible and not worth the per-trial
    /// re-sort.
    enum Reference: Sendable, Equatable {
        case mean
        case trimmedMean(fraction: Double)
        case median
    }

    struct Thresholds: Sendable, Equatable {
        /// Below this slope, with shape still intact, the response reads as
        /// present-but-flattened rather than merely noisy.
        var attenuatedSlope: Double = 0.5
        /// Shape has to survive this well for "attenuated" to mean anything;
        /// otherwise the trial is just divergent.
        var attenuatedMinCorrelation: Double = 0.4
        /// A meaningfully negative slope, i.e. the trial runs opposite the
        /// average rather than simply being small.
        var invertedSlope: Double = -0.2
        /// Below this the trial does not share the average's shape at all.
        var divergentCorrelation: Double = 0.2
        /// MAD-standardised distance past which a trial is unusual regardless
        /// of which individual measure carries it.
        var divergentRobustDistance: Double = 3.0
        /// A cross-category match is only asserted when the winning correlation
        /// is at least this high. Without a floor, a pure-noise trial — which
        /// correlates with nothing — still has a "best" match, and whichever
        /// category edges ahead by luck gets named. That would put false
        /// mislabel claims in front of the user on the one measure here that is
        /// supposed to be directly checkable.
        var mislabelMinimumCorrelation: Double = 0.3
        /// And it must beat the trial's own category by at least this margin,
        /// so a near-tie between two similar conditions is not called a
        /// mislabel either.
        var mislabelMargin: Double = 0.1

        static let defaults = Thresholds()
    }

    // MARK: - Output

    enum Classification: String, Sendable, CaseIterable {
        case typical
        /// Shape intact, amplitude collapsed — the "not attending" signature.
        case attenuated
        /// Runs opposite the average.
        case inverted
        /// Shares little with the average, by shape or by distance.
        case divergent

        var displayName: String {
            switch self {
            case .typical: return "Typical"
            case .attenuated: return "Attenuated"
            case .inverted: return "Inverted"
            case .divergent: return "Divergent"
            }
        }
    }

    struct TrialSimilarity: Identifiable, Sendable {
        var id: Int
        var trialIndex: Int
        var sourceTimeSeconds: Double

        /// Pearson correlation against the leave-one-out reference, over the
        /// analysis window. Amplitude-blind: a half-sized but perfectly shaped
        /// trial scores 1.
        var correlation: Double
        /// Least-squares slope of this trial regressed on the reference.
        /// Amplitude-sensitive, which is what `correlation` misses.
        var slope: Double
        /// RMS of (trial − reference), divided by the RMS of the reference.
        /// 0 is a perfect match; 1 means the residual is as large as the signal.
        var normalizedResidualRMS: Double

        /// Euclidean distance over the three measures above, each standardised
        /// by its median and MAD across this category's trials.
        ///
        /// Deliberately NOT a Mahalanobis distance: that needs a covariance
        /// estimate, and a robust one (MCD and friends) is unstable at the trial
        /// counts these categories actually have. This ignores the correlations
        /// between the measures and says so, rather than reporting a number
        /// whose covariance term is noise.
        var robustDistance: Double

        /// Which category's average this trial actually resembles most,
        /// including its own. When this is not the trial's own category, the
        /// label is worth checking.
        var bestMatchingCategory: String?
        var bestMatchingCorrelation: Double?
        /// The match is this trial's exact category. Informative on its own —
        /// an LC++ trial that looks like RC++ may be a response-hand confusion
        /// worth seeing — but it is NOT the mislabel test.
        var matchesOwnCategory: Bool
        /// The match is the trial's category or something pooled with it. This
        /// is what a mislabel claim rests on: only a match from outside the
        /// pool is a labelling claim.
        var matchesOwnPool: Bool

        var classification: Classification
    }

    struct CategoryResult: Sendable {
        var name: String
        var trials: [TrialSimilarity]
        /// Trials whose best-matching average came from outside their pool.
        var possibleMislabels: [TrialSimilarity] {
            trials.filter { !$0.matchesOwnPool }
        }

        /// Matched a sibling inside the same pool — not a labelling error, but
        /// worth a look: within `correct`, an LC++ trial resembling RC++ is a
        /// statement about the two conditions, not about the label.
        var poolSiblingMatches: [TrialSimilarity] {
            trials.filter { $0.matchesOwnPool && !$0.matchesOwnCategory }
        }
        func trials(classified as: Classification) -> [TrialSimilarity] {
            trials.filter { $0.classification == `as` }
        }
    }

    // MARK: - Entry point

    /// Scores every trial in every category. Cross-category matching needs them
    /// all at once, which is why this takes the whole set rather than one
    /// category at a time.
    ///
    /// Returns `nil` when nothing could be measured. A category with fewer than
    /// two trials is skipped: with one trial the leave-one-out reference is
    /// empty, and any score would be an artefact of that.
    static func analyze(
        categories: [CategoryInput],
        samplingRate: Double,
        windowStartMs: Double,
        windowEndMs: Double,
        reference: Reference = .mean,
        thresholds: Thresholds = .defaults
    ) -> [CategoryResult]? {
        guard samplingRate > 0, windowEndMs > windowStartMs, !categories.isEmpty else { return nil }

        // Each category's plain average, used as the comparison target for
        // trials belonging to the OTHER categories (no leave-one-out needed —
        // the trial is not in them).
        var referenceByCategory: [String: [Double]] = [:]
        var offsetByCategory: [String: Int] = [:]
        for category in categories {
            guard let first = category.trials.first else { continue }
            let offset = category.averageStimulusOffsetSamples ?? first.stimulusOffsetSamples
            guard let averaged = average(category.trials, reference: reference) else { continue }
            referenceByCategory[category.name] = averaged
            offsetByCategory[category.name] = offset
        }
        guard !referenceByCategory.isEmpty else { return nil }

        let relations = pooledRelations(categories)
        var results: [CategoryResult] = []

        for category in categories {
            guard category.trials.count >= 2,
                  let ownOffset = offsetByCategory[category.name] else { continue }

            // Running sum so each trial's leave-one-out mean is a subtraction
            // rather than a re-average.
            let sampleCount = category.trials.map(\.samples.count).min() ?? 0
            guard sampleCount > 0 else { continue }
            var total = [Double](repeating: 0, count: sampleCount)
            for trial in category.trials {
                for index in 0 ..< sampleCount { total[index] += Double(trial.samples[index]) }
            }

            var rows: [TrialSimilarity] = []
            rows.reserveCapacity(category.trials.count)

            for (index, trial) in category.trials.enumerated() {
                let target: [Double]
                switch reference {
                case .mean:
                    let others = Double(category.trials.count - 1)
                    guard others > 0 else { continue }
                    target = (0 ..< sampleCount).map { (total[$0] - Double(trial.samples[$0])) / others }
                case .trimmedMean, .median:
                    guard let robust = referenceByCategory[category.name] else { continue }
                    target = robust
                }

                guard let window = SingleTrialAnalyzer.sampleRange(
                    startMs: windowStartMs, endMs: windowEndMs,
                    stimulusOffsetSamples: trial.stimulusOffsetSamples,
                    samplingRate: samplingRate, length: trial.samples.count
                ) else { continue }

                let trialWindow = trial.samples[window.clamped(to: trial.samples.indices)].map(Double.init)
                let referenceWindow = alignedWindow(
                    target,
                    window: window,
                    fromOffset: trial.stimulusOffsetSamples,
                    toOffset: ownOffset
                )
                guard trialWindow.count == referenceWindow.count, trialWindow.count > 2 else { continue }

                let fit = regression(of: trialWindow, on: referenceWindow)
                let residual = normalizedResidualRMS(trialWindow, referenceWindow)

                // Cross-category: which average does this trial actually look
                // most like? Its own entry uses the leave-one-out target so the
                // comparison is fair.
                var bestCategory: String?
                var bestCorrelation: Double?
                for other in categories {
                    let candidate: [Double]
                    let candidateOffset: Int
                    if other.name == category.name {
                        candidate = target
                        candidateOffset = ownOffset
                    } else {
                        guard let stored = referenceByCategory[other.name],
                              let storedOffset = offsetByCategory[other.name] else { continue }
                        candidate = stored
                        candidateOffset = storedOffset
                    }
                    let candidateWindow = alignedWindow(
                        candidate,
                        window: window,
                        fromOffset: trial.stimulusOffsetSamples,
                        toOffset: candidateOffset
                    )
                    guard candidateWindow.count == trialWindow.count else { continue }
                    guard let r = correlation(trialWindow, candidateWindow) else { continue }
                    if bestCorrelation == nil || r > bestCorrelation! {
                        bestCorrelation = r
                        bestCategory = other.name
                    }
                }

                // Only claim anything when the winner is both convincing on its
                // own terms and clearly ahead of the trial's own category.
                let isConfident =
                    bestCategory != nil
                    && bestCategory != category.name
                    && (bestCorrelation ?? 0) >= thresholds.mislabelMinimumCorrelation
                    && (bestCorrelation ?? 0) - fit.correlation >= thresholds.mislabelMargin

                let pool = relations[category.name] ?? []
                let matchedOutsidePool = isConfident && !pool.contains(bestCategory ?? "")

                rows.append(TrialSimilarity(
                    id: index,
                    trialIndex: index,
                    sourceTimeSeconds: trial.sourceTimeSeconds,
                    correlation: fit.correlation,
                    slope: fit.slope,
                    normalizedResidualRMS: residual,
                    robustDistance: 0,
                    bestMatchingCategory: bestCategory,
                    bestMatchingCorrelation: bestCorrelation,
                    matchesOwnCategory: !isConfident,
                    matchesOwnPool: !matchedOutsidePool,
                    classification: .typical
                ))
            }

            guard !rows.isEmpty else { continue }
            rows = scoringRobustDistance(rows)
            rows = classifying(rows, thresholds: thresholds)
            results.append(CategoryResult(name: category.name, trials: rows))
        }

        return results.isEmpty ? nil : results
    }

    // MARK: - Reference construction

    /// The category-level average under the chosen reference. Used verbatim for
    /// cross-category comparison, and as the target for the robust references.
    static func average(
        _ trials: [SingleTrialAnalyzer.TrialInput],
        reference: Reference
    ) -> [Double]? {
        guard let sampleCount = trials.map(\.samples.count).min(), sampleCount > 0 else { return nil }

        switch reference {
        case .mean:
            var total = [Double](repeating: 0, count: sampleCount)
            for trial in trials {
                for index in 0 ..< sampleCount { total[index] += Double(trial.samples[index]) }
            }
            return total.map { $0 / Double(trials.count) }

        case .median:
            return (0 ..< sampleCount).map { index in
                median(trials.map { Double($0.samples[index]) })
            }

        case .trimmedMean(let fraction):
            let clamped = min(max(fraction, 0), 0.49)
            let drop = Int((Double(trials.count) * clamped).rounded(.down))
            return (0 ..< sampleCount).map { index in
                let column = trials.map { Double($0.samples[index]) }.sorted()
                let kept = column.dropFirst(drop).dropLast(drop)
                guard !kept.isEmpty else { return median(column) }
                return kept.reduce(0, +) / Double(kept.count)
            }
        }
    }

    // MARK: - Statistics

    /// Slope and correlation of `values` regressed on `target`, both taken over
    /// the analysis window only.
    static func regression(of values: [Double], on target: [Double]) -> (slope: Double, correlation: Double) {
        guard values.count == target.count, values.count > 1 else { return (0, 0) }
        let n = Double(values.count)
        let meanValues = values.reduce(0, +) / n
        let meanTarget = target.reduce(0, +) / n

        var covariance = 0.0
        var varianceTarget = 0.0
        var varianceValues = 0.0
        for index in values.indices {
            let dv = values[index] - meanValues
            let dt = target[index] - meanTarget
            covariance += dv * dt
            varianceTarget += dt * dt
            varianceValues += dv * dv
        }
        // A flat reference or a flat trial has no shape to compare.
        guard varianceTarget > 1e-12, varianceValues > 1e-12 else { return (0, 0) }
        return (covariance / varianceTarget, covariance / sqrt(varianceTarget * varianceValues))
    }

    static func correlation(_ values: [Double], _ target: [Double]) -> Double? {
        guard values.count == target.count, values.count > 1 else { return nil }
        let fit = regression(of: values, on: target)
        return fit.correlation == 0 && fit.slope == 0 ? nil : fit.correlation
    }

    static func normalizedResidualRMS(_ values: [Double], _ target: [Double]) -> Double {
        guard values.count == target.count, !values.isEmpty else { return 0 }
        var residual = 0.0
        var reference = 0.0
        for index in values.indices {
            let d = values[index] - target[index]
            residual += d * d
            reference += target[index] * target[index]
        }
        let referenceRMS = sqrt(reference / Double(values.count))
        guard referenceRMS > 1e-12 else { return 0 }
        return sqrt(residual / Double(values.count)) / referenceRMS
    }

    /// Standardises each measure by its own median and MAD, then takes the
    /// Euclidean norm. Median/MAD rather than mean/SD because a handful of wild
    /// trials inflate an SD until nothing exceeds the threshold — the classic
    /// way an outlier detector hides the outliers it was built to find.
    static func scoringRobustDistance(_ rows: [TrialSimilarity]) -> [TrialSimilarity] {
        guard rows.count > 2 else { return rows }
        // Each floor is the smallest difference in that measure worth calling a
        // difference. Without them a tight cluster manufactures outliers: twelve
        // ordinary trials can have a correlation MAD of 0.001, and dividing by
        // that turns a 0.003 gap into a three-sigma event.
        let correlations = robustScale(rows.map(\.correlation), floor: 0.05)
        let slopes = robustScale(rows.map(\.slope), floor: 0.10)
        let residuals = robustScale(rows.map(\.normalizedResidualRMS), floor: 0.10)

        return rows.enumerated().map { index, row in
            var row = row
            row.robustDistance = sqrt(
                correlations[index] * correlations[index]
                    + slopes[index] * slopes[index]
                    + residuals[index] * residuals[index]
            )
            return row
        }
    }

    private static func robustScale(_ values: [Double], floor: Double) -> [Double] {
        let centre = median(values)
        let deviations = values.map { abs($0 - centre) }
        // 1.4826 makes the MAD a consistent estimator of sigma for normal data.
        let scale = max(median(deviations) * 1.4826, floor)
        guard scale > 1e-12 else { return values.map { _ in 0 } }
        return values.map { ($0 - centre) / scale }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    // MARK: - Classification

    static func classifying(_ rows: [TrialSimilarity], thresholds: Thresholds) -> [TrialSimilarity] {
        rows.map { row in
            var row = row
            row.classification = classify(row, thresholds: thresholds)
            return row
        }
    }

    private static func classify(_ row: TrialSimilarity, thresholds: Thresholds) -> Classification {
        // Order is deliberate, most specific first.
        //
        // An inverted trial also has a low slope, so it must be caught before
        // "attenuated". A genuinely shapeless trial is divergent regardless of
        // amplitude. Attenuation is a real description and outranks the
        // distance rule, which is a catch-all for trials that are mildly odd
        // across several measures at once without any one of them saying why.
        if row.slope <= thresholds.invertedSlope { return .inverted }
        if row.correlation < thresholds.divergentCorrelation { return .divergent }
        if row.slope < thresholds.attenuatedSlope,
           row.correlation >= thresholds.attenuatedMinCorrelation { return .attenuated }
        if row.robustDistance > thresholds.divergentRobustDistance { return .divergent }
        return .typical
    }

    // MARK: - Window alignment

    /// Reads `series` over the same span the trial's `window` covers,
    /// translating between the two series' stimulus-onset offsets.
    private static func alignedWindow(
        _ series: [Double],
        window: Range<Int>,
        fromOffset: Int,
        toOffset: Int
    ) -> [Double] {
        let shift = toOffset - fromOffset
        var out: [Double] = []
        out.reserveCapacity(window.count)
        for index in window {
            let mapped = index + shift
            guard series.indices.contains(mapped) else { return [] }
            out.append(series[mapped])
        }
        return out
    }
}
