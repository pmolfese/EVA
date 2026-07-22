//
//  WaveletDenoiser.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Wavelet shrinkage denoising of single-trial (or averaged) ERP traces. The
//  finest-detail coefficients are used to estimate the noise level via the
//  median-absolute-deviation (MAD) rule, then detail coefficients are shrunk
//  with a soft or hard threshold before reconstruction. This raises single-trial
//  SNR so downstream latency estimation (Woody / RIDE / CWT ridge) converges
//  more reliably.
//
//  Reference: Donoho & Johnstone, "Ideal spatial adaptation by wavelet
//  shrinkage," Biometrika 1994 (VisuShrink / SureShrink).
//

import Foundation

nonisolated enum WaveletDenoiser {
    enum Thresholding: String, CaseIterable, Identifiable, Sendable {
        /// Soft thresholding shrinks coefficients toward zero (continuous,
        /// smoother reconstruction). Hard thresholding zeroes small
        /// coefficients and keeps the rest (preserves peak amplitude better).
        case soft = "Soft"
        case hard = "Hard"

        var id: String { rawValue }
    }

    enum ThresholdRule: String, CaseIterable, Identifiable, Sendable {
        /// VisuShrink universal threshold: sigma * sqrt(2 ln N). Aggressive,
        /// good for visual smoothness.
        case universal = "Universal"
        /// SURE (Stein Unbiased Risk Estimate) threshold, chosen per detail
        /// band to minimize estimated risk. Preserves more signal detail.
        case sure = "SURE"

        var id: String { rawValue }
    }

    struct Configuration: Sendable {
        var wavelet: DWTWavelet = .sym4
        var levels: Int = 4
        var thresholding: Thresholding = .soft
        var rule: ThresholdRule = .universal
        /// Multiplies the derived threshold. 1.0 = textbook; lower keeps more
        /// signal, higher smooths more.
        var strength: Double = 1.0

        init(
            wavelet: DWTWavelet = .sym4,
            levels: Int = 4,
            thresholding: Thresholding = .soft,
            rule: ThresholdRule = .universal,
            strength: Double = 1.0
        ) {
            self.wavelet = wavelet
            self.levels = levels
            self.thresholding = thresholding
            self.rule = rule
            self.strength = strength
        }
    }

    /// Denoise a `Float` trace. Returns a trace of identical length. Non-finite
    /// samples are treated as zero for the transform and restored to zero.
    static func denoise(_ samples: [Float], configuration: Configuration = Configuration()) -> [Float] {
        guard samples.count >= 4 else { return samples }
        let input = samples.map { Double($0.isFinite ? $0 : 0) }
        let denoised = denoise(input, configuration: configuration)
        return denoised.map { Float($0) }
    }

    /// Denoise a `Double` trace.
    static func denoise(_ signal: [Double], configuration: Configuration = Configuration()) -> [Double] {
        let levels = max(1, min(configuration.levels, WaveletTransforms.maxLevels(signalLength: signal.count, wavelet: configuration.wavelet)))
        guard levels >= 1 else { return signal }

        var decomposition = WaveletTransforms.forward(signal, wavelet: configuration.wavelet, levels: levels)

        // Estimate noise sigma from the finest detail band (MAD / 0.6745).
        guard let finest = decomposition.details.first, !finest.isEmpty else { return signal }
        let sigma = medianAbsoluteDeviation(finest) / 0.6745
        guard sigma > 0 else { return signal }

        decomposition.details = decomposition.details.map { band in
            let threshold: Double
            switch configuration.rule {
            case .universal:
                threshold = sigma * (2.0 * log(Double(max(band.count, 2)))).squareRoot()
            case .sure:
                threshold = sureThreshold(band, sigma: sigma)
            }
            let scaled = threshold * configuration.strength
            return band.map { apply(threshold: scaled, to: $0, mode: configuration.thresholding) }
        }

        return WaveletTransforms.inverse(decomposition)
    }

    // MARK: - Thresholding

    private static func apply(threshold: Double, to value: Double, mode: Thresholding) -> Double {
        let magnitude = abs(value)
        guard magnitude > threshold else { return 0 }
        switch mode {
        case .hard:
            return value
        case .soft:
            return (value < 0 ? -1.0 : 1.0) * (magnitude - threshold)
        }
    }

    /// SURE threshold selection for a single detail band (Stein's unbiased risk).
    private static func sureThreshold(_ band: [Double], sigma: Double) -> Double {
        guard sigma > 0, !band.isEmpty else { return 0 }
        let n = Double(band.count)
        // Normalize coefficients by sigma, work with squared magnitudes sorted.
        let normalized = band.map { ($0 / sigma) * ($0 / sigma) }.sorted()
        let universal = (2.0 * log(n)).squareRoot()

        // If the band is essentially noise, fall back to the universal threshold.
        let energy = normalized.reduce(0, +)
        let sparsityBound = 1.0 + (log2(n).rounded() * pow(log2(n), 1.5)) / n
        if (energy - n) / n < sparsityBound {
            return sigma * universal
        }

        // Evaluate SURE(t) at each candidate threshold t = sorted |x|/sigma.
        // SURE(t) = n - 2·#{x² ≤ t²} + Σ min(x², t²), with x normalized by sigma.
        // `normalized` holds x² sorted ascending, so the candidate t² is each entry.
        var bestRisk = Double.infinity
        var bestT2 = universal * universal
        var cumulativeBelow = 0.0
        for (index, t2) in normalized.enumerated() {
            cumulativeBelow += t2
            let countBelowOrEqual = Double(index + 1)
            let countAbove = n - countBelowOrEqual
            let sumMin = cumulativeBelow + countAbove * t2
            let sureRisk = (n - 2.0 * countBelowOrEqual + sumMin) / n
            if sureRisk < bestRisk {
                bestRisk = sureRisk
                bestT2 = t2
            }
        }
        return sigma * min(bestT2.squareRoot(), universal)
    }

    // MARK: - Robust noise estimate

    private static func medianAbsoluteDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let med = median(values)
        let deviations = values.map { abs($0 - med) }
        return median(deviations)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
