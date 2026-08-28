//
//  GradientFilters.swift
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
//  Both the OBS and ANC stages high-pass their inputs before estimating
//  anything, so that slow drift does not dominate a basis or an adaptive filter
//  that is supposed to be describing artifact. Two high-pass forms are provided
//  because the two stages work on very different signal lengths:
//
//    - ANC filters whole channels, so it uses a zero-phase Butterworth.
//    - OBS filters individual artifact epochs, which are far too short for a
//      meaningful IIR high-pass, so it removes the mean and linear trend
//      instead. Over a window of one artifact period that is what a high-pass
//      would accomplish anyway.
//

import Foundation

nonisolated enum GradientFilters {

    // MARK: - Zero-phase Butterworth high-pass

    /// Second-order Butterworth high-pass coefficients via the bilinear
    /// transform, in direct-form-I order.
    struct Biquad {
        let b0: Double, b1: Double, b2: Double
        let a1: Double, a2: Double
    }

    static func butterworthHighPass(cutoffHz: Double, samplingRate: Double) -> Biquad {
        let warped = tan(Double.pi * cutoffHz / samplingRate)
        let root2 = 2.0.squareRoot()
        let norm = 1 / (1 + root2 * warped + warped * warped)
        return Biquad(
            b0: norm,
            b1: -2 * norm,
            b2: norm,
            a1: 2 * (warped * warped - 1) * norm,
            a2: (1 - root2 * warped + warped * warped) * norm
        )
    }

    private static func applyBiquad(_ signal: [Double], _ coefficients: Biquad) -> [Double] {
        var output = [Double](repeating: 0, count: signal.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in signal.indices {
            let x0 = signal[index]
            let y0 = coefficients.b0 * x0 + coefficients.b1 * x1 + coefficients.b2 * x2
                - coefficients.a1 * y1 - coefficients.a2 * y2
            output[index] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return output
    }

    /// Applies a second-order Butterworth high-pass forward and backward, giving
    /// a fourth-order response with no phase distortion — important here because
    /// a phase shift between the reference and the signal would defeat the
    /// adaptive filter that consumes them.
    ///
    /// The signal is extended at both ends by odd reflection before filtering so
    /// the IIR start-up transient lands in the padding rather than in the data.
    /// Returns the input unchanged when the cutoff is not usable.
    static func highPassZeroPhase(
        _ signal: [Float],
        cutoffHz: Double,
        samplingRate: Double
    ) -> [Float] {
        let count = signal.count
        guard count > 8, cutoffHz > 0, samplingRate > 0, cutoffHz < samplingRate / 2 else {
            return signal
        }

        // The start-up transient of a high-pass this narrow decays over roughly
        // one cutoff period; pad by several so it dies inside the padding rather
        // than leaking into the first real samples.
        let pad = min(count - 1, max(16, Int(3 * samplingRate / cutoffHz)))
        var padded = [Double]()
        padded.reserveCapacity(count + 2 * pad)

        let first = Double(signal[0])
        let last = Double(signal[count - 1])
        for offset in stride(from: pad, through: 1, by: -1) {
            padded.append(2 * first - Double(signal[offset]))
        }
        for value in signal { padded.append(Double(value)) }
        for offset in 1...pad {
            padded.append(2 * last - Double(signal[count - 1 - offset]))
        }

        let coefficients = butterworthHighPass(cutoffHz: cutoffHz, samplingRate: samplingRate)
        var forward = applyBiquad(padded, coefficients)
        forward.reverse()
        var backward = applyBiquad(forward, coefficients)
        backward.reverse()

        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let value = backward[pad + index]
            output[index] = value.isFinite ? Float(value) : signal[index]
        }
        return output
    }

    // MARK: - Detrending

    /// Removes the least-squares straight line through the samples.
    ///
    /// Used as the high-pass ahead of OBS basis estimation: an artifact epoch is
    /// only one artifact period long, so an IIR high-pass with a cutoff below the
    /// artifact rate has nothing to work with, while removing offset and slope
    /// takes out exactly the drift that would otherwise dominate the first
    /// principal component.
    static func removeLinearTrend(_ signal: [Float]) -> [Float] {
        let count = signal.count
        guard count > 2 else {
            guard count > 0 else { return signal }
            let mean = signal.reduce(0.0) { $0 + Double($1) } / Double(count)
            return signal.map { $0 - Float(mean) }
        }

        let n = Double(count)
        var sumY = 0.0
        var sumXY = 0.0
        for index in 0..<count {
            let y = Double(signal[index])
            sumY += y
            sumXY += Double(index) * y
        }
        let sumX = n * (n - 1) / 2
        let sumXX = (n - 1) * n * (2 * n - 1) / 6
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 1e-12 else { return signal }

        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n

        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            output[index] = signal[index] - Float(intercept + slope * Double(index))
        }
        return output
    }
}
