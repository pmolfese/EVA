//
//  SignalComparison.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  "What did that choice actually buy me?" — measured, between the signals two
//  recording windows are showing (ROADMAP RW-1 item 10).
//
//  ## Why alignment is the hard half
//
//  The two windows are usually the same file at two points in one history, so
//  the naive answer — subtract row *i* from row *i* — is right most of the time
//  and wrong exactly when it matters: after an interpolation that dropped a
//  channel, after an import that renamed one, or when one side is epoched and
//  the other is not. Comparing mismatched rows produces a large, confident,
//  meaningless difference, which is worse than refusing.
//
//  So the alignment is explicit and reported: channels match by name when both
//  sides have names, samples truncate to the shorter of the two, and a sampling
//  rate mismatch is refused rather than resampled. Anything dropped is named in
//  the result, because a comparison over 31 of 32 channels is a different claim
//  from one over all 32.
//
//  Pure and `nonisolated`: no view models, no windows — the registry supplies
//  two signals and this says how they differ.
//

import Foundation

nonisolated struct SignalComparison: Sendable {

    /// How one channel of A differs from the same channel of B.
    struct ChannelDifference: Sendable, Identifiable, Equatable {
        var name: String
        var indexA: Int
        var indexB: Int
        /// RMS of (A − B), in the signal's own units.
        var rmsDifference: Double
        var maxAbsDifference: Double
        /// Pearson correlation between the two traces. `nil` when either side is
        /// constant, where correlation is undefined rather than zero.
        var correlation: Double?
        /// `rmsDifference` as a fraction of A's own RMS — "how much of this
        /// channel changed". `nil` when A is silent.
        var relativeChange: Double?

        var id: String { "\(indexA)-\(indexB)-\(name)" }
    }

    struct Result: Sendable, Equatable {
        /// Per channel, ordered by descending `rmsDifference`: the channels that
        /// changed most are the reason anyone opened this.
        var channels: [ChannelDifference]
        var comparedSampleCount: Int
        var samplingRate: Double
        /// Channels present in one signal and not matched in the other.
        var unmatchedInA: [String]
        var unmatchedInB: [String]
        /// Samples dropped from the longer signal to align lengths.
        var truncatedSamples: Int
        /// RMS of the difference pooled over every aligned channel.
        var overallRMSDifference: Double
        /// True when every aligned sample is bit-for-bit equal.
        var isIdentical: Bool

        var alignedChannelCount: Int { channels.count }

        /// One line for the sheet header: what was actually compared.
        var alignmentSummary: String {
            var parts = ["\(alignedChannelCount) channel\(alignedChannelCount == 1 ? "" : "s")"]
            parts.append(String(format: "%.1f s", Double(comparedSampleCount) / max(samplingRate, 1)))
            if truncatedSamples > 0 {
                parts.append("\(truncatedSamples) sample\(truncatedSamples == 1 ? "" : "s") trimmed")
            }
            let unmatched = unmatchedInA.count + unmatchedInB.count
            if unmatched > 0 { parts.append("\(unmatched) unmatched") }
            return parts.joined(separator: " · ")
        }
    }

    enum Failure: LocalizedError, Equatable {
        case samplingRateMismatch(Double, Double)
        case noCommonChannels
        case noSamples

        var errorDescription: String? {
            switch self {
            case .samplingRateMismatch(let a, let b):
                return "These windows are at different sampling rates (\(Self.rate(a)) and \(Self.rate(b))). "
                    + "Comparing them would mean resampling one, which changes the thing being measured."
            case .noCommonChannels:
                return "No channels could be matched between these two windows."
            case .noSamples:
                return "One of these windows has no samples to compare."
            }
        }

        private static func rate(_ value: Double) -> String {
            String(format: "%.0f Hz", value)
        }
    }

    /// Compares `a` against `b`, aligning channels by name where possible.
    ///
    /// Directional: differences are `A − B`, and `relativeChange` is measured
    /// against A. Swapping the arguments changes the sign of nothing reported
    /// here — every statistic is symmetric in magnitude — but it does change
    /// which side "relative" is relative to.
    static func compare(_ a: MFFSignalData, _ b: MFFSignalData) throws -> Result {
        guard a.samplingRate > 0, b.samplingRate > 0,
              abs(a.samplingRate - b.samplingRate) < 1e-6 else {
            throw Failure.samplingRateMismatch(a.samplingRate, b.samplingRate)
        }
        let lengthA = a.data.first?.count ?? 0
        let lengthB = b.data.first?.count ?? 0
        guard lengthA > 0, lengthB > 0 else { throw Failure.noSamples }

        let pairs = channelPairs(a, b)
        guard !pairs.matched.isEmpty else { throw Failure.noCommonChannels }

        let length = min(lengthA, lengthB)
        var differences: [ChannelDifference] = []
        differences.reserveCapacity(pairs.matched.count)
        var pooledSquares = 0.0
        var pooledCount = 0
        var identical = true

        for pair in pairs.matched {
            let rowA = a.data[pair.indexA]
            let rowB = b.data[pair.indexB]
            let count = min(min(rowA.count, rowB.count), length)
            guard count > 0 else { continue }

            var sumSquares = 0.0
            var maxAbs = 0.0
            var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
            for index in 0..<count {
                let valueA = Double(rowA[index])
                let valueB = Double(rowB[index])
                let difference = valueA - valueB
                if difference != 0 { identical = false }
                sumSquares += difference * difference
                maxAbs = max(maxAbs, abs(difference))
                sumA += valueA; sumB += valueB
                sumAA += valueA * valueA; sumBB += valueB * valueB
                sumAB += valueA * valueB
            }

            let n = Double(count)
            let rms = (sumSquares / n).squareRoot()
            let rmsA = (sumAA / n).squareRoot()
            let varianceA = max(sumAA / n - (sumA / n) * (sumA / n), 0)
            let varianceB = max(sumBB / n - (sumB / n) * (sumB / n), 0)
            let covariance = sumAB / n - (sumA / n) * (sumB / n)
            let denominator = (varianceA * varianceB).squareRoot()

            differences.append(ChannelDifference(
                name: pair.name,
                indexA: pair.indexA,
                indexB: pair.indexB,
                rmsDifference: rms,
                maxAbsDifference: maxAbs,
                // A flat channel has no variance to correlate; reporting 0 there
                // would read as "completely unrelated" rather than "undefined".
                correlation: denominator > 1e-12 ? covariance / denominator : nil,
                relativeChange: rmsA > 1e-12 ? rms / rmsA : nil
            ))
            pooledSquares += sumSquares
            pooledCount += count
        }

        guard !differences.isEmpty else { throw Failure.noCommonChannels }

        return Result(
            channels: differences.sorted { $0.rmsDifference > $1.rmsDifference },
            comparedSampleCount: length,
            samplingRate: a.samplingRate,
            unmatchedInA: pairs.unmatchedInA,
            unmatchedInB: pairs.unmatchedInB,
            truncatedSamples: abs(lengthA - lengthB),
            overallRMSDifference: pooledCount > 0 ? (pooledSquares / Double(pooledCount)).squareRoot() : 0,
            isIdentical: identical
        )
    }

    /// Decimated traces for one channel: A, B, and A − B, over a sample range.
    ///
    /// Plot-facing, so it thins by striding rather than averaging — an averaged
    /// preview would smooth away the spikes that are usually the reason for
    /// looking, and this view is a diagnostic, not a figure.
    static func traces(
        a: MFFSignalData,
        b: MFFSignalData,
        difference: ChannelDifference,
        range: Range<Int>? = nil,
        maximumPoints: Int = 1_200
    ) -> (a: [Float], b: [Float], difference: [Float], startSample: Int, stride: Int) {
        guard difference.indexA < a.data.count, difference.indexB < b.data.count else {
            return ([], [], [], 0, 1)
        }
        let rowA = a.data[difference.indexA]
        let rowB = b.data[difference.indexB]
        let available = min(rowA.count, rowB.count)
        let requested = range ?? 0..<available
        let lower = min(max(requested.lowerBound, 0), max(available - 1, 0))
        let upper = min(max(requested.upperBound, lower), available)
        let count = upper - lower
        guard count > 0 else { return ([], [], [], lower, 1) }

        let stride = max(Int((Double(count) / Double(max(maximumPoints, 1))).rounded(.up)), 1)
        var tracesA: [Float] = [], tracesB: [Float] = [], tracesDifference: [Float] = []
        tracesA.reserveCapacity(count / stride + 1)
        tracesB.reserveCapacity(count / stride + 1)
        tracesDifference.reserveCapacity(count / stride + 1)
        var index = lower
        while index < upper {
            tracesA.append(rowA[index])
            tracesB.append(rowB[index])
            tracesDifference.append(rowA[index] - rowB[index])
            index += stride
        }
        return (tracesA, tracesB, tracesDifference, lower, stride)
    }

    // MARK: - Channel alignment

    private struct Pair {
        var name: String
        var indexA: Int
        var indexB: Int
    }

    /// Matches channels by name when both signals name them, and by position
    /// otherwise.
    ///
    /// Name matching is the safe rule for the case this feature exists for: two
    /// windows on one recording where one of them has been through a stage that
    /// reordered or dropped rows. Positional matching is the fallback for
    /// signals with no names at all, where position is the only identity there
    /// is — and it is capped at the shorter signal rather than assuming the
    /// extra rows in the longer one belong nowhere.
    private static func channelPairs(
        _ a: MFFSignalData,
        _ b: MFFSignalData
    ) -> (matched: [Pair], unmatchedInA: [String], unmatchedInB: [String]) {
        guard let namesA = a.channelNames, let namesB = b.channelNames,
              !namesA.isEmpty, !namesB.isEmpty else {
            let shared = min(a.data.count, b.data.count)
            let matched = (0..<shared).map { index in
                Pair(name: "Channel \(index + 1)", indexA: index, indexB: index)
            }
            let extraInA = (shared..<a.data.count).map { "Channel \($0 + 1)" }
            let extraInB = (shared..<b.data.count).map { "Channel \($0 + 1)" }
            return (matched, extraInA, extraInB)
        }

        var indicesByNameB: [String: Int] = [:]
        for (index, name) in namesB.enumerated() where index < b.data.count {
            // First occurrence wins: a duplicated name is ambiguous, and
            // silently pairing the second one is a guess.
            if indicesByNameB[name] == nil { indicesByNameB[name] = index }
        }

        var matched: [Pair] = []
        var unmatchedInA: [String] = []
        var usedB = Set<Int>()
        for (index, name) in namesA.enumerated() where index < a.data.count {
            if let indexB = indicesByNameB[name], !usedB.contains(indexB) {
                matched.append(Pair(name: name, indexA: index, indexB: indexB))
                usedB.insert(indexB)
            } else {
                unmatchedInA.append(name)
            }
        }
        let unmatchedInB = namesB.enumerated()
            .filter { $0.offset < b.data.count && !usedB.contains($0.offset) }
            .map(\.element)
        return (matched, unmatchedInA, unmatchedInB)
    }
}
