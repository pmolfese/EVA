//
//  TrialChannelResidualAnalyzer.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Multichannel leave-one-out residual attribution for Trial Diagnostics.
//  The channel-resolved similarity score can say that a trial is unusual; this
//  analyzer says whether that mismatch is spread across the selected sensor set
//  or is carried mainly by one sensor.
//

import Foundation

nonisolated enum TrialChannelResidualAnalyzer {
    struct ChannelInput: Sendable {
        var channelIndex: Int
        var channelName: String
        var samples: [Float]
    }

    struct TrialInput: Sendable {
        var trialIndex: Int
        var stimulusOffsetSamples: Int
        var channels: [ChannelInput]
    }

    enum Pattern: String, Sendable, Equatable {
        case localized
        case distributed
    }

    struct ChannelContribution: Identifiable, Sendable, Equatable {
        var id: Int { channelIndex }
        var channelIndex: Int
        var channelName: String
        /// RMS(trial − leave-one-out reference) / RMS(reference), within the
        /// union of the configured windows.
        var normalizedResidualRMS: Double
        /// This channel's share of the trial's total squared normalized
        /// residual. Shares sum to one whenever any residual is present.
        var contributionFraction: Double
    }

    struct TrialResult: Identifiable, Sendable, Equatable {
        var id: Int { trialIndex }
        var trialIndex: Int
        var channels: [ChannelContribution]
        var pattern: Pattern
        var dominantChannelIndex: Int?
        var dominantContributionFraction: Double
        /// Inverse Simpson concentration. Near one means one sensor carries the
        /// mismatch; near the channel count means it is broadly distributed.
        var effectiveChannelCount: Double
        /// RMS of the per-channel normalized residuals.
        var totalNormalizedResidualRMS: Double
    }

    struct Summary: Sendable, Equatable {
        var trials: [TrialResult]
        var channelCount: Int
    }

    static func analyze(
        trials: [TrialInput],
        samplingRate: Double,
        windows: [TrialAlignmentMetrics.AnalysisWindow]
    ) -> Summary? {
        guard trials.count >= 2, samplingRate > 0 else { return nil }
        let commonChannelIDs = Set(trials[0].channels.map(\.channelIndex)).filter { channelID in
            trials.allSatisfy { trial in trial.channels.contains { $0.channelIndex == channelID } }
        }
        guard !commonChannelIDs.isEmpty else { return nil }

        let orderedChannelIDs = trials[0].channels.map(\.channelIndex).filter(commonChannelIDs.contains)
        let results = trials.indices.compactMap { trialOffset -> TrialResult? in
            let trial = trials[trialOffset]
            var residuals: [(
                channel: ChannelInput,
                normalized: Double,
                residualEnergy: Double,
                referenceEnergy: Double
            )] = []

            for channelID in orderedChannelIDs {
                guard let channel = trial.channels.first(where: { $0.channelIndex == channelID }),
                      let reference = leaveOneOutReference(
                        trials: trials,
                        excluding: trialOffset,
                        channelID: channelID
                      ) else { continue }
                let length = min(channel.samples.count, reference.count)
                guard length > 0 else { continue }
                let ranges = mergedRanges(
                    windows: windows,
                    stimulusOffsetSamples: trial.stimulusOffsetSamples,
                    samplingRate: samplingRate,
                    length: length
                )
                guard !ranges.isEmpty else { continue }

                var residualEnergy = 0.0
                var referenceEnergy = 0.0
                var sampleCount = 0
                for range in ranges {
                    for sample in range {
                        let value = Double(channel.samples[sample])
                        let expected = reference[sample]
                        let difference = value - expected
                        residualEnergy += difference * difference
                        referenceEnergy += expected * expected
                        sampleCount += 1
                    }
                }
                guard sampleCount > 0 else { continue }
                // A nearly flat reference still needs to expose an artifact.
                // The small absolute floor prevents division by zero without
                // making a quiet sensor dominate merely because it is quiet.
                let scale = max(referenceEnergy, Double(sampleCount) * 1e-12)
                let normalizedEnergy = residualEnergy / scale
                residuals.append((channel, sqrt(normalizedEnergy), residualEnergy, referenceEnergy))
            }

            guard !residuals.isEmpty else { return nil }
            let totalResidualEnergy = residuals.reduce(0) { $0 + $1.residualEnergy }
            let totalReferenceEnergy = residuals.reduce(0) { $0 + $1.referenceEnergy }
            let uniformShare = 1.0 / Double(residuals.count)
            let contributions = residuals.map { item in
                ChannelContribution(
                    channelIndex: item.channel.channelIndex,
                    channelName: item.channel.channelName,
                    normalizedResidualRMS: item.normalized,
                    contributionFraction: totalResidualEnergy > 1e-12
                        ? item.residualEnergy / totalResidualEnergy
                        : uniformShare
                )
            }
            let dominant = contributions.max { $0.contributionFraction < $1.contributionFraction }
            let dominantShare = dominant?.contributionFraction ?? 0
            let concentration = contributions.reduce(0) {
                $0 + $1.contributionFraction * $1.contributionFraction
            }
            let effectiveCount = concentration > 1e-12 ? 1 / concentration : Double(contributions.count)
            // Two equally bad sensors should read distributed. A sensor must
            // carry at least twice its equal-share expectation, with sensible
            // bounds for very small and very large channel sets.
            let localizedThreshold = min(0.75, max(0.25, 2 * uniformShare))

            return TrialResult(
                trialIndex: trial.trialIndex,
                channels: contributions,
                pattern: contributions.count > 1 && dominantShare >= localizedThreshold
                    ? .localized
                    : .distributed,
                dominantChannelIndex: dominant?.channelIndex,
                dominantContributionFraction: dominantShare,
                effectiveChannelCount: effectiveCount,
                totalNormalizedResidualRMS: sqrt(
                    totalResidualEnergy / max(totalReferenceEnergy, Double(residuals.count) * 1e-12)
                )
            )
        }

        guard !results.isEmpty else { return nil }
        return Summary(trials: results, channelCount: orderedChannelIDs.count)
    }

    private static func leaveOneOutReference(
        trials: [TrialInput],
        excluding excludedOffset: Int,
        channelID: Int
    ) -> [Double]? {
        let samples = trials.indices.compactMap { offset -> [Float]? in
            guard offset != excludedOffset else { return nil }
            return trials[offset].channels.first { $0.channelIndex == channelID }?.samples
        }
        guard let length = samples.map(\.count).min(), length > 0 else { return nil }
        var average = [Double](repeating: 0, count: length)
        for series in samples {
            for sample in 0..<length { average[sample] += Double(series[sample]) }
        }
        let divisor = Double(samples.count)
        for sample in average.indices { average[sample] /= divisor }
        return average
    }

    private static func mergedRanges(
        windows: [TrialAlignmentMetrics.AnalysisWindow],
        stimulusOffsetSamples: Int,
        samplingRate: Double,
        length: Int
    ) -> [Range<Int>] {
        let ranges: [Range<Int>]
        if windows.isEmpty {
            ranges = [0..<length]
        } else {
            ranges = windows.compactMap {
                $0.sampleRange(
                    stimulusOffsetSamples: stimulusOffsetSamples,
                    samplingRate: samplingRate,
                    length: length
                )
            }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in sorted {
            guard let last = merged.last, range.lowerBound <= last.upperBound else {
                merged.append(range)
                continue
            }
            merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        }
        return merged
    }
}
