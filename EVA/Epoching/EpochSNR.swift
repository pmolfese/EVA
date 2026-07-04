//
//  EpochSNR.swift
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
//  Signal-to-noise metrics for an averaged ERP, used to rank each file's
//  contribution to a grand average and to drive inverse-variance weighting and
//  the butterfly noise band. See `RecordingCombiner`.
//

import Foundation

nonisolated struct SNRMetrics: Sendable {
    var trialCount: Int = 0
    /// Predicted relative SNR from count alone (1/√N ⇒ we report √N as the gain).
    var rootN: Double = 0
    /// Empirical noise amplitude from plus-minus (odd/even sign-flipped) averaging.
    var plusMinusNoise: Double?
    /// SNR = RMS(average) / RMS(plus-minus residual).
    var plusMinusSNR: Double?
    /// Baseline-window RMS (pure-noise estimate) vs. response-window peak.
    var baselineNoise: Double?
    var baselineSNR: Double?
    /// Bootstrap standard error of the mean-amplitude measure (lower = better).
    var standardizedMeasurementError: Double?
    /// Split-half reliability (Spearman-Brown corrected), −1…1.
    var splitHalfReliability: Double?
    /// GFP(average) / GFP(plus-minus residual).
    var gfpSNR: Double?
    /// Per-sample noise amplitude curve (RMS across channels of the ± residual),
    /// used to shade the butterfly plot. Empty when unavailable.
    var noiseCurve: [Float] = []

    /// Weight for inverse-variance combination: 1 / noise². Falls back to trial
    /// count when no empirical noise estimate exists.
    var inverseVarianceWeight: Double {
        if let noise = plusMinusNoise ?? baselineNoise, noise > 1e-9 {
            return 1.0 / (noise * noise)
        }
        return Double(max(trialCount, 1))
    }
}

nonisolated enum EpochSNR {
    /// Computes all metrics from a category's single-trial epochs.
    ///
    /// - Parameters:
    ///   - trials: trial × channel × sample.
    ///   - baselineSampleCount: leading samples treated as the pre-stimulus
    ///     baseline (pure noise) for the baseline-RMS metric. 0 to skip.
    static func metrics(
        trials: [[[Float]]],
        baselineSampleCount: Int
    ) -> SNRMetrics {
        guard let first = trials.first, let firstCh = first.first, !firstCh.isEmpty else {
            return SNRMetrics()
        }
        let nTrials = trials.count
        let nCh = first.count
        let nSamp = firstCh.count

        var m = SNRMetrics()
        m.trialCount = nTrials
        m.rootN = sqrt(Double(nTrials))

        // Average across trials.
        let average = averageTrials(trials, channels: nCh, samples: nSamp)

        // Plus-minus (Schimmel) residual: alternate the sign of each trial.
        if nTrials >= 2 {
            var residual = [[Float]](repeating: [Float](repeating: 0, count: nSamp), count: nCh)
            for (t, trial) in trials.enumerated() {
                let sign: Float = (t % 2 == 0) ? 1 : -1
                for c in 0..<nCh {
                    let ch = trial[c]
                    for s in 0..<nSamp { residual[c][s] += sign * ch[s] }
                }
            }
            let invN = 1.0 / Float(nTrials)
            for c in 0..<nCh { for s in 0..<nSamp { residual[c][s] *= invN } }

            m.plusMinusNoise = rms(residual)
            let sig = rms(average)
            if let noise = m.plusMinusNoise, noise > 1e-12 {
                m.plusMinusSNR = sig / noise
            }
            m.noiseCurve = perSampleRMS(residual)
            m.gfpSNR = gfpRatio(signal: average, noise: residual)
        }

        // Baseline vs. response RMS.
        if baselineSampleCount > 1, baselineSampleCount < nSamp {
            let baselineNoise = rms(average, sampleRange: 0..<baselineSampleCount)
            let responsePeak = peakAbs(average, sampleRange: baselineSampleCount..<nSamp)
            m.baselineNoise = baselineNoise
            if baselineNoise > 1e-12 {
                m.baselineSNR = responsePeak / baselineNoise
            }
        }

        // Standardized Measurement Error: bootstrap SD of the mean amplitude in
        // the response window, averaged over channels.
        if nTrials >= 4 {
            m.standardizedMeasurementError = standardizedMeasurementError(
                trials: trials, nCh: nCh, nSamp: nSamp,
                window: (baselineSampleCount < nSamp ? baselineSampleCount : 0)..<nSamp
            )
        }

        // Split-half reliability (Spearman-Brown corrected).
        if nTrials >= 4 {
            m.splitHalfReliability = splitHalfReliability(trials: trials, nCh: nCh, nSamp: nSamp)
        }

        return m
    }

    /// Metrics for an already-averaged category (only count- and baseline-based
    /// metrics are available without single trials).
    static func metricsForAveraged(
        average: [[Float]],
        trialCount: Int,
        baselineSampleCount: Int
    ) -> SNRMetrics {
        var m = SNRMetrics()
        m.trialCount = trialCount
        m.rootN = sqrt(Double(max(trialCount, 0)))
        guard let firstCh = average.first, !firstCh.isEmpty else { return m }
        let nSamp = firstCh.count
        if baselineSampleCount > 1, baselineSampleCount < nSamp {
            let baselineNoise = rms(average, sampleRange: 0..<baselineSampleCount)
            let responsePeak = peakAbs(average, sampleRange: baselineSampleCount..<nSamp)
            m.baselineNoise = baselineNoise
            if baselineNoise > 1e-12 { m.baselineSNR = responsePeak / baselineNoise }
        }
        return m
    }

    // MARK: - Helpers

    static func averageTrials(_ trials: [[[Float]]], channels nCh: Int, samples nSamp: Int) -> [[Float]] {
        var avg = [[Float]](repeating: [Float](repeating: 0, count: nSamp), count: nCh)
        guard !trials.isEmpty else { return avg }
        for trial in trials {
            for c in 0..<nCh {
                let ch = trial[c]
                for s in 0..<nSamp { avg[c][s] += ch[s] }
            }
        }
        let invN = 1.0 / Float(trials.count)
        for c in 0..<nCh { for s in 0..<nSamp { avg[c][s] *= invN } }
        return avg
    }

    private static func rms(_ matrix: [[Float]]) -> Double {
        var sum = 0.0
        var count = 0
        for ch in matrix { for v in ch { sum += Double(v) * Double(v); count += 1 } }
        return count > 0 ? sqrt(sum / Double(count)) : 0
    }

    private static func rms(_ matrix: [[Float]], sampleRange: Range<Int>) -> Double {
        var sum = 0.0
        var count = 0
        for ch in matrix {
            for s in sampleRange where s < ch.count {
                sum += Double(ch[s]) * Double(ch[s]); count += 1
            }
        }
        return count > 0 ? sqrt(sum / Double(count)) : 0
    }

    private static func peakAbs(_ matrix: [[Float]], sampleRange: Range<Int>) -> Double {
        var peak = 0.0
        for ch in matrix {
            for s in sampleRange where s < ch.count {
                peak = max(peak, abs(Double(ch[s])))
            }
        }
        return peak
    }

    private static func perSampleRMS(_ matrix: [[Float]]) -> [Float] {
        guard let nSamp = matrix.first?.count, nSamp > 0 else { return [] }
        var out = [Float](repeating: 0, count: nSamp)
        for s in 0..<nSamp {
            var sum: Float = 0
            for ch in matrix { sum += ch[s] * ch[s] }
            out[s] = (matrix.isEmpty ? 0 : (sum / Float(matrix.count)).squareRoot())
        }
        return out
    }

    private static func gfpRatio(signal: [[Float]], noise: [[Float]]) -> Double {
        let s = perSampleRMS(signal).reduce(0.0) { $0 + Double($1) }
        let n = perSampleRMS(noise).reduce(0.0) { $0 + Double($1) }
        return n > 1e-12 ? s / n : 0
    }

    private static func standardizedMeasurementError(
        trials: [[[Float]]], nCh: Int, nSamp: Int, window: Range<Int>
    ) -> Double {
        let iterations = 200
        let n = trials.count
        guard n >= 2, !window.isEmpty else { return 0 }
        var rng = SystemRandomNumberGenerator()
        var estimates = [Double]()
        estimates.reserveCapacity(iterations)
        for _ in 0..<iterations {
            // Bootstrap resample trial indices with replacement.
            var meanAmp = 0.0
            for c in 0..<nCh {
                var acc = 0.0
                for _ in 0..<n {
                    let t = Int.random(in: 0..<n, using: &rng)
                    let ch = trials[t][c]
                    var w = 0.0
                    for s in window where s < ch.count { w += Double(ch[s]) }
                    acc += w / Double(window.count)
                }
                meanAmp += acc / Double(n)
            }
            estimates.append(meanAmp / Double(nCh))
        }
        let mean = estimates.reduce(0, +) / Double(estimates.count)
        let variance = estimates.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(estimates.count)
        return sqrt(variance)
    }

    private static func splitHalfReliability(trials: [[[Float]]], nCh: Int, nSamp: Int) -> Double {
        let n = trials.count
        let halfA = stride(from: 0, to: n, by: 2).map { trials[$0] }
        let halfB = stride(from: 1, to: n, by: 2).map { trials[$0] }
        guard !halfA.isEmpty, !halfB.isEmpty else { return 0 }
        let avgA = averageTrials(halfA, channels: nCh, samples: nSamp)
        let avgB = averageTrials(halfB, channels: nCh, samples: nSamp)

        // Pearson r over all channel·sample points.
        var xs = [Double](); var ys = [Double]()
        for c in 0..<nCh { for s in 0..<nSamp { xs.append(Double(avgA[c][s])); ys.append(Double(avgB[c][s])) } }
        let r = pearson(xs, ys)
        // Spearman-Brown correction for full-length reliability.
        return (2 * r) / (1 + r)
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        guard n > 1 else { return 0 }
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        let denom = (sxx * syy).squareRoot()
        return denom > 1e-12 ? sxy / denom : 0
    }
}
