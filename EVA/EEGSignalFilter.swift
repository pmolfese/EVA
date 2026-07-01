//
//  EEGSignalFilter.swift
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

/// Rolloff slope expressed as dB per octave. Each step is one additional
/// Butterworth biquad stage (two poles). With zero-phase (filtfilt) the
/// effective slope is the same as the design slope because filtfilt is used
/// to cancel phase shift, and we report the *design* order here to match the
/// convention used by BrainVision Analyzer, EEGLAB, and similar tools.
///
/// Mapping: 12 dB/oct = 2-pole design (1st-order section + filtfilt),
///          24 dB/oct = 4-pole design (1 biquad), 36 = 6-pole (1 biquad + 1st-order),
///          48 = 8-pole (2 biquads). All are applied zero-phase.
enum FilterSlope: Int, CaseIterable, Identifiable, Codable {
    case dB12 = 12
    case dB24 = 24
    case dB36 = 36
    case dB48 = 48

    var id: Int { rawValue }

    var label: String { "\(rawValue) dB/oct" }

    /// Number of poles in the one-sided design (before filtfilt doubling).
    var designPoles: Int { rawValue / 6 }
}

struct EEGSignalFilter {
    nonisolated static func bandPass(
        channels: [[Float]],
        samplingRate: Double,
        lowCutoff: Double,
        highCutoff: Double,
        highPassSlope: FilterSlope = .dB24,
        lowPassSlope: FilterSlope = .dB24,
        notch60HzEnabled: Bool = false,
        notchFrequency: Double = 60,
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
            let highPassStages = BiquadCoefficients.butterworth(
                cutoff: Float(lowCutoff),
                samplingRate: Float(samplingRate),
                poles: highPassSlope.designPoles,
                type: .highPass
            )
            let lowPassStages = BiquadCoefficients.butterworth(
                cutoff: Float(highCutoff),
                samplingRate: Float(samplingRate),
                poles: lowPassSlope.designPoles,
                type: .lowPass
            )
            let notchFilter = BiquadCoefficients.notch(
                centerFrequency: Float(notchFrequency),
                samplingRate: Float(samplingRate),
                q: 30
            )

            // The high-pass (low cutoff) sets the edge-transient length; pad the
            // reflected boundary to cover it so the startup ripple stays outside
            // the data we keep instead of garbling the first/last samples.
            let paddingCount = transientPadding(lowCutoff: lowCutoff, samplingRate: samplingRate)

            for (index, channel) in channels.enumerated() {
                group.addTask {
                    var result = channel
                    for stage in highPassStages {
                        result = zeroPhaseFilter(result, coefficients: stage, paddingCount: paddingCount)
                    }
                    for stage in lowPassStages {
                        result = zeroPhaseFilter(result, coefficients: stage, paddingCount: paddingCount)
                    }
                    if notch60HzEnabled, notchFrequency < (samplingRate / 2) {
                        result = zeroPhaseFilter(result, coefficients: notchFilter, paddingCount: paddingCount)
                    }
                    return (index, result)
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

    nonisolated static func adaptiveLineNoiseReduction(
        channels: [[Float]],
        samplingRate: Double,
        baseFrequency: Double = 60,
        harmonicCount: Int = 2,
        windowSeconds: Double = 4,
        strength: Double = 1,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [[Float]] {
        guard samplingRate > 0,
              baseFrequency > 0,
              !channels.isEmpty else {
            return channels
        }

        let nyquist = samplingRate / 2
        let frequencies = (1...max(harmonicCount, 1))
            .map { baseFrequency * Double($0) }
            .filter { $0 > 0 && $0 < nyquist * 0.98 }
        guard !frequencies.isEmpty else {
            progress?(1)
            return channels
        }

        return await withTaskGroup(of: (Int, [Float]).self) { group in
            let boundedWindow = max(windowSeconds, 0.5)
            let boundedStrength = min(max(strength, 0.1), 1.5)
            for (index, channel) in channels.enumerated() {
                group.addTask {
                    let cleaned = adaptiveLineNoiseChannel(
                        channel,
                        samplingRate: samplingRate,
                        frequencies: frequencies,
                        windowSeconds: boundedWindow,
                        strength: boundedStrength
                    )
                    return (index, cleaned)
                }
            }

            var cleanedChannels = Array(repeating: [Float](), count: channels.count)
            let total = max(channels.count, 1)
            let reportEvery = max(1, total / 100)
            var completed = 0
            for await (index, cleanedChannel) in group {
                cleanedChannels[index] = cleanedChannel
                completed += 1
                if let progress, completed % reportEvery == 0 || completed == total {
                    progress(Double(completed) / Double(total))
                }
            }
            return cleanedChannels
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

    private nonisolated static func adaptiveLineNoiseChannel(
        _ samples: [Float],
        samplingRate: Double,
        frequencies: [Double],
        windowSeconds: Double,
        strength: Double
    ) -> [Float] {
        guard samples.count > 8 else { return samples }
        var cleaned = samples
        for frequency in frequencies {
            cleaned = subtractAdaptiveSinusoid(
                from: cleaned,
                samplingRate: samplingRate,
                frequency: frequency,
                windowSeconds: windowSeconds,
                strength: strength
            )
        }
        return cleaned
    }

    private nonisolated static func subtractAdaptiveSinusoid(
        from samples: [Float],
        samplingRate: Double,
        frequency: Double,
        windowSeconds: Double,
        strength: Double
    ) -> [Float] {
        let sampleCount = samples.count
        let windowSamples = min(
            max(Int((windowSeconds * samplingRate).rounded()), 32),
            sampleCount
        )
        guard windowSamples >= 16 else { return samples }
        let stepSamples = max(windowSamples / 2, 1)
        let taper = hannWindow(count: windowSamples)
        let omega = 2 * Double.pi * frequency / samplingRate
        let minimumExplainedFraction = max(0.0002, 0.002 / max(strength, 0.1))

        var correctionSum = [Double](repeating: 0, count: sampleCount)
        var weightSum = [Double](repeating: 0, count: sampleCount)

        var starts = Array(stride(from: 0, to: max(sampleCount - windowSamples + 1, 1), by: stepSamples))
        let finalStart = max(sampleCount - windowSamples, 0)
        if starts.last != finalStart {
            starts.append(finalStart)
        }

        for start in starts {
            let end = min(start + windowSamples, sampleCount)
            guard end - start >= 16 else { continue }
            var mean = 0.0
            for index in start..<end {
                mean += Double(samples[index])
            }
            mean /= Double(end - start)

            var cc = 0.0
            var ss = 0.0
            var cs = 0.0
            var yc = 0.0
            var ys = 0.0
            var energy = 0.0
            for local in 0..<(end - start) {
                let sampleIndex = start + local
                let centered = Double(samples[sampleIndex]) - mean
                let phase = omega * Double(sampleIndex)
                let cosine = cos(phase)
                let sine = sin(phase)
                cc += cosine * cosine
                ss += sine * sine
                cs += cosine * sine
                yc += centered * cosine
                ys += centered * sine
                energy += centered * centered
            }

            let determinant = cc * ss - cs * cs
            guard determinant > 1e-12, energy > 1e-12 else { continue }
            let cosineCoefficient = (yc * ss - ys * cs) / determinant
            let sineCoefficient = (ys * cc - yc * cs) / determinant

            var fittedEnergy = 0.0
            for local in 0..<(end - start) {
                let sampleIndex = start + local
                let phase = omega * Double(sampleIndex)
                let fitted = cosineCoefficient * cos(phase) + sineCoefficient * sin(phase)
                fittedEnergy += fitted * fitted
            }
            guard fittedEnergy / energy >= minimumExplainedFraction else { continue }

            for local in 0..<(end - start) {
                let sampleIndex = start + local
                let phase = omega * Double(sampleIndex)
                let fitted = cosineCoefficient * cos(phase) + sineCoefficient * sin(phase)
                let weight = taper[local]
                correctionSum[sampleIndex] += fitted * weight
                weightSum[sampleIndex] += weight
            }
        }

        var cleaned = samples
        for index in cleaned.indices where weightSum[index] > 1e-12 {
            cleaned[index] = Float(Double(samples[index]) - strength * correctionSum[index] / weightSum[index])
        }
        return cleaned
    }

    private nonisolated static func hannWindow(count: Int) -> [Double] {
        guard count > 1 else { return [1] }
        return (0..<count).map { index in
            0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1))
        }
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

    enum FilterType { case lowPass, highPass }

    /// Returns the cascade of biquad (and optional 1st-order) sections needed
    /// for an N-pole Butterworth filter at `cutoff`.
    ///
    /// - Odd pole count: one 1st-order section encoded as a biquad with b2=a2=0,
    ///   followed by (poles-1)/2 standard biquad sections.
    /// - Even pole count: poles/2 biquad sections.
    ///
    /// Q values for each pair follow the standard Butterworth pole placement:
    ///   Q_k = 1 / (2 · cos(π(2k+1)/(2N)))  for k = 0 … N/2-1 (0-indexed pairs)
    nonisolated static func butterworth(
        cutoff: Float,
        samplingRate: Float,
        poles: Int,
        type: FilterType
    ) -> [BiquadCoefficients] {
        let n = max(poles, 1)
        var stages: [BiquadCoefficients] = []

        // Odd pole: prepend a 1st-order section (encoded as biquad with b2=a2=0)
        if n % 2 == 1 {
            stages.append(firstOrder(cutoff: cutoff, samplingRate: samplingRate, type: type))
        }

        let pairs = n / 2
        for k in 0..<pairs {
            // Angle for k-th conjugate pair in an N-pole Butterworth
            let angle = Float.pi * Float(2 * k + 1) / Float(2 * n)
            let q = 1.0 / (2.0 * cos(angle))
            switch type {
            case .lowPass:
                stages.append(lowPass(cutoff: cutoff, samplingRate: samplingRate, q: q))
            case .highPass:
                stages.append(highPass(cutoff: cutoff, samplingRate: samplingRate, q: q))
            }
        }
        return stages
    }

    /// Single-pole (1st-order) filter encoded as a biquad with b2 = a2 = 0.
    private nonisolated static func firstOrder(cutoff: Float, samplingRate: Float, type: FilterType) -> Self {
        let omega = 2 * Float.pi * cutoff / samplingRate
        // Bilinear transform of s-domain 1st-order LP: H(s) = 1/(s+1), HP: H(s) = s/(s+1)
        let k = tan(omega / 2)
        switch type {
        case .lowPass:
            let a0 = 1 + k
            return Self(b0: k / a0, b1: k / a0, b2: 0, a1: (k - 1) / a0, a2: 0)
        case .highPass:
            let a0 = 1 + k
            return Self(b0: 1 / a0, b1: -1 / a0, b2: 0, a1: (k - 1) / a0, a2: 0)
        }
    }

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
        b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float
    ) -> Self {
        Self(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }
}
