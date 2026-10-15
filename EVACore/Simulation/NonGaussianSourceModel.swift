//
//  NonGaussianSourceModel.swift
//  EVACore
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Makes dipole source time courses non-Gaussian, which the paper model's
//  band-limited Gaussian sources are not. This matters for evaluating any method
//  that separates sources by their *statistics* rather than their geometry:
//
//    * ICA is only identifiable when at most one source is Gaussian — feeding it
//      Gaussian sources measures the simulator's Gaussianity, not the method.
//    * BSS-CCA (muscle) and other higher-order methods likewise rely on a
//      non-Gaussian / bursty marginal.
//
//  The model is band-preserving on purpose: real cortical rhythms come in
//  *bursts*, so a slow (≈1–2 Hz) positive envelope multiplies the in-band signal.
//  That raises kurtosis and sparsifies the amplitude — a super-Gaussian marginal —
//  while leaving the source inside its declared passband (the envelope's own
//  bandwidth is far below the carrier band). RMS is preserved, so downstream
//  amplitude and SNR bookkeeping is unchanged; only the *shape* of the
//  distribution moves. Burstiness 0 is the identity, so the default path stays
//  byte-for-byte the Gaussian model.
//

import Foundation

nonisolated struct NonGaussianSourceModel: Codable, Sendable, Equatable {
    /// 0 = Gaussian (identity). Higher = sparser, burstier, more super-Gaussian
    /// source amplitude — what ICA and BSS-CCA need to be separable. Clamped to
    /// [0, 1].
    var burstiness: Double = 0.7
    /// Envelope timescale in seconds: roughly how long a burst of power lasts.
    /// Sets the envelope's low-pass cutoff (≈ 1 / burstSeconds), kept well below
    /// the source's carrier band so the passband is preserved.
    var burstSeconds: Double = 0.5

    static let `default` = NonGaussianSourceModel()

    /// Applies the burst envelope to one source time course, in place, preserving
    /// its RMS. Deterministic in `seed`. A no-op at burstiness 0.
    static func shape(
        _ signal: inout [Double], model: NonGaussianSourceModel, samplingRate: Double, seed: UInt64
    ) {
        let burstiness = min(max(model.burstiness, 0), 1)
        guard burstiness > 0, signal.count > 1, samplingRate > 0 else { return }

        func rms(_ x: [Double]) -> Double {
            (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
        }
        let originalRMS = rms(signal)
        guard originalRMS > 1e-12 else { return }

        // A slow Gaussian envelope, independent of the carrier, low-passed to the
        // burst timescale so it modulates power without widening the band.
        var noise = GaussianSource(seed: seed)
        var envelope = (0..<signal.count).map { _ in noise.gaussian() }
        let cutoffHz = 1.0 / max(model.burstSeconds, 1e-3)
        envelope = SpectralNoise.lowPassed(envelope, samplingRate: samplingRate, cutoffHz: cutoffHz)
        SpectralNoise.normalizeToUnitStd(&envelope)

        // Exponentiating a ~N(0,1) envelope gives a log-normal (heavy-tailed)
        // positive multiplier; a larger gain concentrates power into fewer, taller
        // bursts (higher kurtosis). Then normalize the multiplier to unit
        // mean-square so overall power is unchanged before the RMS rescale.
        let gain = 0.5 + 3.5 * burstiness
        var multiplier = envelope.map { exp(gain * $0) }
        let multiplierMS = (multiplier.reduce(0) { $0 + $1 * $1 } / Double(multiplier.count)).squareRoot()
        if multiplierMS > 1e-12 {
            for index in multiplier.indices { multiplier[index] /= multiplierMS }
        }
        for index in signal.indices { signal[index] *= multiplier[index] }

        let shapedRMS = rms(signal)
        if shapedRMS > 1e-12 {
            let scale = originalRMS / shapedRMS
            for index in signal.indices { signal[index] *= scale }
        }
    }

    /// Excess kurtosis of a signal (0 for Gaussian). Reported in truth/tests so a
    /// sweep can say how non-Gaussian the sources actually were.
    static func excessKurtosis(_ x: [Double]) -> Double {
        guard x.count > 3 else { return 0 }
        let mean = x.reduce(0, +) / Double(x.count)
        var m2 = 0.0, m4 = 0.0
        for value in x {
            let d = value - mean
            m2 += d * d
            m4 += d * d * d * d
        }
        m2 /= Double(x.count)
        m4 /= Double(x.count)
        return m2 > 1e-30 ? m4 / (m2 * m2) - 3 : 0
    }
}
