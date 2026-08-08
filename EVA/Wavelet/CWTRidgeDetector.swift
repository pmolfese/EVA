//
//  CWTRidgeDetector.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Continuous-wavelet-transform ridge detection for locating ERP peaks. A CWT is
//  computed across a range of scales; local maxima of |CWT| are linked from
//  coarse to fine scale into ridge lines. Ridges that persist across enough
//  scales and clear a noise-relative strength threshold are reported as peaks.
//  The scale at which a ridge is strongest estimates the peak's width, which
//  distinguishes narrow (e.g. N1) from broad (e.g. P3) components.
//
//  This is far more robust to single-trial noise than amplitude-threshold peak
//  picking, and provides the seed peaks that the CWT-Ridge pipeline then aligns
//  non-linearly.
//
//  Reference: Du, Kibbe & Lin, "Improved peak detection ... using a continuous
//  wavelet transform," Bioinformatics 2006.
//

import Foundation

nonisolated enum CWTRidgeDetector {
    enum Polarity: String, CaseIterable, Identifiable, Sendable {
        case positive = "Positive"
        case negative = "Negative"
        case either = "Either"

        var id: String { rawValue }
    }

    struct Configuration: Sendable {
        var wavelet: CWTWavelet = .ricker
        /// Smallest / largest wavelet scale in samples, and how many scales to
        /// sample geometrically between them.
        var minScale: Double = 2
        var maxScale: Double = 64
        var scaleCount: Int = 24
        /// A ridge must span at least this many scales to be considered real.
        var minRidgeLength: Int = 4
        /// Peak strength (max |CWT| along the ridge) must exceed this multiple of
        /// the estimated noise level.
        var minSNR: Double = 3.0
        /// When linking maxima across scales, a ridge may drift at most this many
        /// samples per scale step.
        var maxRidgeGap: Int = 3
        var polarity: Polarity = .either

        init(
            wavelet: CWTWavelet = .ricker,
            minScale: Double = 2,
            maxScale: Double = 64,
            scaleCount: Int = 24,
            minRidgeLength: Int = 4,
            minSNR: Double = 3.0,
            maxRidgeGap: Int = 3,
            polarity: Polarity = .either
        ) {
            self.wavelet = wavelet
            self.minScale = minScale
            self.maxScale = maxScale
            self.scaleCount = scaleCount
            self.minRidgeLength = minRidgeLength
            self.minSNR = minSNR
            self.maxRidgeGap = maxRidgeGap
            self.polarity = polarity
        }
    }

    /// A detected peak.
    struct Peak: Identifiable, Sendable {
        var id: Int
        /// Sample index of the peak on the original trace (refined to the local
        /// extremum near the finest ridge point).
        var sampleIndex: Int
        /// Latency in milliseconds relative to the stimulus, if a sampling rate
        /// and stimulus offset were supplied.
        var latencyMs: Double?
        /// Estimated half-width of the component in samples (best ridge scale).
        var widthSamples: Double
        /// Sign of the deflection at the peak (+1 / −1).
        var polaritySign: Int
        /// Signed amplitude of the deflection on the original trace.
        var amplitude: Double
        /// Max |CWT| along the ridge, expressed as a multiple of the noise level.
        var snr: Double
        /// Number of scales the ridge spanned.
        var ridgeLength: Int
    }

    struct Result: Sendable {
        var peaks: [Peak]
        var scales: [Double]
        /// CWT coefficient matrix `[scaleIndex][timeIndex]` (for plotting the
        /// scalogram).
        var coefficients: [[Double]]
        var noiseLevel: Double
    }

    static func detect(
        _ samples: [Float],
        samplingRate: Double? = nil,
        stimulusOffsetSamples: Int = 0,
        configuration: Configuration = Configuration()
    ) -> Result {
        let signal = samples.map { Double($0.isFinite ? $0 : 0) }
        return detect(
            signal,
            samplingRate: samplingRate,
            stimulusOffsetSamples: stimulusOffsetSamples,
            configuration: configuration
        )
    }

    static func detect(
        _ signal: [Double],
        samplingRate: Double? = nil,
        stimulusOffsetSamples: Int = 0,
        configuration: Configuration = Configuration()
    ) -> Result {
        guard signal.count >= 4 else {
            return Result(peaks: [], scales: [], coefficients: [], noiseLevel: 0)
        }

        let scales = geometricScales(configuration)
        let coefficients = ContinuousWaveletTransform.transform(signal, wavelet: configuration.wavelet, scales: scales)
        guard !coefficients.isEmpty else {
            return Result(peaks: [], scales: scales, coefficients: [], noiseLevel: 0)
        }

        // Noise level from the finest-scale row via MAD.
        let noiseLevel = madSigma(coefficients[0])
        let effectiveNoise = noiseLevel > 0 ? noiseLevel : 1e-9

        let ridges = traceRidges(coefficients: coefficients, maxGap: configuration.maxRidgeGap)
        var peaks: [Peak] = []

        for ridge in ridges {
            guard ridge.points.count >= configuration.minRidgeLength else { continue }

            // Strongest point along the ridge determines the peak scale/strength.
            var bestScaleIndex = ridge.points[0].scaleIndex
            var bestTimeIndex = ridge.points[0].timeIndex
            var bestMagnitude = 0.0
            for point in ridge.points {
                let magnitude = abs(coefficients[point.scaleIndex][point.timeIndex])
                if magnitude > bestMagnitude {
                    bestMagnitude = magnitude
                    bestScaleIndex = point.scaleIndex
                    bestTimeIndex = point.timeIndex
                }
            }

            let snr = bestMagnitude / effectiveNoise
            guard snr >= configuration.minSNR else { continue }

            // Refine to the nearest local extremum on the original trace.
            let refined = refinePeakIndex(signal, near: bestTimeIndex, radius: max(2, Int(scales[bestScaleIndex].rounded())))
            let amplitude = signal[refined]
            let sign = amplitude >= 0 ? 1 : -1

            switch configuration.polarity {
            case .positive where sign < 0: continue
            case .negative where sign > 0: continue
            default: break
            }

            let latencyMs: Double? = samplingRate.map { rate in
                Double(refined - stimulusOffsetSamples) / rate * 1000.0
            }

            peaks.append(Peak(
                id: peaks.count,
                sampleIndex: refined,
                latencyMs: latencyMs,
                widthSamples: scales[bestScaleIndex],
                polaritySign: sign,
                amplitude: amplitude,
                snr: snr,
                ridgeLength: ridge.points.count
            ))
        }

        // Merge peaks that refined onto the same sample, keeping the strongest.
        peaks = dedupe(peaks)
            .sorted { $0.sampleIndex < $1.sampleIndex }
            .enumerated()
            .map { index, peak in
                var p = peak
                p.id = index
                return p
            }

        return Result(peaks: peaks, scales: scales, coefficients: coefficients, noiseLevel: noiseLevel)
    }

    // MARK: - Scales

    private static func geometricScales(_ configuration: Configuration) -> [Double] {
        let count = max(2, configuration.scaleCount)
        let lo = max(1e-3, min(configuration.minScale, configuration.maxScale))
        let hi = max(configuration.maxScale, lo + 1)
        let logLo = log(lo)
        let logHi = log(hi)
        return (0..<count).map { i in
            exp(logLo + (logHi - logLo) * Double(i) / Double(count - 1))
        }
    }

    // MARK: - Ridge tracing

    private struct RidgePoint: Sendable {
        var scaleIndex: Int
        var timeIndex: Int
    }

    private struct Ridge: Sendable {
        var points: [RidgePoint]
    }

    /// Link local maxima of |CWT| from the coarsest scale down to the finest.
    private static func traceRidges(coefficients: [[Double]], maxGap: Int) -> [Ridge] {
        let scaleCount = coefficients.count
        guard scaleCount > 0 else { return [] }
        let timeCount = coefficients[0].count

        // Local maxima of magnitude per scale row.
        var maximaByScale: [[Int]] = coefficients.map { row in
            localMaximaOfMagnitude(row)
        }

        var ridges: [Ridge] = []
        var used = maximaByScale.map { Set<Int>(minimumCapacity: $0.count) }

        // Seed from the coarsest scale and follow to finer scales.
        for coarse in stride(from: scaleCount - 1, through: 0, by: -1) {
            for start in maximaByScale[coarse] where !used[coarse].contains(start) {
                var points: [RidgePoint] = [RidgePoint(scaleIndex: coarse, timeIndex: start)]
                used[coarse].insert(start)
                var currentTime = start

                var scale = coarse - 1
                while scale >= 0 {
                    guard let next = nearestMaximum(maximaByScale[scale], to: currentTime, within: maxGap, excluding: used[scale]) else {
                        break
                    }
                    used[scale].insert(next)
                    points.append(RidgePoint(scaleIndex: scale, timeIndex: next))
                    currentTime = next
                    scale -= 1
                }
                ridges.append(Ridge(points: points))
            }
        }
        _ = timeCount
        return ridges
    }

    private static func localMaximaOfMagnitude(_ row: [Double]) -> [Int] {
        guard row.count >= 3 else { return [] }
        var maxima: [Int] = []
        for i in 1..<(row.count - 1) {
            let m = abs(row[i])
            if m >= abs(row[i - 1]) && m > abs(row[i + 1]) && m > 0 {
                maxima.append(i)
            }
        }
        return maxima
    }

    private static func nearestMaximum(_ candidates: [Int], to time: Int, within gap: Int, excluding used: Set<Int>) -> Int? {
        var best: Int?
        var bestDistance = gap + 1
        for candidate in candidates where !used.contains(candidate) {
            let distance = abs(candidate - time)
            if distance <= gap && distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    // MARK: - Refinement & noise

    private static func refinePeakIndex(_ signal: [Double], near index: Int, radius: Int) -> Int {
        let lower = max(0, index - radius)
        let upper = min(signal.count - 1, index + radius)
        guard lower <= upper else { return min(max(index, 0), signal.count - 1) }
        var best = index
        var bestMagnitude = -1.0
        for i in lower...upper {
            let m = abs(signal[i])
            if m > bestMagnitude {
                bestMagnitude = m
                best = i
            }
        }
        return best
    }

    private static func dedupe(_ peaks: [Peak]) -> [Peak] {
        var byIndex: [Int: Peak] = [:]
        for peak in peaks {
            if let existing = byIndex[peak.sampleIndex] {
                if peak.snr > existing.snr { byIndex[peak.sampleIndex] = peak }
            } else {
                byIndex[peak.sampleIndex] = peak
            }
        }
        return Array(byIndex.values)
    }

    private static func madSigma(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let med = medianOfSorted(sorted)
        let deviations = values.map { abs($0 - med) }.sorted()
        return medianOfSorted(deviations) / 0.6745
    }

    private static func medianOfSorted(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
