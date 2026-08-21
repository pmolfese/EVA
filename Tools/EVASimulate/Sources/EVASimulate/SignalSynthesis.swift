//
//  SignalSynthesis.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Shared numerical parts: Gaussian draws from EVA's seeded generator,
//  band-limited noise synthesis, and the high-rate template injector that both
//  artifact models are built on.
//

import Foundation

// MARK: - Random draws

/// Box-Muller Gaussian draws on top of `SeededGenerator`, so every number in a
/// simulation traces back to one seed. The spare value is kept rather than
/// discarded purely so a given seed produces the same stream regardless of how
/// callers interleave their draws with uniform ones.
nonisolated struct GaussianSource {
    private var generator: SeededGenerator
    private var spare: Double?

    init(seed: UInt64) {
        generator = SeededGenerator(seed: seed)
    }

    mutating func uniform() -> Double {
        Double.random(in: 0..<1, using: &generator)
    }

    mutating func gaussian() -> Double {
        if let spare {
            self.spare = nil
            return spare
        }
        var u = 0.0
        var v = 0.0
        var s = 0.0
        repeat {
            u = 2 * uniform() - 1
            v = 2 * uniform() - 1
            s = u * u + v * v
        } while s >= 1 || s == 0
        let factor = (-2 * log(s) / s).squareRoot()
        spare = v * factor
        return u * factor
    }
}

// MARK: - Band-limited noise

nonisolated enum SpectralNoise {

    static func nextPowerOfTwo(_ value: Int) -> Int {
        var n = 1
        while n < value { n <<= 1 }
        return n
    }

    /// Gaussian noise confined to `lowHz ..< highHz`, normalized to unit
    /// standard deviation over the returned samples.
    ///
    /// Synthesized in the frequency domain rather than by filtering white noise:
    /// the band edges are then exact, there is no filter transition band to
    /// account for when interpreting a per-band SNR later, and the cost is one
    /// inverse FFT instead of a long convolution.
    static func bandLimited(
        sampleCount: Int,
        samplingRate: Double,
        lowHz: Double,
        highHz: Double,
        source: inout GaussianSource
    ) -> [Double] {
        let n = nextPowerOfTwo(sampleCount)
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        let binHz = samplingRate / Double(n)

        for k in 1..<(n / 2) {
            let frequency = Double(k) * binHz
            guard frequency >= lowHz, frequency < highHz else { continue }
            let a = source.gaussian()
            let b = source.gaussian()
            re[k] = a
            im[k] = b
            re[n - k] = a
            im[n - k] = -b
        }

        DSP.fft(re: &re, im: &im, inverse: true)
        var out = Array(re.prefix(sampleCount))
        normalizeToUnitStd(&out)
        return out
    }

    static func normalizeToUnitStd(_ x: inout [Double]) {
        guard !x.isEmpty else { return }
        let mean = x.reduce(0, +) / Double(x.count)
        var sumSquares = 0.0
        for value in x { sumSquares += (value - mean) * (value - mean) }
        let std = (sumSquares / Double(x.count)).squareRoot()
        guard std > 1e-12 else {
            for i in x.indices { x[i] = 0 }
            return
        }
        for i in x.indices { x[i] = (x[i] - mean) / std }
    }

    /// Zero every frequency bin at or above `cutoffHz`, in place, on a copy of
    /// the signal padded to a power of two. Used to give a modelled artifact the
    /// band limit that a real amplifier's anti-alias filter would impose before
    /// its ADC ever sees the waveform.
    static func lowPassed(_ x: [Double], samplingRate: Double, cutoffHz: Double) -> [Double] {
        guard cutoffHz > 0, cutoffHz < samplingRate / 2 else { return x }
        let n = nextPowerOfTwo(x.count)
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        for i in x.indices { re[i] = x[i] }

        DSP.fft(re: &re, im: &im, inverse: false)
        let binHz = samplingRate / Double(n)
        for k in 0...(n / 2) {
            guard Double(k) * binHz >= cutoffHz else { continue }
            re[k] = 0
            im[k] = 0
            if k > 0, k < n / 2 {
                re[n - k] = 0
                im[n - k] = 0
            }
        }
        DSP.fft(re: &re, im: &im, inverse: true)
        return Array(re.prefix(x.count)).map { $0 / Double(n) }
    }
}

// MARK: - High-rate template injection

/// An artifact waveform modelled at a rate far above the EEG's, so that it can
/// be *point-sampled* onto the output grid at an arbitrary continuous start
/// time.
///
/// This is the mechanism the whole clock-offset model rests on. A real EEG
/// amplifier samples a continuous artifact on its own clock, which drifts
/// against the scanner's; two nominally identical slice artifacts therefore land
/// on different sub-sample phases and do not cancel when averaged. Reproducing
/// that requires the artifact to exist between output samples, which is what
/// this type provides.
nonisolated struct HighRateTemplate {
    let samples: [Double]
    let rate: Double

    var durationSeconds: Double { Double(samples.count) / rate }

    /// Adds this template into `buffer` (sampled at `outputRate`), starting at
    /// continuous time `startSeconds`, scaled by `scale`.
    func add(
        into buffer: inout [Double],
        outputRate: Double,
        startSeconds: Double,
        scale: Double
    ) {
        guard scale != 0, !samples.isEmpty else { return }
        let firstOutputSample = Int(ceil(startSeconds * outputRate))
        guard firstOutputSample < buffer.count else { return }
        let lastOutputSample = min(
            buffer.count - 1,
            Int(floor((startSeconds + durationSeconds) * outputRate))
        )
        guard lastOutputSample >= firstOutputSample else { return }

        for n in max(0, firstOutputSample)...lastOutputSample {
            let offsetSeconds = Double(n) / outputRate - startSeconds
            let index = Int((offsetSeconds * rate).rounded())
            guard index >= 0, index < samples.count else { continue }
            buffer[n] += scale * samples[index]
        }
    }
}
