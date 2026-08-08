//
//  ContinuousWaveletTransform.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Continuous wavelet transform (CWT) primitives for peak/ridge detection on ERP
//  traces. The discrete (DWT/SWT) transforms live in `WaveletReducer.swift`
//  (`WaveletFilterBank` / `WaveletTransform`); this file is deliberately the
//  *continuous* counterpart and shares nothing with them beyond the folder.
//
//  Used by `CWTRidgeDetector` and `MatchedWaveletTemplate`.
//

import Foundation

/// Continuous mother wavelets available for ridge detection.
nonisolated enum CWTWavelet: String, CaseIterable, Identifiable, Sendable {
    case ricker = "Ricker (Mexican hat)"
    case morlet = "Morlet"

    var id: String { rawValue }
}

nonisolated enum ContinuousWaveletTransform {
    /// Sampled mother-wavelet kernel for a given scale, centered at zero and
    /// truncated to a compact support. Returns the real part only (sufficient
    /// for ridge/peak magnitude on real ERP traces).
    static func kernel(_ wavelet: CWTWavelet, scale: Double) -> [Double] {
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
    static func transform(_ signal: [Double], wavelet: CWTWavelet, scales: [Double]) -> [[Double]] {
        guard !signal.isEmpty, !scales.isEmpty else { return [] }
        let n = signal.count
        return scales.map { scale in
            let kernel = kernel(wavelet, scale: scale)
            let radius = kernel.count / 2
            var row = [Double](repeating: 0, count: n)
            for t in 0..<n {
                var acc = 0.0
                for (k, coeff) in kernel.enumerated() {
                    let index = t + (k - radius)
                    guard index >= 0, index < n else { continue }
                    acc += signal[index] * coeff
                }
                // The Ricker/Morlet real parts used here are symmetric, so
                // convolution with the time-reversed kernel is exact as written.
                row[t] = acc
            }
            return row
        }
    }
}
