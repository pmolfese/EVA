//
//  CleaningVarianceAccount.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A uniform answer to "how much did this cleaning stage actually remove?",
//  reported the same way by every stage that modifies the signal.
//
//  ## Why this exists
//
//  EVA's cleaning stages each reported their effect differently, or not at all.
//  Wavelet reduction produced `WaveletChannelReductionMetrics`; gradient
//  correction, ICA component removal, CWL, and the artifact cleaner produced
//  nothing comparable. A user running gradient -> ICA -> wavelet therefore got
//  a variance-accounting number from exactly one of three stages, and no way to
//  compare them.
//
//  The quantity itself is deliberately plain: the variance of what was removed,
//  as a fraction of the variance of what went in.
//
//      removedFraction = var(original - cleaned) / var(original)
//
//  It is not a quality score and should not be read as one. A large fraction
//  means a stage was aggressive, which is correct behaviour on a badly
//  contaminated channel and a red flag on a clean one. Its value is that it is
//  the *same* number everywhere, so it can be compared across stages, across
//  channels, across epochs, and between paired runs.
//
//  ## Interpretation
//
//  - Near 0: the stage barely touched this channel.
//  - Near 1: almost everything was classified as artifact. On a real channel
//    that usually means the channel is broken, not that the stage did well.
//  - Above 1: possible, and worth surfacing rather than hiding. It means the
//    removed estimate has more variance than the input, which happens when a
//    stage *adds* variance (a badly scaled template subtraction, a filter with
//    gain) rather than only subtracting it.
//
//  ## Undefined cases
//
//  A flat channel has zero input variance, so the fraction is undefined rather
//  than infinite. Those channels are listed in `undefinedChannels` instead of
//  being given a sentinel value: infinities do not survive JSON encoding, and a
//  silently substituted 0 or 1 would be indistinguishable from a real result.
//
//  ## Scope
//
//  This type reports. It does not decide. Thresholding it into a rejection
//  decision belongs to the caller (channel health, epoch rejection), driven by
//  a user-visible setting.
//

import Foundation

nonisolated struct CleaningVarianceAccount: Codable, Sendable, Equatable {

    /// Identifies the stage that produced this account, for the process log and
    /// the `eva.xml` sidecar. Stable across runs; not localized.
    var stageName: String

    /// Channels this account covers. A stage that cleans a subset reports only
    /// that subset, so an absent channel means "not processed", not "unchanged".
    var channelIndices: [Int]

    /// var(removed) / var(original), pooled over every accounted channel.
    var globalRemovedFraction: Double

    /// Per-channel removed fraction, keyed by channel index. Channels with zero
    /// input variance are absent here and listed in `undefinedChannels`.
    var removedFractionByChannel: [Int: Double]

    /// Accounted channels whose input variance was zero, leaving the fraction
    /// undefined. Usually flat or disconnected electrodes.
    var undefinedChannels: [Int]

    /// RMS of the removed signal per channel, in the data's own units
    /// (microvolts for EEG). Complements the fraction: a large fraction on a
    /// low-amplitude channel and a large fraction on a high-amplitude one are
    /// very different events, and the ratio alone cannot tell them apart.
    var removedRMSByChannel: [Int: Double]

    /// Removed fraction per fixed-length epoch, pooled across accounted
    /// channels. `nil` for an epoch with zero input variance. Empty when the
    /// account was built without an epoch grid.
    var removedFractionByEpoch: [Double?]

    /// Epoch length used for `removedFractionByEpoch`, when there is one.
    var epochSeconds: Double?

    /// The epoch grid every stage uses for its per-epoch breakdown.
    ///
    /// Fixed rather than per-stage on purpose: two stages' epoch series are
    /// only comparable — and only diffable between paired runs — if they are
    /// on the same grid. One second is short enough to localize a blink or a
    /// movement burst and long enough for a stable variance estimate at every
    /// sampling rate EVA reads.
    static let defaultEpochSeconds: Double = 1

    // MARK: - Construction

    /// Builds an account from the signal before and after a stage.
    ///
    /// - Parameters:
    ///   - original: channels x samples, before the stage.
    ///   - cleaned: channels x samples, after the stage. Must match `original`
    ///     in shape.
    ///   - channelIndices: rows to account for. Defaults to every row.
    ///   - samplingRate: required only when `epochSeconds` is supplied.
    ///   - epochSeconds: when set, also computes the per-epoch breakdown.
    static func between(
        original: [[Float]],
        cleaned: [[Float]],
        channelIndices: [Int]? = nil,
        samplingRate: Double? = nil,
        epochSeconds: Double? = nil,
        stageName: String
    ) -> CleaningVarianceAccount {
        let indices = resolvedIndices(channelIndices, rowCount: min(original.count, cleaned.count))
        let removed = indices.map { index -> [Double] in
            let before = original[index]
            let after = cleaned[index]
            let count = min(before.count, after.count)
            var difference = [Double](repeating: 0, count: count)
            for sample in 0..<count { difference[sample] = Double(before[sample]) - Double(after[sample]) }
            return difference
        }
        return account(
            original: original, removedRows: removed, indices: indices,
            samplingRate: samplingRate, epochSeconds: epochSeconds, stageName: stageName
        )
    }

    /// Builds an account from an explicit artifact estimate, for stages that
    /// produce one directly rather than only a cleaned signal.
    ///
    /// Equivalent to `between(original:cleaned:)` when
    /// `artifact == original - cleaned`, which is the invariant those stages
    /// are expected to hold.
    static func fromArtifact(
        original: [[Float]],
        artifact: [[Float]],
        channelIndices: [Int]? = nil,
        samplingRate: Double? = nil,
        epochSeconds: Double? = nil,
        stageName: String
    ) -> CleaningVarianceAccount {
        let indices = resolvedIndices(channelIndices, rowCount: min(original.count, artifact.count))
        let removed = indices.map { artifact[$0].map(Double.init) }
        return account(
            original: original, removedRows: removed, indices: indices,
            samplingRate: samplingRate, epochSeconds: epochSeconds, stageName: stageName
        )
    }

    /// Convenience for the common case where both sides are full recordings.
    static func between(
        original: MFFSignalData,
        cleaned: MFFSignalData,
        channelIndices: [Int]? = nil,
        epochSeconds: Double? = nil,
        stageName: String
    ) -> CleaningVarianceAccount {
        between(
            original: original.data, cleaned: cleaned.data,
            channelIndices: channelIndices,
            samplingRate: original.samplingRate, epochSeconds: epochSeconds,
            stageName: stageName
        )
    }

    // MARK: - Core

    private static func resolvedIndices(_ requested: [Int]?, rowCount: Int) -> [Int] {
        guard let requested else { return Array(0..<rowCount) }
        return requested.filter { $0 >= 0 && $0 < rowCount }
    }

    /// Shared body. `removedRows` is parallel to `indices`, already in Double.
    private static func account(
        original: [[Float]],
        removedRows: [[Double]],
        indices: [Int],
        samplingRate: Double?,
        epochSeconds: Double?,
        stageName: String
    ) -> CleaningVarianceAccount {
        var fractionByChannel: [Int: Double] = [:]
        var rmsByChannel: [Int: Double] = [:]
        var undefined: [Int] = []

        // Pooled sums, so the global figure is variance-weighted across
        // channels rather than an unweighted mean of per-channel ratios. A
        // mean of ratios would let a quiet channel outvote a loud one.
        var pooledOriginal = 0.0
        var pooledRemoved = 0.0

        for (slot, channel) in indices.enumerated() {
            let removed = removedRows[slot]
            let before = original[channel].prefix(removed.count).map(Double.init)

            let originalVariance = SignalStatistics.populationVariance(before)
            let removedVariance = SignalStatistics.populationVariance(removed)

            pooledOriginal += originalVariance
            pooledRemoved += removedVariance

            rmsByChannel[channel] = SignalStatistics.rootMeanSquare(removed)

            if originalVariance > 0 {
                fractionByChannel[channel] = removedVariance / originalVariance
            } else {
                undefined.append(channel)
            }
        }

        let global = pooledOriginal > 0 ? pooledRemoved / pooledOriginal : 0

        var byEpoch: [Double?] = []
        if let epochSeconds, let samplingRate, epochSeconds > 0, samplingRate > 0 {
            byEpoch = epochBreakdown(
                original: original, removedRows: removedRows, indices: indices,
                epochSamples: max(Int((epochSeconds * samplingRate).rounded()), 1)
            )
        }

        return CleaningVarianceAccount(
            stageName: stageName,
            channelIndices: indices,
            globalRemovedFraction: global,
            removedFractionByChannel: fractionByChannel,
            undefinedChannels: undefined,
            removedRMSByChannel: rmsByChannel,
            removedFractionByEpoch: byEpoch,
            epochSeconds: byEpoch.isEmpty ? nil : epochSeconds
        )
    }

    /// Pooled removed fraction within each consecutive block of
    /// `epochSamples`. A trailing partial block is included; it is shorter, so
    /// its variance estimate is noisier, but dropping it would silently lose
    /// the end of the recording where movement artifacts cluster.
    private static func epochBreakdown(
        original: [[Float]],
        removedRows: [[Double]],
        indices: [Int],
        epochSamples: Int
    ) -> [Double?] {
        let sampleCount = removedRows.map(\.count).min() ?? 0
        guard sampleCount > 0 else { return [] }
        let epochCount = Int(ceil(Double(sampleCount) / Double(epochSamples)))

        var result: [Double?] = []
        result.reserveCapacity(epochCount)

        for epoch in 0..<epochCount {
            let start = epoch * epochSamples
            let end = min(start + epochSamples, sampleCount)
            guard end > start else { continue }

            var pooledOriginal = 0.0
            var pooledRemoved = 0.0
            for (slot, channel) in indices.enumerated() {
                let before = original[channel][start..<end].map(Double.init)
                let removed = Array(removedRows[slot][start..<end])
                pooledOriginal += SignalStatistics.populationVariance(before)
                pooledRemoved += SignalStatistics.populationVariance(removed)
            }
            result.append(pooledOriginal > 0 ? pooledRemoved / pooledOriginal : nil)
        }
        return result
    }
}

// MARK: - Reporting

extension CleaningVarianceAccount {

    /// One line for the process log and the audit trail.
    ///
    /// Leads with the pooled figure, then names the channels that carry it.
    /// The pooled number alone is not actionable — 12% removed spread evenly
    /// across a montage and 12% removed almost entirely from three electrodes
    /// are different findings, and only the second is a channel problem.
    ///
    /// - Parameters:
    ///   - channelNames: labels indexed by channel, when available. Falls back
    ///     to `#index` so the line is still readable without a montage.
    ///   - topChannelCount: how many of the worst channels to name.
    func summary(channelNames: [String]? = nil, topChannelCount: Int = 3) -> String {
        func label(_ index: Int) -> String {
            guard let channelNames, channelNames.indices.contains(index) else { return "#\(index)" }
            return channelNames[index]
        }
        func percent(_ fraction: Double) -> String {
            String(format: "%.1f%%", fraction * 100)
        }

        var line = "\(stageName) removed \(percent(globalRemovedFraction)) of variance"
        line += " across \(channelIndices.count) channel\(channelIndices.count == 1 ? "" : "s")"

        let ranked = removedFractionByChannel
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(max(topChannelCount, 0))
        if !ranked.isEmpty {
            let named = ranked.map { "\(label($0.key)) \(percent($0.value))" }
            line += "; most affected " + named.joined(separator: ", ")
        }

        if !undefinedChannels.isEmpty {
            let count = undefinedChannels.count
            line += "; \(count) flat channel\(count == 1 ? "" : "s") unaccounted"
        }

        // Epoch detail only earns its place when one epoch stands out. The
        // comparison is against the *median* epoch, not the global figure: a
        // burst large enough to be worth naming also dominates the pooled
        // variance, so measuring it against the global fraction can never
        // fire. Against the median it fires exactly when the removal is
        // localized, which is the thing worth saying.
        let epochValues = removedFractionByEpoch.enumerated().compactMap { index, value in
            value.map { (index: index, value: $0) }
        }
        let median = SignalStatistics.percentile(epochValues.map(\.value).sorted(), fraction: 0.5)
        if let worst = epochValues.max(by: { $0.value < $1.value }),
           worst.value > 0, worst.value > median * 2,
           let epochSeconds {
            let start = Double(worst.index) * epochSeconds
            line += String(format: "; peak at %.1fs (%@)", start, percent(worst.value))
        }

        return line
    }
}

extension CleaningVarianceAccount {

    /// The `log_eva_*.txt` form: `key=value` fields rather than prose, matching
    /// the other result lines in [[ProcessingAuditLog]], and 1-based channel
    /// numbers matching how that file names channels everywhere else.
    var auditLogLine: String {
        func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

        var fields = [
            "removed=\(percent(globalRemovedFraction))",
            "channels=\(channelIndices.count)"
        ]

        let ranked = removedFractionByChannel
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(3)
            .map { "\($0.key + 1):\(percent($0.value))" }
        if !ranked.isEmpty {
            fields.append("worst=\(ranked.joined(separator: ","))")
        }
        if !undefinedChannels.isEmpty {
            fields.append("flatUnaccounted=\(undefinedChannels.map { String($0 + 1) }.joined(separator: ","))")
        }
        return "\(stageName) variance: \(fields.joined(separator: ", "))"
    }
}
