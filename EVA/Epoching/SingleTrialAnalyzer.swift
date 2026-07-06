//
//  SingleTrialAnalyzer.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Pure computation for "Single Trial Analysis": given the per-trial epochs a
//  PSA segmentation produced (before they got collapsed into the average) plus
//  the grand average itself, extracts per-trial amplitude/latency measures
//  within a user-picked time window, split-half-style trend comparisons, and a
//  retained-trial-count distribution across the recording.
//
//  All measures are computed relative to the *grand average's* peak latency
//  (found once, per polarity, within the window) except the "own latency"
//  peak, which is each trial's own independent extremum — see field docs on
//  `SingleTrialValue`.
//

import Foundation

nonisolated enum SingleTrialAnalyzer {
    /// One input trial: an already channel-resolved series (a single channel,
    /// or an ROI average across several — the caller does that averaging
    /// before this point, so everything downstream is a plain `[Float]`).
    struct TrialInput: Sendable {
        var sourceTimeSeconds: Double
        var stimulusOffsetSamples: Int
        var samples: [Float]
    }

    struct SingleTrialValue: Identifiable, Sendable {
        var id: Int
        var trialIndex: Int
        var sourceTimeSeconds: Double
        /// Plain average over the whole selected window — no latency search.
        /// Use a window centered on your component of interest; there's no
        /// separate positive/negative variant since a fixed window has no
        /// polarity of its own.
        var meanAmplitude: Double
        /// Amplitude at the SAME sample offset as the grand average's
        /// positive/negative peak (every trial read at one shared latency).
        var peakAmplitudeAtAverageLatencyPositive: Double
        var peakAmplitudeAtAverageLatencyNegative: Double
        /// This trial's own independent extremum within the window (its own
        /// latency, not the grand average's).
        var peakAmplitudeOwnLatencyPositive: Double
        var peakLatencyOwnPositiveMs: Double
        var peakAmplitudeOwnLatencyNegative: Double
        var peakLatencyOwnNegativeMs: Double
        /// Average over a short window centered on the grand average's peak
        /// latency (same center for every trial, unlike the per-trial-centered
        /// "own latency" peak) — a middle ground between Mean and Peak.
        var adaptiveMeanAmplitudePositive: Double
        var adaptiveMeanAmplitudeNegative: Double
        /// This trial's own positive-own-latency peak minus its own
        /// negative-own-latency peak (classic N1-P2-style measure).
        var peakToPeakAmplitude: Double
        /// > `outlierThresholdSD` standard deviations from this batch's mean
        /// meanAmplitude — a statistical flag independent of PSA's own
        /// artifact/bad-channel rejection (which already excluded trials
        /// before they ever reached this analyzer).
        var isOutlier: Bool
    }

    struct SplitGroupStats: Identifiable, Sendable {
        var id: Int
        var label: String
        var trialCount: Int
        /// measure name -> (mean, sd) across this group's trials.
        var stats: [String: (mean: Double, sd: Double)]
    }

    struct TimeChunkCount: Identifiable, Sendable {
        var id: Int
        var label: String
        var startSeconds: Double
        var endSeconds: Double
        var retainedTrialCount: Int
    }

    struct Result: Sendable {
        var averagePeakLatencyPositiveMs: Double?
        var averagePeakLatencyNegativeMs: Double?
        var trials: [SingleTrialValue]
        var splitGroups: [SplitGroupStats]
        var distribution: [TimeChunkCount]
    }

    /// - Parameters:
    ///   - averageSamples: the grand-average trace (already channel-resolved)
    ///     for the category being analyzed, used only to locate the shared
    ///     peak latencies — never itself a row in the output.
    ///   - averageStimulusOffsetSamples: sample offset of "0 ms" within
    ///     `averageSamples`.
    ///   - trials: individual pre-average epochs, same channel-resolved shape.
    ///   - windowStartMs/windowEndMs: analysis window, relative to stimulus onset.
    ///   - adaptiveHalfWidthMs: half-width of the adaptive-mean sub-window.
    ///   - splitCount: number of chronological groups for the split comparison
    ///     (2 = first half vs. last half).
    ///   - outlierThresholdSD: trials whose meanAmplitude is this many SDs from
    ///     the batch mean are flagged.
    ///   - distributionChunkCount: number of equal-duration time chunks to
    ///     bucket retained trials into, spanning the trials' own time range.
    static func analyze(
        averageSamples: [Float],
        averageStimulusOffsetSamples: Int,
        samplingRate: Double,
        trials: [TrialInput],
        windowStartMs: Double,
        windowEndMs: Double,
        adaptiveHalfWidthMs: Double,
        splitCount: Int,
        outlierThresholdSD: Double,
        distributionChunkCount: Int
    ) -> Result? {
        guard samplingRate > 0, windowEndMs > windowStartMs, !trials.isEmpty else { return nil }

        guard let averageWindow = sampleRange(
            startMs: windowStartMs, endMs: windowEndMs,
            stimulusOffsetSamples: averageStimulusOffsetSamples,
            samplingRate: samplingRate, length: averageSamples.count
        ) else { return nil }

        let avgPositivePeak = peak(averageSamples, in: averageWindow, positive: true)
        let avgNegativePeak = peak(averageSamples, in: averageWindow, positive: false)
        let averagePeakLatencyPositiveMs = avgPositivePeak.map {
            msFromSample($0.sampleIndex, stimulusOffsetSamples: averageStimulusOffsetSamples, samplingRate: samplingRate)
        }
        let averagePeakLatencyNegativeMs = avgNegativePeak.map {
            msFromSample($0.sampleIndex, stimulusOffsetSamples: averageStimulusOffsetSamples, samplingRate: samplingRate)
        }
        let adaptiveHalfWidthSamples = max(Int((adaptiveHalfWidthMs / 1000.0 * samplingRate).rounded()), 0)

        var rows: [SingleTrialValue] = []
        rows.reserveCapacity(trials.count)

        for (index, trial) in trials.enumerated() {
            guard let window = sampleRange(
                startMs: windowStartMs, endMs: windowEndMs,
                stimulusOffsetSamples: trial.stimulusOffsetSamples,
                samplingRate: samplingRate, length: trial.samples.count
            ) else { continue }

            let meanAmplitude = mean(trial.samples, in: window)
            let ownPositive = peak(trial.samples, in: window, positive: true)
            let ownNegative = peak(trial.samples, in: window, positive: false)

            let avgLatencyPositive = avgPositivePeak.flatMap {
                sampleValue(trial.samples, atAverageSample: $0.sampleIndex, averageStimulusOffsetSamples: averageStimulusOffsetSamples, trialStimulusOffsetSamples: trial.stimulusOffsetSamples)
            } ?? 0
            let avgLatencyNegative = avgNegativePeak.flatMap {
                sampleValue(trial.samples, atAverageSample: $0.sampleIndex, averageStimulusOffsetSamples: averageStimulusOffsetSamples, trialStimulusOffsetSamples: trial.stimulusOffsetSamples)
            } ?? 0

            let adaptivePositive = avgPositivePeak.map {
                adaptiveMean(trial.samples, averageSample: $0.sampleIndex, averageStimulusOffsetSamples: averageStimulusOffsetSamples, trialStimulusOffsetSamples: trial.stimulusOffsetSamples, halfWidthSamples: adaptiveHalfWidthSamples)
            } ?? 0
            let adaptiveNegative = avgNegativePeak.map {
                adaptiveMean(trial.samples, averageSample: $0.sampleIndex, averageStimulusOffsetSamples: averageStimulusOffsetSamples, trialStimulusOffsetSamples: trial.stimulusOffsetSamples, halfWidthSamples: adaptiveHalfWidthSamples)
            } ?? 0

            rows.append(SingleTrialValue(
                id: index,
                trialIndex: index,
                sourceTimeSeconds: trial.sourceTimeSeconds,
                meanAmplitude: meanAmplitude,
                peakAmplitudeAtAverageLatencyPositive: avgLatencyPositive,
                peakAmplitudeAtAverageLatencyNegative: avgLatencyNegative,
                peakAmplitudeOwnLatencyPositive: ownPositive?.value ?? 0,
                peakLatencyOwnPositiveMs: ownPositive.map { msFromSample($0.sampleIndex, stimulusOffsetSamples: trial.stimulusOffsetSamples, samplingRate: samplingRate) } ?? 0,
                peakAmplitudeOwnLatencyNegative: ownNegative?.value ?? 0,
                peakLatencyOwnNegativeMs: ownNegative.map { msFromSample($0.sampleIndex, stimulusOffsetSamples: trial.stimulusOffsetSamples, samplingRate: samplingRate) } ?? 0,
                adaptiveMeanAmplitudePositive: adaptivePositive,
                adaptiveMeanAmplitudeNegative: adaptiveNegative,
                peakToPeakAmplitude: (ownPositive?.value ?? 0) - (ownNegative?.value ?? 0),
                isOutlier: false
            ))
        }

        guard !rows.isEmpty else { return nil }

        rows = flaggingOutliers(rows, thresholdSD: outlierThresholdSD)
        let splitGroups = splitGroupStats(rows, splitCount: max(splitCount, 1))
        let distribution = timeChunkDistribution(rows, chunkCount: max(distributionChunkCount, 1))

        return Result(
            averagePeakLatencyPositiveMs: averagePeakLatencyPositiveMs,
            averagePeakLatencyNegativeMs: averagePeakLatencyNegativeMs,
            trials: rows,
            splitGroups: splitGroups,
            distribution: distribution
        )
    }

    // MARK: - Sample/ms conversion

    private static func sampleRange(
        startMs: Double, endMs: Double, stimulusOffsetSamples: Int, samplingRate: Double, length: Int
    ) -> Range<Int>? {
        guard length > 0 else { return nil }
        let startSample = stimulusOffsetSamples + Int((startMs / 1000.0 * samplingRate).rounded())
        let endSample = stimulusOffsetSamples + Int((endMs / 1000.0 * samplingRate).rounded())
        let lower = max(min(startSample, endSample), 0)
        let upper = min(max(startSample, endSample), length - 1)
        guard lower <= upper else { return nil }
        return lower..<(upper + 1)
    }

    private static func msFromSample(_ sample: Int, stimulusOffsetSamples: Int, samplingRate: Double) -> Double {
        Double(sample - stimulusOffsetSamples) / samplingRate * 1000.0
    }

    /// Reads `trial`'s value at the sample corresponding to the grand
    /// average's `averageSample`, translating between each series' own
    /// stimulus-onset offset (in case they differ).
    private static func sampleValue(
        _ trial: [Float], atAverageSample averageSample: Int,
        averageStimulusOffsetSamples: Int, trialStimulusOffsetSamples: Int
    ) -> Double? {
        let relative = averageSample - averageStimulusOffsetSamples
        let trialSample = trialStimulusOffsetSamples + relative
        guard trial.indices.contains(trialSample) else { return nil }
        return Double(trial[trialSample])
    }

    private static func adaptiveMean(
        _ trial: [Float], averageSample: Int, averageStimulusOffsetSamples: Int,
        trialStimulusOffsetSamples: Int, halfWidthSamples: Int
    ) -> Double {
        let relative = averageSample - averageStimulusOffsetSamples
        let center = trialStimulusOffsetSamples + relative
        let lower = max(center - halfWidthSamples, 0)
        let upper = min(center + halfWidthSamples, trial.count - 1)
        guard lower <= upper else { return 0 }
        return mean(trial, in: lower..<(upper + 1))
    }

    // MARK: - Window math

    private static func mean(_ signal: [Float], in range: Range<Int>) -> Double {
        guard !range.isEmpty else { return 0 }
        var sum = 0.0
        var count = 0
        for i in range where signal.indices.contains(i) {
            sum += Double(signal[i])
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func peak(_ signal: [Float], in range: Range<Int>, positive: Bool) -> (value: Double, sampleIndex: Int)? {
        var best: (value: Float, index: Int)?
        for i in range where signal.indices.contains(i) {
            let v = signal[i]
            if best == nil || (positive ? v > best!.value : v < best!.value) {
                best = (v, i)
            }
        }
        guard let best else { return nil }
        return (Double(best.value), best.index)
    }

    // MARK: - Outliers

    private static func flaggingOutliers(_ rows: [SingleTrialValue], thresholdSD: Double) -> [SingleTrialValue] {
        guard thresholdSD > 0, rows.count > 1 else { return rows }
        let values = rows.map(\.meanAmplitude)
        let (mean, sd) = meanAndSD(values)
        guard sd > 1e-9 else { return rows }
        return rows.map { row in
            var row = row
            row.isOutlier = abs(row.meanAmplitude - mean) > thresholdSD * sd
            return row
        }
    }

    private static func meanAndSD(_ values: [Double]) -> (mean: Double, sd: Double) {
        guard !values.isEmpty else { return (0, 0) }
        let mean = values.reduce(0, +) / Double(values.count)
        guard values.count > 1 else { return (mean, 0) }
        let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return (mean, sqrt(variance))
    }

    // MARK: - Split comparison

    /// Divides `rows` (assumed already in chronological/trial order) into
    /// `splitCount` contiguous, roughly-equal-sized groups and reports
    /// mean/SD of each headline measure per group.
    private static func splitGroupStats(_ rows: [SingleTrialValue], splitCount: Int) -> [SplitGroupStats] {
        guard splitCount > 0, !rows.isEmpty else { return [] }
        let groupSize = max(Int(ceil(Double(rows.count) / Double(splitCount))), 1)
        var groups: [SplitGroupStats] = []
        var start = 0
        var groupIndex = 0
        while start < rows.count {
            let end = min(start + groupSize, rows.count)
            let slice = Array(rows[start..<end])
            let label: String
            if splitCount == 2 {
                label = groupIndex == 0 ? "First Half" : "Last Half"
            } else {
                label = "Group \(groupIndex + 1) of \(splitCount)"
            }
            var stats: [String: (mean: Double, sd: Double)] = [:]
            stats["Mean Amplitude"] = meanAndSD(slice.map(\.meanAmplitude))
            stats["Peak (own latency, +)"] = meanAndSD(slice.map(\.peakAmplitudeOwnLatencyPositive))
            stats["Peak (own latency, −)"] = meanAndSD(slice.map(\.peakAmplitudeOwnLatencyNegative))
            stats["Adaptive Mean (+)"] = meanAndSD(slice.map(\.adaptiveMeanAmplitudePositive))
            stats["Adaptive Mean (−)"] = meanAndSD(slice.map(\.adaptiveMeanAmplitudeNegative))
            stats["Peak-to-Peak"] = meanAndSD(slice.map(\.peakToPeakAmplitude))
            groups.append(SplitGroupStats(id: groupIndex, label: label, trialCount: slice.count, stats: stats))
            start = end
            groupIndex += 1
        }
        return groups
    }

    // MARK: - Trial-count distribution

    /// Retained-trial count per equal-duration time chunk spanning this
    /// analysis's own trials — answers "how many usable trials are in the
    /// first vs. second part of the recording," not a rejection *rate* (PSA
    /// already dropped rejected trials before they reach this analyzer, and
    /// their timestamps aren't retained, so a true rejection-rate-over-time
    /// breakdown isn't available here).
    private static func timeChunkDistribution(_ rows: [SingleTrialValue], chunkCount: Int) -> [TimeChunkCount] {
        guard chunkCount > 0, !rows.isEmpty else { return [] }
        let times = rows.map(\.sourceTimeSeconds)
        let minTime = times.min() ?? 0
        let maxTime = times.max() ?? minTime
        let span = max(maxTime - minTime, 1e-6)
        let chunkDuration = span / Double(chunkCount)

        var counts = [Int](repeating: 0, count: chunkCount)
        for time in times {
            let index = min(Int((time - minTime) / chunkDuration), chunkCount - 1)
            counts[index] += 1
        }
        return (0..<chunkCount).map { i in
            let chunkStart = minTime + Double(i) * chunkDuration
            let chunkEnd = i == chunkCount - 1 ? maxTime : chunkStart + chunkDuration
            return TimeChunkCount(
                id: i,
                label: "\(formatMinutesSeconds(chunkStart))–\(formatMinutesSeconds(chunkEnd))",
                startSeconds: chunkStart,
                endSeconds: chunkEnd,
                retainedTrialCount: counts[i]
            )
        }
    }

    private static func formatMinutesSeconds(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
