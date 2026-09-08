//
//  TimeFrequencyModels.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Value types for event-related time-frequency (ERSP / ITPC). Kept separate
//  from the engine so the frequency plan and baseline policy can be constructed
//  and reasoned about (and unit-tested) without pulling in the CWT machinery.
//

import Foundation

/// Time-frequency decomposition method.
nonisolated enum TFMethod: String, CaseIterable, Identifiable, Sendable {
    /// Complex Morlet CWT — variable cycles, the default (TF-1).
    case morlet = "Morlet"
    /// Short-time DPSS multitaper — better high-frequency control (TF-2).
    case multitaper = "Multitaper"

    var id: String { rawValue }
}

/// Which trial component supplies the Power map. ITPC is always computed from
/// the original trials because it is itself a phase-consistency measure.
nonisolated enum TFPowerMode: String, CaseIterable, Identifiable, Sendable {
    /// Mean single-trial power — the historical EVA ERSP behavior.
    case total = "Total"
    /// Power of the ERP (the trial-average waveform), retaining only the
    /// phase-locked response.
    case evoked = "Evoked"
    /// Mean power after the condition ERP is removed from every trial.
    case induced = "Induced"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .total: return "Mean single-trial power; includes phase-locked and non-phase-locked activity."
        case .evoked: return "Power of the trial-average ERP; phase-locked activity only."
        case .induced: return "Mean power after removing the condition ERP from each trial."
        }
    }
}

/// How trial-averaged power is expressed relative to a pre-stimulus baseline.
nonisolated enum TFBaselineMethod: String, CaseIterable, Identifiable, Sendable {
    /// `10·log10(power / baseline)` — decibels. The field default.
    case decibel = "dB"
    /// `100·(power − baseline) / baseline` — percent change.
    case percent = "% change"
    /// `(power − baselineMean) / baselineStd`, moments over the baseline window.
    case zscore = "z-score"
    /// `power / baseline` — divisive (ratio).
    case divisive = "divisive"
    /// No normalization — raw `|c|²`.
    case none = "none"

    var id: String { rawValue }
}

/// The set of analysis frequencies plus the per-frequency wavelet width
/// (`nCycles`). Variable cycles are the Cohen-textbook default: low frequencies
/// get frequency resolution (more cycles), high frequencies get time resolution
/// (fewer cycles).
nonisolated struct TFFrequencyPlan: Sendable, Equatable {
    /// Center frequencies (Hz), ascending.
    var frequenciesHz: [Double]
    /// Wavelet width in cycles, one per frequency (same length as `frequenciesHz`).
    var nCycles: [Double]

    /// Log-spaced frequencies with `nCycles` linearly ramped across the band.
    /// - Parameters:
    ///   - minHz/maxHz: band edges (inclusive).
    ///   - count: number of frequency bins.
    ///   - cyclesLow/cyclesHigh: cycles at `minHz` and `maxHz` (linear ramp,
    ///     default 3 → 10).
    static func logSpaced(
        minHz: Double,
        maxHz: Double,
        count: Int,
        cyclesLow: Double = 3.0,
        cyclesHigh: Double = 10.0
    ) -> TFFrequencyPlan {
        precondition(minHz > 0 && maxHz > minHz && count >= 1, "invalid frequency plan")
        let frequencies: [Double] = (0..<count).map { i in
            let t = count == 1 ? 0.0 : Double(i) / Double(count - 1)
            return minHz * pow(maxHz / minHz, t)
        }
        let cycles: [Double] = (0..<count).map { i in
            let t = count == 1 ? 0.0 : Double(i) / Double(count - 1)
            return cyclesLow + (cyclesHigh - cyclesLow) * t
        }
        return TFFrequencyPlan(frequenciesHz: frequencies, nCycles: cycles)
    }

    /// A plan with an explicit frequency list and a single fixed cycle count —
    /// primarily for matching an external reference (e.g. MNE cross-check).
    static func explicit(frequenciesHz: [Double], nCycles: Double) -> TFFrequencyPlan {
        TFFrequencyPlan(
            frequenciesHz: frequenciesHz,
            nCycles: [Double](repeating: nCycles, count: frequenciesHz.count)
        )
    }
}

/// The pre-stimulus window (in epoch sample indices, `0` = epoch start) used to
/// normalize power, and the method applied.
nonisolated struct TFBaselineSpec: Sendable, Equatable {
    var startSample: Int
    var endSample: Int   // inclusive
    var method: TFBaselineMethod

    static func none() -> TFBaselineSpec {
        TFBaselineSpec(startSample: 0, endSample: 0, method: .none)
    }
}

/// The product of an ERSP computation: a baseline-normalized power map plus the
/// raw trial-averaged power it was derived from.
nonisolated struct TimeFrequencyResult: Sendable {
    /// Baseline-normalized power, `ersp[frequencyIndex][timeIndex]`
    /// (frequency ascending). Units depend on `baselineMethod`.
    var ersp: [[Double]]
    /// Raw trial-averaged `|c|²`, same shape, before baseline normalization.
    var meanPower: [[Double]]
    /// Inter-trial phase coherence, `itpc[frequencyIndex][timeIndex]` in
    /// `[0, 1]`. Already a normalized quantity — not baseline-corrected.
    var itpc: [[Double]]
    /// Center frequency (Hz) for each row, ascending.
    var frequenciesHz: [Double]
    /// Wavelet width (cycles) actually used for each row.
    var nCycles: [Double]
    /// Number of trials averaged.
    var trialCount: Int
    /// Samples per second of the analyzed epochs.
    var samplingRate: Double
    /// Baseline method applied to produce `ersp`.
    var baselineMethod: TFBaselineMethod

    var frequencyCount: Int { frequenciesHz.count }
    var timeCount: Int { ersp.first?.count ?? 0 }
}
