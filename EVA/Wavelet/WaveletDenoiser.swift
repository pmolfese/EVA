//
//  WaveletDenoiser.swift
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
//  Wavelet shrinkage denoising of single-trial (or averaged) ERP traces, used to
//  raise SNR before latency estimation (Woody / RIDE / CWT-Ridge). It reuses the
//  shared discrete-wavelet machinery in `WaveletReducer.swift`
//  (`WaveletFilterBank`, `WaveletTransform`, `WaveletReductionFamily`) and the
//  `robustSigma` / `applyThreshold` helpers, so there is a single DWT + filter
//  implementation in the app. What is specific to denoising lives here: the
//  VisuShrink (universal) and SURE threshold rules.
//
//  Reference: Donoho & Johnstone, "Ideal spatial adaptation by wavelet
//  shrinkage," Biometrika 1994 (VisuShrink / SureShrink).
//

import Foundation

nonisolated enum WaveletDenoiser {
    /// Per-band threshold selection rule.
    enum ThresholdModel: String, CaseIterable, Identifiable, Sendable {
        /// VisuShrink universal threshold: sigma * sqrt(2 ln N). Aggressive,
        /// good for visual smoothness.
        case universal = "Universal"
        /// SURE (Stein Unbiased Risk Estimate) threshold, chosen per detail band
        /// to minimize estimated risk. Preserves more signal detail.
        case sure = "SURE"

        var id: String { rawValue }
    }

    struct Configuration: Sendable {
        var family: WaveletReductionFamily = .sym4
        var levels: Int = 4
        /// Soft or hard thresholding (shared enum with the artifact-rejection path).
        var rule: WaveletCleaningThresholdRule = .soft
        var thresholdModel: ThresholdModel = .universal
        /// Multiplies the derived threshold. 1.0 = textbook; lower keeps more
        /// signal, higher smooths more.
        var strength: Double = 1.0

        init(
            family: WaveletReductionFamily = .sym4,
            levels: Int = 4,
            rule: WaveletCleaningThresholdRule = .soft,
            thresholdModel: ThresholdModel = .universal,
            strength: Double = 1.0
        ) {
            self.family = family
            self.levels = levels
            self.rule = rule
            self.thresholdModel = thresholdModel
            self.strength = strength
        }
    }

    /// Denoise a `Float` trace. Returns a trace of identical length. Non-finite
    /// samples are treated as zero for the transform.
    static func denoise(_ samples: [Float], configuration: Configuration = Configuration()) -> [Float] {
        guard samples.count >= 4 else { return samples }
        let input = samples.map { Double($0.isFinite ? $0 : 0) }
        return denoise(input, configuration: configuration).map { Float($0) }
    }

    /// Denoise a `Double` trace.
    static func denoise(_ signal: [Double], configuration: Configuration = Configuration()) -> [Double] {
        let levels = clampedLevels(configuration.levels, signalLength: signal.count)
        guard levels >= 1 else { return signal }

        let bank = WaveletFilterBank.orthonormal(configuration.family.scalingFilter)
        let transform = WaveletTransform(bank: bank)
        var decomposition = transform.forwardDWT(signal, levels: levels)

        // Estimate noise sigma from the finest detail band (MAD / 0.6745).
        guard let finest = decomposition.details.first, !finest.isEmpty else { return signal }
        let sigma = WaveletReducer.robustSigma(finest)
        guard sigma > 0 else { return signal }

        decomposition.details = decomposition.details.map { band in
            let threshold: Double
            switch configuration.thresholdModel {
            case .universal:
                threshold = sigma * (2.0 * log(Double(max(band.count, 2)))).squareRoot()
            case .sure:
                threshold = sureThreshold(band, sigma: sigma)
            }
            let scaled = threshold * configuration.strength
            return band.map { WaveletReducer.applyThreshold($0, threshold: scaled, rule: configuration.rule) }
        }

        return transform.inverseDWT(decomposition)
    }

    // MARK: - Level clamping

    private static func clampedLevels(_ requested: Int, signalLength: Int) -> Int {
        guard signalLength >= 4 else { return 0 }
        let maxLevels = max(1, Int(floor(log2(Double(signalLength)))) - 1)
        return max(1, min(requested, maxLevels))
    }

    // MARK: - SURE threshold selection

    /// SURE threshold for a single detail band (Stein's unbiased risk), evaluated
    /// at each candidate threshold t = sorted |x|/sigma.
    /// SURE(t) = n - 2·#{x² ≤ t²} + Σ min(x², t²), with x normalized by sigma.
    private static func sureThreshold(_ band: [Double], sigma: Double) -> Double {
        guard sigma > 0, !band.isEmpty else { return 0 }
        let n = Double(band.count)
        let normalized = band.map { ($0 / sigma) * ($0 / sigma) }.sorted() // x² ascending
        let universal = (2.0 * log(n)).squareRoot()

        // If the band is essentially noise, fall back to the universal threshold.
        let energy = normalized.reduce(0, +)
        let sparsityBound = 1.0 + (log2(n).rounded() * pow(log2(n), 1.5)) / n
        if (energy - n) / n < sparsityBound {
            return sigma * universal
        }

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
}
