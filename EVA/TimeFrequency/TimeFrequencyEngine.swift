//
//  TimeFrequencyEngine.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Event-related spectral perturbation (ERSP): per-trial complex Morlet CWT,
//  averaged as `|c|²` over trials, then baseline-normalized. This is the
//  epoch-level frequency-lens counterpart to the ERP average — same epoch
//  selection, viewed through the wavelet.
//
//  The trial-averaged power here equals MNE's `tfr_array_morlet(..,
//  output='avg_power')` and the ITPC equals `output='itc'` for the Morlet path
//  (no taper weighting); the validation gate cross-checks exactly those. The
//  multitaper path is a later TF-2 step and reuses this trial-stack aggregation.
//

import Foundation

nonisolated enum TimeFrequencyEngine {

    /// Trial-averaged power and inter-trial phase coherence for one channel,
    /// computed in a **single** per-trial complex CWT pass (each trial is
    /// convolved once; both maps fall out of the same coefficients).
    ///
    /// - `meanPower[freq][time]` = mean over trials of `|c|²` — an unbiased power
    ///   estimate, unlike squaring a real-only CWT.
    /// - `itpc[freq][time]` = `|mean over trials of (c / |c|)|` — inter-trial
    ///   phase coherence in `[0, 1]`, 1 = perfectly phase-locked across trials.
    ///
    /// `trials` is a stack of equal-length single-channel epochs (trial × time),
    /// already segmented and baseline-corrected upstream if desired.
    static func decompose(
        trials: [[Double]],
        samplingRate: Double,
        plan: TFFrequencyPlan,
        method: TFMethod = .morlet,
        timeBandwidth: Double = 4.0
    ) -> (meanPower: [[Double]], itpc: [[Double]]) {
        guard !trials.isEmpty, let n = trials.first?.count, n > 0,
              samplingRate > 0, !plan.frequenciesHz.isEmpty else { return ([], []) }

        var meanPower = [[Double]](repeating: [], count: plan.frequenciesHz.count)
        var itpc = [[Double]](repeating: [], count: plan.frequenciesHz.count)

        for fi in plan.frequenciesHz.indices {
            let (power, phase): ([Double], [Double])
            switch method {
            case .morlet:
                let kernel = ComplexMorlet.kernel(
                    frequencyHz: plan.frequenciesHz[fi],
                    nCycles: plan.nCycles[fi],
                    samplingRate: samplingRate
                )
                (power, phase) = morletBin(trials: trials, kernel: kernel, n: n)
            case .multitaper:
                (power, phase) = multitaperBin(
                    trials: trials, n: n, samplingRate: samplingRate,
                    frequencyHz: plan.frequenciesHz[fi], nCycles: plan.nCycles[fi],
                    timeBandwidth: timeBandwidth
                )
            }
            meanPower[fi] = power
            itpc[fi] = phase
        }
        return (meanPower, itpc)
    }

    /// Single Morlet wavelet: mean `|c|²` and ITPC over trials.
    private static func morletBin(trials: [[Double]], kernel: ComplexMorlet.Kernel, n: Int) -> (power: [Double], itpc: [Double]) {
        let trialCount = Double(trials.count)
        var power = [Double](repeating: 0, count: n)
        var phaseRe = [Double](repeating: 0, count: n)
        var phaseIm = [Double](repeating: 0, count: n)
        for trial in trials {
            let (re, im) = ComplexMorlet.convolveSame(signal: trial, kernel: kernel)
            let count = min(n, re.count)
            for t in 0..<count {
                let magnitudeSq = re[t] * re[t] + im[t] * im[t]
                power[t] += magnitudeSq
                let magnitude = magnitudeSq.squareRoot()
                if magnitude > 0 {
                    phaseRe[t] += re[t] / magnitude
                    phaseIm[t] += im[t] / magnitude
                }
            }
        }
        var itpc = [Double](repeating: 0, count: n)
        for t in 0..<n {
            power[t] /= trialCount
            let meanRe = phaseRe[t] / trialCount
            let meanIm = phaseIm[t] / trialCount
            itpc[t] = (meanRe * meanRe + meanIm * meanIm).squareRoot()
        }
        return (power, itpc)
    }

    /// DPSS multitaper for one frequency, combined per MNE `tfr_array_multitaper`:
    /// power = `2·Σ_m conc_m·mean_trials|c_m|² / Σ_m conc_m`; ITC = `Σ_m
    /// |Σ_trials c_m/|c_m|| / n_trials` (per-taper phase-locking, summed).
    private static func multitaperBin(
        trials: [[Double]], n: Int, samplingRate: Double,
        frequencyHz: Double, nCycles: Double, timeBandwidth: Double
    ) -> (power: [Double], itpc: [Double]) {
        let (kernels, concentrations) = Multitaper.wavelets(
            frequencyHz: frequencyHz, nCycles: nCycles, samplingRate: samplingRate,
            timeBandwidth: timeBandwidth
        )
        guard !kernels.isEmpty else { return ([Double](repeating: 0, count: n), [Double](repeating: 0, count: n)) }

        let trialCount = Double(trials.count)
        let concentrationSum = concentrations.reduce(0, +)
        var power = [Double](repeating: 0, count: n)     // Σ_m conc_m·Σ_trials|c|²
        var itpc = [Double](repeating: 0, count: n)      // Σ_m |plf_m|

        for (m, kernel) in kernels.enumerated() {
            let conc = concentrations[m]
            var phaseRe = [Double](repeating: 0, count: n)
            var phaseIm = [Double](repeating: 0, count: n)
            for trial in trials {
                let (re, im) = ComplexMorlet.convolveSame(signal: trial, kernel: kernel)
                let count = min(n, re.count)
                for t in 0..<count {
                    let magnitudeSq = re[t] * re[t] + im[t] * im[t]
                    power[t] += conc * magnitudeSq
                    let magnitude = magnitudeSq.squareRoot()
                    if magnitude > 0 {
                        phaseRe[t] += re[t] / magnitude
                        phaseIm[t] += im[t] / magnitude
                    }
                }
            }
            for t in 0..<n {
                itpc[t] += (phaseRe[t] * phaseRe[t] + phaseIm[t] * phaseIm[t]).squareRoot()
            }
        }

        let powerScale = concentrationSum > 0 ? 2.0 / concentrationSum : 0.0
        for t in 0..<n {
            power[t] = power[t] / trialCount * powerScale
            itpc[t] /= trialCount
        }
        return (power, itpc)
    }

    /// Trial-averaged `|c|²` for one channel — a thin wrapper over `decompose`
    /// for callers that only need power.
    static func meanPower(
        trials: [[Double]],
        samplingRate: Double,
        plan: TFFrequencyPlan
    ) -> [[Double]] {
        decompose(trials: trials, samplingRate: samplingRate, plan: plan).meanPower
    }

    /// Full ERSP + ITPC: single decomposition pass, power baseline-normalized per
    /// the spec. ITPC is returned raw (it is already a normalized `[0, 1]`
    /// quantity and is not baseline-corrected).
    static func ersp(
        trials: [[Double]],
        samplingRate: Double,
        plan: TFFrequencyPlan,
        baseline: TFBaselineSpec,
        method: TFMethod = .morlet,
        timeBandwidth: Double = 4.0,
        usesGPU: Bool = false
    ) -> TimeFrequencyResult? {
        let power: [[Double]]
        let itpc: [[Double]]
        if usesGPU, method == .morlet,
           let gpu = TimeFrequencyMetalBackend.shared?.decompose(trials: trials, samplingRate: samplingRate, plan: plan) {
            power = gpu.meanPower
            itpc = gpu.itpc
        } else {
            (power, itpc) = decompose(
                trials: trials, samplingRate: samplingRate, plan: plan,
                method: method, timeBandwidth: timeBandwidth
            )
        }
        guard !power.isEmpty else { return nil }

        let normalized = normalize(power: power, baseline: baseline)
        return TimeFrequencyResult(
            ersp: normalized,
            meanPower: power,
            itpc: itpc,
            frequenciesHz: plan.frequenciesHz,
            nCycles: plan.nCycles,
            trialCount: trials.count,
            samplingRate: samplingRate,
            baselineMethod: baseline.method
        )
    }

    /// Applies the baseline policy to a trial-averaged power map.
    ///
    /// The baseline for each frequency row is the mean power over the baseline
    /// window; z-score additionally uses that window's standard deviation.
    static func normalize(power: [[Double]], baseline: TFBaselineSpec) -> [[Double]] {
        guard baseline.method != .none else { return power }
        guard let n = power.first?.count, n > 0 else { return power }

        let lo = max(0, min(baseline.startSample, n - 1))
        let hi = max(lo, min(baseline.endSample, n - 1))
        let windowCount = Double(hi - lo + 1)

        return power.map { row -> [Double] in
            var mean = 0.0
            for t in lo...hi { mean += row[t] }
            mean /= windowCount

            switch baseline.method {
            case .none:
                return row
            case .decibel:
                let ref = mean > 0 ? mean : Double.leastNormalMagnitude
                return row.map { 10.0 * log10(max($0, Double.leastNormalMagnitude) / ref) }
            case .percent:
                let ref = mean != 0 ? mean : Double.leastNormalMagnitude
                return row.map { 100.0 * ($0 - mean) / ref }
            case .divisive:
                let ref = mean != 0 ? mean : Double.leastNormalMagnitude
                return row.map { $0 / ref }
            case .zscore:
                var variance = 0.0
                for t in lo...hi {
                    let d = row[t] - mean
                    variance += d * d
                }
                variance /= windowCount
                let std = variance > 0 ? variance.squareRoot() : Double.leastNormalMagnitude
                return row.map { ($0 - mean) / std }
            }
        }
    }
}
