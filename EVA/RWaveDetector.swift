//
//  RWaveDetector.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  ECG / QRS (R-wave) detection engine and its supporting types, extracted from
//  WaveformView (REFACTOR.md L5 — this is really an L3 algorithm that had ended
//  up in the view file). Multiple transparent detectors (Pan-Tompkins, Hamilton,
//  WFDB-style, wavelet, Christov, simple).
//

import Accelerate
import Foundation

struct ECGAlgorithmResult: Sendable {
    let count: Int
    let bpm: Double?
}

enum ECGDetectionAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case simple = "Simple"
    case panTompkins = "Pan-Tompkins"
    case hamilton = "Hamilton"
    case wfdb = "WFDB"
    case wavelet = "Wavelet"
    case christov = "Christov"

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String { rawValue }

    nonisolated var tabTitle: String {
        switch self {
        case .simple:
            return "Simple"
        case .panTompkins:
            return "Pan-T"
        case .hamilton:
            return "Hamilton"
        case .wfdb:
            return "WFDB"
        case .wavelet:
            return "Wavelet"
        case .christov:
            return "Christov"
        }
    }

    nonisolated var summary: String {
        switch self {
        case .simple:
            return "Robust peak picking on the baseline-corrected waveform."
        case .panTompkins:
            return "Band-pass, derivative, squaring, moving integration, and adaptive QRS thresholding."
        case .hamilton:
            return "Slope-envelope QRS detection with adaptive signal/noise thresholding."
        case .wfdb:
            return "WFDB-style curve-length and slope-energy QRS detection inspired by wqrs/gqrs."
        case .wavelet:
            return "Multiscale detail-energy QRS detection for sharp cardiac transients in noisy signals."
        case .christov:
            return "Christov-style adaptive slope-envelope detection with time-varying signal/noise thresholds."
        }
    }
}

enum ECGDetectionPolarity: String, CaseIterable, Identifiable, Sendable {
    case positive = "Positive"
    case negative = "Negative"
    case either = "Either"

    var id: String { rawValue }

    nonisolated func score(_ zValue: Double) -> Double {
        switch self {
        case .positive:
            return max(zValue, 0)
        case .negative:
            return max(-zValue, 0)
        case .either:
            return abs(zValue)
        }
    }
}

struct ECGDetectionSource: Sendable {
    var id: String
    var label: String
    var channelLabels: [String]
    var channels: [[Float]]
    var samplingRate: Double
    var duration: TimeInterval
}

struct ECGDetectionConfiguration: Sendable {
    var algorithm: ECGDetectionAlgorithm
    var thresholdSD: Double
    var minimumRRSeconds: Double
    var polarity: ECGDetectionPolarity
}

struct ECGProcessedChannel: Sendable {
    var scores: [Double]
    var waveform: [Double]
}

struct RWaveCandidate: Sendable {
    var timeSeconds: Double
    var score: Double
    var sourceID: String
    var sourceLabel: String
}

nonisolated enum EyeArtifactKind {
    case blink
    case movement

    var eventCode: String {
        switch self {
        case .blink: return "Eye Blink"
        case .movement: return "Eye Movement"
        }
    }

    var idComponent: String {
        switch self {
        case .blink: return "eye-blink"
        case .movement: return "eye-movement"
        }
    }
}

nonisolated enum RWaveDetector {
    static let eventCode = "R Wave"
    private static let sourceFile = "ECG Detection"
    private static let baselineWindowSeconds = 0.60
    private static let qrsHighPassWindowSeconds = 0.20
    private static let qrsSmoothingWindowSeconds = 0.035
    private static let panTompkinsIntegrationWindowSeconds = 0.150
    private static let hamiltonSlopeWindowSeconds = 0.080
    private static let hamiltonNoiseWindowSeconds = 1.00
    private static let wfdbCurveLengthWindowSeconds = 0.130
    private static let wfdbSlopeWindowSeconds = 0.050
    private static let waveletDetailEnvelopeWindowSeconds = 0.080
    private static let christovEnvelopeWindowSeconds = 0.040
    private static let christovLongSlopeWindowSeconds = 0.280
    private static let adaptivePeakSpacingSeconds = 0.080
    private static let rPeakRefinementWindowSeconds = 0.080

    static func detect(
        sources: [ECGDetectionSource],
        configuration: ECGDetectionConfiguration
    ) -> [MFFEvent] {
        let threshold = min(max(configuration.thresholdSD, 1), 20)
        let minimumRRSeconds = min(max(configuration.minimumRRSeconds, 0.15), 2.0)
        var candidates: [RWaveCandidate] = []

        for source in sources {
            candidates += detectCandidates(
                in: source,
                algorithm: configuration.algorithm,
                threshold: threshold,
                minimumRRSeconds: minimumRRSeconds,
                polarity: configuration.polarity
            )
        }

        let selected = strongestNonOverlapping(candidates, minimumIntervalSeconds: minimumRRSeconds)
            .sorted { $0.timeSeconds < $1.timeSeconds }

        return selected.enumerated().map { index, candidate in
            let time = candidate.timeSeconds
            return MFFEvent(
                id: "artifact-rwave-\(configuration.algorithm.id)-\(index)-\(Int((time * 1_000_000).rounded()))",
                code: eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: "\(sourceFile): \(configuration.algorithm.rawValue)"
            )
        }
    }

    private static func detectCandidates(
        in source: ECGDetectionSource,
        algorithm: ECGDetectionAlgorithm,
        threshold: Double,
        minimumRRSeconds: Double,
        polarity: ECGDetectionPolarity
    ) -> [RWaveCandidate] {
        guard source.samplingRate > 0,
              source.duration > 0,
              let sampleCount = source.channels.map(\.count).min(),
              sampleCount > 2 else {
            return []
        }

        let processedChannels = source.channels.compactMap {
            processedChannel(
                samples: $0,
                sampleCount: sampleCount,
                samplingRate: source.samplingRate,
                algorithm: algorithm,
                polarity: polarity
            )
        }
        guard !processedChannels.isEmpty else { return [] }

        let aggregate = aggregateScores(processedChannels, sampleCount: sampleCount)

        switch algorithm {
        case .simple:
            return staticPeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: threshold,
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .panTompkins:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.45, 0.90),
                floorThreshold: max(threshold * 0.25, 0.55),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .hamilton:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.55, 1.00),
                floorThreshold: max(threshold * 0.30, 0.65),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .wfdb:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.50, 0.95),
                floorThreshold: max(threshold * 0.28, 0.60),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .wavelet:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.48, 0.90),
                floorThreshold: max(threshold * 0.25, 0.55),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .christov:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.52, 0.95),
                floorThreshold: max(threshold * 0.30, 0.60),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        }
    }

    private static func processedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double,
        algorithm: ECGDetectionAlgorithm,
        polarity: ECGDetectionPolarity
    ) -> ECGProcessedChannel? {
        switch algorithm {
        case .simple:
            return simpleProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate,
                polarity: polarity
            )
        case .panTompkins:
            return panTompkinsProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        case .hamilton:
            return hamiltonProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        case .wfdb:
            return wfdbProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        case .wavelet:
            return waveletProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        case .christov:
            return christovProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        }
    }

    private static func simpleProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double,
        polarity: ECGDetectionPolarity
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let highPassed = baselineRemoved(
            samples: samples,
            sampleCount: sampleCount,
            samplingRate: samplingRate
        )
        guard let scores = normalizedPolarityScores(
            values: highPassed,
            sampleCount: sampleCount,
            polarity: polarity
        ) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: highPassed)
    }

    private static func panTompkinsProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let differentiated = derivative(filtered)
        let squared = differentiated.map { $0 * $0 }
        let integrationWindow = sampleWindow(
            seconds: panTompkinsIntegrationWindowSeconds,
            samplingRate: samplingRate,
            minimum: 3
        )
        let integrated = centeredMovingAverage(
            squared,
            sampleCount: sampleCount,
            windowSamples: integrationWindow
        )
        guard let scores = normalizedEnvelopeScores(values: integrated, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func hamiltonProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let slope = derivative(filtered).map { abs($0) }
        let shortWindow = sampleWindow(
            seconds: hamiltonSlopeWindowSeconds,
            samplingRate: samplingRate,
            minimum: 3
        )
        let longWindow = sampleWindow(
            seconds: hamiltonNoiseWindowSeconds,
            samplingRate: samplingRate,
            minimum: shortWindow * 2
        )
        let shortEnvelope = centeredMovingAverage(
            slope,
            sampleCount: sampleCount,
            windowSamples: shortWindow
        )
        let noiseEnvelope = centeredMovingAverage(
            shortEnvelope,
            sampleCount: sampleCount,
            windowSamples: longWindow
        )
        var enhanced = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            enhanced[sample] = max(shortEnvelope[sample] - noiseEnvelope[sample] * 0.50, 0)
        }
        guard let scores = normalizedEnvelopeScores(values: enhanced, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func wfdbProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let slope = derivative(filtered).map { abs($0) }
        let slopeWindow = sampleWindow(
            seconds: wfdbSlopeWindowSeconds,
            samplingRate: samplingRate,
            minimum: 3
        )
        let slopeEnergy = centeredMovingAverage(
            slope.map { $0 * $0 },
            sampleCount: sampleCount,
            windowSamples: slopeWindow
        )
        let curveLength = curveLengthEnvelope(
            filtered,
            sampleCount: sampleCount,
            samplingRate: samplingRate
        )
        var combined = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            combined[sample] = curveLength[sample] + sqrt(max(slopeEnergy[sample], 0))
        }

        guard let scores = normalizedEnvelopeScores(values: combined, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func waveletProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let first = centeredMovingAverage(
            filtered,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(seconds: 0.025, samplingRate: samplingRate, minimum: 1)
        )
        let second = centeredMovingAverage(
            filtered,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(seconds: 0.050, samplingRate: samplingRate, minimum: 3)
        )
        let third = centeredMovingAverage(
            filtered,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(seconds: 0.100, samplingRate: samplingRate, minimum: 5)
        )
        let fourth = centeredMovingAverage(
            filtered,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(seconds: 0.200, samplingRate: samplingRate, minimum: 9)
        )

        var detailEnergy = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            let d1 = filtered[sample] - first[sample]
            let d2 = first[sample] - second[sample]
            let d3 = second[sample] - third[sample]
            let d4 = third[sample] - fourth[sample]
            detailEnergy[sample] = d1 * d1 + 0.85 * d2 * d2 + 0.60 * d3 * d3 + 0.35 * d4 * d4
        }
        let envelope = centeredMovingAverage(
            detailEnergy.map { sqrt(max($0, 0)) },
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: waveletDetailEnvelopeWindowSeconds,
                samplingRate: samplingRate,
                minimum: 3
            )
        )
        guard let scores = normalizedEnvelopeScores(values: envelope, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func christovProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let firstDerivative = derivative(filtered)
        let secondDerivative = derivative(firstDerivative)
        var complexLead = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            complexLead[sample] = abs(firstDerivative[sample]) + 0.45 * abs(secondDerivative[sample])
        }
        let shortEnvelope = centeredMovingAverage(
            complexLead,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: christovEnvelopeWindowSeconds,
                samplingRate: samplingRate,
                minimum: 3
            )
        )
        let slowEnvelope = centeredMovingAverage(
            shortEnvelope,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: christovLongSlopeWindowSeconds,
                samplingRate: samplingRate,
                minimum: 7
            )
        )
        var enhanced = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            enhanced[sample] = max(shortEnvelope[sample] - slowEnvelope[sample] * 0.35, 0)
        }
        guard let scores = normalizedEnvelopeScores(values: enhanced, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func aggregateScores(
        _ channels: [ECGProcessedChannel],
        sampleCount: Int
    ) -> [Double] {
        var aggregate = Array(repeating: 0.0, count: sampleCount)
        for channel in channels {
            for sample in 0..<sampleCount where channel.scores[sample] > aggregate[sample] {
                aggregate[sample] = channel.scores[sample]
            }
        }
        return aggregate
    }

    private static func staticPeakCandidates(
        aggregate: [Double],
        processedChannels: [ECGProcessedChannel],
        source: ECGDetectionSource,
        threshold: Double,
        minimumRRSeconds: Double,
        polarity: ECGDetectionPolarity
    ) -> [RWaveCandidate] {
        let sampleCount = aggregate.count
        var candidates: [RWaveCandidate] = []
        for sample in 1..<(sampleCount - 1) {
            let score = aggregate[sample]
            guard score >= threshold,
                  score >= aggregate[sample - 1],
                  score > aggregate[sample + 1] else {
                continue
            }
            let refinedSample = refinedPeakSample(
                near: sample,
                processedChannels: processedChannels,
                samplingRate: source.samplingRate,
                polarity: polarity
            )
            let time = Double(refinedSample) / source.samplingRate
            guard time >= 0, time <= source.duration else { continue }
            candidates.append(RWaveCandidate(
                timeSeconds: time,
                score: score,
                sourceID: source.id,
                sourceLabel: source.label
            ))
        }

        return strongestNonOverlapping(candidates, minimumIntervalSeconds: minimumRRSeconds)
    }

    private static func adaptivePeakCandidates(
        aggregate: [Double],
        processedChannels: [ECGProcessedChannel],
        source: ECGDetectionSource,
        threshold: Double,
        floorThreshold: Double,
        minimumRRSeconds: Double,
        polarity: ECGDetectionPolarity
    ) -> [RWaveCandidate] {
        let spacingSamples = sampleWindow(
            seconds: adaptivePeakSpacingSeconds,
            samplingRate: source.samplingRate,
            minimum: 1
        )
        let peaks = localPeakIndices(in: aggregate, minimumSpacingSamples: spacingSamples)
        guard !peaks.isEmpty else { return [] }

        var peakScores = peaks.map { aggregate[$0] }.filter(\.isFinite)
        peakScores.sort()
        var signalLevel = max(threshold, percentile(sortedValues: peakScores, fraction: 0.85))
        var noiseLevel = max(0, percentile(sortedValues: peakScores, fraction: 0.20))
        var adaptiveThreshold = max(floorThreshold, min(threshold, noiseLevel + 0.25 * (signalLevel - noiseLevel)))
        var candidates: [RWaveCandidate] = []

        for peak in peaks {
            let score = aggregate[peak]
            guard score.isFinite else { continue }

            if score >= adaptiveThreshold {
                let refinedSample = refinedPeakSample(
                    near: peak,
                    processedChannels: processedChannels,
                    samplingRate: source.samplingRate,
                    polarity: polarity
                )
                let time = Double(refinedSample) / source.samplingRate
                if time >= 0, time <= source.duration {
                    candidates.append(RWaveCandidate(
                        timeSeconds: time,
                        score: score,
                        sourceID: source.id,
                        sourceLabel: source.label
                    ))
                }
                signalLevel = 0.125 * score + 0.875 * signalLevel
            } else {
                noiseLevel = 0.125 * score + 0.875 * noiseLevel
            }

            adaptiveThreshold = max(floorThreshold, noiseLevel + 0.25 * (signalLevel - noiseLevel))
        }

        return strongestNonOverlapping(candidates, minimumIntervalSeconds: minimumRRSeconds)
    }

    private static func normalizedPolarityScores(
        values: [Double],
        sampleCount: Int,
        polarity: ECGDetectionPolarity
    ) -> [Double]? {
        guard let stats = robustStats(values: values, sampleCount: sampleCount) else { return nil }
        return values.map { value in
            guard value.isFinite else { return 0 }
            return polarity.score((value - stats.center) / stats.scale)
        }
    }

    private static func normalizedEnvelopeScores(
        values: [Double],
        sampleCount: Int
    ) -> [Double]? {
        guard let stats = robustStats(values: values, sampleCount: sampleCount) else { return nil }
        return values.map { value in
            guard value.isFinite else { return 0 }
            return max((value - stats.center) / stats.scale, 0)
        }
    }

    private static func qrsFiltered(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> [Double] {
        let baselineCorrected = baselineRemoved(
            samples: samples,
            sampleCount: sampleCount,
            samplingRate: samplingRate
        )
        let highPassWindow = sampleWindow(
            seconds: qrsHighPassWindowSeconds,
            samplingRate: samplingRate,
            minimum: 3
        )
        let trend = centeredMovingAverage(
            baselineCorrected,
            sampleCount: sampleCount,
            windowSamples: highPassWindow
        )
        var highPassed = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            highPassed[sample] = baselineCorrected[sample] - trend[sample]
        }

        let smoothingWindow = sampleWindow(
            seconds: qrsSmoothingWindowSeconds,
            samplingRate: samplingRate,
            minimum: 1
        )
        return centeredMovingAverage(
            highPassed,
            sampleCount: sampleCount,
            windowSamples: smoothingWindow
        )
    }

    private static func baselineRemoved(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> [Double] {
        let halfWindow = max(Int((baselineWindowSeconds * samplingRate / 2).rounded()), 1)
        var sums = Array(repeating: 0.0, count: sampleCount + 1)
        var counts = Array(repeating: 0.0, count: sampleCount + 1)

        for index in 0..<sampleCount {
            let value = Double(samples[index])
            if value.isFinite {
                sums[index + 1] = sums[index] + value
                counts[index + 1] = counts[index] + 1
            } else {
                sums[index + 1] = sums[index]
                counts[index + 1] = counts[index]
            }
        }

        var result = Array(repeating: 0.0, count: sampleCount)
        for index in 0..<sampleCount {
            let lower = max(0, index - halfWindow)
            let upper = min(sampleCount, index + halfWindow + 1)
            let count = counts[upper] - counts[lower]
            let baseline = count > 0 ? (sums[upper] - sums[lower]) / count : 0
            let value = Double(samples[index])
            result[index] = value.isFinite ? value - baseline : 0
        }
        return result
    }

    private static func derivative(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values }
        var result = Array(repeating: 0.0, count: values.count)
        result[0] = values[1] - values[0]
        result[values.count - 1] = values[values.count - 1] - values[values.count - 2]
        if values.count > 2 {
            for index in 1..<(values.count - 1) {
                result[index] = (values[index + 1] - values[index - 1]) / 2
            }
        }
        return result
    }

    private static func curveLengthEnvelope(
        _ values: [Double],
        sampleCount: Int,
        samplingRate: Double
    ) -> [Double] {
        guard sampleCount > 1 else { return Array(values.prefix(sampleCount)) }

        let differences = derivative(values)
        let robustScale = robustStats(values: differences, sampleCount: sampleCount)?.scale ?? 1
        let scale = max(robustScale, 1e-6)
        var increments = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            let normalizedSlope = differences[sample] / scale
            increments[sample] = sqrt(1 + normalizedSlope * normalizedSlope) - 1
        }

        return centeredMovingAverage(
            increments,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: wfdbCurveLengthWindowSeconds,
                samplingRate: samplingRate,
                minimum: 3
            )
        )
    }

    private static func centeredMovingAverage(
        _ values: [Double],
        sampleCount: Int,
        windowSamples: Int
    ) -> [Double] {
        guard sampleCount > 0 else { return [] }
        guard windowSamples > 1 else { return Array(values.prefix(sampleCount)) }

        let radius = max(windowSamples / 2, 1)
        var sums = Array(repeating: 0.0, count: sampleCount + 1)
        var counts = Array(repeating: 0.0, count: sampleCount + 1)

        for index in 0..<sampleCount {
            let value = values[index]
            if value.isFinite {
                sums[index + 1] = sums[index] + value
                counts[index + 1] = counts[index] + 1
            } else {
                sums[index + 1] = sums[index]
                counts[index + 1] = counts[index]
            }
        }

        var result = Array(repeating: 0.0, count: sampleCount)
        for index in 0..<sampleCount {
            let lower = max(0, index - radius)
            let upper = min(sampleCount, index + radius + 1)
            let count = counts[upper] - counts[lower]
            result[index] = count > 0 ? (sums[upper] - sums[lower]) / count : 0
        }
        return result
    }

    private static func sampleWindow(seconds: Double, samplingRate: Double, minimum: Int) -> Int {
        max(Int((seconds * samplingRate).rounded()), minimum)
    }

    private static func localPeakIndices(
        in values: [Double],
        minimumSpacingSamples: Int
    ) -> [Int] {
        guard values.count > 2 else { return [] }

        var peaks: [Int] = []
        for index in 1..<(values.count - 1) {
            guard values[index].isFinite,
                  values[index] >= values[index - 1],
                  values[index] > values[index + 1] else {
                continue
            }
            peaks.append(index)
        }
        guard let firstPeak = peaks.first else { return [] }

        var selected: [Int] = []
        var clusterStart = firstPeak
        var bestPeak = firstPeak
        for peak in peaks.dropFirst() {
            if peak - clusterStart <= minimumSpacingSamples {
                if values[peak] > values[bestPeak] {
                    bestPeak = peak
                }
            } else {
                selected.append(bestPeak)
                clusterStart = peak
                bestPeak = peak
            }
        }
        selected.append(bestPeak)
        return selected
    }

    private static func refinedPeakSample(
        near sample: Int,
        processedChannels: [ECGProcessedChannel],
        samplingRate: Double,
        polarity: ECGDetectionPolarity
    ) -> Int {
        guard let sampleCount = processedChannels.map(\.waveform.count).min(), sampleCount > 0 else {
            return sample
        }

        let radius = sampleWindow(
            seconds: rPeakRefinementWindowSeconds,
            samplingRate: samplingRate,
            minimum: 1
        )
        let lower = max(0, sample - radius)
        let upper = min(sampleCount - 1, sample + radius)
        var bestSample = min(max(sample, lower), upper)
        var bestScore = -Double.greatestFiniteMagnitude

        for candidateSample in lower...upper {
            var score = 0.0
            for channel in processedChannels {
                let value = channel.waveform[candidateSample]
                guard value.isFinite else { continue }
                score = max(score, polarity.score(value))
            }
            if score > bestScore {
                bestScore = score
                bestSample = candidateSample
            }
        }

        return bestSample
    }

    private static func robustStats(
        values: [Double],
        sampleCount: Int
    ) -> (center: Double, scale: Double)? {
        let sampleStride = max(sampleCount / 20_000, 1)
        var sampled: [Double] = []
        sampled.reserveCapacity(sampleCount / sampleStride + 1)
        for index in stride(from: 0, to: sampleCount, by: sampleStride) {
            let value = values[index]
            if value.isFinite {
                sampled.append(value)
            }
        }
        guard sampled.count >= 8 else { return nil }

        var centerValues = sampled
        let center = median(&centerValues)
        var deviations = sampled.map { abs($0 - center) }
        let mad = median(&deviations)
        let rms = sqrt(sampled.reduce(0.0) { $0 + ($1 - center) * ($1 - center) } / Double(sampled.count))
        let p95 = percentile(sortedValues: centerValues, fraction: 0.95)
        let scale = max(mad * 1.4826, (p95 - center) / 3, rms * 0.10, 1e-6)
        return (center, scale)
    }

    private static func strongestNonOverlapping(
        _ candidates: [RWaveCandidate],
        minimumIntervalSeconds: Double
    ) -> [RWaveCandidate] {
        var selected: [RWaveCandidate] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let overlaps = selected.contains { abs($0.timeSeconds - candidate.timeSeconds) < minimumIntervalSeconds }
            if !overlaps {
                selected.append(candidate)
            }
        }
        return selected
    }

    private static func percentile(sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        let position = clamped * Double(sortedValues.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper {
            return sortedValues[lower]
        }
        let weight = position - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    private static func median(_ values: inout [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        values.sort()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

nonisolated enum EyeArtifactThresholdDetector {
    private static let thresholdMicrovolts: Float = 150
    private static let minimumDurationSeconds = 0.05
    private static let mergeGapSeconds = 0.25

    static func detect(
        kind: EyeArtifactKind,
        channels: [[Float]],
        samplingRate: Double,
        duration: TimeInterval
    ) -> [MFFEvent] {
        guard samplingRate > 0, duration > 0, let sampleCount = channels.first?.count, sampleCount > 0 else {
            return []
        }

        let candidateChannels = ocularChannelIndices(kind: kind, channelCount: channels.count)
            .filter { $0 < channels.count && channels[$0].count == sampleCount }
        guard !candidateChannels.isEmpty else { return [] }

        let minimumSamples = max(Int((minimumDurationSeconds * samplingRate).rounded()), 1)
        let mergeGapSamples = max(Int((mergeGapSeconds * samplingRate).rounded()), 1)

        var intervals: [ClosedRange<Int>] = []
        var activeStart: Int?
        var lastAboveThreshold: Int?

        for sample in 0..<sampleCount {
            let exceedsThreshold = candidateChannels.contains { channelIndex in
                abs(channels[channelIndex][sample]) >= thresholdMicrovolts
            }

            if exceedsThreshold {
                if activeStart == nil {
                    activeStart = sample
                }
                lastAboveThreshold = sample
            } else if let start = activeStart, let end = lastAboveThreshold {
                if end - start + 1 >= minimumSamples {
                    append(start...end, to: &intervals, mergeGapSamples: mergeGapSamples)
                }
                activeStart = nil
                lastAboveThreshold = nil
            }
        }

        if let start = activeStart, let end = lastAboveThreshold, end - start + 1 >= minimumSamples {
            append(start...end, to: &intervals, mergeGapSamples: mergeGapSamples)
        }

        return intervals.enumerated().map { index, interval in
            let peakSample = peakSample(in: interval, channels: channels, candidateChannels: candidateChannels)
            let time = min(max(Double(peakSample) / samplingRate, 0), duration)
            return MFFEvent(
                id: "artifact-\(kind.idComponent)-threshold-\(index)-\(peakSample)",
                code: kind.eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: "Artifact Detection"
            )
        }
    }

    private static func ocularChannelIndices(kind: EyeArtifactKind, channelCount: Int) -> [Int] {
        // EGI channel numbers are 1-based; signal arrays are 0-based.
        let oneBasedChannels: [Int]
        switch (kind, channelCount) {
        case (.blink, 241...):
            oneBasedChannels = [18, 37, 238, 241]
        case (.blink, 127...):
            oneBasedChannels = [8, 25, 126, 127]
        case (.movement, 252...):
            oneBasedChannels = [226, 252]
        case (.movement, 128...):
            oneBasedChannels = [1, 32, 125, 128]
        default:
            oneBasedChannels = Array(1...min(channelCount, 4))
        }

        return oneBasedChannels.map { $0 - 1 }
    }

    private static func append(
        _ interval: ClosedRange<Int>,
        to intervals: inout [ClosedRange<Int>],
        mergeGapSamples: Int
    ) {
        guard let last = intervals.last else {
            intervals.append(interval)
            return
        }

        if interval.lowerBound - last.upperBound <= mergeGapSamples {
            intervals[intervals.count - 1] = last.lowerBound...interval.upperBound
        } else {
            intervals.append(interval)
        }
    }

    private static func peakSample(
        in interval: ClosedRange<Int>,
        channels: [[Float]],
        candidateChannels: [Int]
    ) -> Int {
        var peakSample = interval.lowerBound
        var peakValue: Float = 0

        for sample in interval {
            for channelIndex in candidateChannels {
                let value = abs(channels[channelIndex][sample])
                if value > peakValue {
                    peakValue = value
                    peakSample = sample
                }
            }
        }

        return peakSample
    }
}
