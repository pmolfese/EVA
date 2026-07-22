//
//  WaveletTransforms.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Low-level wavelet primitives shared by the Trials analysis methods:
//   * A single-family discrete wavelet transform (DWT) with periodic boundary
//     handling, used for wavelet denoising (`WaveletDenoiser`).
//   * Continuous wavelet transform (CWT) mother wavelets (Ricker / Morlet) and a
//     naive direct-convolution CWT used by `CWTRidgeDetector`.
//
//  Everything here is `nonisolated` and pure so it can run off the main actor,
//  matching `WoodyAlignmentAnalyzer` / `RIDEAnalyzer`.
//

import Foundation

// MARK: - Discrete Wavelet Transform

/// Orthogonal wavelet families available for the discrete transform. Only the
/// low-pass (scaling) decomposition coefficients are stored; the remaining
/// filters are derived by the standard quadrature-mirror relations.
nonisolated enum DWTWavelet: String, CaseIterable, Identifiable, Sendable {
    case haar = "Haar"
    case db2 = "Daubechies 2"
    case db4 = "Daubechies 4"
    case sym4 = "Symlet 4"

    var id: String { rawValue }

    /// Decomposition low-pass filter coefficients (normalized so the L2 norm is 1).
    var lowPass: [Double] {
        switch self {
        case .haar:
            let s = 1.0 / 2.0.squareRoot()
            return [s, s]
        case .db2:
            let s = 4.0.squareRoot()
            return [
                (1 + 3.0.squareRoot()) / s / 2,
                (3 + 3.0.squareRoot()) / s / 2,
                (3 - 3.0.squareRoot()) / s / 2,
                (1 - 3.0.squareRoot()) / s / 2
            ]
        case .db4:
            return [
                -0.010597401784997278,
                0.032883011666982945,
                0.030841381835986965,
                -0.18703481171888114,
                -0.02798376941698385,
                0.6308807679295904,
                0.7148465705525415,
                0.23037781330885523
            ]
        case .sym4:
            return [
                -0.07576571478927333,
                -0.02963552764599851,
                0.49761866763201545,
                0.8037387518059161,
                0.29785779560527736,
                -0.09921954357684722,
                -0.012603967262037833,
                0.032223100604042702
            ]
        }
    }
}

/// One level of DWT coefficients: `approximation` (low-pass) and `detail`
/// (high-pass) halves.
nonisolated struct DWTLevel: Sendable {
    var approximation: [Double]
    var detail: [Double]
}

/// A full multi-level decomposition. `finalApproximation` is the coarsest
/// low-pass residual; `details[0]` is the finest (highest-frequency) detail.
nonisolated struct DWTDecomposition: Sendable {
    var wavelet: DWTWavelet
    var originalLength: Int
    var finalApproximation: [Double]
    var details: [[Double]]

    var levels: Int { details.count }
}

nonisolated enum WaveletTransforms {
    // MARK: DWT (single family, periodic boundary)

    /// Largest number of decomposition levels that keeps every detail band at
    /// least as long as the filter.
    static func maxLevels(signalLength: Int, wavelet: DWTWavelet) -> Int {
        let filter = wavelet.lowPass.count
        guard signalLength >= filter, filter > 1 else { return 0 }
        let ratio = Double(signalLength) / Double(filter - 1)
        guard ratio > 1 else { return 0 }
        return max(0, Int(floor(log2(ratio))))
    }

    /// Forward multi-level DWT with periodic (circular) extension. The input is
    /// padded to an even length internally per level.
    static func forward(_ signal: [Double], wavelet: DWTWavelet, levels: Int) -> DWTDecomposition {
        let lo = wavelet.lowPass
        let hi = highPass(from: lo)
        var approximation = signal
        var details: [[Double]] = []
        let clampedLevels = max(0, min(levels, maxLevels(signalLength: signal.count, wavelet: wavelet)))

        for _ in 0..<clampedLevels {
            let (a, d) = decomposeStep(approximation, lo: lo, hi: hi)
            details.append(d)
            approximation = a
        }

        return DWTDecomposition(
            wavelet: wavelet,
            originalLength: signal.count,
            finalApproximation: approximation,
            details: details
        )
    }

    /// Inverse multi-level DWT. Reconstructs to `decomposition.originalLength`.
    static func inverse(_ decomposition: DWTDecomposition) -> [Double] {
        let lo = decomposition.wavelet.lowPass
        let hi = highPass(from: lo)
        var approximation = decomposition.finalApproximation

        for detail in decomposition.details.reversed() {
            approximation = reconstructStep(approximation: approximation, detail: detail, lo: lo, hi: hi)
        }

        if approximation.count > decomposition.originalLength {
            approximation = Array(approximation.prefix(decomposition.originalLength))
        } else if approximation.count < decomposition.originalLength {
            approximation.append(contentsOf: repeatElement(0, count: decomposition.originalLength - approximation.count))
        }
        return approximation
    }

    /// Quadrature-mirror high-pass filter derived from the low-pass filter.
    static func highPass(from lowPass: [Double]) -> [Double] {
        let n = lowPass.count
        return (0..<n).map { i in
            let sign = (i % 2 == 0) ? 1.0 : -1.0
            return sign * lowPass[n - 1 - i]
        }
    }

    private static func decomposeStep(_ signal: [Double], lo: [Double], hi: [Double]) -> (approximation: [Double], detail: [Double]) {
        var input = signal
        if input.count % 2 != 0 { input.append(input.last ?? 0) }
        let n = input.count
        let half = n / 2
        var approximation = [Double](repeating: 0, count: half)
        var detail = [Double](repeating: 0, count: half)
        let filterLength = lo.count

        for k in 0..<half {
            var sumLo = 0.0
            var sumHi = 0.0
            for j in 0..<filterLength {
                let index = ((2 * k + j) % n + n) % n
                let value = input[index]
                sumLo += value * lo[j]
                sumHi += value * hi[j]
            }
            approximation[k] = sumLo
            detail[k] = sumHi
        }
        return (approximation, detail)
    }

    private static func reconstructStep(approximation: [Double], detail: [Double], lo: [Double], hi: [Double]) -> [Double] {
        let half = min(approximation.count, detail.count)
        let n = half * 2
        var output = [Double](repeating: 0, count: n)
        let filterLength = lo.count

        for k in 0..<half {
            let a = approximation[k]
            let d = detail[k]
            for j in 0..<filterLength {
                let index = ((2 * k + j) % n + n) % n
                output[index] += a * lo[j] + d * hi[j]
            }
        }
        return output
    }

    // MARK: - CWT

    /// Continuous mother wavelets available for ridge detection.
    enum CWTWavelet: String, CaseIterable, Identifiable, Sendable {
        case ricker = "Ricker (Mexican hat)"
        case morlet = "Morlet"

        var id: String { rawValue }
    }

    /// Sampled mother-wavelet kernel for a given scale, centered at zero and
    /// truncated to a compact support. Returns the real part only (sufficient
    /// for ridge/peak magnitude on real ERP traces).
    static func waveletKernel(_ wavelet: CWTWavelet, scale: Double) -> [Double] {
        let s = max(scale, 1e-6)
        switch wavelet {
        case .ricker:
            // Ricker (second derivative of Gaussian). Support ~ ±5 scales.
            let radius = Int((5.0 * s).rounded(.up))
            let norm = 2.0 / (3.0 * s).squareRoot() / Double.pi.squareRoot().squareRoot()
            return (-radius...radius).map { i in
                let t = Double(i) / s
                let t2 = t * t
                return norm * (1.0 - t2) * exp(-t2 / 2.0)
            }
        case .morlet:
            // Real part of the Morlet wavelet with central frequency w0 = 6.
            let w0 = 6.0
            let radius = Int((4.0 * s).rounded(.up))
            let norm = 1.0 / (Double.pi.squareRoot().squareRoot() * s.squareRoot())
            return (-radius...radius).map { i in
                let t = Double(i) / s
                return norm * cos(w0 * t) * exp(-t * t / 2.0)
            }
        }
    }

    /// Direct-convolution CWT. Returns a matrix `[scaleIndex][timeIndex]` of the
    /// (real) transform coefficients. Signal is zero-padded at the boundaries.
    static func cwt(_ signal: [Double], wavelet: CWTWavelet, scales: [Double]) -> [[Double]] {
        guard !signal.isEmpty, !scales.isEmpty else { return [] }
        let n = signal.count
        return scales.map { scale in
            let kernel = waveletKernel(wavelet, scale: scale)
            let radius = kernel.count / 2
            var row = [Double](repeating: 0, count: n)
            for t in 0..<n {
                var acc = 0.0
                for (k, coeff) in kernel.enumerated() {
                    let index = t + (k - radius)
                    guard index >= 0, index < n else { continue }
                    acc += signal[index] * coeff
                }
                // Wavelet convolution is with the time-reversed kernel; the
                // Ricker/Morlet real parts used here are symmetric, so the
                // reversal is a no-op and this is exact.
                row[t] = acc
            }
            return row
        }
    }
}
