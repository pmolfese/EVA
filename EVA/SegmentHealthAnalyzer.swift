//
//  SegmentHealthAnalyzer.swift
//  EVA
//
//  Copyright (C) 2026 Peter Molfese
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Explainable per-segment signal-quality scoring. This mirrors the channel
//  health path: deterministic metrics first, with a feature schema that can
//  later be used to train a Core ML segment-quality model.
//

import Foundation

nonisolated struct SegmentHealthMetric: Codable, Identifiable, Sendable {
    var name: String
    var score: Double
    var grade: ChannelHealthGrade
    var detail: String
    var weight: Double

    var id: String { name }
}

nonisolated struct SegmentHealthInputSegment: Codable, Identifiable, Sendable {
    var segmentID: String
    var segmentIndex: Int
    var category: String
    var startSample: Int
    var endSample: Int
    var stimulusOffsetSamples: Int?
    var sourceCode: String?
    var sourceTimeSeconds: Double?
    var contributingEpochCount: Int

    var id: String { segmentID }
}

nonisolated struct SegmentHealthArtifactInterval: Codable, Identifiable, Sendable {
    var artifactID: String
    var code: String
    var startSample: Int
    var endSample: Int
    var sourceFile: String

    var id: String { artifactID }
}

nonisolated struct SegmentHealthResult: Codable, Identifiable, Sendable {
    var segmentID: String
    var segmentIndex: Int
    var category: String
    var startSample: Int
    var endSample: Int
    var startTimeSeconds: Double
    var endTimeSeconds: Double
    var durationSeconds: Double
    var stimulusOffsetSamples: Int?
    var sourceCode: String?
    var sourceTimeSeconds: Double?
    var contributingEpochCount: Int
    var goodPercentage: Int
    var grade: ChannelHealthGrade
    var summary: String
    var metrics: [SegmentHealthMetric]

    var id: String { segmentID }
}

nonisolated struct SegmentHealthAnalysis: Sendable {
    var results: [SegmentHealthResult]
    var featuresBySegmentID: [String: SegmentHealthFeatures] = [:]
    var baselines: SegmentHealthBaselines?
    var sampleStride: Int = 1
    var effectiveSamplingRate: Double = 0
    var analyzedSampleCount: Int = 0
    var segmentDefinition: SegmentHealthSegmentDefinition = .continuous
}

nonisolated enum SegmentHealthSegmentDefinition: String, Codable, Sendable {
    case continuous
    case epoch
}

nonisolated struct SegmentHealthFeatures: Codable, Sendable {
    var finiteFraction: Double
    var includedChannelCount: Int
    var includedChannelFraction: Double
    var sampleCount: Int
    var analyzedTimePointCount: Int
    var rmsMicrovolts: Double
    var p95AbsMicrovolts: Double
    var p99AbsMicrovolts: Double
    var maxAbsMicrovolts: Double
    var gfpMedianMicrovolts: Double
    var gfpP95Microvolts: Double
    var gfpMaxMicrovolts: Double
    var derivativeRMSMicrovolts: Double
    var derivativeRatio: Double
    var flatlineFraction: Double
    var clippingFraction: Double
    var driftRMSMicrovolts: Double
    var artifactOverlapFraction: Double
    var artifactCount: Int
    var amplitudeTypicality: Double
    var burstTypicality: Double
    var gfpTypicality: Double
    var gfpBurstTypicality: Double
    var derivativeTypicality: Double
    var driftTypicality: Double
}

nonisolated struct SegmentHealthBaselines: Codable, Sendable {
    var p95AbsMicrovolts: Double
    var p99AbsMicrovolts: Double
    var gfpMedianMicrovolts: Double
    var gfpP95Microvolts: Double
    var gfpP99Microvolts: Double
    var derivativeRatio: Double
}

nonisolated enum SegmentHealthAnalyzer {
    static let continuousWindowSeconds = 2.0

    static func analysisSegments(
        for signal: MFFSignalData,
        epochSegments: [EpochSegment]
    ) -> [SegmentHealthInputSegment] {
        guard let sampleCount = signal.data.first?.count,
              sampleCount > 0,
              signal.samplingRate > 0 else {
            return []
        }

        if !epochSegments.isEmpty {
            return epochSegments.enumerated().map { index, segment in
                SegmentHealthInputSegment(
                    segmentID: "epoch-\(index)-\(segment.startSample)-\(segment.endSample)-\(segment.category)",
                    segmentIndex: index,
                    category: segment.category,
                    startSample: min(max(segment.startSample, 0), sampleCount - 1),
                    endSample: min(max(segment.endSample, segment.startSample), sampleCount - 1),
                    stimulusOffsetSamples: segment.stimulusOffsetSamples,
                    sourceCode: segment.sourceCode,
                    sourceTimeSeconds: segment.sourceTimeSeconds,
                    contributingEpochCount: segment.contributingEpochCount
                )
            }
        }

        let windowSamples = max(Int((continuousWindowSeconds * signal.samplingRate).rounded()), 1)
        var segments: [SegmentHealthInputSegment] = []
        var index = 0
        for start in stride(from: 0, to: sampleCount, by: windowSamples) {
            let end = min(start + windowSamples - 1, sampleCount - 1)
            segments.append(
                SegmentHealthInputSegment(
                    segmentID: "continuous-\(index)-\(start)-\(end)",
                    segmentIndex: index,
                    category: "Continuous",
                    startSample: start,
                    endSample: end,
                    stimulusOffsetSamples: nil,
                    sourceCode: nil,
                    sourceTimeSeconds: nil,
                    contributingEpochCount: 1
                )
            )
            index += 1
        }
        return segments
    }

    static func analyze(
        signal: MFFSignalData,
        segments: [SegmentHealthInputSegment],
        excludedChannelIndices: Set<Int>,
        artifactIntervals: [SegmentHealthArtifactInterval] = [],
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> SegmentHealthAnalysis {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 2,
              !signal.data.isEmpty,
              !segments.isEmpty else {
            return SegmentHealthAnalysis(results: [])
        }

        let sampleStride = analysisStride(sampleCount: sampleCount, samplingRate: signal.samplingRate)
        let includedChannels = includedChannelIndices(in: signal, excluding: excludedChannelIndices)
        let baselines = baselines(for: signal, channels: includedChannels, sampleStride: sampleStride)
        progress?(0.25)

        var results: [SegmentHealthResult] = []
        var featuresBySegmentID: [String: SegmentHealthFeatures] = [:]
        results.reserveCapacity(segments.count)
        featuresBySegmentID.reserveCapacity(segments.count)

        for (offset, segment) in segments.enumerated() {
            if Task.isCancelled {
                return SegmentHealthAnalysis(results: [])
            }
            let summary = summary(
                for: segment,
                signal: signal,
                channels: includedChannels,
                sampleStride: sampleStride,
                baselines: baselines,
                artifactIntervals: artifactIntervals
            )
            let result = result(for: segment, summary: summary, baselines: baselines, signal: signal)
            results.append(result)
            featuresBySegmentID[segment.segmentID] = features(for: summary, baselines: baselines, signal: signal)
            progress?(0.25 + 0.75 * Double(offset + 1) / Double(max(segments.count, 1)))
        }

        return SegmentHealthAnalysis(
            results: results,
            featuresBySegmentID: featuresBySegmentID,
            baselines: baselines,
            sampleStride: sampleStride,
            effectiveSamplingRate: signal.samplingRate / Double(max(sampleStride, 1)),
            analyzedSampleCount: max(sampleCount / max(sampleStride, 1), 1),
            segmentDefinition: segments.contains { $0.sourceCode != nil || $0.stimulusOffsetSamples != nil } ? .epoch : .continuous
        )
    }

    private static func analysisStride(sampleCount: Int, samplingRate: Double) -> Int {
        let targetRateStride = max(Int((samplingRate / 200.0).rounded()), 1)
        let sampleBudgetStride = max(Int((Double(sampleCount) / 120_000.0).rounded(.up)), 1)
        return max(targetRateStride, sampleBudgetStride)
    }

    private static func includedChannelIndices(in signal: MFFSignalData, excluding excluded: Set<Int>) -> [Int] {
        let available = signal.data.indices.filter { !excluded.contains($0) && !signal.data[$0].isEmpty }
        if !available.isEmpty {
            return available
        }
        return signal.data.indices.filter { !signal.data[$0].isEmpty }
    }

    private static func baselines(
        for signal: MFFSignalData,
        channels: [Int],
        sampleStride: Int
    ) -> SegmentHealthBaselines {
        let sampleCount = signal.data.first?.count ?? 0
        let analyzedPoints = max(sampleCount / max(sampleStride, 1), 1)
        let totalObservations = max(analyzedPoints * max(channels.count, 1), 1)
        let captureStride = max(Int((Double(totalObservations) / 100_000.0).rounded(.up)), 1)
        var observationIndex = 0

        var absValues: [Double] = []
        var gfpValues: [Double] = []
        absValues.reserveCapacity(min(totalObservations, 100_000))
        gfpValues.reserveCapacity(analyzedPoints)

        var previousValues = Array<Double?>(repeating: nil, count: signal.data.count)
        var sumSquares = 0.0
        var finiteCount = 0
        var differenceSquares = 0.0
        var differenceCount = 0

        for sample in stride(from: 0, to: sampleCount, by: sampleStride) {
            var sampleSquares = 0.0
            var sampleFiniteCount = 0
            for channelIndex in channels {
                let channel = signal.data[channelIndex]
                guard sample < channel.count else { continue }
                let value = Double(channel[sample])
                guard value.isFinite else {
                    previousValues[channelIndex] = nil
                    continue
                }

                let absValue = abs(value)
                if observationIndex % captureStride == 0 {
                    absValues.append(absValue)
                }
                observationIndex += 1

                sumSquares += value * value
                finiteCount += 1
                sampleSquares += value * value
                sampleFiniteCount += 1

                if let previous = previousValues[channelIndex] {
                    let difference = value - previous
                    differenceSquares += difference * difference
                    differenceCount += 1
                }
                previousValues[channelIndex] = value
            }

            if sampleFiniteCount > 0 {
                gfpValues.append(sqrt(sampleSquares / Double(sampleFiniteCount)))
            }
        }

        absValues.sort()
        gfpValues.sort()
        let rms = finiteCount > 0 ? sqrt(sumSquares / Double(finiteCount)) : 0
        let derivativeRMS = differenceCount > 0 ? sqrt(differenceSquares / Double(differenceCount)) : 0
        let derivativeRatio = derivativeRMS / max(rms, 1e-9)

        return SegmentHealthBaselines(
            p95AbsMicrovolts: max(percentile(absValues, fraction: 0.95), 1e-9),
            p99AbsMicrovolts: max(percentile(absValues, fraction: 0.99), 1e-9),
            gfpMedianMicrovolts: max(percentile(gfpValues, fraction: 0.50), 1e-9),
            gfpP95Microvolts: max(percentile(gfpValues, fraction: 0.95), 1e-9),
            gfpP99Microvolts: max(percentile(gfpValues, fraction: 0.99), 1e-9),
            derivativeRatio: max(derivativeRatio, 1e-9)
        )
    }

    private static func summary(
        for segment: SegmentHealthInputSegment,
        signal: MFFSignalData,
        channels: [Int],
        sampleStride: Int,
        baselines: SegmentHealthBaselines,
        artifactIntervals: [SegmentHealthArtifactInterval]
    ) -> SegmentSummary {
        let sampleCount = signal.data.first?.count ?? 0
        let start = min(max(segment.startSample, 0), max(sampleCount - 1, 0))
        let end = min(max(segment.endSample, start), max(sampleCount - 1, start))
        let segmentSampleCount = max(end - start + 1, 0)
        let artifactOverlap = artifactOverlapSamples(
            in: start...end,
            artifactIntervals: artifactIntervals
        )
        let analyzedPoints = max(Int((Double(segmentSampleCount) / Double(max(sampleStride, 1))).rounded(.up)), 1)
        let totalObservations = max(analyzedPoints * max(channels.count, 1), 1)
        let captureStride = max(Int((Double(totalObservations) / 80_000.0).rounded(.up)), 1)
        let firstCutoff = start + max(segmentSampleCount / 3, 1)
        let lastCutoff = end - max(segmentSampleCount / 3, 1)
        let flatlineThreshold = max(baselines.p95AbsMicrovolts * 0.0001, 1e-7)

        var absValues: [Double] = []
        var gfpValues: [Double] = []
        absValues.reserveCapacity(min(totalObservations, 80_000))
        gfpValues.reserveCapacity(analyzedPoints)

        var previousValues = Array<Double?>(repeating: nil, count: channels.count)
        var firstSums = Array(repeating: 0.0, count: channels.count)
        var firstCounts = Array(repeating: 0, count: channels.count)
        var lastSums = Array(repeating: 0.0, count: channels.count)
        var lastCounts = Array(repeating: 0, count: channels.count)

        var observationIndex = 0
        var finiteCount = 0
        var totalCount = 0
        var sumSquares = 0.0
        var differenceSquares = 0.0
        var differenceCount = 0
        var flatlineCount = 0

        for sample in stride(from: start, through: end, by: sampleStride) {
            var sampleSquares = 0.0
            var sampleFiniteCount = 0

            for (localIndex, channelIndex) in channels.enumerated() {
                totalCount += 1
                let channel = signal.data[channelIndex]
                guard sample < channel.count else {
                    previousValues[localIndex] = nil
                    continue
                }

                let value = Double(channel[sample])
                guard value.isFinite else {
                    previousValues[localIndex] = nil
                    continue
                }

                let absValue = abs(value)
                if observationIndex % captureStride == 0 {
                    absValues.append(absValue)
                }
                observationIndex += 1

                finiteCount += 1
                sumSquares += value * value
                sampleSquares += value * value
                sampleFiniteCount += 1

                if let previous = previousValues[localIndex] {
                    let difference = value - previous
                    differenceSquares += difference * difference
                    differenceCount += 1
                    if abs(difference) <= flatlineThreshold {
                        flatlineCount += 1
                    }
                }
                previousValues[localIndex] = value

                if sample <= firstCutoff {
                    firstSums[localIndex] += value
                    firstCounts[localIndex] += 1
                }
                if sample >= lastCutoff {
                    lastSums[localIndex] += value
                    lastCounts[localIndex] += 1
                }
            }

            if sampleFiniteCount > 0 {
                gfpValues.append(sqrt(sampleSquares / Double(sampleFiniteCount)))
            }
        }

        absValues.sort()
        let maxAbs = absValues.last ?? 0
        let clippingFraction = clippingFraction(absValues: absValues, maxAbs: maxAbs)
        gfpValues.sort()

        var driftValues: [Double] = []
        driftValues.reserveCapacity(channels.count)
        for index in channels.indices {
            guard firstCounts[index] > 0, lastCounts[index] > 0 else { continue }
            let firstMean = firstSums[index] / Double(firstCounts[index])
            let lastMean = lastSums[index] / Double(lastCounts[index])
            driftValues.append(lastMean - firstMean)
        }

        let rms = finiteCount > 0 ? sqrt(sumSquares / Double(finiteCount)) : 0
        let derivativeRMS = differenceCount > 0 ? sqrt(differenceSquares / Double(differenceCount)) : 0
        let derivativeRatio = derivativeRMS / max(rms, 1e-9)

        return SegmentSummary(
            finiteFraction: totalCount > 0 ? Double(finiteCount) / Double(totalCount) : 0,
            includedChannelCount: channels.count,
            includedChannelFraction: Double(channels.count) / Double(max(signal.numberOfChannels, 1)),
            sampleCount: segmentSampleCount,
            analyzedTimePointCount: gfpValues.count,
            rms: rms,
            p95Abs: percentile(absValues, fraction: 0.95),
            p99Abs: percentile(absValues, fraction: 0.99),
            maxAbs: maxAbs,
            gfpMedian: percentile(gfpValues, fraction: 0.50),
            gfpP95: percentile(gfpValues, fraction: 0.95),
            gfpMax: gfpValues.last ?? 0,
            derivativeRMS: derivativeRMS,
            derivativeRatio: derivativeRatio,
            flatlineFraction: differenceCount > 0 ? Double(flatlineCount) / Double(differenceCount) : 1,
            clippingFraction: clippingFraction,
            driftRMS: rootMeanSquare(driftValues),
            artifactOverlapFraction: segmentSampleCount > 0
                ? Double(min(artifactOverlap.samples, segmentSampleCount)) / Double(segmentSampleCount)
                : 0,
            artifactCount: artifactOverlap.count
        )
    }

    private static func result(
        for segment: SegmentHealthInputSegment,
        summary: SegmentSummary,
        baselines: SegmentHealthBaselines,
        signal: MFFSignalData
    ) -> SegmentHealthResult {
        let features = features(for: summary, baselines: baselines, signal: signal)
        var metrics: [SegmentHealthMetric] = []

        metrics.append(metric(
            name: "Finite Samples",
            score: scoreLowerBound(summary.finiteFraction, green: 0.995, red: 0.92),
            detail: "\(formatPercent(summary.finiteFraction)) finite values",
            weight: 1.2
        ))

        metrics.append(metric(
            name: "Channel Coverage",
            score: scoreLowerBound(summary.includedChannelFraction, green: 0.80, red: 0.45),
            detail: "\(summary.includedChannelCount) of \(signal.numberOfChannels) channels scored",
            weight: 0.6
        ))

        metrics.append(metric(
            name: "Global Field Power",
            score: scoreUpperRatio(features.gfpTypicality, green: 2.0, red: 5.0),
            detail: "GFP p95 \(formatMicrovolts(summary.gfpP95)), \(formatRatio(features.gfpTypicality)) typical",
            weight: 1.5
        ))

        metrics.append(metric(
            name: "Segment Amplitude",
            score: scoreUpperRatio(features.amplitudeTypicality, green: 3.0, red: 8.0),
            detail: "p95 \(formatMicrovolts(summary.p95Abs)), \(formatRatio(features.amplitudeTypicality)) typical",
            weight: 1.2
        ))

        metrics.append(metric(
            name: "Burst Peaks",
            score: scoreUpperRatio(features.burstTypicality, green: 8.0, red: 24.0),
            detail: "max \(formatMicrovolts(summary.maxAbs)), \(formatRatio(features.burstTypicality)) median p99",
            weight: 1.0
        ))

        metrics.append(metric(
            name: "GFP Bursts",
            score: scoreUpperRatio(features.gfpBurstTypicality, green: 6.0, red: 18.0),
            detail: "max GFP \(formatMicrovolts(summary.gfpMax)), \(formatRatio(features.gfpBurstTypicality)) typical",
            weight: 1.0
        ))

        let dropoutScore = min(
            scoreUpperFraction(summary.flatlineFraction, green: 0.01, red: 0.20),
            scoreUpperFraction(summary.clippingFraction, green: 0.002, red: 0.08)
        )
        metrics.append(metric(
            name: "Flatline / Clipping",
            score: dropoutScore,
            detail: "\(formatPercent(summary.flatlineFraction)) flat, \(formatPercent(summary.clippingFraction)) clipped",
            weight: 1.1
        ))

        metrics.append(metric(
            name: "Fast Noise",
            score: scoreUpperRatio(features.derivativeTypicality, green: 2.0, red: 5.0),
            detail: "sample-to-sample change \(formatRatio(features.derivativeTypicality)) typical",
            weight: 1.0
        ))

        if summary.sampleCount >= max(Int((signal.samplingRate * 0.25).rounded()), 2) {
            metrics.append(metric(
                name: "Slow Drift",
                score: scoreUpperRatio(features.driftTypicality, green: 0.8, red: 2.5),
                detail: "early-to-late shift \(formatMicrovolts(summary.driftRMS))",
                weight: 0.8
            ))
        }

        let artifactScore = summary.artifactCount == 0
            ? 1
            : min(scoreUpperFraction(summary.artifactOverlapFraction, green: 0.02, red: 0.15), 0.15)
        metrics.append(metric(
            name: "Labeled Artifacts",
            score: artifactScore,
            detail: summary.artifactCount == 0
                ? "No labeled artifacts in segment"
                : "\(summary.artifactCount) artifact\(summary.artifactCount == 1 ? "" : "s"), \(formatPercent(summary.artifactOverlapFraction)) window coverage",
            weight: 2.4
        ))

        let weightedTotal = metrics.reduce(0) { $0 + $1.score * $1.weight }
        let weightTotal = metrics.reduce(0) { $0 + $1.weight }
        let goodFraction = weightTotal > 0 ? weightedTotal / weightTotal : 0
        let percentage = Int((min(max(goodFraction, 0), 1) * 100).rounded())
        let grade = grade(for: goodFraction)
        let weakMetrics = metrics
            .filter { $0.score < 0.78 }
            .sorted { $0.score < $1.score }
            .prefix(2)
            .map(\.name)
        let summaryText = weakMetrics.isEmpty
            ? "Metrics look typical for this segment."
            : "\(weakMetrics.joined(separator: " and ")) need review."

        let startTime = Double(segment.startSample) / signal.samplingRate
        let endTime = Double(segment.endSample + 1) / signal.samplingRate
        return SegmentHealthResult(
            segmentID: segment.segmentID,
            segmentIndex: segment.segmentIndex,
            category: segment.category,
            startSample: segment.startSample,
            endSample: segment.endSample,
            startTimeSeconds: startTime,
            endTimeSeconds: endTime,
            durationSeconds: max(endTime - startTime, 0),
            stimulusOffsetSamples: segment.stimulusOffsetSamples,
            sourceCode: segment.sourceCode,
            sourceTimeSeconds: segment.sourceTimeSeconds,
            contributingEpochCount: segment.contributingEpochCount,
            goodPercentage: percentage,
            grade: grade,
            summary: summaryText,
            metrics: metrics.sorted { $0.score < $1.score }
        )
    }

    private static func features(
        for summary: SegmentSummary,
        baselines: SegmentHealthBaselines,
        signal: MFFSignalData
    ) -> SegmentHealthFeatures {
        let driftTypicality = summary.driftRMS / max(baselines.p95AbsMicrovolts * 0.25, 1e-9)
        return SegmentHealthFeatures(
            finiteFraction: summary.finiteFraction,
            includedChannelCount: summary.includedChannelCount,
            includedChannelFraction: summary.includedChannelFraction,
            sampleCount: summary.sampleCount,
            analyzedTimePointCount: summary.analyzedTimePointCount,
            rmsMicrovolts: summary.rms,
            p95AbsMicrovolts: summary.p95Abs,
            p99AbsMicrovolts: summary.p99Abs,
            maxAbsMicrovolts: summary.maxAbs,
            gfpMedianMicrovolts: summary.gfpMedian,
            gfpP95Microvolts: summary.gfpP95,
            gfpMaxMicrovolts: summary.gfpMax,
            derivativeRMSMicrovolts: summary.derivativeRMS,
            derivativeRatio: summary.derivativeRatio,
            flatlineFraction: summary.flatlineFraction,
            clippingFraction: summary.clippingFraction,
            driftRMSMicrovolts: summary.driftRMS,
            artifactOverlapFraction: summary.artifactOverlapFraction,
            artifactCount: summary.artifactCount,
            amplitudeTypicality: summary.p95Abs / max(baselines.p95AbsMicrovolts, 1e-9),
            burstTypicality: summary.maxAbs / max(baselines.p99AbsMicrovolts, 1e-9),
            gfpTypicality: summary.gfpP95 / max(baselines.gfpP95Microvolts, 1e-9),
            gfpBurstTypicality: summary.gfpMax / max(baselines.gfpP99Microvolts, 1e-9),
            derivativeTypicality: summary.derivativeRatio / max(baselines.derivativeRatio, 1e-9),
            driftTypicality: driftTypicality
        )
    }

    private static func metric(name: String, score: Double, detail: String, weight: Double) -> SegmentHealthMetric {
        let boundedScore = min(max(score, 0), 1)
        return SegmentHealthMetric(
            name: name,
            score: boundedScore,
            grade: grade(for: boundedScore),
            detail: detail,
            weight: weight
        )
    }

    private static func clippingFraction(absValues: [Double], maxAbs: Double) -> Double {
        guard absValues.count > 3, maxAbs > 20 else { return 0 }
        let tolerance = max(maxAbs * 0.001, 0.01)
        let clipped = absValues.filter { abs($0 - maxAbs) <= tolerance }.count
        return Double(clipped) / Double(absValues.count)
    }

    private static func artifactOverlapSamples(
        in segmentRange: ClosedRange<Int>,
        artifactIntervals: [SegmentHealthArtifactInterval]
    ) -> (samples: Int, count: Int) {
        var overlapSamples = 0
        var overlapCount = 0
        for interval in artifactIntervals {
            let lower = max(segmentRange.lowerBound, interval.startSample)
            let upper = min(segmentRange.upperBound, interval.endSample)
            guard upper >= lower else { continue }
            overlapSamples += upper - lower + 1
            overlapCount += 1
        }
        return (overlapSamples, overlapCount)
    }

    private static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let position = min(max(fraction, 0), 1) * Double(sortedValues.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sortedValues.count - 1)
        let weight = position - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    private static func scoreUpperRatio(_ ratio: Double, green: Double, red: Double) -> Double {
        guard ratio.isFinite else { return 0 }
        if ratio <= green { return 1 }
        if ratio >= red { return 0 }
        return 1 - (ratio - green) / max(red - green, 1e-9)
    }

    private static func scoreUpperFraction(_ fraction: Double, green: Double, red: Double) -> Double {
        scoreUpperRatio(fraction, green: green, red: red)
    }

    private static func scoreLowerBound(_ value: Double, green: Double, red: Double) -> Double {
        guard value.isFinite else { return 0 }
        if value >= green { return 1 }
        if value <= red { return 0 }
        return (value - red) / max(green - red, 1e-9)
    }

    private static func grade(for score: Double) -> ChannelHealthGrade {
        if score >= 0.78 { return .good }
        if score >= 0.50 { return .watch }
        return .poor
    }

    private static func formatPercent(_ fraction: Double) -> String {
        String(format: "%.1f%%", min(max(fraction, 0), 1) * 100)
    }

    private static func formatRatio(_ ratio: Double) -> String {
        guard ratio.isFinite else { return "nanx" }
        return String(format: "%.1fx", ratio)
    }

    private static func formatMicrovolts(_ value: Double) -> String {
        guard value.isFinite else { return "nan uV" }
        if abs(value) >= 100 {
            return String(format: "%.0f uV", value)
        }
        if abs(value) >= 10 {
            return String(format: "%.1f uV", value)
        }
        return String(format: "%.2f uV", value)
    }
}

private nonisolated struct SegmentSummary: Sendable {
    var finiteFraction: Double = 0
    var includedChannelCount: Int = 0
    var includedChannelFraction: Double = 0
    var sampleCount: Int = 0
    var analyzedTimePointCount: Int = 0
    var rms: Double = 0
    var p95Abs: Double = 0
    var p99Abs: Double = 0
    var maxAbs: Double = 0
    var gfpMedian: Double = 0
    var gfpP95: Double = 0
    var gfpMax: Double = 0
    var derivativeRMS: Double = 0
    var derivativeRatio: Double = 0
    var flatlineFraction: Double = 1
    var clippingFraction: Double = 0
    var driftRMS: Double = 0
    var artifactOverlapFraction: Double = 0
    var artifactCount: Int = 0
}
