//
//  TrialSelectionAnalyzer.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Trial-wise Phase 3: turning trial scores into a proposed exclusion set,
//  and being honest about what excluding them buys.
//
//  The honesty is the hard part. Selecting trials by their similarity to the
//  average ALWAYS improves the apparent SNR of that average, whether or not the
//  discarded trials were bad — the criterion and the outcome measure are the
//  same quantity. So every outcome here is reported against a null: exclude the
//  same NUMBER of trials at random, many times, and see where the real
//  selection falls in that distribution. The null controls for the mechanical
//  part (fewer trials is a different average) and leaves the part the criterion
//  actually chose. It does not, and cannot, tell you the excluded trials were
//  bad.
//

import Foundation

nonisolated enum TrialSelectionAnalyzer {

    // MARK: - Criteria

    /// Every bound is optional; `nil` means "do not exclude on this". Bounds
    /// combine with OR — a trial failing any active rule is excluded — because
    /// the rules describe different failure modes rather than degrees of one.
    struct Criteria: Sendable, Equatable {
        var minCorrelation: Double?
        var minSlope: Double?
        var maxResidualRMS: Double?
        var maxRobustDistance: Double?
        var excludedClassifications: Set<TrialSimilarityAnalyzer.Classification> = []
        /// Exclude trials whose best-matching average was another category.
        var excludesMislabels: Bool = false

        static let none = Criteria()

        var isActive: Bool {
            minCorrelation != nil
                || minSlope != nil
                || maxResidualRMS != nil
                || maxRobustDistance != nil
                || !excludedClassifications.isEmpty
                || excludesMislabels
        }
    }

    /// Why a given trial was excluded, for the UI to show beside it.
    struct Exclusion: Identifiable, Sendable, Equatable {
        var id: Int { trialIndex }
        var trialIndex: Int
        var reasons: [String]
        /// Who decided. `.rule` until an operator overrules it — the same three
        /// origins the committed record carries, deliberately reusing
        /// `ExcludedTrial.Origin` rather than a parallel enum that would have to
        /// be mapped and kept in step.
        var origin: ExcludedTrial.Origin = .rule

        /// Whether this row removes a trial from the average. A `.restored` row
        /// is listed so the operator can see the rule was overruled, and see it
        /// well enough to change their mind again.
        var isExcluded: Bool { origin != .restored }
    }

    /// An operator's overrides on top of whatever the criteria proposed, held
    /// per category by trial index.
    ///
    /// Kept as two sets rather than baked into the proposals because the
    /// criteria are still live: a slider drag re-proposes from scratch, and an
    /// override has to survive that. Nothing here is pruned when a re-tune makes
    /// it moot — see `reviewed(proposals:review:)`, which decides what an
    /// override *means* against the current proposal without destroying it, so
    /// dragging a threshold back restores the operator's decision rather than
    /// having silently discarded it.
    struct Review: Sendable, Equatable {
        /// Rule-flagged trials the operator put back.
        var restored: Set<Int> = []
        /// Trials the rule did not flag, excluded by hand.
        var manual: Set<Int> = []

        static let none = Review()

        var isEmpty: Bool { restored.isEmpty && manual.isEmpty }
    }

    /// The proposals as reviewed: what committing right now would write.
    ///
    /// Precedence, in order:
    ///
    /// 1. **A restored trial the rule still flags** is listed as `.restored` and
    ///    excludes nothing. This is the only override that can contradict the
    ///    rule, so it wins outright.
    /// 2. **A rule-flagged trial** is `.rule`. Note this absorbs a hand-excluded
    ///    trial the criteria have since caught up with: the rule now accounts
    ///    for it, and recording it as a manual override would credit the
    ///    operator with a decision the rule makes on its own.
    /// 3. **A hand-excluded trial the rule does not flag** is `.manual` — the
    ///    case no threshold can express, and the reason the committed record
    ///    stores a trial list at all.
    ///
    /// A restoration of a trial the rule no longer flags drops out silently: it
    /// excludes nothing and undoes nothing, so there is nothing to show.
    static func reviewed(
        proposals: [Exclusion],
        review: Review
    ) -> [Exclusion] {
        let flagged = Dictionary(uniqueKeysWithValues: proposals.map { ($0.trialIndex, $0) })

        var out: [Exclusion] = proposals.map { proposal in
            var row = proposal
            row.origin = review.restored.contains(proposal.trialIndex) ? .restored : .rule
            return row
        }
        for index in review.manual.sorted() where flagged[index] == nil {
            out.append(Exclusion(
                trialIndex: index,
                reasons: ["excluded by operator"],
                origin: .manual
            ))
        }
        return out.sorted { $0.trialIndex < $1.trialIndex }
    }

    static func exclusions(
        from trials: [TrialSimilarityAnalyzer.TrialSimilarity],
        criteria: Criteria
    ) -> [Exclusion] {
        guard criteria.isActive else { return [] }

        return trials.compactMap { trial in
            var reasons: [String] = []
            if let bound = criteria.minCorrelation, trial.correlation < bound {
                reasons.append("r < \(formatted(bound))")
            }
            if let bound = criteria.minSlope, trial.slope < bound {
                reasons.append("β < \(formatted(bound))")
            }
            if let bound = criteria.maxResidualRMS, trial.normalizedResidualRMS > bound {
                reasons.append("residual > \(formatted(bound))")
            }
            if let bound = criteria.maxRobustDistance, trial.robustDistance > bound {
                reasons.append("distance > \(formatted(bound))")
            }
            if criteria.excludedClassifications.contains(trial.classification) {
                reasons.append(trial.classification.displayName.lowercased())
            }
            if criteria.excludesMislabels, !trial.matchesOwnPool {
                reasons.append("matches \(trial.bestMatchingCategory ?? "another category")")
            }
            return reasons.isEmpty ? nil : Exclusion(trialIndex: trial.trialIndex, reasons: reasons)
        }
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Outcome

    struct Outcome: Sendable {
        var keptCount: Int
        var excludedCount: Int
        var before: SNRMetrics
        var after: SNRMetrics

        /// Change in plus-minus SNR from excluding the same NUMBER of trials at
        /// random, one entry per draw. The yardstick the real change is read
        /// against.
        var nullChanges: [Double]
        /// Fraction of the null draws the observed change beat, 0...1. High
        /// means the selection did more than merely shrink the trial count —
        /// which is expected, since it selected on similarity to this very
        /// average, and is NOT evidence that the excluded trials were bad.
        var percentileAmongNull: Double?

        var observedChange: Double? {
            guard let after = after.plusMinusSNR, let before = before.plusMinusSNR else { return nil }
            return after - before
        }

        var medianNullChange: Double? {
            nullChanges.isEmpty ? nil : TrialDriftStatistics.median(nullChanges)
        }

        /// The part of the improvement not explained by simply averaging fewer
        /// trials.
        var changeBeyondNull: Double? {
            guard let observed = observedChange, let null = medianNullChange else { return nil }
            return observed - null
        }

        /// A plotting range that shows the bulk of the null and the observed
        /// value, without letting one freak draw set the scale.
        ///
        /// Plus-minus SNR is a ratio, and a random half-split that happens to
        /// cancel almost perfectly sends it to absurd values. One such draw
        /// stretched the axis to ±1000 and made a real change of 17 look like
        /// zero.
        var nullPlotRange: ClosedRange<Double>? {
            guard !nullChanges.isEmpty else { return nil }
            let sorted = nullChanges.sorted()
            func percentile(_ fraction: Double) -> Double {
                let position = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
                return sorted[position]
            }
            var low = percentile(0.02)
            var high = percentile(0.98)
            if let observed = observedChange {
                low = min(low, observed)
                high = max(high, observed)
            }
            let padding = max((high - low) * 0.08, 1e-6)
            return (low - padding) ... (high + padding)
        }

        /// The null as a histogram, clipped to `nullPlotRange`. Values outside
        /// it are folded into the end bins rather than dropped, so the counts
        /// still sum to the number of draws.
        func nullHistogram(binCount: Int = 24) -> [(center: Double, count: Int)] {
            guard let range = nullPlotRange, binCount > 0 else { return [] }
            let width = (range.upperBound - range.lowerBound) / Double(binCount)
            guard width > 0 else { return [] }
            var counts = [Int](repeating: 0, count: binCount)
            for change in nullChanges {
                let position = (change - range.lowerBound) / width
                let index = min(max(Int(position), 0), binCount - 1)
                counts[index] += 1
            }
            return counts.enumerated().map { index, count in
                (range.lowerBound + (Double(index) + 0.5) * width, count)
            }
        }
    }

    /// Recomputes SNR with and without the excluded trials, then builds the
    /// random-exclusion null.
    ///
    /// - Parameters:
    ///   - trials: `[trial][channel][sample]`, in trial order.
    ///   - excludedIndices: positions in `trials` to drop.
    ///   - permutations: null draws. 0 skips the null entirely.
    ///   - seed: fixed so the same selection reports the same null twice. A
    ///     threshold slider that reshuffled its own yardstick on every drag
    ///     would be unreadable — and `SeededGenerator` exists for exactly this,
    ///     per its own file note about anything contributing to a reported
    ///     number.
    static func evaluate(
        trials: [[[Float]]],
        excludedIndices: Set<Int>,
        baselineSampleCount: Int,
        permutations: Int = 200,
        seed: UInt64 = 0x5EED_5EED
    ) -> Outcome? {
        guard trials.count >= 4 else { return nil }
        let kept = trials.indices.filter { !excludedIndices.contains($0) }
        // Plus-minus SNR needs at least a pair, and an average of one trial is
        // not an average.
        guard kept.count >= 2 else { return nil }

        let before = EpochSNR.metrics(trials: trials, baselineSampleCount: baselineSampleCount)
        let after = EpochSNR.metrics(
            trials: kept.map { trials[$0] },
            baselineSampleCount: baselineSampleCount
        )

        var nullChanges: [Double] = []
        if permutations > 0, !excludedIndices.isEmpty, let baseline = before.plusMinusSNR {
            var generator = SeededGenerator(seed: seed)
            nullChanges.reserveCapacity(permutations)
            for _ in 0 ..< permutations {
                let drawn = randomSubset(
                    count: excludedIndices.count,
                    from: trials.count,
                    using: &generator
                )
                let sample = trials.indices.filter { !drawn.contains($0) }.map { trials[$0] }
                let metrics = EpochSNR.metrics(trials: sample, baselineSampleCount: baselineSampleCount)
                guard let snr = metrics.plusMinusSNR else { continue }
                nullChanges.append(snr - baseline)
            }
        }

        var percentile: Double?
        if let observed = after.plusMinusSNR, let baseline = before.plusMinusSNR, !nullChanges.isEmpty {
            let change = observed - baseline
            let beaten = nullChanges.filter { $0 < change }.count
            percentile = Double(beaten) / Double(nullChanges.count)
        }

        return Outcome(
            keptCount: kept.count,
            excludedCount: trials.count - kept.count,
            before: before,
            after: after,
            nullChanges: nullChanges,
            percentileAmongNull: percentile
        )
    }

    /// `count` distinct indices below `bound`, by partial Fisher-Yates so the
    /// draw stays uniform without rejection looping when count approaches bound.
    static func randomSubset(count: Int, from bound: Int, using generator: inout SeededGenerator) -> Set<Int> {
        guard count > 0, bound > 0 else { return [] }
        let wanted = min(count, bound)
        var pool = Array(0 ..< bound)
        for position in 0 ..< wanted {
            let swap = position + Int(generator.next() % UInt64(bound - position))
            pool.swapAt(position, swap)
        }
        return Set(pool.prefix(wanted))
    }
}
