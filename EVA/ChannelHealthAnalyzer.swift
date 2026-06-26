//
//  ChannelHealthAnalyzer.swift
//  EVA
//
//  Copyright (C) 2026 Peter Molfese
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Explainable per-channel signal-quality scoring. This is intentionally a
//  metrics model first: the feature/result shape can later feed a trained Core
//  ML ranker, while today's UI already has useful reasons for every score.
//

import Foundation

nonisolated enum ChannelHealthGrade: String, Codable, Sendable {
    case good
    case watch
    case poor

    var displayName: String {
        switch self {
        case .good: return "Good"
        case .watch: return "Watch"
        case .poor: return "Poor"
        }
    }
}

nonisolated struct ChannelHealthMetric: Codable, Identifiable, Sendable {
    var name: String
    var score: Double
    var grade: ChannelHealthGrade
    var detail: String
    var weight: Double

    var id: String { name }
}

nonisolated struct ChannelHealthResult: Codable, Identifiable, Sendable {
    var channelIndex: Int
    var goodPercentage: Int
    var grade: ChannelHealthGrade
    var summary: String
    var metrics: [ChannelHealthMetric]

    var id: Int { channelIndex }
}

nonisolated struct ChannelHealthAnalysis: Sendable {
    var resultsByChannel: [Int: ChannelHealthResult]
    var featuresByChannel: [Int: ChannelHealthFeatures] = [:]
    var baselines: ChannelHealthBaselines?
    var sampleStride: Int = 1
    var effectiveSamplingRate: Double = 0
    var analyzedSampleCount: Int = 0
}

nonisolated struct ChannelHealthFeatures: Codable, Sendable {
    var finiteFraction: Double
    var meanMicrovolts: Double
    var rmsMicrovolts: Double
    var p95AbsMicrovolts: Double
    var p99AbsMicrovolts: Double
    var maxAbsMicrovolts: Double
    var differenceRMSMicrovolts: Double
    var flatlineFraction: Double
    var clippingFraction: Double
    var driftRMSMicrovolts: Double
    var lineNoisePower: Double
    var amplitudeTypicality: Double
    var burstTypicality: Double
    var derivativeRatio: Double
    var derivativeTypicality: Double
    var driftRatio: Double
    var driftTypicality: Double
    var lineNoiseTypicality: Double?
    var neighborAgreement: Double?
}

nonisolated struct ChannelHealthBaselines: Codable, Sendable {
    var medianP95AbsMicrovolts: Double
    var medianP99AbsMicrovolts: Double
    var medianDerivativeRatio: Double
    var medianDriftRatio: Double
    var medianLineNoisePower: Double

    fileprivate init(summaries: [ChannelSummary]) {
        medianP95AbsMicrovolts = ChannelHealthAnalyzer.median(summaries.map(\.p95Abs))
        medianP99AbsMicrovolts = ChannelHealthAnalyzer.median(summaries.map(\.p99Abs))
        medianDerivativeRatio = ChannelHealthAnalyzer.median(
            summaries.map { $0.differenceRMS / max($0.rms, 1e-9) }
        )
        medianDriftRatio = ChannelHealthAnalyzer.median(
            summaries.map { $0.driftRMS / max($0.rms, 1e-9) },
            fallback: 0.02
        )
        medianLineNoisePower = ChannelHealthAnalyzer.median(summaries.map(\.lineNoisePower), fallback: 0)
    }
}

nonisolated enum ChannelHealthAnalyzer {
    static func analyze(
        signal: MFFSignalData,
        layout: SensorLayout?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> ChannelHealthAnalysis {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 2,
              !signal.data.isEmpty else {
            return ChannelHealthAnalysis(resultsByChannel: [:])
        }

        let sampleStride = analysisStride(sampleCount: sampleCount, samplingRate: signal.samplingRate)
        var summaries: [ChannelSummary] = []
        summaries.reserveCapacity(signal.data.count)
        for (index, channel) in signal.data.enumerated() {
            if Task.isCancelled {
                return ChannelHealthAnalysis(resultsByChannel: [:])
            }
            summaries.append(summary(for: channel, channelIndex: index, samplingRate: signal.samplingRate, sampleStride: sampleStride))
            progress?(0.60 * Double(index + 1) / Double(max(signal.data.count, 1)))
        }

        let baselines = ChannelHealthBaselines(summaries: summaries)
        let neighborScores = neighborAgreementScores(summaries: summaries, layout: layout) { fraction in
            progress?(0.60 + 0.30 * fraction)
        }

        var results: [Int: ChannelHealthResult] = [:]
        var features: [Int: ChannelHealthFeatures] = [:]
        results.reserveCapacity(summaries.count)
        features.reserveCapacity(summaries.count)
        for summary in summaries {
            let neighborScore = neighborScores[summary.channelIndex]
            let result = result(for: summary, baselines: baselines, neighborScore: neighborScore)
            results[summary.channelIndex] = result
            features[summary.channelIndex] = channelFeatures(
                for: summary,
                baselines: baselines,
                neighborScore: neighborScore
            )
        }
        progress?(1)

        return ChannelHealthAnalysis(
            resultsByChannel: results,
            featuresByChannel: features,
            baselines: baselines,
            sampleStride: sampleStride,
            effectiveSamplingRate: signal.samplingRate / Double(max(sampleStride, 1)),
            analyzedSampleCount: max(sampleCount / max(sampleStride, 1), 1)
        )
    }

    private static func analysisStride(sampleCount: Int, samplingRate: Double) -> Int {
        let targetRateStride = max(Int((samplingRate / 250.0).rounded()), 1)
        let sampleBudgetStride = max(Int((Double(sampleCount) / 30_000.0).rounded(.up)), 1)
        return max(targetRateStride, sampleBudgetStride)
    }

    private static func summary(
        for channel: [Float],
        channelIndex: Int,
        samplingRate: Double,
        sampleStride: Int
    ) -> ChannelSummary {
        guard !channel.isEmpty else {
            return ChannelSummary(channelIndex: channelIndex)
        }

        var sampledValues: [Double] = []
        var finiteValues: [Double] = []
        var absValues: [Double] = []
        var differences: [Double] = []
        var nonFiniteCount = 0
        var previousFinite: Double?
        var sum = 0.0
        var sumSquares = 0.0

        sampledValues.reserveCapacity(channel.count / max(sampleStride, 1) + 1)
        finiteValues.reserveCapacity(sampledValues.capacity)
        absValues.reserveCapacity(sampledValues.capacity)

        for sample in stride(from: 0, to: channel.count, by: sampleStride) {
            let value = Double(channel[sample])
            guard value.isFinite else {
                nonFiniteCount += 1
                sampledValues.append(previousFinite ?? 0)
                continue
            }

            sampledValues.append(value)
            finiteValues.append(value)
            let absValue = abs(value)
            absValues.append(absValue)
            sum += value
            sumSquares += value * value

            if let previousFinite {
                differences.append(abs(value - previousFinite))
            }
            previousFinite = value
        }

        guard !finiteValues.isEmpty else {
            return ChannelSummary(
                channelIndex: channelIndex,
                sampledValues: sampledValues,
                finiteFraction: 0
            )
        }

        absValues.sort()
        let finiteCount = finiteValues.count
        let mean = sum / Double(finiteCount)
        let rms = sqrt(sumSquares / Double(finiteCount))
        let p95Abs = percentile(absValues, fraction: 0.95)
        let p99Abs = percentile(absValues, fraction: 0.99)
        let maxAbs = absValues.last ?? 0
        let differenceRMS = rootMeanSquare(differences)
        let flatlineThreshold = max(p95Abs * 0.0001, 1e-7)
        let flatlineFraction = differences.isEmpty
            ? 1
            : Double(differences.filter { $0 <= flatlineThreshold }.count) / Double(differences.count)
        let clippingFraction = clippingFraction(absValues: absValues, maxAbs: maxAbs)
        let driftRMS = blockMeanRMS(values: sampledValues, samplingRate: samplingRate / Double(max(sampleStride, 1)))
        let lineNoisePower = sinusoidPower(
            values: sampledValues,
            effectiveSamplingRate: samplingRate / Double(max(sampleStride, 1)),
            frequency: 60
        )

        return ChannelSummary(
            channelIndex: channelIndex,
            sampledValues: sampledValues,
            finiteFraction: Double(finiteCount) / Double(max(finiteCount + nonFiniteCount, 1)),
            mean: mean,
            rms: rms,
            p95Abs: p95Abs,
            p99Abs: p99Abs,
            maxAbs: maxAbs,
            differenceRMS: differenceRMS,
            flatlineFraction: flatlineFraction,
            clippingFraction: clippingFraction,
            driftRMS: driftRMS,
            lineNoisePower: lineNoisePower
        )
    }

    private static func result(
        for summary: ChannelSummary,
        baselines: ChannelHealthBaselines,
        neighborScore: Double?
    ) -> ChannelHealthResult {
        var metrics: [ChannelHealthMetric] = []

        metrics.append(metric(
            name: "Finite Samples",
            score: scoreLowerBound(summary.finiteFraction, green: 0.995, red: 0.90),
            detail: "\(formatPercent(summary.finiteFraction)) finite samples",
            weight: 1.4
        ))

        if summary.rms <= 1e-12 || summary.p95Abs <= 1e-12 {
            metrics.append(metric(
                name: "Signal Amplitude",
                score: 0,
                detail: "No measurable channel variance",
                weight: 1.4
            ))
        } else {
            let ratio = summary.p95Abs / baselines.medianP95AbsMicrovolts
            metrics.append(metric(
                name: "Signal Amplitude",
                score: scoreTwoSidedRatio(ratio, green: 2.5, red: 6.0),
                detail: "p95 \(formatMicrovolts(summary.p95Abs)), \(formatRatio(ratio)) typical",
                weight: 1.4
            ))
        }

        let burstRatio = summary.maxAbs / max(baselines.medianP99AbsMicrovolts, 1e-9)
        metrics.append(metric(
            name: "Burst Peaks",
            score: scoreUpperRatio(burstRatio, green: 8.0, red: 24.0),
            detail: "max \(formatMicrovolts(summary.maxAbs)), \(formatRatio(burstRatio)) median p99",
            weight: 1.0
        ))

        let dropoutScore = min(
            scoreUpperFraction(summary.flatlineFraction, green: 0.005, red: 0.15),
            scoreUpperFraction(summary.clippingFraction, green: 0.002, red: 0.08)
        )
        metrics.append(metric(
            name: "Flatline / Clipping",
            score: dropoutScore,
            detail: "\(formatPercent(summary.flatlineFraction)) flat, \(formatPercent(summary.clippingFraction)) clipped",
            weight: 1.3
        ))

        let derivativeRatio = summary.differenceRMS / max(summary.rms, 1e-9)
        let derivativeTypicality = derivativeRatio / baselines.medianDerivativeRatio
        metrics.append(metric(
            name: "Fast Noise",
            score: scoreUpperRatio(derivativeTypicality, green: 2.0, red: 5.0),
            detail: "sample-to-sample change \(formatRatio(derivativeTypicality)) typical",
            weight: 1.0
        ))

        let driftRatio = summary.driftRMS / max(summary.rms, 1e-9)
        let driftTypicality = driftRatio / baselines.medianDriftRatio
        metrics.append(metric(
            name: "Slow Drift",
            score: scoreUpperRatio(driftTypicality, green: 2.5, red: 6.0),
            detail: "block-mean drift \(formatRatio(driftTypicality)) typical",
            weight: 0.8
        ))

        if summary.lineNoisePower > 0, baselines.medianLineNoisePower > 0 {
            let lineRatio = summary.lineNoisePower / baselines.medianLineNoisePower
            metrics.append(metric(
                name: "60 Hz Line",
                score: scoreUpperRatio(lineRatio, green: 3.0, red: 10.0),
                detail: "60 Hz proxy \(formatRatio(lineRatio)) typical",
                weight: 0.8
            ))
        }

        if let neighborScore {
            metrics.append(metric(
                name: "Neighbor Agreement",
                score: scoreLowerBound(neighborScore, green: 0.45, red: 0.15),
                detail: "best nearby correlation \(String(format: "%.2f", neighborScore))",
                weight: 1.2
            ))
        }

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
            ? "Metrics look typical for this recording."
            : "\(weakMetrics.joined(separator: " and ")) need review."

        return ChannelHealthResult(
            channelIndex: summary.channelIndex,
            goodPercentage: percentage,
            grade: grade,
            summary: summaryText,
            metrics: metrics.sorted { $0.score < $1.score }
        )
    }

    private static func metric(name: String, score: Double, detail: String, weight: Double) -> ChannelHealthMetric {
        let boundedScore = min(max(score, 0), 1)
        return ChannelHealthMetric(
            name: name,
            score: boundedScore,
            grade: grade(for: boundedScore),
            detail: detail,
            weight: weight
        )
    }

    private static func channelFeatures(
        for summary: ChannelSummary,
        baselines: ChannelHealthBaselines,
        neighborScore: Double?
    ) -> ChannelHealthFeatures {
        let derivativeRatio = summary.differenceRMS / max(summary.rms, 1e-9)
        let driftRatio = summary.driftRMS / max(summary.rms, 1e-9)
        let lineTypicality = baselines.medianLineNoisePower > 0
            ? summary.lineNoisePower / baselines.medianLineNoisePower
            : nil

        return ChannelHealthFeatures(
            finiteFraction: summary.finiteFraction,
            meanMicrovolts: summary.mean,
            rmsMicrovolts: summary.rms,
            p95AbsMicrovolts: summary.p95Abs,
            p99AbsMicrovolts: summary.p99Abs,
            maxAbsMicrovolts: summary.maxAbs,
            differenceRMSMicrovolts: summary.differenceRMS,
            flatlineFraction: summary.flatlineFraction,
            clippingFraction: summary.clippingFraction,
            driftRMSMicrovolts: summary.driftRMS,
            lineNoisePower: summary.lineNoisePower,
            amplitudeTypicality: summary.p95Abs / max(baselines.medianP95AbsMicrovolts, 1e-9),
            burstTypicality: summary.maxAbs / max(baselines.medianP99AbsMicrovolts, 1e-9),
            derivativeRatio: derivativeRatio,
            derivativeTypicality: derivativeRatio / max(baselines.medianDerivativeRatio, 1e-9),
            driftRatio: driftRatio,
            driftTypicality: driftRatio / max(baselines.medianDriftRatio, 1e-9),
            lineNoiseTypicality: lineTypicality,
            neighborAgreement: neighborScore
        )
    }

    private static func neighborAgreementScores(
        summaries: [ChannelSummary],
        layout: SensorLayout?,
        progress: (Double) -> Void
    ) -> [Int: Double] {
        guard let layout else { return [:] }
        let positionsByChannel = Dictionary(uniqueKeysWithValues: layout.positions.map { ($0.channelIndex, $0) })
        let summariesByChannel = Dictionary(uniqueKeysWithValues: summaries.map { ($0.channelIndex, $0) })
        var scores: [Int: Double] = [:]
        scores.reserveCapacity(summaries.count)

        for (offset, summary) in summaries.enumerated() {
            if Task.isCancelled { return scores }
            guard let position = positionsByChannel[summary.channelIndex] else { continue }
            let neighbors = layout.positions
                .filter { $0.channelIndex != summary.channelIndex && summariesByChannel[$0.channelIndex] != nil }
                .sorted {
                    squaredDistance($0, position) < squaredDistance($1, position)
                }
                .prefix(6)

            let best = neighbors.compactMap { neighbor -> Double? in
                guard let other = summariesByChannel[neighbor.channelIndex] else { return nil }
                return abs(correlation(summary.sampledValues, other.sampledValues))
            }
            .max()

            if let best {
                scores[summary.channelIndex] = best
            }
            progress(Double(offset + 1) / Double(max(summaries.count, 1)))
        }

        return scores
    }

    private static func squaredDistance(_ lhs: SensorPosition, _ rhs: SensorPosition) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 3 else { return 0 }
        let left = lhs.prefix(count)
        let right = rhs.prefix(count)
        let leftMean = left.reduce(0, +) / Double(count)
        let rightMean = right.reduce(0, +) / Double(count)
        var numerator = 0.0
        var leftEnergy = 0.0
        var rightEnergy = 0.0
        for index in 0..<count {
            let l = lhs[index] - leftMean
            let r = rhs[index] - rightMean
            numerator += l * r
            leftEnergy += l * l
            rightEnergy += r * r
        }
        let denominator = sqrt(leftEnergy * rightEnergy)
        guard denominator > 1e-12 else { return 0 }
        return numerator / denominator
    }

    private static func clippingFraction(absValues: [Double], maxAbs: Double) -> Double {
        guard absValues.count > 3, maxAbs > 20 else { return 0 }
        let tolerance = max(maxAbs * 0.001, 0.01)
        let clipped = absValues.filter { abs($0 - maxAbs) <= tolerance }.count
        return Double(clipped) / Double(absValues.count)
    }

    private static func blockMeanRMS(values: [Double], samplingRate: Double) -> Double {
        guard values.count > 10, samplingRate > 0 else { return 0 }
        let blockSize = max(Int((samplingRate * 2.0).rounded()), 8)
        guard values.count >= blockSize * 2 else { return 0 }
        var means: [Double] = []
        means.reserveCapacity(values.count / blockSize)
        for start in stride(from: 0, to: values.count, by: blockSize) {
            let end = min(start + blockSize, values.count)
            guard end > start else { continue }
            let mean = values[start..<end].reduce(0, +) / Double(end - start)
            means.append(mean)
        }
        guard means.count > 1 else { return 0 }
        let overallMean = means.reduce(0, +) / Double(means.count)
        let variance = means.reduce(0) { $0 + ($1 - overallMean) * ($1 - overallMean) } / Double(means.count)
        return sqrt(max(variance, 0))
    }

    private static func sinusoidPower(values: [Double], effectiveSamplingRate: Double, frequency: Double) -> Double {
        guard values.count > 20,
              effectiveSamplingRate > frequency * 2.2 else {
            return 0
        }
        let omega = 2.0 * Double.pi * frequency / effectiveSamplingRate
        var cosineProjection = 0.0
        var sineProjection = 0.0
        var energy = 0.0
        for (index, value) in values.enumerated() {
            let centered = value
            let phase = omega * Double(index)
            cosineProjection += centered * cos(phase)
            sineProjection += centered * sin(phase)
            energy += centered * centered
        }
        guard energy > 1e-12 else { return 0 }
        return 2.0 * (cosineProjection * cosineProjection + sineProjection * sineProjection) / (Double(values.count) * energy)
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

    fileprivate static func median(_ values: [Double], fallback: Double = 1) -> Double {
        var finite = values.filter { $0.isFinite && $0 > 0 }
        guard !finite.isEmpty else { return fallback }
        finite.sort()
        return max(percentile(finite, fraction: 0.5), 1e-9)
    }

    private static func scoreUpperRatio(_ ratio: Double, green: Double, red: Double) -> Double {
        guard ratio.isFinite else { return 0 }
        if ratio <= green { return 1 }
        if ratio >= red { return 0 }
        return 1 - (ratio - green) / max(red - green, 1e-9)
    }

    private static func scoreTwoSidedRatio(_ ratio: Double, green: Double, red: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 0 }
        return scoreUpperRatio(max(ratio, 1 / ratio), green: green, red: red)
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

private nonisolated struct ChannelSummary: Sendable {
    var channelIndex: Int
    var sampledValues: [Double] = []
    var finiteFraction: Double = 0
    var mean: Double = 0
    var rms: Double = 0
    var p95Abs: Double = 0
    var p99Abs: Double = 0
    var maxAbs: Double = 0
    var differenceRMS: Double = 0
    var flatlineFraction: Double = 1
    var clippingFraction: Double = 0
    var driftRMS: Double = 0
    var lineNoisePower: Double = 0
}
