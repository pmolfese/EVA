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

    /// Describes invalid cutoffs or numerical failure using the requested values/channel number.
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

    /// User-facing precision label; Auto lets the numerical heuristics choose the first attempt.
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
/// Butterworth biquad stage (two poles) in the one-pass design. Filtering is
/// always applied zero-phase (filtfilt), which squares the magnitude
/// response and therefore *doubles* the actual dB/octave attenuation
/// relative to a single forward pass. The `rawValue` stores the one-pass
/// design slope (used to derive `designPoles`); `label` reports the true,
/// user-facing effective slope actually delivered by the filter.
///
/// Mapping: rawValue 12 uses 2 poles (1 biquad), 24 uses 4 poles (2 biquads),
/// 36 uses 6 poles (3 biquads), and 48 uses 8 poles (4 biquads). The forward/
/// backward application doubles their asymptotic attenuation to 24/48/72/96 dB/oct.
enum FilterSlope: Int, CaseIterable, Identifiable, Codable, Sendable {
    case dB12 = 12
    case dB24 = 24
    case dB36 = 36
    case dB48 = 48

    nonisolated var id: Int { rawValue }

    /// True effective slope after zero-phase (filtfilt) doubling.
    nonisolated var label: String { "\(rawValue * 2) dB/oct" }

    /// Number of poles in the one-sided design (before filtfilt doubling).
    nonisolated var designPoles: Int { rawValue / 6 }
}

/// Filter implementation family for a given cutoff edge.
///
/// - `iir`: zero-phase recursive filtering. Butterworth is the historical
///   design; elliptic is available for a steeper transition.
/// - `fir`: linear-phase FIR with a selectable window and application. A causal
///   forward pass retains constant group delay; the other modes remove it.
/// - `auto`: the Net Station (EGI) strategy — use IIR on the low-frequency side
///   of the crossover (where an FIR kernel would be impractically long) and FIR
///   elsewhere. See `resolvedFamily(forEdge:cutoff:crossoverHz:)`.
enum FilterFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case iir
    case fir
    case auto

    nonisolated var id: String { rawValue }

    /// Short UI name for the requested filter family before resolving Auto per edge.
    nonisolated var label: String {
        switch self {
        case .iir: return "IIR"
        case .fir: return "FIR"
        case .auto: return "Auto"
        }
    }
}

enum IIRDesign: String, CaseIterable, Identifiable, Codable, Sendable {
    case butterworth
    case elliptic

    nonisolated var id: String { rawValue }
    /// Display name for the recursive filter’s coefficient-design method.
    nonisolated var label: String {
        switch self {
        case .butterworth: return "Butterworth"
        case .elliptic: return "Elliptic"
        }
    }
}

enum FIRWindow: String, CaseIterable, Identifiable, Codable, Sendable {
    case hamming
    case kaiser

    nonisolated var id: String { rawValue }
    /// Display name for the FIR window used to taper the ideal sinc kernel.
    nonisolated var label: String {
        switch self {
        case .hamming: return "Hamming"
        case .kaiser: return "Kaiser"
        }
    }
}

/// How a linear-phase FIR kernel is applied. The historical EVA behavior is
/// `.zeroPhase`; `.delayCompensated` matches single-pass EEG-toolbox FIRs that
/// remove their fixed group delay, while `.forward` is genuinely causal.
enum FIRApplication: String, CaseIterable, Identifiable, Codable, Sendable {
    case zeroPhase
    case delayCompensated
    case forward

    nonisolated var id: String { rawValue }
    /// Explains whether FIR application keeps, removes, or cancels its phase delay.
    nonisolated var label: String {
        switch self {
        case .zeroPhase: return "Zero phase (two pass)"
        case .delayCompensated: return "Single pass (delay compensated)"
        case .forward: return "Forward only (causal)"
        }
    }
}

/// Which cutoff edge a family is being resolved for.
nonisolated enum FilterEdge: Sendable { case highPass, lowPass }

/// Whether the Auto family's IIR side stops before the crossover or includes
/// it. Historical EVA behavior is `.below`; Net Station uses `.through` at its
/// 1-Hz boundary.
enum AutoCrossoverRule: String, CaseIterable, Identifiable, Codable, Sendable {
    case below
    case through

    nonisolated var id: String { rawValue }
    /// Display text for whether the Auto crossover includes the boundary frequency.
    nonisolated var label: String {
        switch self {
        case .below: return "below"
        case .through: return "at or below"
        }
    }
}

/// How EVA derives a FIR design from a requested cutoff.
///
/// The choices below are conventions, not preferences: two packages given the
/// same "30 Hz low-pass" can build measurably different filters because they
/// disagree about what the number *means* and how wide the transition should
/// be. Making the convention explicit is what lets EVA reproduce another
/// package's filtering, and what lets a published `eva.xml` state which
/// convention produced its figures rather than leaving a reader to infer it.
nonisolated enum FIRDesignRule: String, CaseIterable, Identifiable, Sendable {
    /// EVA's own rule: 25% of the cutoff, floored at 2 Hz and capped at the
    /// available band, with the requested frequency as the −6 dB point.
    ///
    /// The clamps are MNE's and EEGLAB's, adopted because an unfloored 25% at a
    /// low high-pass produced kernels long enough that the channel-length cap
    /// silently changed the filter — a 0.1 Hz high-pass asked for 33,001 taps,
    /// or 132 s of data at 250 Hz. The −6 dB reading of the requested frequency
    /// is EVA's own and is what distinguishes this from `.eeglabMNE`.
    case eva

    /// EEGLAB `pop_eegfiltnew` / MNE-Python `firwin`: same clamped transition,
    /// but the requested frequency is the **passband edge** and the −6 dB point
    /// falls half a transition beyond it. A band-pass uses one kernel sized by
    /// the narrower of the two transitions rather than one kernel per edge.
    ///
    /// MNE documents its default design as reproducing `pop_eegfiltnew`, so the
    /// two packages genuinely agree and share this case rather than each having
    /// their own.
    case eeglabMNE

    nonisolated var id: String { rawValue }

    /// Display name for the convention used to interpret requested FIR cutoffs.
    var label: String {
        switch self {
        case .eva: return "EVA"
        case .eeglabMNE: return "EEGLAB / MNE"
        }
    }

    /// Whether the requested frequency names the passband edge rather than the
    /// −6 dB point.
    var requestedFrequencyIsPassbandEdge: Bool { self == .eeglabMNE }

    /// Whether a band-pass shares one kernel length across both edges.
    var usesSharedKernelLength: Bool { self == .eeglabMNE }
}

struct EEGSignalFilter {
    /// Minimum automatic FIR transition width, in Hz. Matches MNE's and
    /// EEGLAB's floor.
    nonisolated static let minimumFIRTransitionHz = 2.0
    /// Default crossover (Hz) below which an `.auto` high-pass stays IIR.
    nonisolated static let defaultFIRCrossoverHz = 1.0
    /// Default FIR transition-band width as a fraction of the cutoff frequency,
    /// used when no explicit transition width is supplied.
    nonisolated static let defaultFIRTransitionFraction = 0.25
    nonisolated static let defaultEllipticPassbandRippleDB = 0.1
    nonisolated static let defaultEllipticStopbandAttenuationDB = 60.0
    nonisolated static let defaultKaiserAttenuationDB = 60.0

    /// Resolves `.auto` to a concrete `.iir` / `.fir` for one edge using the
    /// selected crossover boundary rule.
    nonisolated static func resolvedFamily(
        _ family: FilterFamily,
        edge: FilterEdge,
        cutoff: Double,
        crossoverHz: Double,
        crossoverRule: AutoCrossoverRule = .below
    ) -> FilterFamily {
        switch family {
        case .iir, .fir:
            return family
        case .auto:
            switch edge {
            case .highPass:
                let usesIIR = switch crossoverRule {
                case .below: cutoff < crossoverHz
                case .through: cutoff <= crossoverHz
                }
                return usesIIR ? .iir : .fir
            case .lowPass:
                return .fir
            }
        }
    }

    /// Filters `channels[channel][sample]`, preserving the array's channel order.
    /// Frequencies and samplingRate are in Hz; nil cutoffs disable the respective
    /// high/low-pass edge. Filter family, phase and boundary handling are separate
    /// choices: read FIRApplication and the per-channel routines before changing them.
    ///
    /// Flow: validate requested edges → resolve filter design → process channels
    /// → validate output. This function computes samples; recording/history updates
    /// belong to FilterViewModel and its caller. Progress is a fraction, not a sample index.
    nonisolated static func bandPass(
        channels: [[Float]],
        samplingRate: Double,
        lowCutoff: Double?,
        highCutoff: Double?,
        highPassSlope: FilterSlope = .dB24,
        lowPassSlope: FilterSlope = .dB24,
        highPassFamily: FilterFamily = .iir,
        lowPassFamily: FilterFamily = .iir,
        iirDesign: IIRDesign = .butterworth,
        ellipticPassbandRippleDB: Double = defaultEllipticPassbandRippleDB,
        ellipticStopbandAttenuationDB: Double = defaultEllipticStopbandAttenuationDB,
        firWindow: FIRWindow = .hamming,
        firKaiserAttenuationDB: Double = defaultKaiserAttenuationDB,
        firApplication: FIRApplication = .zeroPhase,
        firCrossoverHz: Double = defaultFIRCrossoverHz,
        firCrossoverRule: AutoCrossoverRule = .below,
        firTransitionHz: Double? = nil,
        firDesignRule: FIRDesignRule = .eva,
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

        // Nyquist is half the sample rate. A digital cutoff must lie below it;
        // lowCutoff names the high-pass edge and highCutoff names the low-pass edge.
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

        // EEGLAB/MNE size a band-pass from the *narrower* of the two
        // transitions and use that one length for both edges, so the pair
        // shares one tap count; the edges are still applied in sequence below. EVA's own rules
        // size each edge independently, which is why this is nil for them.
        let sharedFIRTaps = firDesignRule.usesSharedKernelLength
            ? sharedBandpassTapCount(
                lowCutoff: lowCutoff, highCutoff: highCutoff, samplingRate: samplingRate,
                highPassFamily: highPassFamily, lowPassFamily: lowPassFamily,
                crossoverHz: firCrossoverHz, crossoverRule: firCrossoverRule,
                transitionHz: firTransitionHz, maxChannelLength: minChannelLength,
                window: firWindow, kaiserAttenuationDB: firKaiserAttenuationDB,
                rule: firDesignRule
            )
            : nil

        var highPassStages: [BiquadCoefficients] = []
        var highPassFIRKernel: [Double] = []
        if let lowCutoff {
            switch resolvedFamily(
                highPassFamily, edge: .highPass, cutoff: lowCutoff,
                crossoverHz: firCrossoverHz, crossoverRule: firCrossoverRule
            ) {
            case .fir:
                highPassFIRKernel = firKernel(
                    cutoff: lowCutoff, samplingRate: samplingRate, edge: .highPass,
                    transitionHz: firTransitionHz, maxChannelLength: minChannelLength,
                    window: firWindow, kaiserAttenuationDB: firKaiserAttenuationDB,
                    rule: firDesignRule, tapOverride: sharedFIRTaps
                )
            case .iir, .auto:
                highPassStages = BiquadCoefficients.designed(
                    design: iirDesign, cutoff: lowCutoff, samplingRate: samplingRate,
                    poles: highPassSlope.designPoles, type: .highPass,
                    passbandRippleDB: ellipticPassbandRippleDB,
                    stopbandAttenuationDB: ellipticStopbandAttenuationDB)
            }
        }

        var lowPassStages: [BiquadCoefficients] = []
        var lowPassFIRKernel: [Double] = []
        if let highCutoff {
            switch resolvedFamily(
                lowPassFamily, edge: .lowPass, cutoff: highCutoff,
                crossoverHz: firCrossoverHz, crossoverRule: firCrossoverRule
            ) {
            case .fir:
                lowPassFIRKernel = firKernel(
                    cutoff: highCutoff, samplingRate: samplingRate, edge: .lowPass,
                    transitionHz: firTransitionHz, maxChannelLength: minChannelLength,
                    window: firWindow, kaiserAttenuationDB: firKaiserAttenuationDB,
                    rule: firDesignRule, tapOverride: sharedFIRTaps
                )
            case .iir, .auto:
                lowPassStages = BiquadCoefficients.designed(
                    design: iirDesign, cutoff: highCutoff, samplingRate: samplingRate,
                    poles: lowPassSlope.designPoles, type: .lowPass,
                    passbandRippleDB: ellipticPassbandRippleDB,
                    stopbandAttenuationDB: ellipticStopbandAttenuationDB)
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
                maxChannelLength: minChannelLength,
                window: firWindow,
                kaiserAttenuationDB: firKaiserAttenuationDB
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
        // The compiler cannot prove these parallel mutations safe. The lock protects
        // shared progress/error state; the output buffer below gives each worker a
        // different channel slot. Keep both invariants when changing this loop.
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0
        nonisolated(unsafe) var firstError: Error?
        let designedHighPassStages = highPassStages
        let designedLowPassStages = lowPassStages
        let designedHighPassFIRKernel = highPassFIRKernel
        let designedLowPassFIRKernel = lowPassFIRKernel
        let designedNotchFIRKernel = notchFIRKernel

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
                        highPassStages: designedHighPassStages,
                        lowPassStages: designedLowPassStages,
                        highPassFIRKernel: designedHighPassFIRKernel,
                        lowPassFIRKernel: designedLowPassFIRKernel,
                        notchFilter: notchFilter,
                        notchEnabled: iirNotchEnabled,
                        notchFIRKernel: designedNotchFIRKernel,
                        firApplication: firApplication,
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

    /// Reduces line-frequency sinusoids and valid harmonics independently per channel.
    /// Uses overlapping local fits so amplitude/phase can vary over time; clamps window
    /// and subtraction strength. Invalid basic inputs return the original arrays.
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

    /// Common-average reference: subtract the instantaneous mean across non-bad
    /// channels from every channel at each sample. Returns the data unchanged if it is ragged.
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

    /// In-place common-average reference. Mutates the caller’s arrays through
    /// inout; Swift may still copy buffers if another value shares their storage. Bad channels are excluded from the average so
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
    /// reduce ringing in the retained samples; actual padding is limited by input length.
    nonisolated static func transientPadding(lowCutoff: Double, samplingRate: Double) -> Int {
        guard lowCutoff > 0, samplingRate > 0 else { return 24 }
        let estimate = Int((3.0 * samplingRate / lowCutoff).rounded(.up))
        return max(estimate, 24)
    }

    /// Chooses Double for especially small normalized high-pass cutoffs or low-pass
    /// cutoffs near Nyquist, where recursive Float arithmetic is more fragile. Otherwise
    /// starts with Float; automatic mode can retry numerical failures in Double.
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

    /// Filters one channel and retries in Double only when Auto first used Float
    /// and output validation reported instability. Explicit precision requests never retry.
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
        firApplication: FIRApplication,
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
                firApplication: firApplication,
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
                    firApplication: firApplication,
                    paddingCount: paddingCount
                )
            }
            throw error
        }
    }

    /// Applies the prepared high-pass, low-pass, and optional notch stages in order,
    /// then verifies length, finite values, and excessive growth before returning samples.
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
        firApplication: FIRApplication,
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
        // Linear-phase FIR edges use the selected application in Double, then
        // are written back to Float. Each application owns its edge handling.
        if !highPassFIRKernel.isEmpty {
            result = applyFIRKernel(highPassFIRKernel, to: result, application: firApplication)
        }
        if !lowPassFIRKernel.isEmpty {
            result = applyFIRKernel(lowPassFIRKernel, to: result, application: firApplication)
        }
        // Line-noise notch: exactly one of these is populated for a given run.
        if notchEnabled {
            result = zeroPhaseFilter(result, coefficients: notchFilter, precision: precision, paddingCount: paddingCount)
        }
        if !notchFIRKernel.isEmpty {
            result = applyFIRKernel(notchFIRKernel, to: result, application: firApplication)
        }
        try validateFilteredChannel(result, source: channel, channelIndex: channelIndex)
        return result
    }

    /// Applies a symmetric (linear-phase) FIR kernel to a Float channel using
    /// the selected phase/application mode. Float↔Double conversions go through
    /// Accelerate (vDSP) rather than scalar `map`.
    private nonisolated static func applyFIRKernel(
        _ kernel: [Double],
        to samples: [Float],
        application: FIRApplication
    ) -> [Float] {
        guard kernel.count > 1, samples.count > 1 else { return samples }
        let n = vDSP_Length(samples.count)
        var x = [Double](repeating: 0, count: samples.count)
        vDSP_vspdp(samples, 1, &x, 1, n)
        let y: [Double]
        switch application {
        case .zeroPhase:
            y = DSP.filtfiltFIR(kernel, x)
        case .delayCompensated:
            y = DSP.delayCompensatedFIR(kernel, x)
        case .forward:
            y = DSP.firFilter(kernel, x)
        }
        var out = [Float](repeating: 0, count: y.count)
        vDSP_vdpsp(y, 1, &out, 1, vDSP_Length(y.count))
        return out
    }

    /// The automatic transition width for one edge, in Hz, before any
    /// length-driven capping.
    ///
    /// 25% of the cutoff, subject to MNE's and EEGLAB's clamps: at least
    /// `minimumFIRTransitionHz`, and never wider than the band actually
    /// available on that side — the cutoff itself for a high-pass, the distance
    /// to Nyquist for a low-pass. Without the floor a 0.1 Hz high-pass asks for
    /// a 0.025 Hz transition, which is a 33,001-tap kernel at 250 Hz.
    ///
    /// `rule` is taken even though both current rules clamp identically: the
    /// width is the rule's to decide, and a future rule that wants a different
    /// one should not have to change every call site to get it.
    nonisolated static func automaticTransitionHz(
        cutoff: Double,
        samplingRate: Double,
        edge: FilterEdge,
        rule: FIRDesignRule
    ) -> Double {
        let fraction = cutoff * defaultFIRTransitionFraction
        let headroom = edge == .highPass ? cutoff : max(samplingRate / 2 - cutoff, 0)
        let floored = max(fraction, minimumFIRTransitionHz)
        return max(min(floored, headroom), samplingRate / 10_000)
    }

    /// What a FIR request resolves to, separating what the settings asked for
    /// from what the recording could actually accommodate.
    ///
    /// The two used to be conflated: the tap count was silently capped to a
    /// fraction of the channel length, so the *same settings on a shorter
    /// recording produced a different filter* with nothing said about it. They
    /// are reported separately now so callers can surface the difference, the
    /// process log can record it, and `eva.xml` can store the realized tap count
    /// rather than a length-dependent guess.
    nonisolated struct FIRDesignReport: Equatable, Sendable {
        let requestedTransitionHz: Double
        let requestedTaps: Int
        let realizedTaps: Int
        let samplingRate: Double

        /// True when the recording was too short for the requested kernel, so
        /// the realized filter is wider than asked for.
        var wasCapped: Bool { realizedTaps < requestedTaps }

        /// The transition width actually achieved, back-derived from the taps
        /// that survived capping.
        var realizedTransitionHz: Double {
            guard realizedTaps > 0 else { return requestedTransitionHz }
            return requestedTransitionHz * Double(requestedTaps) / Double(realizedTaps)
        }

        /// Duration represented by the uncapped requested FIR tap count.
        var requestedKernelSeconds: Double {
            samplingRate > 0 ? Double(requestedTaps) / samplingRate : 0
        }

        /// Shortest recording, in seconds, that would have carried the
        /// requested kernel uncapped — the number a user needs in order to know
        /// what to do about a capped filter.
        var requiredRecordingSeconds: Double {
            samplingRate > 0 ? Double((requestedTaps + 1) * 3) / samplingRate : 0
        }

        /// Summarizes realized taps and estimated transition width, including a capping warning.
        var summary: String {
            let transition = String(format: "%.3g", realizedTransitionHz)
            guard wasCapped else {
                return "\(realizedTaps) taps, \(transition) Hz transition"
            }
            return "\(realizedTaps) taps (asked \(requestedTaps)), transition widened to \(transition) Hz"
        }
    }

    /// One tap count for both edges of a band-pass, taken from the narrower
    /// transition — EEGLAB's and MNE's behaviour, where a band-pass is a single
    /// kernel rather than two filters in series.
    ///
    /// Returns `nil` unless both edges are actually FIR, since a hybrid run has
    /// no second FIR edge to share with.
    private nonisolated static func sharedBandpassTapCount(
        lowCutoff: Double?,
        highCutoff: Double?,
        samplingRate: Double,
        highPassFamily: FilterFamily,
        lowPassFamily: FilterFamily,
        crossoverHz: Double,
        crossoverRule: AutoCrossoverRule,
        transitionHz: Double?,
        maxChannelLength: Int,
        window: FIRWindow,
        kaiserAttenuationDB: Double,
        rule: FIRDesignRule
    ) -> Int? {
        var transitions: [Double] = []

        if let lowCutoff, resolvedFamily(
            highPassFamily, edge: .highPass, cutoff: lowCutoff,
            crossoverHz: crossoverHz, crossoverRule: crossoverRule
        ) == .fir {
            transitions.append(transitionHz ?? automaticTransitionHz(
                cutoff: lowCutoff, samplingRate: samplingRate, edge: .highPass, rule: rule
            ))
        }
        if let highCutoff, resolvedFamily(
            lowPassFamily, edge: .lowPass, cutoff: highCutoff,
            crossoverHz: crossoverHz, crossoverRule: crossoverRule
        ) == .fir {
            transitions.append(transitionHz ?? automaticTransitionHz(
                cutoff: highCutoff, samplingRate: samplingRate, edge: .lowPass, rule: rule
            ))
        }

        guard transitions.count == 2, let narrowest = transitions.min() else { return nil }
        return firTapCount(
            transition: narrowest, samplingRate: samplingRate,
            maxChannelLength: maxChannelLength, window: window,
            kaiserAttenuationDB: kaiserAttenuationDB
        )
    }

    /// Resolves one edge's FIR design without building the kernel, for UI
    /// preview and for the process log.
    nonisolated static func firDesignReport(
        cutoff: Double,
        samplingRate: Double,
        edge: FilterEdge,
        transitionHz: Double?,
        maxChannelLength: Int,
        window: FIRWindow = .hamming,
        kaiserAttenuationDB: Double = defaultKaiserAttenuationDB,
        rule: FIRDesignRule = .eva
    ) -> FIRDesignReport {
        let transition = transitionHz ?? automaticTransitionHz(
            cutoff: cutoff, samplingRate: samplingRate, edge: edge, rule: rule
        )
        let requested = firTapCount(
            transition: transition, samplingRate: samplingRate,
            maxChannelLength: .max, window: window, kaiserAttenuationDB: kaiserAttenuationDB
        )
        let realized = firTapCount(
            transition: transition, samplingRate: samplingRate,
            maxChannelLength: maxChannelLength, window: window, kaiserAttenuationDB: kaiserAttenuationDB
        )
        return FIRDesignReport(
            requestedTransitionHz: transition,
            requestedTaps: requested,
            realizedTaps: realized,
            samplingRate: samplingRate
        )
    }

    /// Odd (Type-I) tap count for a linear-phase FIR with the given transition
    /// width, bounded so `filtfiltFIR` can pad without exceeding the channel
    /// length (short channels widen the effective transition via fewer taps).
    ///
    /// Pass `Int.max` for `maxChannelLength` to get the uncapped count the
    /// settings ask for — `firDesignReport` uses both to tell the two apart.
    private nonisolated static func firTapCount(
        transition: Double,
        samplingRate: Double,
        maxChannelLength: Int,
        window: FIRWindow,
        kaiserAttenuationDB: Double
    ) -> Int {
        let estimate: Double
        switch window {
        case .hamming:
            // Kelley/Hamming rule of thumb: taps ≈ 3.3 · fs / transitionWidth.
            estimate = 3.3 * samplingRate / transition
        case .kaiser:
            // Kaiser order estimate: N ~= (A - 8) / (2.285 * deltaOmega).
            let attenuation = max(kaiserAttenuationDB, 21)
            let deltaOmega = 2 * Double.pi * transition / samplingRate
            estimate = (attenuation - 8) / (2.285 * deltaOmega) + 1
        }
        var taps = Int(estimate.rounded(.up))
        if maxChannelLength > 7 {
            let capFromLength = (maxChannelLength / 3) - 1
            taps = min(taps, max(capFromLength, 3))
        }
        taps = max(taps, 3)
        // An odd tap count gives a symmetric Type-I kernel one exact center sample,
        // needed by the high-pass spectral-inversion impulse.
        if taps % 2 == 0 { taps += 1 }
        return taps
    }

    /// Designs a linear-phase FIR kernel (odd length, Type-I) for one edge using
    /// the selected windowed-sinc method.
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
        maxChannelLength: Int,
        window: FIRWindow = .hamming,
        kaiserAttenuationDB: Double = defaultKaiserAttenuationDB,
        rule: FIRDesignRule = .eva,
        tapOverride: Int? = nil
    ) -> [Double] {
        let nyquist = samplingRate / 2
        guard nyquist > 0, cutoff > 0, cutoff < nyquist else { return [] }

        let transition = transitionHz ?? automaticTransitionHz(
            cutoff: cutoff, samplingRate: samplingRate, edge: edge, rule: rule
        )
        let taps = tapOverride ?? firTapCount(
            transition: transition, samplingRate: samplingRate, maxChannelLength: maxChannelLength,
            window: window, kaiserAttenuationDB: kaiserAttenuationDB)

        // A windowed sinc puts its −6 dB point at the design cutoff. Rules that
        // read the requested frequency as the *passband edge* therefore have to
        // move the design cutoff half a transition into the stopband, which is
        // exactly what MNE reports as its separate "−6 dB cutoff frequency".
        // Without this shift EVA's 30 Hz low-pass is −6 dB at 30 Hz where MNE
        // is still in the passband there and −6 dB only at 33.75 Hz.
        let designCutoff: Double
        if rule.requestedFrequencyIsPassbandEdge {
            let shift = transition / 2
            designCutoff = edge == .lowPass
                ? min(cutoff + shift, nyquist * 0.999)
                : max(cutoff - shift, nyquist * 0.0001)
        } else {
            designCutoff = cutoff
        }
        let normalizedCutoff = designCutoff / nyquist
        let beta = window == .kaiser ? kaiserBeta(forAttenuationDB: kaiserAttenuationDB) : nil
        let lowPass = DSP.windowedSincLowPass(
            numtaps: taps, cutoff: normalizedCutoff, gain: 1, kaiserBeta: beta)

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
        maxChannelLength: Int,
        window: FIRWindow = .hamming,
        kaiserAttenuationDB: Double = defaultKaiserAttenuationDB
    ) -> [Double] {
        let nyquist = samplingRate / 2
        guard nyquist > 0, frequency > 0, frequency < nyquist else { return [] }

        let transition = max(transitionHz ?? 1.0, samplingRate / 10_000)
        let taps = firTapCount(
            transition: transition, samplingRate: samplingRate, maxChannelLength: maxChannelLength,
            window: window, kaiserAttenuationDB: kaiserAttenuationDB)
        let beta = window == .kaiser ? kaiserBeta(forAttenuationDB: kaiserAttenuationDB) : nil
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
            let lpUpper = DSP.windowedSincLowPass(numtaps: taps, cutoff: upper, gain: 1, kaiserBeta: beta)
            let lpLower = DSP.windowedSincLowPass(numtaps: taps, cutoff: lower, gain: 1, kaiserBeta: beta)
            for i in 0..<taps { kernel[i] -= lpUpper[i] - lpLower[i] }
        }
        return kernel
    }

    /// Converts requested stopband attenuation into the piecewise Kaiser-window beta
    /// parameter. Higher beta changes the taper; low attenuation uses beta zero.
    nonisolated static func kaiserBeta(forAttenuationDB attenuationDB: Double) -> Double {
        let attenuation = max(attenuationDB, 0)
        if attenuation > 50 {
            return 0.1102 * (attenuation - 8.7)
        }
        if attenuation >= 21 {
            let delta = attenuation - 21
            return 0.5842 * pow(delta, 0.4) + 0.07886 * delta
        }
        return 0
    }

    /// Identifies numerical output failures that an automatic Double retry may address.
    private nonisolated static func isPrecisionFallbackError(_ error: Error) -> Bool {
        switch error {
        case EEGSignalFilterError.nonFiniteOutput(_), EEGSignalFilterError.unstableOutput(_):
            return true
        default:
            return false
        }
    }

    /// Rejects changed output length, nonfinite samples, or extreme growth relative
    /// to the source. Reported channel numbers are one-based for user-facing errors.
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

        // This is a numerical blow-up check, not an artifact detector: allow normal
        // filter transients while rejecting orders-of-magnitude runaway feedback.
        let growthLimit = max(Double(sourceMax) * 10_000, 1.0e9)
        if Double(resultMax) > growthLimit {
            throw EEGSignalFilterError.unstableOutput(channel: channelIndex + 1)
        }
    }

    /// Dispatches one forward/backward biquad operation to Float or Double arithmetic.
    /// An unresolved Auto value takes the Double path here.
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

    /// Pads, filters forward, filters the reversed result, restores order, and trims padding.
    /// Uses Double recurrence state/coefficients but stores each pass’s samples as Float.
    /// Inputs of six samples or fewer are returned unchanged.
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

    /// Float-state counterpart of the forward/backward biquad operation, preserving
    /// input length after trimming reflected boundaries. Very short inputs are unchanged.
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

    /// Subtracts each requested sinusoid in sequence from one channel; very short traces are unchanged.
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

    /// Fits sine/cosine coefficients within half-overlapping windows, accepting fits
    /// only when they explain enough local energy. Hann-weighted overlap averaging
    /// blends corrections before subtracting them at the requested strength.
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

            // Solve the 2×2 least-squares normal equations for cosine/sine amplitudes.
            // cc/ss are basis energies, cs is their cross-product, and yc/ys project the
            // mean-centered data onto each basis. A tiny determinant means an unreliable fit.
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
            // Ignore fits too small relative to the window’s signal energy, avoiding
            // subtraction driven by an insignificant sinusoidal match.
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
        // Normalize overlapping accepted fits by their accumulated taper weights.
        // Uncovered points (including zero-weight endpoints) retain the original sample.
        for index in cleaned.indices where weightSum[index] > 1e-12 {
            cleaned[index] = Float(Double(samples[index]) - strength * correctionSum[index] / weightSum[index])
        }
        return cleaned
    }

    /// Creates a symmetric Hann taper with zero-valued endpoints for overlap blending.
    /// Counts of zero or one use the single weight [1].
    private nonisolated static func hannWindow(count: Int) -> [Double] {
        guard count > 1 else { return [1] }
        return (0..<count).map { index in
            0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1))
        }
    }

    /// Mirrors samples on both ends without repeating the endpoint itself.
    /// The caller must limit count to samples.count−1 before forming these slices.
    private nonisolated static func reflectedPadding(for samples: [Float], count: Int) -> [Float] {
        guard count > 0, samples.count > 1 else {
            return samples
        }

        // These are even reflections of nearby values, not zero padding or a
        // reflection around the endpoint amplitude. Filtering transients occur in the padding.
        let prefix = Array(samples[1...count].reversed())
        let suffixStart = samples.count - count - 1
        let suffix = Array(samples[suffixStart..<(samples.count - 1)].reversed())
        return prefix + samples + suffix
    }

    /// Applies a biquad recurrence with Double coefficients/state and Float output.
    /// x1/x2 are prior input samples; y1/y2 are prior outputs. All state starts at zero.
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

    /// Applies the same biquad recurrence entirely in Float, converting coefficients once.
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

    /// Builds recursive sections using the selected Butterworth or elliptic design.
    /// Converts elliptic sections into the coefficient representation used by this filter.
    nonisolated static func designed(
        design: IIRDesign,
        cutoff: Double,
        samplingRate: Double,
        poles: Int,
        type: FilterType,
        passbandRippleDB: Double,
        stopbandAttenuationDB: Double
    ) -> [BiquadCoefficients] {
        switch design {
        case .butterworth:
            return butterworth(cutoff: cutoff, samplingRate: samplingRate, poles: poles, type: type)
        case .elliptic:
            let edge: EllipticFilterDesign.Edge
            switch type {
            case .lowPass: edge = .lowPass
            case .highPass: edge = .highPass
            }
            return EllipticFilterDesign.sections(
                cutoff: cutoff,
                samplingRate: samplingRate,
                order: poles,
                edge: edge,
                passbandRippleDB: passbandRippleDB,
                stopbandAttenuationDB: stopbandAttenuationDB
            ).map {
                BiquadCoefficients(b0: $0.b0, b1: $0.b1, b2: $0.b2, a1: $0.a1, a2: $0.a2)
            }
        }
    }

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

    /// Designs a normalized second-order low-pass section for cutoff Hz and quality factor Q.
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

    /// Designs a normalized second-order high-pass section; Q controls the pole-pair damping.
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

    /// Designs a notch at the requested frequency; Q controls how narrow the rejected band is.
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

    /// Divides numerator/denominator coefficients by a0 so the recurrence assumes a0 = 1.
    private nonisolated static func normalize(
        b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
    ) -> Self {
        Self(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }
}
