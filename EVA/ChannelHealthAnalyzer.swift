//
//  ChannelHealthAnalyzer.swift
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
//  Explainable per-channel signal-quality scoring. This is intentionally a
//  metrics model first: the feature/result shape can later feed a trained Core
//  ML ranker, while today's UI already has useful reasons for every score.
//

import Accelerate
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

// MARK: - Spectral outlier detection (HAPPE pop_rejchan 'spec')

nonisolated struct ChannelSpectralConfiguration: Codable, Sendable {
    /// Low edge of the power band examined, in Hz.
    var lowFrequencyHz: Double = 1
    /// High edge of the power band examined, in Hz (clamped to Nyquist).
    var highFrequencyHz: Double = 100
    /// Channels with a band-power z-score above this are flagged as noisy.
    var upperZThreshold: Double = 1.8935
    /// Channels with a band-power z-score below the negative of this are
    /// flagged as abnormally quiet. HAPPE keeps this lenient (5.0).
    var lowerZThreshold: Double = 5

    static let happeStandard = ChannelSpectralConfiguration()
}

nonisolated struct ChannelSpectralResult: Identifiable, Sendable {
    var channelIndex: Int
    var zScore: Double
    var logBandPower: Double
    var isOutlier: Bool
    var score: Double

    var id: Int { channelIndex }
}

// MARK: - Neighbor-prediction detection (HAPPE clean_rawdata ChannelCriterion)

nonisolated struct ChannelRansacConfiguration: Codable, Sendable {
    /// Minimum acceptable correlation between a channel and its
    /// neighbor-based reconstruction. Below this, the channel is flagged.
    var minimumCorrelation: Double = 0.485
    /// Number of nearest neighbors used to reconstruct each channel.
    var neighborCount: Int = 6
    /// Length, in seconds, of the sliding window over which correlation is
    /// measured. The median window correlation drives the decision.
    var windowSeconds: Double = 4

    static let happeStandard = ChannelRansacConfiguration()
}

nonisolated struct ChannelRansacResult: Identifiable, Sendable {
    var channelIndex: Int
    var medianCorrelation: Double
    var badWindowFraction: Double
    var neighborCount: Int
    var isBad: Bool
    var score: Double

    var id: Int { channelIndex }
}

// MARK: - Base (core health) metric thresholds

/// Green/red thresholds for the always-on core health metrics. "Green" is the
/// value scoring 1.0 (fully good); "red" scores 0.0 (fully poor); values in
/// between interpolate.
nonisolated struct ChannelBaseMetricSettings: Codable, Sendable {
    /// Finite-sample fraction (lower bound: higher is better).
    var finiteGreen: Double = 0.995
    var finiteRed: Double = 0.90
    /// p95 amplitude vs. recording median (two-sided ratio: nearer 1x is better).
    var amplitudeGreen: Double = 2.5
    var amplitudeRed: Double = 6.0
    /// Peak vs. median p99 (upper ratio: lower is better).
    var burstGreen: Double = 8.0
    var burstRed: Double = 24.0
    /// Flatline fraction (upper: lower is better).
    var flatlineGreen: Double = 0.005
    var flatlineRed: Double = 0.15
    /// Clipping fraction (upper: lower is better).
    var clippingGreen: Double = 0.002
    var clippingRed: Double = 0.08
    /// Sample-to-sample change vs. typical (upper: lower is better).
    var fastNoiseGreen: Double = 2.0
    var fastNoiseRed: Double = 5.0
    /// Block-mean drift vs. typical (upper: lower is better).
    var slowDriftGreen: Double = 2.5
    var slowDriftRed: Double = 6.0

    static let defaults = ChannelBaseMetricSettings()
}

nonisolated enum ChannelHealthAnalyzer {
    static func analyze(
        signal: MFFSignalData,
        layout: SensorLayout?,
        base: ChannelBaseMetricSettings = ChannelBaseMetricSettings(),
        spectral: ChannelSpectralConfiguration? = nil,
        ransac: ChannelRansacConfiguration? = nil,
        // Impedance is a stable property of the *recording*, independent of the
        // processing pipeline (filtering, gradient correction, re-referencing),
        // so it is passed explicitly rather than read off the processed signal.
        // Falls back to the signal's own values when not provided.
        impedancesKOhm: [Float]? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> ChannelHealthAnalysis {
        let impedances = impedancesKOhm ?? signal.impedancesKOhm
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
            let impedance = impedances.flatMap { values in
                values.indices.contains(summary.channelIndex) ? values[summary.channelIndex] : nil
            }
            let result = result(
                for: summary,
                baselines: baselines,
                base: base,
                neighborScore: neighborScore,
                impedanceKOhm: impedance
            )
            results[summary.channelIndex] = result
            features[summary.channelIndex] = channelFeatures(
                for: summary,
                baselines: baselines,
                neighborScore: neighborScore
            )
        }
        var analysis = ChannelHealthAnalysis(
            resultsByChannel: results,
            featuresByChannel: features,
            baselines: baselines,
            sampleStride: sampleStride,
            effectiveSamplingRate: signal.samplingRate / Double(max(sampleStride, 1)),
            analyzedSampleCount: max(sampleCount / max(sampleStride, 1), 1)
        )

        if let spectral {
            let spectralResults = spectralDetection(signal: signal, configuration: spectral)
            analysis = addingSpectralMetrics(to: analysis, spectralResults: spectralResults)
        }
        if let ransac {
            let ransacResults = ransacDetection(signal: signal, layout: layout, configuration: ransac)
            analysis = addingRansacMetrics(to: analysis, ransacResults: ransacResults)
        }

        // Spectral-shape metrics (aperiodic slope, muscle band, line harmonics)
        // always run — they are cheap once the periodogram is computed and need
        // no cross-channel baseline or layout.
        let advanced = advancedSpectralMetrics(signal: signal)
        analysis = adding(metricsByChannel: advanced, to: analysis)

        progress?(1)

        return analysis
    }

    static func addingWaveletMetrics(
        to analysis: ChannelHealthAnalysis,
        waveletResults: [Int: WaveletChannelGoodnessResult]
    ) -> ChannelHealthAnalysis {
        guard !waveletResults.isEmpty else { return analysis }
        var analysis = analysis
        for (channelIndex, wavelet) in waveletResults {
            guard var result = analysis.resultsByChannel[channelIndex] else { continue }
            let waveletMetric = metric(
                name: "Wavelet Burden",
                score: wavelet.goodnessScore,
                detail: [
                    "energy \(HealthScoring.formatPercent(wavelet.artifactEnergyFraction))",
                    "bursts \(HealthScoring.formatPercent(wavelet.burstFraction))",
                    "peak \(HealthScoring.formatMicrovolts(Double(wavelet.peakArtifactMagnitude)))",
                    "L\(wavelet.dominantLevel)"
                ].joined(separator: ", "),
                weight: 1.4
            )
            let metrics = result.metrics.filter { $0.name != waveletMetric.name } + [waveletMetric]
            result = recomputedResult(channelIndex: channelIndex, metrics: metrics)
            analysis.resultsByChannel[channelIndex] = result
        }
        return analysis
    }

    // MARK: - Spectral outlier detection

    /// Computes a band-power z-score per channel (mirroring EEGLAB's
    /// `pop_rejchan` with `'measure','spec'`): the mean log power over the
    /// configured frequency band is standardized across channels, and channels
    /// outside the z-threshold band are flagged.
    static func spectralDetection(
        signal: MFFSignalData,
        configuration: ChannelSpectralConfiguration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> [Int: ChannelSpectralResult] {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 32,
              !signal.data.isEmpty else {
            return [:]
        }

        let nyquist = signal.samplingRate / 2
        let low = max(configuration.lowFrequencyHz, 0.1)
        let high = min(configuration.highFrequencyHz, nyquist * 0.95)
        guard high > low else { return [:] }

        var logPowers: [Int: Double] = [:]
        logPowers.reserveCapacity(signal.data.count)
        for (index, channel) in signal.data.enumerated() {
            if Task.isCancelled { return [:] }
            let power = welchBandPower(channel, samplingRate: signal.samplingRate, low: low, high: high)
            if power > 0 {
                logPowers[index] = log10(power)
            }
            progress?(0.9 * Double(index + 1) / Double(max(signal.data.count, 1)))
        }

        let values = Array(logPowers.values)
        guard values.count > 2 else { return [:] }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let standardDeviation = sqrt(max(variance, 0))
        guard standardDeviation > 1e-12 else { return [:] }

        var results: [Int: ChannelSpectralResult] = [:]
        results.reserveCapacity(logPowers.count)
        let greenZ = configuration.upperZThreshold * 0.6
        for (channelIndex, logPower) in logPowers {
            let z = (logPower - mean) / standardDeviation
            let isOutlier = z > configuration.upperZThreshold || z < -configuration.lowerZThreshold
            let upperScore = HealthScoring.scoreUpperRatio(z, green: greenZ, red: configuration.upperZThreshold)
            let lowerScore = HealthScoring.scoreUpperRatio(-z, green: configuration.lowerZThreshold * 0.6, red: configuration.lowerZThreshold)
            results[channelIndex] = ChannelSpectralResult(
                channelIndex: channelIndex,
                zScore: z,
                logBandPower: logPower,
                isOutlier: isOutlier,
                score: min(upperScore, lowerScore)
            )
        }
        progress?(1)
        return results
    }

    static func addingSpectralMetrics(
        to analysis: ChannelHealthAnalysis,
        spectralResults: [Int: ChannelSpectralResult]
    ) -> ChannelHealthAnalysis {
        guard !spectralResults.isEmpty else { return analysis }
        var analysis = analysis
        for (channelIndex, spectral) in spectralResults {
            guard var result = analysis.resultsByChannel[channelIndex] else { continue }
            let detail = spectral.isOutlier
                ? "z \(formatSigned(spectral.zScore)) - spectral power outlier"
                : "z \(formatSigned(spectral.zScore)) - within typical band"
            let spectralMetric = metric(
                name: "Spectral Outlier",
                score: spectral.score,
                detail: detail,
                weight: 1.3
            )
            let metrics = result.metrics.filter { $0.name != spectralMetric.name } + [spectralMetric]
            result = recomputedResult(channelIndex: channelIndex, metrics: metrics)
            analysis.resultsByChannel[channelIndex] = result
        }
        return analysis
    }

    // MARK: - Advanced spectral metrics (slope, muscle, line harmonics)

    /// Per-channel spectral-shape metrics derived from one Welch periodogram:
    /// the aperiodic 1/f slope, the high-frequency (EMG/muscle) band fraction,
    /// and power-line harmonic prominence. Each is self-contained (no
    /// cross-channel baseline) so the thresholds are absolute.
    static func advancedSpectralMetrics(
        signal: MFFSignalData,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> [Int: [ChannelHealthMetric]] {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 32,
              !signal.data.isEmpty else {
            return [:]
        }

        let nyquist = signal.samplingRate / 2
        var output: [Int: [ChannelHealthMetric]] = [:]
        output.reserveCapacity(signal.data.count)

        for (index, channel) in signal.data.enumerated() {
            if Task.isCancelled { return output }
            defer { progress?(Double(index + 1) / Double(max(signal.data.count, 1))) }
            guard let (spectrum, binHz) = averagedPowerSpectrum(channel, samplingRate: signal.samplingRate) else {
                continue
            }

            var metrics: [ChannelHealthMetric] = []

            // Aperiodic slope: log–log fit of power vs. frequency. Clean EEG
            // falls off as ~1/f^x (negative slope ≈ −1…−2.5). A near-flat
            // (white) slope marks broadband noise / disconnection; an extreme
            // negative slope marks drift/DC dominance.
            let slopeHigh = min(40, nyquist * 0.9)
            if let slope = aperiodicSlope(spectrum, binHz: binHz, low: 2, high: slopeHigh) {
                let negSlope = -slope
                let lowScore = HealthScoring.scoreLowerBound(negSlope, green: 0.7, red: 0.0)
                let highScore = HealthScoring.scoreUpperRatio(negSlope, green: 3.0, red: 5.0)
                metrics.append(metric(
                    name: "Aperiodic Slope",
                    score: min(lowScore, highScore),
                    detail: String(format: "1/f exponent %.2f", negSlope),
                    weight: 1.2
                ))
            }

            // Muscle (EMG): high-frequency band power relative to the mid band.
            // Sustained muscle activity lifts 20–40 Hz well above its usual
            // small fraction of low-band power.
            if nyquist > 25 {
                let emgHigh = min(40, nyquist * 0.9)
                let highBand = bandPower(spectrum, binHz: binHz, low: 20, high: emgHigh)
                let lowBand = bandPower(spectrum, binHz: binHz, low: 2, high: 20)
                if lowBand > 0 {
                    let ratio = highBand / lowBand
                    metrics.append(metric(
                        name: "Muscle (EMG)",
                        score: HealthScoring.scoreUpperRatio(ratio, green: 0.4, red: 2.0),
                        detail: String(format: "HF/LF power %.2f", ratio),
                        weight: 1.1
                    ))
                }
            }

            // Line harmonics + notch residual: prominence (local SNR) of the
            // 60 Hz fundamental and its harmonics above the surrounding
            // spectrum. Leftover line energy after notching shows here too.
            if let (snr, freq) = lineHarmonicProminence(spectrum, binHz: binHz, fundamental: 60, nyquist: nyquist) {
                metrics.append(metric(
                    name: "Line Harmonics",
                    score: HealthScoring.scoreUpperRatio(snr, green: 3, red: 15),
                    detail: String(format: "%.0f Hz %.1f× local", freq, snr),
                    weight: 0.9
                ))
            }

            if !metrics.isEmpty { output[index] = metrics }
        }
        return output
    }

    /// Merges a batch of per-channel metrics into an analysis, replacing any
    /// existing metric of the same name and recomputing the channel score.
    static func adding(
        metricsByChannel: [Int: [ChannelHealthMetric]],
        to analysis: ChannelHealthAnalysis
    ) -> ChannelHealthAnalysis {
        guard !metricsByChannel.isEmpty else { return analysis }
        var analysis = analysis
        for (channelIndex, newMetrics) in metricsByChannel {
            guard let result = analysis.resultsByChannel[channelIndex] else { continue }
            let names = Set(newMetrics.map(\.name))
            let merged = result.metrics.filter { !names.contains($0.name) } + newMetrics
            analysis.resultsByChannel[channelIndex] = recomputedResult(channelIndex: channelIndex, metrics: merged)
        }
        return analysis
    }

    /// Ordinary-least-squares slope of log10(power) vs. log10(frequency) over
    /// `low...high` Hz, skipping bins within ±2 Hz of a 60 Hz harmonic so line
    /// noise doesn't bias the fit. Returns `nil` with too few usable bins.
    private static func aperiodicSlope(
        _ spectrum: [Double],
        binHz: Double,
        low: Double,
        high: Double
    ) -> Double? {
        guard high > low, binHz > 0 else { return nil }
        let half = spectrum.count
        let lowBin = max(Int((low / binHz).rounded(.down)), 1)
        let highBin = min(Int((high / binHz).rounded(.up)), half - 1)
        guard highBin > lowBin else { return nil }

        var xs: [Double] = []
        var ys: [Double] = []
        for bin in lowBin...highBin {
            let freq = Double(bin) * binHz
            // Skip ±2 Hz around each 60 Hz harmonic.
            let nearLine = stride(from: 60.0, through: high, by: 60.0).contains { abs(freq - $0) <= 2 }
            if nearLine { continue }
            let power = spectrum[bin]
            guard power > 0 else { continue }
            xs.append(log10(freq))
            ys.append(log10(power))
        }
        guard xs.count >= 8 else { return nil }

        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0
        var sxy = 0.0
        for i in xs.indices {
            let dx = xs[i] - meanX
            sxx += dx * dx
            sxy += dx * (ys[i] - meanY)
        }
        guard sxx > 1e-12 else { return nil }
        return sxy / sxx
    }

    /// Largest local SNR among the fundamental and its harmonics: peak power at
    /// the harmonic bin (±1) divided by the median power of nearby off-peak
    /// bins. Returns the SNR and the harmonic frequency that produced it.
    private static func lineHarmonicProminence(
        _ spectrum: [Double],
        binHz: Double,
        fundamental: Double,
        nyquist: Double
    ) -> (snr: Double, frequency: Double)? {
        guard binHz > 0 else { return nil }
        let half = spectrum.count
        var best: (snr: Double, frequency: Double)? = nil

        var harmonic = 1
        while true {
            let freq = fundamental * Double(harmonic)
            if freq >= nyquist * 0.95 { break }
            harmonic += 1
            let centerBin = Int((freq / binHz).rounded())
            guard centerBin > 2, centerBin < half - 2 else { continue }

            let peak = (max(centerBin - 1, 0)...min(centerBin + 1, half - 1))
                .map { spectrum[$0] }
                .max() ?? 0

            // Off-peak neighbors: ±2…±6 bins, excluding the peak shoulder.
            var neighbors: [Double] = []
            for offset in 2...6 {
                if centerBin - offset >= 1 { neighbors.append(spectrum[centerBin - offset]) }
                if centerBin + offset < half { neighbors.append(spectrum[centerBin + offset]) }
            }
            let baseline = median(neighbors)
            guard baseline > 0 else { continue }
            let snr = peak / baseline
            if best == nil || snr > best!.snr {
                best = (snr, freq)
            }
        }
        return best
    }

    private static func welchBandPower(
        _ samples: [Float],
        samplingRate: Double,
        low: Double,
        high: Double
    ) -> Double {
        guard let spectrum = averagedPowerSpectrum(samples, samplingRate: samplingRate) else { return 0 }
        return bandPower(spectrum.power, binHz: spectrum.binHz, low: low, high: high)
    }

    /// Welch-averaged periodogram: mean power per FFT bin (Hann window, 50 %
    /// overlap). Returns the per-bin power array (length = segment/2) and the
    /// frequency width of each bin, or `nil` if the channel is too short.
    private static func averagedPowerSpectrum(
        _ samples: [Float],
        samplingRate: Double
    ) -> (power: [Double], binHz: Double)? {
        let count = samples.count
        guard count > 32 else { return nil }

        // Segment length: a power of two near two seconds, bounded for speed.
        let target = min(max(Int(samplingRate * 2), 64), 4096)
        var segment = 16
        while segment * 2 <= target { segment *= 2 }
        guard count >= segment,
              let dft = vDSP.DFT(
                count: segment,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
              ) else {
            return nil
        }

        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: segment,
            isHalfWindow: false
        )
        let imaginaryInput = [Float](repeating: 0, count: segment)
        let half = segment / 2
        var averagePower = [Double](repeating: 0, count: half)
        var segmentCount = 0
        let step = max(segment / 2, 1)

        var start = 0
        while start + segment <= count {
            var realInput = Array(samples[start..<start + segment])
            let mean = vDSP.mean(realInput)
            realInput = vDSP.add(-mean, realInput)
            realInput = vDSP.multiply(realInput, window)

            var realOutput = [Float](repeating: 0, count: segment)
            var imaginaryOutput = [Float](repeating: 0, count: segment)
            dft.transform(
                inputReal: realInput,
                inputImaginary: imaginaryInput,
                outputReal: &realOutput,
                outputImaginary: &imaginaryOutput
            )
            for bin in 0..<half {
                let re = Double(realOutput[bin])
                let im = Double(imaginaryOutput[bin])
                averagePower[bin] += re * re + im * im
            }
            segmentCount += 1
            start += step
        }

        guard segmentCount > 0 else { return nil }
        for bin in 0..<half { averagePower[bin] /= Double(segmentCount) }
        return (averagePower, samplingRate / Double(segment))
    }

    /// Mean power across the FFT bins spanning `low...high` Hz.
    private static func bandPower(_ spectrum: [Double], binHz: Double, low: Double, high: Double) -> Double {
        let half = spectrum.count
        let lowBin = max(Int((low / binHz).rounded(.down)), 1)
        let highBin = min(Int((high / binHz).rounded(.up)), half - 1)
        guard highBin >= lowBin else { return 0 }
        var sum = 0.0
        for bin in lowBin...highBin { sum += spectrum[bin] }
        return sum / Double(highBin - lowBin + 1)
    }

    // MARK: - Neighbor-prediction (RANSAC-style) detection

    /// Reconstructs each channel from an inverse-distance-weighted blend of its
    /// nearest neighbors and measures the median sliding-window correlation
    /// between the channel and its reconstruction. This is the spirit of
    /// EEGLAB clean_rawdata's `ChannelCriterion` (predictability from
    /// neighbors), using a deterministic neighbor blend in place of the random
    /// spherical-spline RANSAC sampling.
    static func ransacDetection(
        signal: MFFSignalData,
        layout: SensorLayout?,
        configuration: ChannelRansacConfiguration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> [Int: ChannelRansacResult] {
        guard let layout,
              signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 32 else {
            return [:]
        }

        let stride = analysisStride(sampleCount: sampleCount, samplingRate: signal.samplingRate)
        let effectiveRate = signal.samplingRate / Double(max(stride, 1))
        var seriesByChannel: [Int: [Double]] = [:]
        seriesByChannel.reserveCapacity(signal.data.count)
        for index in signal.data.indices {
            seriesByChannel[index] = downsampledSeries(signal.data[index], stride: stride)
        }

        let positions = layout.positions.filter { seriesByChannel[$0.channelIndex] != nil }
        let windowSamples = max(Int((configuration.windowSeconds * effectiveRate).rounded()), 16)
        let neighborCount = max(configuration.neighborCount, 1)

        var results: [Int: ChannelRansacResult] = [:]
        results.reserveCapacity(positions.count)
        for (offset, position) in positions.enumerated() {
            if Task.isCancelled { return results }
            guard let actual = seriesByChannel[position.channelIndex] else { continue }

            let neighbors = positions
                .filter { $0.channelIndex != position.channelIndex }
                .sorted { squaredDistance($0, position) < squaredDistance($1, position) }
                .prefix(neighborCount)

            let weightedNeighbors = neighbors.compactMap { neighbor -> (series: [Double], weight: Double)? in
                guard let series = seriesByChannel[neighbor.channelIndex] else { return nil }
                let distance = sqrt(squaredDistance(neighbor, position))
                return (series, 1.0 / max(distance, 1e-6))
            }
            guard !weightedNeighbors.isEmpty else { continue }

            let predicted = reconstruct(from: weightedNeighbors, length: actual.count)
            let correlations = windowedCorrelations(
                actual,
                predicted,
                windowSamples: windowSamples
            )
            guard !correlations.isEmpty else { continue }

            let medianCorrelation = median(correlations.map { max($0, 0) })
            let badWindows = correlations.filter { $0 < configuration.minimumCorrelation }.count
            let badFraction = Double(badWindows) / Double(correlations.count)
            results[position.channelIndex] = ChannelRansacResult(
                channelIndex: position.channelIndex,
                medianCorrelation: medianCorrelation,
                badWindowFraction: badFraction,
                neighborCount: weightedNeighbors.count,
                isBad: medianCorrelation < configuration.minimumCorrelation,
                score: HealthScoring.scoreLowerBound(
                    medianCorrelation,
                    green: min(configuration.minimumCorrelation + 0.2, 0.95),
                    red: configuration.minimumCorrelation
                )
            )
            progress?(Double(offset + 1) / Double(max(positions.count, 1)))
        }
        return results
    }

    static func addingRansacMetrics(
        to analysis: ChannelHealthAnalysis,
        ransacResults: [Int: ChannelRansacResult]
    ) -> ChannelHealthAnalysis {
        guard !ransacResults.isEmpty else { return analysis }
        var analysis = analysis
        for (channelIndex, ransac) in ransacResults {
            guard var result = analysis.resultsByChannel[channelIndex] else { continue }
            let ransacMetric = metric(
                name: "Neighbor Prediction",
                score: ransac.score,
                detail: "median r \(String(format: "%.2f", ransac.medianCorrelation)), \(HealthScoring.formatPercent(ransac.badWindowFraction)) bad windows",
                weight: 1.4
            )
            let metrics = result.metrics.filter { $0.name != ransacMetric.name } + [ransacMetric]
            result = recomputedResult(channelIndex: channelIndex, metrics: metrics)
            analysis.resultsByChannel[channelIndex] = result
        }
        return analysis
    }

    private static func downsampledSeries(_ channel: [Float], stride: Int) -> [Double] {
        guard !channel.isEmpty else { return [] }
        var values: [Double] = []
        values.reserveCapacity(channel.count / max(stride, 1) + 1)
        var previous = 0.0
        for sample in Swift.stride(from: 0, to: channel.count, by: max(stride, 1)) {
            let value = Double(channel[sample])
            if value.isFinite {
                previous = value
                values.append(value)
            } else {
                values.append(previous)
            }
        }
        return values
    }

    private static func reconstruct(
        from weightedNeighbors: [(series: [Double], weight: Double)],
        length: Int
    ) -> [Double] {
        guard length > 0 else { return [] }
        var predicted = [Double](repeating: 0, count: length)
        var totalWeight = 0.0
        for neighbor in weightedNeighbors {
            totalWeight += neighbor.weight
            let count = min(length, neighbor.series.count)
            for index in 0..<count {
                predicted[index] += neighbor.series[index] * neighbor.weight
            }
        }
        guard totalWeight > 1e-12 else { return predicted }
        for index in predicted.indices {
            predicted[index] /= totalWeight
        }
        return predicted
    }

    private static func windowedCorrelations(
        _ lhs: [Double],
        _ rhs: [Double],
        windowSamples: Int
    ) -> [Double] {
        let count = min(lhs.count, rhs.count)
        guard count >= windowSamples, windowSamples >= 8 else {
            return count > 8 ? [correlation(lhs, rhs)] : []
        }
        var values: [Double] = []
        values.reserveCapacity(count / windowSamples + 1)
        for start in Swift.stride(from: 0, to: count - windowSamples + 1, by: windowSamples) {
            let end = start + windowSamples
            values.append(correlation(Array(lhs[start..<end]), Array(rhs[start..<end])))
        }
        return values
    }

    private static func formatSigned(_ value: Double) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%+.2f", value)
    }

    private static func analysisStride(sampleCount: Int, samplingRate: Double) -> Int {
        let targetRateStride = Downsampler.factor(sourceRate: samplingRate, targetRate: 250)
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
        let p95Abs = SignalStatistics.percentile(absValues, fraction: 0.95)
        let p99Abs = SignalStatistics.percentile(absValues, fraction: 0.99)
        let maxAbs = absValues.last ?? 0
        let differenceRMS = SignalStatistics.rootMeanSquare(differences)
        let flatlineThreshold = max(p95Abs * 0.0001, 1e-7)
        let flatlineFraction = differences.isEmpty
            ? 1
            : Double(differences.filter { $0 <= flatlineThreshold }.count) / Double(differences.count)
        let clippingFraction = HealthScoring.clippingFraction(absValues: absValues, maxAbs: maxAbs)
        let driftRMS = blockMeanRMS(values: sampledValues, samplingRate: samplingRate / Double(max(sampleStride, 1)))
        let lineNoisePower = sinusoidPower(
            values: sampledValues,
            effectiveSamplingRate: samplingRate / Double(max(sampleStride, 1)),
            frequency: 60
        )

        // Excess kurtosis (Fisher) of the finite samples. m4/m2² − 3.
        var m2 = 0.0
        var m4 = 0.0
        for value in finiteValues {
            let d = value - mean
            let d2 = d * d
            m2 += d2
            m4 += d2 * d2
        }
        m2 /= Double(finiteCount)
        m4 /= Double(finiteCount)
        let excessKurtosis = m2 > 1e-18 ? m4 / (m2 * m2) - 3 : 0

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
            lineNoisePower: lineNoisePower,
            excessKurtosis: excessKurtosis
        )
    }

    private static func result(
        for summary: ChannelSummary,
        baselines: ChannelHealthBaselines,
        base: ChannelBaseMetricSettings,
        neighborScore: Double?,
        impedanceKOhm: Float? = nil
    ) -> ChannelHealthResult {
        var metrics: [ChannelHealthMetric] = []

        // Electrode impedance (EGI ICAL), only when the file recorded a value.
        if let impedanceKOhm, impedanceKOhm.isFinite {
            let kOhm = Double(impedanceKOhm)
            metrics.append(metric(
                name: "Impedance",
                score: HealthScoring.scoreImpedanceKOhm(kOhm),
                detail: String(format: "%.0f kΩ (%@)", kOhm, HealthScoring.impedanceBand(kOhm)),
                weight: 1.4
            ))
        }

        metrics.append(metric(
            name: "Finite Samples",
            score: HealthScoring.scoreLowerBound(summary.finiteFraction, green: base.finiteGreen, red: base.finiteRed),
            detail: "\(HealthScoring.formatPercent(summary.finiteFraction)) finite samples",
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
                score: HealthScoring.scoreTwoSidedRatio(ratio, green: base.amplitudeGreen, red: base.amplitudeRed),
                detail: "p95 \(HealthScoring.formatMicrovolts(summary.p95Abs)), \(HealthScoring.formatRatio(ratio)) typical",
                weight: 1.4
            ))
        }

        let burstRatio = summary.maxAbs / max(baselines.medianP99AbsMicrovolts, 1e-9)
        metrics.append(metric(
            name: "Burst Peaks",
            score: HealthScoring.scoreUpperRatio(burstRatio, green: base.burstGreen, red: base.burstRed),
            detail: "max \(HealthScoring.formatMicrovolts(summary.maxAbs)), \(HealthScoring.formatRatio(burstRatio)) median p99",
            weight: 1.0
        ))

        metrics.append(metric(
            name: "Flatline",
            score: HealthScoring.scoreUpperFraction(summary.flatlineFraction, green: base.flatlineGreen, red: base.flatlineRed),
            detail: "\(HealthScoring.formatPercent(summary.flatlineFraction)) near-zero / no-change samples",
            weight: 1.3
        ))

        metrics.append(metric(
            name: "Clipping",
            score: HealthScoring.scoreUpperFraction(summary.clippingFraction, green: base.clippingGreen, red: base.clippingRed),
            detail: "\(HealthScoring.formatPercent(summary.clippingFraction)) samples pinned at rail",
            weight: 1.1
        ))

        let derivativeRatio = summary.differenceRMS / max(summary.rms, 1e-9)
        let derivativeTypicality = derivativeRatio / baselines.medianDerivativeRatio
        metrics.append(metric(
            name: "Fast Noise",
            score: HealthScoring.scoreUpperRatio(derivativeTypicality, green: base.fastNoiseGreen, red: base.fastNoiseRed),
            detail: "sample-to-sample change \(HealthScoring.formatRatio(derivativeTypicality)) typical",
            weight: 1.0
        ))

        let driftRatio = summary.driftRMS / max(summary.rms, 1e-9)
        let driftTypicality = driftRatio / baselines.medianDriftRatio
        metrics.append(metric(
            name: "Slow Drift",
            score: HealthScoring.scoreUpperRatio(driftTypicality, green: base.slowDriftGreen, red: base.slowDriftRed),
            detail: "block-mean drift \(HealthScoring.formatRatio(driftTypicality)) typical",
            weight: 0.8
        ))

        // Heavy-tailed sample distribution (FASTER): isolated pops/spikes that a
        // single max (Burst Peaks) can miss. Excess kurtosis ≈ 0 for clean EEG.
        let kurtosis = max(summary.excessKurtosis, 0)
        metrics.append(metric(
            name: "Kurtosis",
            score: HealthScoring.scoreUpperRatio(kurtosis, green: 5, red: 20),
            detail: String(format: "excess kurtosis %.1f", summary.excessKurtosis),
            weight: 1.0
        ))

        if summary.lineNoisePower > 0, baselines.medianLineNoisePower > 0 {
            let lineRatio = summary.lineNoisePower / baselines.medianLineNoisePower
            metrics.append(metric(
                name: "60 Hz Line",
                score: HealthScoring.scoreUpperRatio(lineRatio, green: 3.0, red: 10.0),
                detail: "60 Hz proxy \(HealthScoring.formatRatio(lineRatio)) typical",
                weight: 0.8
            ))
        }

        // Neighbor Agreement is intentionally not emitted as a scored metric:
        // the stronger Neighbor Prediction (RANSAC) metric supersedes it. The
        // value is still retained in features for the ML ranker.
        _ = neighborScore

        let weightedTotal = metrics.reduce(0) { $0 + $1.score * $1.weight }
        let weightTotal = metrics.reduce(0) { $0 + $1.weight }
        let goodFraction = weightTotal > 0 ? weightedTotal / weightTotal : 0
        let percentage = Int((min(max(goodFraction, 0), 1) * 100).rounded())
        let grade = HealthScoring.grade(for: goodFraction)
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

    private static func recomputedResult(channelIndex: Int, metrics: [ChannelHealthMetric]) -> ChannelHealthResult {
        let sortedMetrics = metrics.sorted { $0.score < $1.score }
        let weightedTotal = sortedMetrics.reduce(0) { $0 + $1.score * $1.weight }
        let weightTotal = sortedMetrics.reduce(0) { $0 + $1.weight }
        let goodFraction = weightTotal > 0 ? weightedTotal / weightTotal : 0
        let percentage = Int((min(max(goodFraction, 0), 1) * 100).rounded())
        let grade = HealthScoring.grade(for: goodFraction)
        let weakMetrics = sortedMetrics
            .filter { $0.score < 0.78 }
            .prefix(2)
            .map(\.name)
        let summaryText = weakMetrics.isEmpty
            ? "Metrics look typical for this recording."
            : "\(weakMetrics.joined(separator: " and ")) need review."

        return ChannelHealthResult(
            channelIndex: channelIndex,
            goodPercentage: percentage,
            grade: grade,
            summary: summaryText,
            metrics: sortedMetrics
        )
    }

    private static func metric(name: String, score: Double, detail: String, weight: Double) -> ChannelHealthMetric {
        let boundedScore = min(max(score, 0), 1)
        return ChannelHealthMetric(
            name: name,
            score: boundedScore,
            grade: HealthScoring.grade(for: boundedScore),
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

    fileprivate static func median(_ values: [Double], fallback: Double = 1) -> Double {
        var finite = values.filter { $0.isFinite && $0 > 0 }
        guard !finite.isEmpty else { return fallback }
        finite.sort()
        return max(SignalStatistics.percentile(finite, fraction: 0.5), 1e-9)
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
    /// Excess kurtosis of the sample distribution (0 for Gaussian). Spiky,
    /// intermittently-popping channels run heavy-tailed (large positive).
    var excessKurtosis: Double = 0
}
