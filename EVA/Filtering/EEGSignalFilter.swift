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
    case invalidFilterRange(lowCutoff: Double?, highCutoff: Double?, nyquist: Double)
    case nonFiniteOutput(channel: Int)
    case unstableOutput(channel: Int)

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
        case let .invalidFilterRange(lowCutoff, highCutoff, nyquist):
            let lowText = lowCutoff.map { String(format: "%.2f", $0) } ?? "blank"
            let highText = highCutoff.map { String(format: "%.2f", $0) } ?? "blank"
            return String(
                format: "The filter cutoff range is not valid for this signal "
                    + "(high-pass %@ Hz, low-pass %@ Hz; any enabled cutoff must be between 0 and Nyquist = %.2f Hz).",
                lowText, highText, nyquist
            )
        case let .nonFiniteOutput(channel):
            return "The filter became numerically unstable on channel \(channel). Try a higher high-pass cutoff or a gentler slope."
        case let .unstableOutput(channel):
            return "The filter output grew too large on channel \(channel). Try Double precision, a higher high-pass cutoff, or a gentler slope."
        }
    }
}

enum FilterPrecision: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case float
    case double

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .auto:
            return "Auto"
        case .float:
            return "Float"
        case .double:
            return "Double"
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
enum FilterSlope: Int, CaseIterable, Identifiable, Codable, Sendable {
    case dB12 = 12
    case dB24 = 24
    case dB36 = 36
    case dB48 = 48

    nonisolated var id: Int { rawValue }

    nonisolated var label: String { "\(rawValue) dB/oct" }

    /// Number of poles in the one-sided design (before filtfilt doubling).
    nonisolated var designPoles: Int { rawValue / 6 }
}

/// Filter implementation family for a given cutoff edge.
///
/// - `iir`: zero-phase Butterworth (the historical behavior). Cheap and works
///   down to arbitrarily low high-pass cutoffs.
/// - `fir`: zero-phase linear-phase FIR (`filtfilt` over a symmetric kernel).
///   Constant group delay across frequency, at the cost of a long kernel for
///   low cutoffs.
/// - `auto`: the Net Station (EGI) strategy — use IIR for a high-pass below the
///   crossover (where an FIR kernel would be impractically long) and FIR for
///   everything else. See `resolvedFamily(forEdge:cutoff:crossoverHz:)`.
enum FilterFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case iir
    case fir
    case auto

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .iir: return "IIR"
        case .fir: return "FIR"
        case .auto: return "Auto"
        }
    }
}

/// Which cutoff edge a family is being resolved for.
enum FilterEdge: Sendable { case highPass, lowPass }

struct EEGSignalFilter {
    /// Default crossover (Hz) below which an `.auto` high-pass stays IIR.
    nonisolated static let defaultFIRCrossoverHz = 1.0
    /// Default FIR transition-band width as a fraction of the cutoff frequency,
    /// used when no explicit transition width is supplied.
    nonisolated static let defaultFIRTransitionFraction = 0.25

    /// Resolves `.auto` to a concrete `.iir` / `.fir` for one edge. IIR wins for
    /// a high-pass below `crossoverHz`; FIR is used otherwise.
    nonisolated static func resolvedFamily(
        _ family: FilterFamily,
        edge: FilterEdge,
        cutoff: Double,
        crossoverHz: Double
    ) -> FilterFamily {
        switch family {
        case .iir, .fir:
            return family
        case .auto:
            if edge == .highPass, cutoff < crossoverHz {
                return .iir
            }
            return .fir
        }
    }

    nonisolated static func bandPass(
        channels: [[Float]],
        samplingRate: Double,
        lowCutoff: Double?,
        highCutoff: Double?,
        highPassSlope: FilterSlope = .dB24,
        lowPassSlope: FilterSlope = .dB24,
        highPassFamily: FilterFamily = .iir,
        lowPassFamily: FilterFamily = .iir,
        firCrossoverHz: Double = defaultFIRCrossoverHz,
        firTransitionHz: Double? = nil,
        notch60HzEnabled: Bool = false,
        notchFrequency: Double = 60,
        notchIsFIR: Bool = false,
        notchHarmonics: Int = 1,
        precision: FilterPrecision = .auto,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [[Float]] {
        guard samplingRate > 0 else {
            throw EEGSignalFilterError.invalidSamplingRate
        }

        let nyquist = samplingRate / 2
        if let lowCutoff, !(lowCutoff > 0 && lowCutoff < nyquist) {
            throw EEGSignalFilterError.invalidFilterRange(lowCutoff: lowCutoff, highCutoff: highCutoff, nyquist: nyquist)
        }
        if let highCutoff, !(highCutoff > 0 && highCutoff < nyquist) {
            throw EEGSignalFilterError.invalidFilterRange(lowCutoff: lowCutoff, highCutoff: highCutoff, nyquist: nyquist)
        }
        if let lowCutoff, let highCutoff, highCutoff <= lowCutoff {
            throw EEGSignalFilterError.invalidBandpassRange(lowCutoff: lowCutoff, highCutoff: highCutoff, nyquist: nyquist)
        }

        // Resolve each edge's family (turning `.auto` into a concrete choice),
        // then design either a Butterworth biquad cascade (IIR) or a linear-phase
        // FIR kernel for that edge. FIR kernels are designed once here — outside
        // the per-channel loop — exactly like the biquad stages.
        let minChannelLength = channels.map(\.count).min() ?? 0

        var highPassStages: [BiquadCoefficients] = []
        var highPassFIRKernel: [Double] = []
        if let lowCutoff {
            switch resolvedFamily(highPassFamily, edge: .highPass, cutoff: lowCutoff, crossoverHz: firCrossoverHz) {
            case .fir:
                highPassFIRKernel = firKernel(
                    cutoff: lowCutoff, samplingRate: samplingRate, edge: .highPass,
                    transitionHz: firTransitionHz, maxChannelLength: minChannelLength
                )
            case .iir, .auto:
                highPassStages = BiquadCoefficients.butterworth(
                    cutoff: lowCutoff, samplingRate: samplingRate,
                    poles: highPassSlope.designPoles, type: .highPass
                )
            }
        }

        var lowPassStages: [BiquadCoefficients] = []
        var lowPassFIRKernel: [Double] = []
        if let highCutoff {
            switch resolvedFamily(lowPassFamily, edge: .lowPass, cutoff: highCutoff, crossoverHz: firCrossoverHz) {
            case .fir:
                lowPassFIRKernel = firKernel(
                    cutoff: highCutoff, samplingRate: samplingRate, edge: .lowPass,
                    transitionHz: firTransitionHz, maxChannelLength: minChannelLength
                )
            case .iir, .auto:
                lowPassStages = BiquadCoefficients.butterworth(
                    cutoff: highCutoff, samplingRate: samplingRate,
                    poles: lowPassSlope.designPoles, type: .lowPass
                )
            }
        }
        // The notch runs as either a single zero-phase IIR biquad (cheap, sharp)
        // or a linear-phase FIR band-stop that can null several harmonics in one
        // kernel. Only one is active for a given run.
        let iirNotchEnabled = notch60HzEnabled && !notchIsFIR && notchFrequency < nyquist
        let notchFilter = BiquadCoefficients.notch(
            centerFrequency: notchFrequency,
            samplingRate: samplingRate,
            q: 30
        )
        var notchFIRKernel: [Double] = []
        if notch60HzEnabled, notchIsFIR {
            notchFIRKernel = firNotchKernel(
                frequency: notchFrequency,
                harmonics: notchHarmonics,
                samplingRate: samplingRate,
                transitionHz: firTransitionHz,
                maxChannelLength: minChannelLength
            )
        }

        // The high-pass (low cutoff) sets the edge-transient length; pad the
        // reflected boundary to cover it so the startup ripple stays outside
        // the data we keep instead of garbling the first/last samples.
        let paddingReference = lowCutoff ?? highCutoff ?? (notch60HzEnabled ? notchFrequency : nil)
        let paddingCount = transientPadding(lowCutoff: paddingReference ?? 0, samplingRate: samplingRate)
        let automaticPrecision = automaticPrecision(
            samplingRate: samplingRate,
            lowCutoff: lowCutoff,
            highCutoff: highCutoff,
            highPassSlope: highPassSlope,
            lowPassSlope: lowPassSlope
        )

        let total = max(channels.count, 1)
        let reportEvery = max(1, total / 100)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0
        nonisolated(unsafe) var firstError: Error?

        var filteredChannels = Array(repeating: [Float](), count: channels.count)
        filteredChannels.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct index; bounded to evaMaxWorkers
            // instead of one task per channel — an unbounded task-per-channel
            // fan-out here both risked oversubscribing the machine on large
            // channel counts AND made progress reporting look like "0% then
            // 100%": with far more ready tasks than cores, all channels crawl
            // forward together and finish in a last-moment clump instead of
            // completing steadily throughout the run.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: channels.count) { index in
                do {
                    out[index] = try filterChannel(
                        channels[index],
                        channelIndex: index,
                        requestedPrecision: precision,
                        automaticPrecision: automaticPrecision,
                        highPassStages: highPassStages,
                        lowPassStages: lowPassStages,
                        highPassFIRKernel: highPassFIRKernel,
                        lowPassFIRKernel: lowPassFIRKernel,
                        notchFilter: notchFilter,
                        notchEnabled: iirNotchEnabled,
                        notchFIRKernel: notchFIRKernel,
                        paddingCount: paddingCount
                    )
                } catch {
                    progressLock.lock()
                    if firstError == nil { firstError = error }
                    progressLock.unlock()
                }

                progressLock.lock()
                completed += 1
                let done = completed
                progressLock.unlock()
                if let progress, done % reportEvery == 0 || done == total {
                    progress(Double(done) / Double(total))
                }
            }
        }

        if let firstError { throw firstError }
        return filteredChannels
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

        let boundedWindow = max(windowSeconds, 0.5)
        let boundedStrength = min(max(strength, 0.1), 1.5)
        let total = max(channels.count, 1)
        let reportEvery = max(1, total / 100)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0

        var cleanedChannels = Array(repeating: [Float](), count: channels.count)
        cleanedChannels.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct index, so concurrent writes don't
            // overlap; bounded to evaMaxWorkers so this can't oversubscribe the
            // machine the way an unbounded task-per-channel fan-out could.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: channels.count) { index in
                out[index] = adaptiveLineNoiseChannel(
                    channels[index],
                    samplingRate: samplingRate,
                    frequencies: frequencies,
                    windowSeconds: boundedWindow,
                    strength: boundedStrength
                )
                if let progress {
                    progressLock.lock()
                    completed += 1
                    let done = completed
                    progressLock.unlock()
                    if done % reportEvery == 0 || done == total {
                        progress(Double(done) / Double(total))
                    }
                }
            }
        }
        return cleanedChannels
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

    private nonisolated static func automaticPrecision(
        samplingRate: Double,
        lowCutoff: Double?,
        highCutoff: Double?,
        highPassSlope: FilterSlope,
        lowPassSlope: FilterSlope
    ) -> FilterPrecision {
        guard samplingRate > 0 else { return .double }
        let nyquist = samplingRate / 2

        if let lowCutoff {
            let normalizedToRate = lowCutoff / samplingRate
            if normalizedToRate < 0.00005 {
                return .double
            }
            if highPassSlope.designPoles >= 8, normalizedToRate < 0.0002 {
                return .double
            }
        }

        if let highCutoff, nyquist > 0 {
            let distanceFromNyquist = (nyquist - highCutoff) / nyquist
            if distanceFromNyquist < 0.02 || lowPassSlope.designPoles >= 8 && distanceFromNyquist < 0.05 {
                return .double
            }
        }

        return .float
    }

    private nonisolated static func filterChannel(
        _ channel: [Float],
        channelIndex: Int,
        requestedPrecision: FilterPrecision,
        automaticPrecision: FilterPrecision,
        highPassStages: [BiquadCoefficients],
        lowPassStages: [BiquadCoefficients],
        highPassFIRKernel: [Double],
        lowPassFIRKernel: [Double],
        notchFilter: BiquadCoefficients,
        notchEnabled: Bool,
        notchFIRKernel: [Double],
        paddingCount: Int
    ) throws -> [Float] {
        let initialPrecision = requestedPrecision == .auto ? automaticPrecision : requestedPrecision
        do {
            return try filterChannelOnce(
                channel,
                channelIndex: channelIndex,
                precision: initialPrecision,
                highPassStages: highPassStages,
                lowPassStages: lowPassStages,
                highPassFIRKernel: highPassFIRKernel,
                lowPassFIRKernel: lowPassFIRKernel,
                notchFilter: notchFilter,
                notchEnabled: notchEnabled,
                notchFIRKernel: notchFIRKernel,
                paddingCount: paddingCount
            )
        } catch {
            if requestedPrecision == .auto,
               initialPrecision == .float,
               isPrecisionFallbackError(error) {
                return try filterChannelOnce(
                    channel,
                    channelIndex: channelIndex,
                    precision: .double,
                    highPassStages: highPassStages,
                    lowPassStages: lowPassStages,
                    highPassFIRKernel: highPassFIRKernel,
                    lowPassFIRKernel: lowPassFIRKernel,
                    notchFilter: notchFilter,
                    notchEnabled: notchEnabled,
                    notchFIRKernel: notchFIRKernel,
                    paddingCount: paddingCount
                )
            }
            throw error
        }
    }

    private nonisolated static func filterChannelOnce(
        _ channel: [Float],
        channelIndex: Int,
        precision: FilterPrecision,
        highPassStages: [BiquadCoefficients],
        lowPassStages: [BiquadCoefficients],
        highPassFIRKernel: [Double],
        lowPassFIRKernel: [Double],
        notchFilter: BiquadCoefficients,
        notchEnabled: Bool,
        notchFIRKernel: [Double],
        paddingCount: Int
    ) throws -> [Float] {
        var result = channel
        // IIR high-pass stages (empty when the high-pass edge resolved to FIR).
        for stage in highPassStages {
            result = zeroPhaseFilter(result, coefficients: stage, precision: precision, paddingCount: paddingCount)
        }
        // IIR low-pass stages (empty when the low-pass edge resolved to FIR).
        for stage in lowPassStages {
            result = zeroPhaseFilter(result, coefficients: stage, precision: precision, paddingCount: paddingCount)
        }
        // Linear-phase FIR edges are applied zero-phase in Double, then written
        // back to Float. `filtfiltFIR` handles its own reflection padding.
        if !highPassFIRKernel.isEmpty {
            result = applyFIRKernel(highPassFIRKernel, to: result)
        }
        if !lowPassFIRKernel.isEmpty {
            result = applyFIRKernel(lowPassFIRKernel, to: result)
        }
        // Line-noise notch: exactly one of these is populated for a given run.
        if notchEnabled {
            result = zeroPhaseFilter(result, coefficients: notchFilter, precision: precision, paddingCount: paddingCount)
        }
        if !notchFIRKernel.isEmpty {
            result = applyFIRKernel(notchFIRKernel, to: result)
        }
        try validateFilteredChannel(result, source: channel, channelIndex: channelIndex)
        return result
    }

    /// Applies a symmetric (linear-phase) FIR kernel zero-phase to a Float
    /// channel, bridging through Double for the `DSP.filtfiltFIR` core. The
    /// Float↔Double conversions go through Accelerate (vDSP) rather than scalar
    /// `map`, so the whole per-channel path stays vectorized.
    private nonisolated static func applyFIRKernel(_ kernel: [Double], to samples: [Float]) -> [Float] {
        guard kernel.count > 1, samples.count > 1 else { return samples }
        let n = vDSP_Length(samples.count)
        var x = [Double](repeating: 0, count: samples.count)
        vDSP_vspdp(samples, 1, &x, 1, n)
        let y = DSP.filtfiltFIR(kernel, x)
        var out = [Float](repeating: 0, count: y.count)
        vDSP_vdpsp(y, 1, &out, 1, vDSP_Length(y.count))
        return out
    }

    /// Odd (Type-I) tap count for a linear-phase FIR with the given transition
    /// width, bounded so `filtfiltFIR` can pad without exceeding the channel
    /// length (short channels widen the effective transition via fewer taps).
    private nonisolated static func firTapCount(
        transition: Double,
        samplingRate: Double,
        maxChannelLength: Int
    ) -> Int {
        // Kelley/Hamming rule of thumb: taps ≈ 3.3 · fs / transitionWidth.
        var taps = Int((3.3 * samplingRate / transition).rounded(.up))
        if maxChannelLength > 7 {
            let capFromLength = (maxChannelLength / 3) - 1
            taps = min(taps, max(capFromLength, 3))
        }
        taps = max(taps, 3)
        if taps % 2 == 0 { taps += 1 }
        return taps
    }

    /// Designs a zero-phase-ready linear-phase FIR kernel (odd length, Type-I)
    /// for one edge using the windowed-sinc (Hamming) method.
    ///
    /// Windowed-sinc is O(taps) to design, unlike a least-squares (`firls`)
    /// solve, which builds and factors a dense (taps/2)³ system on a single
    /// thread — pathological for the long kernels a low FIR cutoff requires, and
    /// the reason the run appeared to stall on one core before the parallel
    /// per-channel convolution even started. High-pass is derived from the
    /// low-pass by spectral inversion.
    nonisolated static func firKernel(
        cutoff: Double,
        samplingRate: Double,
        edge: FilterEdge,
        transitionHz: Double?,
        maxChannelLength: Int
    ) -> [Double] {
        let nyquist = samplingRate / 2
        guard nyquist > 0, cutoff > 0, cutoff < nyquist else { return [] }

        let transition = max(transitionHz ?? (cutoff * defaultFIRTransitionFraction), samplingRate / 10_000)
        let taps = firTapCount(transition: transition, samplingRate: samplingRate, maxChannelLength: maxChannelLength)
        let normalizedCutoff = cutoff / nyquist
        let lowPass = DSP.windowedSincLowPass(numtaps: taps, cutoff: normalizedCutoff, gain: 1)

        switch edge {
        case .lowPass:
            return lowPass
        case .highPass:
            // Spectral inversion: h_hp = δ − h_lp (negate the low-pass and add a
            // unit impulse at the center tap). Stays symmetric → linear phase.
            var kernel = lowPass.map { -$0 }
            kernel[(taps - 1) / 2] += 1
            return kernel
        }
    }

    /// Full stopband width (Hz) of the FIR notch null. Kept narrow so brain
    /// signal adjacent to the line frequency is preserved; the transition width
    /// drives the tap count.
    nonisolated static let firNotchStopbandHz = 1.0

    /// Designs a linear-phase FIR band-stop kernel that nulls the line frequency
    /// and its harmonics in a single kernel, built as δ minus the sum of a
    /// windowed-sinc band-pass around each harmonic (each band-pass is the
    /// difference of two low-pass kernels). O(taps · harmonics) to design — no
    /// dense solve. Returns `[]` if no harmonic sits below Nyquist.
    nonisolated static func firNotchKernel(
        frequency: Double,
        harmonics: Int,
        samplingRate: Double,
        transitionHz: Double?,
        maxChannelLength: Int
    ) -> [Double] {
        let nyquist = samplingRate / 2
        guard nyquist > 0, frequency > 0, frequency < nyquist else { return [] }

        let transition = max(transitionHz ?? 1.0, samplingRate / 10_000)
        let taps = firTapCount(transition: transition, samplingRate: samplingRate, maxChannelLength: maxChannelLength)
        let stopHalf = firNotchStopbandHz / 2

        let centers = (1...max(harmonics, 1))
            .map { Double($0) * frequency }
            .filter { $0 > 0 && $0 < nyquist * 0.98 }
        guard !centers.isEmpty else { return [] }

        // Start from the all-pass impulse, then subtract a band-pass per harmonic.
        var kernel = [Double](repeating: 0, count: taps)
        kernel[(taps - 1) / 2] = 1
        for center in centers {
            let upper = min((center + stopHalf) / nyquist, 1 - 1e-4)
            let lower = max((center - stopHalf) / nyquist, 1e-4)
            guard upper > lower else { continue }
            let lpUpper = DSP.windowedSincLowPass(numtaps: taps, cutoff: upper, gain: 1)
            let lpLower = DSP.windowedSincLowPass(numtaps: taps, cutoff: lower, gain: 1)
            for i in 0..<taps { kernel[i] -= lpUpper[i] - lpLower[i] }
        }
        return kernel
    }

    private nonisolated static func isPrecisionFallbackError(_ error: Error) -> Bool {
        switch error {
        case EEGSignalFilterError.nonFiniteOutput(_), EEGSignalFilterError.unstableOutput(_):
            return true
        default:
            return false
        }
    }

    private nonisolated static func validateFilteredChannel(
        _ result: [Float],
        source: [Float],
        channelIndex: Int
    ) throws {
        guard result.count == source.count else {
            throw EEGSignalFilterError.unstableOutput(channel: channelIndex + 1)
        }

        var sourceMax = Float(0)
        var resultMax = Float(0)
        for value in source where value.isFinite {
            sourceMax = max(sourceMax, abs(value))
        }
        for value in result {
            guard value.isFinite else {
                throw EEGSignalFilterError.nonFiniteOutput(channel: channelIndex + 1)
            }
            resultMax = max(resultMax, abs(value))
        }

        let growthLimit = max(Double(sourceMax) * 10_000, 1.0e9)
        if Double(resultMax) > growthLimit {
            throw EEGSignalFilterError.unstableOutput(channel: channelIndex + 1)
        }
    }

    private nonisolated static func zeroPhaseFilter(
        _ samples: [Float],
        coefficients: BiquadCoefficients,
        precision: FilterPrecision,
        paddingCount requestedPadding: Int = 24
    ) -> [Float] {
        switch precision {
        case .auto, .double:
            return zeroPhaseFilterDouble(samples, coefficients: coefficients, paddingCount: requestedPadding)
        case .float:
            return zeroPhaseFilterFloat(samples, coefficients: coefficients, paddingCount: requestedPadding)
        }
    }

    private nonisolated static func zeroPhaseFilterDouble(
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

    private nonisolated static func zeroPhaseFilterFloat(
        _ samples: [Float],
        coefficients: BiquadCoefficients,
        paddingCount requestedPadding: Int = 24
    ) -> [Float] {
        guard samples.count > 6 else {
            return samples
        }

        let paddingCount = min(max(requestedPadding, 0), samples.count - 1)
        let paddedSamples = reflectedPadding(for: samples, count: paddingCount)
        let forward = applyBiquadFloat(to: paddedSamples, coefficients: coefficients)
        let backward = applyBiquadFloat(to: Array(forward.reversed()), coefficients: coefficients)
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

        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0

        for sample in samples {
            let x0 = Double(sample)
            let y0 = coefficients.b0 * x0
                + coefficients.b1 * x1
                + coefficients.b2 * x2
                - coefficients.a1 * y1
                - coefficients.a2 * y2
            filtered.append(Float(y0))
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }

        return filtered
    }

    private nonisolated static func applyBiquadFloat(to samples: [Float], coefficients: BiquadCoefficients) -> [Float] {
        var filtered: [Float] = []
        filtered.reserveCapacity(samples.count)

        let b0 = Float(coefficients.b0)
        let b1 = Float(coefficients.b1)
        let b2 = Float(coefficients.b2)
        let a1 = Float(coefficients.a1)
        let a2 = Float(coefficients.a2)

        var x1 = Float(0)
        var x2 = Float(0)
        var y1 = Float(0)
        var y2 = Float(0)

        for sample in samples {
            let y0 = b0 * sample
                + b1 * x1
                + b2 * x2
                - a1 * y1
                - a2 * y2
            filtered.append(y0)
            x2 = x1
            x1 = sample
            y2 = y1
            y1 = y0
        }

        return filtered
    }
}

private struct BiquadCoefficients {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

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
        cutoff: Double,
        samplingRate: Double,
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
            let angle = Double.pi * Double(2 * k + 1) / Double(2 * n)
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
    private nonisolated static func firstOrder(cutoff: Double, samplingRate: Double, type: FilterType) -> Self {
        let omega = 2 * Double.pi * cutoff / samplingRate
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

    nonisolated static func lowPass(cutoff: Double, samplingRate: Double, q: Double) -> Self {
        let omega = 2 * Double.pi * cutoff / samplingRate
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

    nonisolated static func highPass(cutoff: Double, samplingRate: Double, q: Double) -> Self {
        let omega = 2 * Double.pi * cutoff / samplingRate
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

    nonisolated static func notch(centerFrequency: Double, samplingRate: Double, q: Double) -> Self {
        let omega = 2 * Double.pi * centerFrequency / samplingRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let b0: Double = 1
        let b1 = -2 * cosine
        let b2: Double = 1
        let a0 = 1 + alpha
        let a1 = -2 * cosine
        let a2 = 1 - alpha

        return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    private nonisolated static func normalize(
        b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
    ) -> Self {
        Self(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }
}
