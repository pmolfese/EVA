//
//  TimeFrequencyTrials.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Turns epoched segments + a raw recording into the equal-length,
//  channel-resolved trial stack the time-frequency engine consumes. This is the
//  same "average across the selected channels over the segment's sample range"
//  reduction the Trials workspace uses (`channelResolvedSamples`), factored out
//  so the TF view and its tests share one definition and don't depend on the
//  waveform view's private plumbing.
//

import Foundation

nonisolated enum TimeFrequencyTrials {

    /// A prepared trial stack for one condition.
    struct Stack: Sendable {
        /// `trials[trialIndex][timeIndex]`, all trimmed to a common length.
        var trials: [[Double]]
        /// Samples per second (from the source recording).
        var samplingRate: Double
        /// Event (t = 0) sample index within each trimmed trial. Sub-stimulus
        /// samples are the pre-stimulus baseline period.
        var stimulusOffsetSamples: Int

        var isEmpty: Bool { trials.isEmpty }
        var timeCount: Int { trials.first?.count ?? 0 }
    }

    /// Builds a channel-resolved trial stack for `category` from `segments`.
    ///
    /// Each trial is the mean of `channelIndices` over the segment's
    /// `[startSample, endSample]` range. Trials are trimmed to the shortest
    /// length present so the engine sees a rectangular stack; the representative
    /// stimulus offset is the smallest across the kept segments (clamped to the
    /// trimmed length).
    static func stack(
        signal: MFFSignalData,
        segments: [EpochSegment],
        category: String,
        channelIndices: [Int]
    ) -> Stack {
        let matching = segments.filter { $0.category == category }
        guard !matching.isEmpty, signal.samplingRate > 0 else {
            return Stack(trials: [], samplingRate: signal.samplingRate, stimulusOffsetSamples: 0)
        }

        var trials: [[Double]] = []
        trials.reserveCapacity(matching.count)
        var minLength = Int.max
        var minOffset = Int.max
        for segment in matching {
            let series = channelResolved(
                signal: signal,
                startSample: segment.startSample,
                endSample: segment.endSample,
                channels: channelIndices
            )
            guard !series.isEmpty else { continue }
            trials.append(series)
            minLength = min(minLength, series.count)
            minOffset = min(minOffset, segment.stimulusOffsetSamples)
        }
        guard !trials.isEmpty, minLength > 0 else {
            return Stack(trials: [], samplingRate: signal.samplingRate, stimulusOffsetSamples: 0)
        }

        // Trim to a common length.
        for i in trials.indices where trials[i].count > minLength {
            trials[i] = Array(trials[i].prefix(minLength))
        }
        let offset = max(0, min(minOffset == Int.max ? 0 : minOffset, minLength - 1))
        return Stack(trials: trials, samplingRate: signal.samplingRate, stimulusOffsetSamples: offset)
    }

    /// Mean across `channels` of `signal` over `[startSample, endSample]`,
    /// returned as `Double`. Mirrors the Trials workspace reduction.
    private static func channelResolved(
        signal: MFFSignalData,
        startSample: Int,
        endSample: Int,
        channels: [Int]
    ) -> [Double] {
        guard endSample >= startSample, startSample >= 0 else { return [] }
        let valid = channels.filter { signal.data.indices.contains($0) }
        guard !valid.isEmpty else { return [] }
        let length = endSample - startSample + 1
        var result = [Double](repeating: 0, count: length)
        var contributing = 0
        for channel in valid {
            let series = signal.data[channel]
            guard endSample < series.count else { continue }
            for i in 0..<length { result[i] += Double(series[startSample + i]) }
            contributing += 1
        }
        guard contributing > 0 else { return [] }
        let divisor = Double(contributing)
        for i in 0..<length { result[i] /= divisor }
        return result
    }
}
