//
//  MatchedWaveletTemplate.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Builds a clean, wavelet-shaped template for Woody alignment. Instead of
//  cross-correlating each trial against a noisy grand-average, we fit a mother
//  wavelet (Ricker / Morlet) to the dominant deflection inside the analysis
//  window: its latency, width, polarity and amplitude are estimated from the
//  average via a CWT, then a full-length template is synthesized. Because the
//  matched wavelet is band-limited and noise-free, per-trial latency estimates
//  are less biased by out-of-band noise than a raw-average template.
//

import Foundation

nonisolated enum MatchedWaveletTemplate {
    struct Fit: Sendable {
        var centerSample: Int
        var widthSamples: Double
        var polaritySign: Int
        var amplitude: Double
        var wavelet: CWTWavelet
    }

    /// Estimate the dominant peak inside `window` on `reference` and return a
    /// wavelet fit. Returns `nil` if no peak clears detection.
    static func fit(
        to reference: [Float],
        window: Range<Int>,
        wavelet: CWTWavelet = .ricker,
        polarity: CWTRidgeDetector.Polarity = .either
    ) -> Fit? {
        guard !reference.isEmpty else { return nil }
        let clampedLower = max(0, window.lowerBound)
        let clampedUpper = min(reference.count, window.upperBound)
        guard clampedLower < clampedUpper else { return nil }

        // Run ridge detection on the whole trace, then keep peaks inside window.
        let detection = CWTRidgeDetector.detect(
            reference,
            configuration: CWTRidgeDetector.Configuration(
                wavelet: wavelet,
                minScale: 2,
                maxScale: max(8, Double(clampedUpper - clampedLower)),
                scaleCount: 20,
                minRidgeLength: 2,
                minSNR: 1.5,
                polarity: polarity
            )
        )

        let windowed = detection.peaks.filter { (clampedLower..<clampedUpper).contains($0.sampleIndex) }
        guard let dominant = windowed.max(by: { $0.snr < $1.snr }) else {
            // Fall back to the plain extremum in the window.
            return fallbackFit(reference, lower: clampedLower, upper: clampedUpper, wavelet: wavelet, polarity: polarity)
        }

        return Fit(
            centerSample: dominant.sampleIndex,
            widthSamples: max(1, dominant.widthSamples),
            polaritySign: dominant.polaritySign,
            amplitude: dominant.amplitude,
            wavelet: wavelet
        )
    }

    /// Synthesize a full-length template (same length as `reference`) from a fit,
    /// scaled to match the fitted amplitude.
    static func synthesize(_ fit: Fit, length: Int) -> [Float] {
        guard length > 0 else { return [] }
        let kernel = ContinuousWaveletTransform.kernel(fit.wavelet, scale: fit.widthSamples)
        let radius = kernel.count / 2

        // Normalize the kernel so its peak magnitude is 1, then scale to amplitude.
        let peakMagnitude = kernel.map(abs).max() ?? 1
        let safePeak = peakMagnitude > 0 ? peakMagnitude : 1
        // The Ricker/Morlet real part peaks positive at its center; multiply by
        // the desired sign so the template matches the deflection polarity.
        let scale = fit.amplitude / safePeak

        var template = [Float](repeating: 0, count: length)
        for (k, coeff) in kernel.enumerated() {
            let index = fit.centerSample + (k - radius)
            guard index >= 0, index < length else { continue }
            template[index] = Float(coeff * scale)
        }
        return template
    }

    /// Convenience: fit and synthesize in one call.
    static func template(
        for reference: [Float],
        window: Range<Int>,
        wavelet: CWTWavelet = .ricker,
        polarity: CWTRidgeDetector.Polarity = .either
    ) -> [Float]? {
        guard let fit = fit(to: reference, window: window, wavelet: wavelet, polarity: polarity) else { return nil }
        return synthesize(fit, length: reference.count)
    }

    // MARK: - Fallback

    private static func fallbackFit(
        _ reference: [Float],
        lower: Int,
        upper: Int,
        wavelet: CWTWavelet,
        polarity: CWTRidgeDetector.Polarity
    ) -> Fit? {
        var bestIndex = lower
        var bestScore = -Double.infinity
        for i in lower..<upper {
            let value = Double(reference[i])
            guard value.isFinite else { continue }
            let score: Double
            switch polarity {
            case .positive: score = value
            case .negative: score = -value
            case .either: score = abs(value)
            }
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        guard bestScore.isFinite else { return nil }
        let amplitude = Double(reference[bestIndex])
        return Fit(
            centerSample: bestIndex,
            widthSamples: max(2, Double(upper - lower) / 6),
            polaritySign: amplitude >= 0 ? 1 : -1,
            amplitude: amplitude,
            wavelet: wavelet
        )
    }
}
