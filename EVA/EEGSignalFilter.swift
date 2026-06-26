//
//  EEGSignalFilter.swift
//  EVA
//
//  Copyright (C) 2026 Peter Molfese
//  SPDX-License-Identifier: GPL-3.0-only
//

import Accelerate
import Foundation

enum EEGSignalFilterError: LocalizedError {
    case invalidSamplingRate
    /// Carries the actual cutoffs and Nyquist so the message reflects what the
    /// user asked for rather than a hardcoded range.
    case invalidBandpassRange(lowCutoff: Double, highCutoff: Double, nyquist: Double)

    var errorDescription: String? {
        switch self {
        case .invalidSamplingRate:
            return "The signal sampling rate is invalid for filtering."
        case let .invalidBandpassRange(lowCutoff, highCutoff, nyquist):
            return String(
                format: "The %.2f–%.2f Hz band-pass range is not valid for this signal "
                    + "(must be 0 < low < high < Nyquist = %.2f Hz).",
                lowCutoff, highCutoff, nyquist
            )
        }
    }
}

struct EEGSignalFilter {
    private nonisolated static let butterworthQ: Float = 1.0 / Float(sqrt(2.0))

    nonisolated static func bandPass(
        channels: [[Float]],
        samplingRate: Double,
        lowCutoff: Double,
        highCutoff: Double,
        notch60HzEnabled: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [[Float]] {
        guard samplingRate > 0 else {
            throw EEGSignalFilterError.invalidSamplingRate
        }

        let nyquist = samplingRate / 2
        guard lowCutoff > 0, highCutoff > lowCutoff, highCutoff < nyquist else {
            throw EEGSignalFilterError.invalidBandpassRange(
                lowCutoff: lowCutoff,
                highCutoff: highCutoff,
                nyquist: nyquist
            )
        }

        return try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            let highPass = BiquadCoefficients.highPass(
                cutoff: Float(lowCutoff),
                samplingRate: Float(samplingRate),
                q: butterworthQ
            )
            let lowPass = BiquadCoefficients.lowPass(
                cutoff: Float(highCutoff),
                samplingRate: Float(samplingRate),
                q: butterworthQ
            )
            let notchFilter = BiquadCoefficients.notch(
                centerFrequency: 60,
                samplingRate: Float(samplingRate),
                q: 30
            )

            // The high-pass (low cutoff) sets the edge-transient length; pad the
            // reflected boundary to cover it so the startup ripple stays outside
            // the data we keep instead of garbling the first/last samples.
            let paddingCount = transientPadding(lowCutoff: lowCutoff, samplingRate: samplingRate)

            for (index, channel) in channels.enumerated() {
                group.addTask {
                    let highPassed = zeroPhaseFilter(channel, coefficients: highPass, paddingCount: paddingCount)
                    let bandPassed = zeroPhaseFilter(highPassed, coefficients: lowPass, paddingCount: paddingCount)
                    let finalSamples: [Float]

                    if notch60HzEnabled, 60 < (samplingRate / 2) {
                        finalSamples = zeroPhaseFilter(bandPassed, coefficients: notchFilter, paddingCount: paddingCount)
                    } else {
                        finalSamples = bandPassed
                    }

                    return (index, finalSamples)
                }
            }

            var filteredChannels = Array(repeating: [Float](), count: channels.count)
            let total = max(channels.count, 1)
            let reportEvery = max(1, total / 100)
            var completed = 0
            for try await (index, filteredChannel) in group {
                filteredChannels[index] = filteredChannel
                completed += 1
                if let progress, completed % reportEvery == 0 || completed == total {
                    progress(Double(completed) / Double(total))
                }
            }

            return filteredChannels
        }
    }

    /// Common-average reference: subtract the instantaneous mean across all
    /// channels at each sample. Returns the data unchanged if it is ragged.
    ///
    /// Implemented as two cache-friendly, SIMD-vectorized passes: accumulate
    /// every channel row into a per-sample sum (vDSP_vadd), scale to a mean,
    /// then subtract that mean from each row (vDSP_vsub). This touches each row
    /// contiguously instead of striding across channels per sample.
    nonisolated static func averageReferenced(_ channels: [[Float]], excluding bad: Set<Int> = []) -> [[Float]] {
        var copy = channels
        averageReferenceInPlace(&copy, excluding: bad)
        return copy
    }

    /// In-place common-average reference. Avoids copying the channel buffers,
    /// so the filter pipeline (which owns its band-passed buffer) can re-reference
    /// without an extra allocation. Bad channels are excluded from the average so
    /// they do not corrupt the reference, but the reference is still subtracted
    /// from every channel.
    nonisolated static func averageReferenceInPlace(_ channels: inout [[Float]], excluding bad: Set<Int> = []) {
        guard let sampleCount = channels.first?.count,
              sampleCount > 0,
              channels.allSatisfy({ $0.count == sampleCount }) else {
            return
        }
        let channelCount = channels.count
        guard channelCount > 1 else { return }

        let length = vDSP_Length(sampleCount)
        var mean = [Float](repeating: 0, count: sampleCount)
        var goodCount = 0
        for index in 0..<channelCount where !bad.contains(index) {
            channels[index].withUnsafeBufferPointer { source in
                vDSP_vadd(mean, 1, source.baseAddress!, 1, &mean, 1, length)
            }
            goodCount += 1
        }
        guard goodCount > 0 else { return }
        var scale = 1 / Float(goodCount)
        vDSP_vsmul(mean, 1, &scale, &mean, 1, length)

        for index in 0..<channelCount {
            channels[index].withUnsafeMutableBufferPointer { destination in
                // vDSP_vsub computes C = B - A, i.e. channel - mean.
                vDSP_vsub(mean, 1, destination.baseAddress!, 1, destination.baseAddress!, 1, length)
            }
        }
    }

    /// Estimated edge-transient length (in samples) for a zero-phase IIR
    /// high-pass. The high-pass time constant is τ = 1/(2π·f), and the response
    /// settles in a few τ; filtfilt roughly doubles the effective order, so we
    /// pad ~3/f seconds (≈ 4× the 1% settling time of a single pass) to keep the
    /// ringing entirely within the reflected boundary.
    nonisolated static func transientPadding(lowCutoff: Double, samplingRate: Double) -> Int {
        guard lowCutoff > 0, samplingRate > 0 else { return 24 }
        let estimate = Int((3.0 * samplingRate / lowCutoff).rounded(.up))
        return max(estimate, 24)
    }

    private nonisolated static func zeroPhaseFilter(
        _ samples: [Float],
        coefficients: BiquadCoefficients,
        paddingCount requestedPadding: Int = 24
    ) -> [Float] {
        guard samples.count > 6 else {
            return samples
        }

        let paddingCount = min(max(requestedPadding, 0), samples.count - 1)
        let paddedSamples = reflectedPadding(for: samples, count: paddingCount)
        let forward = applyBiquad(to: paddedSamples, coefficients: coefficients)
        let backward = applyBiquad(to: Array(forward.reversed()), coefficients: coefficients)
        let restored = Array(backward.reversed())

        guard paddingCount > 0, restored.count > paddingCount * 2 else {
            return restored
        }

        return Array(restored[paddingCount..<(restored.count - paddingCount)])
    }

    private nonisolated static func reflectedPadding(for samples: [Float], count: Int) -> [Float] {
        guard count > 0, samples.count > 1 else {
            return samples
        }

        let prefix = Array(samples[1...count].reversed())
        let suffixStart = samples.count - count - 1
        let suffix = Array(samples[suffixStart..<(samples.count - 1)].reversed())
        return prefix + samples + suffix
    }

    private nonisolated static func applyBiquad(to samples: [Float], coefficients: BiquadCoefficients) -> [Float] {
        var filtered: [Float] = []
        filtered.reserveCapacity(samples.count)

        var x1: Float = 0
        var x2: Float = 0
        var y1: Float = 0
        var y2: Float = 0

        for x0 in samples {
            let y0 = coefficients.b0 * x0
                + coefficients.b1 * x1
                + coefficients.b2 * x2
                - coefficients.a1 * y1
                - coefficients.a2 * y2
            filtered.append(y0)
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }

        return filtered
    }
}

private struct BiquadCoefficients {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    nonisolated static func lowPass(cutoff: Float, samplingRate: Float, q: Float) -> Self {
        let omega = 2 * Float.pi * cutoff / samplingRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let b0 = (1 - cosine) / 2
        let b1 = 1 - cosine
        let b2 = (1 - cosine) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosine
        let a2 = 1 - alpha

        return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    nonisolated static func highPass(cutoff: Float, samplingRate: Float, q: Float) -> Self {
        let omega = 2 * Float.pi * cutoff / samplingRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let b0 = (1 + cosine) / 2
        let b1 = -(1 + cosine)
        let b2 = (1 + cosine) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosine
        let a2 = 1 - alpha

        return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    nonisolated static func notch(centerFrequency: Float, samplingRate: Float, q: Float) -> Self {
        let omega = 2 * Float.pi * centerFrequency / samplingRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let b0: Float = 1
        let b1 = -2 * cosine
        let b2: Float = 1
        let a0 = 1 + alpha
        let a1 = -2 * cosine
        let a2 = 1 - alpha

        return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    private nonisolated static func normalize(
        b0: Float,
        b1: Float,
        b2: Float,
        a0: Float,
        a1: Float,
        a2: Float
    ) -> Self {
        Self(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }
}
