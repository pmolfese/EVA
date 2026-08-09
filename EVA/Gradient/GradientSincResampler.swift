//
//  GradientSincResampler.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Independent implementation written from EVA's own functional specification
//  (docs/provenance/fastr-functional-spec.md) under the clean-room process
//  described in docs/provenance/README.md. No third-party artifact-correction source
//  was consulted.
//
//  Windowed-sinc (Lanczos) resampling used by the gradient-artifact template
//  corrector for two jobs:
//
//    1. integer upsampling, so artifact epochs can be aligned on a finer grid
//       than the recorded sampling rate;
//    2. fractional-sample delay, so epochs whose true onset falls between
//       samples can be brought onto a shared sub-sample grid before averaging.
//
//  The Lanczos kernel is used rather than frequency-domain phase shifting
//  because it needs no transform setup and is directly testable against
//  analytically shifted sinusoids. It is exactly 1 at zero offset and exactly 0
//  at every other integer offset, so samples already on the integer grid survive
//  an upsample/decimate round trip unchanged.
//

import Foundation

nonisolated enum GradientSincResampler {

    /// Half-width of the interpolation window used for integer upsampling.
    static let upsampleLobes = 4
    /// Half-width of the interpolation window used for fractional delay. Wider
    /// than `upsampleLobes` because a fractional delay is applied once per epoch
    /// and benefits from the extra stopband rejection.
    static let delayLobes = 8

    /// Lanczos kernel: `sinc(x) * sinc(x / a)` inside `|x| < a`, zero outside.
    ///
    /// Equals 1 at `x == 0` and 0 at every other integer, which is what makes
    /// integer-grid samples exact under interpolation.
    static func kernel(_ x: Double, lobes a: Int) -> Double {
        let limit = Double(a)
        if x <= -limit || x >= limit { return 0 }
        if abs(x) < 1e-12 { return 1 }
        let piX = Double.pi * x
        return (sin(piX) / piX) * (sin(piX / limit) / (piX / limit))
    }

    /// Interpolates `signal` onto a grid `factor` times finer.
    ///
    /// Output sample `m` represents time `m / factor` in input samples, so
    /// `output[k * factor] == signal[k]` to within floating-point rounding.
    /// Values outside the input are handled by clamping to the nearest end
    /// sample (edge extension), which avoids ringing into the first and last
    /// epochs from an implied zero.
    static func upsample(_ signal: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return signal }
        guard signal.count > 1 else {
            return [Float](repeating: signal.first ?? 0, count: signal.count * factor)
        }

        let a = upsampleLobes
        let tapCount = 2 * a
        // Polyphase tables: one set of taps per output phase. Phase 0 is the
        // identity tap set, so integer-grid samples pass through untouched.
        //
        // Each phase's taps are normalized to sum to 1. A truncated Lanczos
        // window does not have unity DC gain on its own — without this a
        // constant input comes back with a few-tenths-of-a-percent ripple, and
        // that same gain error scales every interpolated sample.
        var taps = [Double](repeating: 0, count: factor * tapCount)
        for phase in 0..<factor {
            let offset = Double(phase) / Double(factor)
            var sum = 0.0
            for tap in 0..<tapCount {
                // Tap `tap` reads input index `base + tap - a + 1`.
                let distance = offset - Double(tap - a + 1)
                let weight = kernel(distance, lobes: a)
                taps[phase * tapCount + tap] = weight
                sum += weight
            }
            if abs(sum) > 1e-12 {
                for tap in 0..<tapCount { taps[phase * tapCount + tap] /= sum }
            }
        }

        let count = signal.count
        var output = [Float](repeating: 0, count: count * factor)
        for m in 0..<output.count {
            let base = m / factor
            let phase = m % factor
            if phase == 0 {
                output[m] = signal[base]
                continue
            }
            var sum = 0.0
            let tapBase = phase * tapCount
            for tap in 0..<tapCount {
                let index = min(max(base + tap - a + 1, 0), count - 1)
                sum += Double(signal[index]) * taps[tapBase + tap]
            }
            output[m] = Float(sum)
        }
        return output
    }

    /// Selects every `factor`-th sample, inverting `upsample` exactly on the
    /// integer grid.
    static func decimate(_ signal: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return signal }
        var output = [Float]()
        output.reserveCapacity((signal.count + factor - 1) / factor)
        var index = 0
        while index < signal.count {
            output.append(signal[index])
            index += factor
        }
        return output
    }

    /// Delays `signal` by `delay` samples, where `delay` may be fractional.
    ///
    /// A positive delay moves the waveform later in time: `output[n] ≈
    /// signal[n - delay]`. Edges are clamped to the nearest end sample. A delay
    /// that is (near) an exact integer is handled by plain index shifting so no
    /// interpolation error is introduced.
    static func fractionalDelay(_ signal: [Float], by delay: Double) -> [Float] {
        guard !signal.isEmpty else { return signal }
        guard abs(delay) > 1e-9 else { return signal }

        let count = signal.count
        let rounded = (delay).rounded()
        if abs(delay - rounded) < 1e-9 {
            let shift = Int(rounded)
            var output = [Float](repeating: 0, count: count)
            for n in 0..<count {
                output[n] = signal[min(max(n - shift, 0), count - 1)]
            }
            return output
        }

        // For a constant delay the fractional part is the same at every output
        // sample, so the tap set is computed once. Normalized to unity DC gain
        // for the same reason as in `upsample`.
        let a = delayLobes
        let frac = (Double(0) - delay) - (Double(0) - delay).rounded(.down)
        let tapCount = 2 * a
        var taps = [Double](repeating: 0, count: tapCount)
        var sum = 0.0
        for (slot, j) in ((-a + 1)...a).enumerated() {
            let weight = kernel(frac - Double(j), lobes: a)
            taps[slot] = weight
            sum += weight
        }
        if abs(sum) > 1e-12 {
            for slot in 0..<tapCount { taps[slot] /= sum }
        }

        var output = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let base = Int((Double(n) - delay).rounded(.down))
            var accumulated = 0.0
            for (slot, j) in ((-a + 1)...a).enumerated() {
                let index = min(max(base + j, 0), count - 1)
                accumulated += Double(signal[index]) * taps[slot]
            }
            output[n] = Float(accumulated)
        }
        return output
    }
}
