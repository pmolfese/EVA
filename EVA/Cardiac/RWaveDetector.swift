//
//  RWaveDetector.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ECG / QRS (R-wave) detection engine and its supporting types, extracted from
//  WaveformView (REFACTOR.md L5 — this is really an L3 algorithm that had ended
//  up in the view file). Multiple transparent detectors (Pan-Tompkins, Hamilton,
//  WFDB-style, wavelet, Christov, simple).
//
//  The named detectors are original Swift implementations of published QRS
//  detection algorithms.
//
//  References:
//    * Pan-Tompkins: Pan, J., & Tompkins, W. J. (1985). A real-time QRS
//      detection algorithm. IEEE Transactions on Biomedical Engineering,
//      BME-32(3), 230-236. https://doi.org/10.1109/TBME.1985.325532
//    * Hamilton: Hamilton, P. (2002). Open source ECG analysis. Computers in
//      Cardiology, 29, 101-104. https://doi.org/10.1109/CIC.2002.1166717
//    * Christov: Christov, I. I. (2004). Real time electrocardiogram QRS
//      detection using combined adaptive threshold. BioMedical Engineering
//      OnLine, 3, 28. https://doi.org/10.1186/1475-925X-3-28
//    * WFDB-style (gqrs/wqrs): Goldberger, A. L., et al. (2000). PhysioBank,
//      PhysioToolkit, and PhysioNet. Circulation, 101(23), e215-e220.
//      https://doi.org/10.1161/01.CIR.101.23.e215
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
    case pulse = "Pulse-Ox"

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
        case .pulse:
            return "Pulse"
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
        case .pulse:
            return "Pulse-oximeter (PPG) systolic peak picking on the smoothed, baseline-corrected pulse waveform."
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
    /// Measured width of the R deflection around the peak — see
    /// `RWaveDetector.complexWidthSeconds`. `nil` when it could not be measured
    /// (flat or non-finite neighbourhood).
    var widthSeconds: Double?
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
    private static let pulseSmoothingWindowSeconds = 0.090
    private static let adaptivePeakSpacingSeconds = 0.080
    private static let rPeakRefinementWindowSeconds = 0.080
    /// Half-width of the search for the complex's onset and offset. A QRS
    /// complex is under 120 ms normally and under ~200 ms even when abnormal, so
    /// 100 ms each side comfortably contains it while bounding the walk on a
    /// noisy trace that never returns toward baseline.
    private static let complexWidthSearchSeconds = 0.100
    /// Onset/offset are taken where the deflection has decayed to this fraction
    /// of its peak. True QRS onset is a return to baseline, which is not
    /// robustly identifiable on a single beat, so a fixed fraction of the peak
    /// is the usual proxy.
    private static let complexWidthAmplitudeFraction = 0.20

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
                sourceFile: "\(sourceFile): \(configuration.algorithm.rawValue)",
                // The marker stays on the R peak, so unlike an imported event
                // this duration is the deflection's width *around* the onset
                // time rather than a span starting at it.
                durationSeconds: candidate.widthSeconds
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
        case .simple, .pulse:
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
        case .pulse:
            return pulseProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate,
                polarity: polarity
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

    /// Pulse-oximeter (PPG) systolic peak detection. Unlike the QRS algorithms, a
    /// PPG pulse is a smooth, single-lobed wave with no sharp high-frequency
    /// transient, so the derivative/energy pipelines used for the R-wave do not
    /// apply here. Instead we remove slow drift, smooth away sensor noise and the
    /// dicrotic-notch ripple, and pick amplitude peaks on the resulting waveform —
    /// the same static, non-overlapping peak picker used by `.simple`.
    ///
    /// Note: a PPG peak already lags the ECG R-wave by the peripheral pulse-transit
    /// time, so events produced here are NOT interchangeable with ECG R-waves for
    /// BCG timing — they need a smaller, separate lag when driving BCG correction.
    private static func pulseProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double,
        polarity: ECGDetectionPolarity
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let baselineCorrected = baselineRemoved(
            samples: samples,
            sampleCount: sampleCount,
            samplingRate: samplingRate
        )
        let smoothed = centeredMovingAverage(
            baselineCorrected,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: pulseSmoothingWindowSeconds,
                samplingRate: samplingRate,
                minimum: 3
            )
        )
        guard let scores = normalizedPolarityScores(
            values: smoothed,
            sampleCount: sampleCount,
            polarity: polarity
        ) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: smoothed)
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
                sourceLabel: source.label,
                widthSeconds: complexWidthSeconds(
                    at: refinedSample,
                    processedChannels: processedChannels,
                    samplingRate: source.samplingRate,
                    polarity: polarity
                )
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
                        sourceLabel: source.label,
                        widthSeconds: complexWidthSeconds(
                            at: refinedSample,
                            processedChannels: processedChannels,
                            samplingRate: source.samplingRate,
                            polarity: polarity
                        )
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

    /// Width of the detected complex, measured on the trace rather than assumed,
    /// so a user can click the event and check the detection against the ECG or
    /// PNS channels.
    ///
    /// Every algorithm's `waveform` is the baseline-removed (or band-passed)
    /// signal, so zero is the local baseline and `polarity.score` gives the
    /// deflection in the direction the detector was looking. Onset and offset are
    /// the first samples either side of the peak where that deflection has
    /// decayed to `complexWidthAmplitudeFraction` of its peak value; the width is
    /// the span between them.
    ///
    /// Measured on the single channel carrying the peak, not the aggregate:
    /// averaging across leads with different QRS morphologies would widen the
    /// complex by their misalignment rather than measuring any of them.
    ///
    /// This is the width of the **R deflection**, not full QRS onset-to-offset.
    /// The Q and S limbs cross baseline, so the deflection falls under the
    /// cutoff there and the walk stops regardless of polarity. Reporting a true
    /// QRS interval would need separate Q-onset and S-offset detection, which is
    /// a different (and much less robust) measurement than this one.
    ///
    /// Returns `nil` rather than 0 when there is nothing to measure, so callers
    /// can leave the event's duration unset instead of reporting a false 0 ms.
    static func complexWidthSeconds(
        at sample: Int,
        processedChannels: [ECGProcessedChannel],
        samplingRate: Double,
        polarity: ECGDetectionPolarity
    ) -> Double? {
        guard samplingRate > 0,
              let sampleCount = processedChannels.map(\.waveform.count).min(),
              sample >= 0, sample < sampleCount else {
            return nil
        }

        var peakWaveform: [Double]?
        var peakAmplitude = 0.0
        for channel in processedChannels {
            let value = channel.waveform[sample]
            guard value.isFinite else { continue }
            let amplitude = polarity.score(value)
            if amplitude > peakAmplitude {
                peakAmplitude = amplitude
                peakWaveform = channel.waveform
            }
        }
        guard let waveform = peakWaveform, peakAmplitude > 0 else { return nil }

        let radius = sampleWindow(
            seconds: complexWidthSearchSeconds,
            samplingRate: samplingRate,
            minimum: 1
        )
        let cutoff = peakAmplitude * complexWidthAmplitudeFraction

        var onset = sample
        var index = sample - 1
        let lower = max(0, sample - radius)
        while index >= lower {
            let value = waveform[index]
            guard value.isFinite, polarity.score(value) > cutoff else { break }
            onset = index
            index -= 1
        }

        var offset = sample
        index = sample + 1
        let upper = min(sampleCount - 1, sample + radius)
        while index <= upper {
            let value = waveform[index]
            guard value.isFinite, polarity.score(value) > cutoff else { break }
            offset = index
            index += 1
        }

        guard offset > onset else { return nil }
        return Double(offset - onset) / samplingRate
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
