//
//  ComplexMorlet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Complex analytic Morlet wavelet for event-related time-frequency analysis
//  (ERSP / ITPC). This is the frequency-domain counterpart to the real-only
//  ridge-detection kernel in `EVA/Wavelet/ContinuousWaveletTransform.swift`:
//  that one keeps the cosine (real) part for peak/ridge magnitude on ERP
//  traces; this one carries the full analytic `(re, im)` coefficient so we
//  recover phase (→ ITPC) and an unbiased `|c|²` power estimate.
//
//  The kernel and the "same"-mode convolution deliberately reproduce
//  `mne.time_frequency.morlet` / `tfr_array_morlet` (Morlet path) exactly so
//  the numbers cross-check against MNE — see `TimeFrequencyEngineTests`.
//

import Foundation

nonisolated enum ComplexMorlet {

    /// A sampled complex Morlet wavelet, centered at `t = 0`.
    struct Kernel: Sendable {
        var re: [Double]
        var im: [Double]
        var frequencyHz: Double
        var nCycles: Double
        var count: Int { re.count }
    }

    /// Builds a complex Morlet wavelet for one frequency, matching MNE's
    /// `mne.time_frequency.morlet` convention with the adaptive (frequency-
    /// dependent) time resolution.
    ///
    /// Definition (with `σ_t = nCycles / (2π·f)`):
    /// - oscillation `exp(2iπ·f·t)`, optionally zero-meaned (default) by
    ///   subtracting `exp(-2(π·f·σ_t)²)` from the real part so the wavelet
    ///   satisfies the CWT admissibility criterion;
    /// - Gaussian envelope `exp(-t² / 2σ_t²)`;
    /// - time vector `t = arange(0, 5σ_t, 1/fs)` reflected to `[-t[::-1], t[1:]]`
    ///   so support is ±5σ_t with a sample exactly at `t = 0`;
    /// - normalized by `√0.5 · ‖W‖` (‖W‖ = 1 for the real part, √2 for the full
    ///   wavelet), the Tallon-Baudry scaling MNE uses.
    static func kernel(
        frequencyHz f: Double,
        nCycles: Double,
        samplingRate sfreq: Double,
        zeroMean: Bool = true
    ) -> Kernel {
        precondition(f > 0 && sfreq > 0 && nCycles > 0, "Morlet parameters must be positive")
        let sigmaT = nCycles / (2.0 * Double.pi * f)
        let dt = 1.0 / sfreq
        let limit = 5.0 * sigmaT

        // Replicate numpy `arange(0, limit, dt)`: length = ceil(limit/dt),
        // values i·dt (computed from the index, not accumulated, to avoid drift).
        let posCount = max(Int((limit / dt).rounded(.up)), 1)
        // Time vector: [-pos reversed, pos[1:]] → symmetric, sample at t = 0.
        var ts = [Double](repeating: 0, count: 2 * posCount - 1)
        for i in 0..<posCount {
            let value = Double(i) * dt
            ts[posCount - 1 - i] = -value   // negative half (reversed)
            if i > 0 { ts[posCount - 1 + i] = value }  // positive half (drop the duplicate 0)
        }

        let realOffset: Double = zeroMean
            ? exp(-2.0 * (Double.pi * f * sigmaT) * (Double.pi * f * sigmaT))
            : 0.0

        var re = [Double](repeating: 0, count: ts.count)
        var im = [Double](repeating: 0, count: ts.count)
        let twoSigma2 = 2.0 * sigmaT * sigmaT
        for i in 0..<ts.count {
            let t = ts[i]
            let angle = 2.0 * Double.pi * f * t
            let envelope = exp(-(t * t) / twoSigma2)
            re[i] = (cos(angle) - realOffset) * envelope
            im[i] = sin(angle) * envelope
        }

        // Normalize: W /= √0.5 · ‖W‖.
        var normSq = 0.0
        for i in 0..<re.count { normSq += re[i] * re[i] + im[i] * im[i] }
        let denom = (0.5).squareRoot() * normSq.squareRoot()
        if denom > 0 {
            for i in 0..<re.count { re[i] /= denom; im[i] /= denom }
        }

        return Kernel(re: re, im: im, frequencyHz: f, nCycles: nCycles)
    }

    /// Complex "same"-mode convolution of a real signal with a complex kernel,
    /// reproducing `np.convolve(x, W, 'same')` — which is what MNE's Morlet CWT
    /// computes (FFT convolution followed by a central crop to the signal
    /// length). Unlike the real ridge kernel, the imaginary part is
    /// antisymmetric, so this performs a true (kernel-flipped) convolution
    /// rather than assuming symmetry.
    static func convolveSame(signal x: [Double], kernel W: Kernel) -> (re: [Double], im: [Double]) {
        let n = x.count
        let w = W.count
        guard n > 0, w > 0 else { return ([], []) }

        let fullLength = n + w - 1
        var fullRe = [Double](repeating: 0, count: fullLength)
        var fullIm = [Double](repeating: 0, count: fullLength)
        // full[m] = Σ_k x[k]·W[m - k].
        for k in 0..<n {
            let xk = x[k]
            if xk == 0 { continue }
            let base = k
            for j in 0..<w {
                let m = base + j
                fullRe[m] += xk * W.re[j]
                fullIm[m] += xk * W.im[j]
            }
        }

        // 'same' → central `n` samples; offset matches numpy / MNE `_centered`.
        let offset = (w - 1) / 2
        var outRe = [Double](repeating: 0, count: n)
        var outIm = [Double](repeating: 0, count: n)
        for t in 0..<n {
            outRe[t] = fullRe[t + offset]
            outIm[t] = fullIm[t + offset]
        }
        return (outRe, outIm)
    }
}
