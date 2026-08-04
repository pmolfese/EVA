//
//  WoodyAlignmentAnalyzer.swift
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
//  Pure computation for Woody-style adaptive latency correction of single-trial
//  ERP traces. The analyzer works on channel-resolved trial series: callers can
//  provide either one channel or an ROI average, matching the existing Trials
//  analysis path.
//
//  Reference: Woody, C. D. (1967). Characterization of an adaptive filter for
//  the analysis of variable latency neuroelectric signals. Medical & Biological
//  Engineering, 5(6), 539-554. https://doi.org/10.1007/BF02474247
//

import Foundation

nonisolated enum WoodyAlignmentAnalyzer {
    enum AlignmentMode: String, CaseIterable, Identifiable, Sendable {
        case correlation = "Correlation"
        case peak = "Peak"
        /// Cross-correlate each trial against a clean matched-wavelet template
        /// fitted to the dominant deflection in the window, instead of the noisy
        /// evolving average. The template is band-limited, so latency estimates
        /// are less biased by out-of-band noise. The template stays fixed across
        /// iterations.
        case matchedWavelet = "Matched Wavelet"

        var id: String { rawValue }

        /// Whether the mode uses a fixed template (not re-averaged each pass).
        var usesFixedTemplate: Bool { self == .matchedWavelet }
    }

    enum PeakPolarity: String, CaseIterable, Identifiable, Sendable {
        case positive = "Positive"
        case negative = "Negative"
        case either = "Either"

        var id: String { rawValue }
    }

    struct TrialInput: Sendable {
        var sourceTimeSeconds: Double
        var stimulusOffsetSamples: Int
        var samples: [Float]
    }

    struct TrialShift: Identifiable, Sendable {
        var id: Int
        var trialIndex: Int
        var sourceTimeSeconds: Double
        /// Positive values mean the trial waveform was estimated to occur later
        /// than the template and was shifted earlier by this many samples.
        var latencyShiftSamples: Int
        var latencyShiftMs: Double
        var correlation: Double
    }

    struct IterationSummary: Identifiable, Sendable {
        var id: Int { iteration }
        var iteration: Int
        var changedTrialCount: Int
        var maxShiftChangeSamples: Int
        var meanCorrelation: Double
    }

    struct Result: Sendable {
        var shifts: [TrialShift]
        var alignedTrials: [[Float]]
        var initialTemplate: [Float]
        var finalTemplate: [Float]
        var unalignedAverage: [Float]
        var alignedAverage: [Float]
        var iterations: [IterationSummary]
        var converged: Bool
    }

    static func align(
        trials: [TrialInput],
        samplingRate: Double,
        windowStartMs: Double,
        windowEndMs: Double,
        maxLagMs: Double,
        maxIterations: Int,
        convergenceToleranceSamples: Int,
        alignmentMode: AlignmentMode = .correlation,
        peakPolarity: PeakPolarity = .either
    ) -> Result? {
        guard samplingRate > 0,
              windowEndMs > windowStartMs,
              maxLagMs >= 0,
              maxIterations > 0,
              let first = trials.first,
              !first.samples.isEmpty else { return nil }

        let length = first.samples.count
        guard trials.allSatisfy({ $0.samples.count == length }) else { return nil }
        guard let firstWindow = sampleRange(
            startMs: windowStartMs,
            endMs: windowEndMs,
            stimulusOffsetSamples: first.stimulusOffsetSamples,
            samplingRate: samplingRate,
            length: length
        ) else { return nil }

        let maxLagSamples = max(Int((maxLagMs / 1000.0 * samplingRate).rounded()), 0)
        let tolerance = max(convergenceToleranceSamples, 0)
        let unalignedAverage = average(trials.map(\.samples), length: length)
        let initialTemplate: [Float]
        if alignmentMode == .matchedWavelet,
           let matched = MatchedWaveletTemplate.template(
                for: unalignedAverage,
                window: firstWindow,
                polarity: cwtPolarity(for: peakPolarity)
           ) {
            initialTemplate = matched
        } else {
            initialTemplate = unalignedAverage
        }
        var template = initialTemplate
        var previousShifts = [Int](repeating: 0, count: trials.count)
        var currentShifts = previousShifts
        var currentCorrelations = [Double](repeating: 0, count: trials.count)
        var iterations: [IterationSummary] = []
        var alignedTrials = trials.map(\.samples)
        var converged = false

        for iteration in 1...maxIterations {
            var changed = 0
            var maxChange = 0

            for (index, trial) in trials.enumerated() {
                guard let window = sampleRange(
                    startMs: windowStartMs,
                    endMs: windowEndMs,
                    stimulusOffsetSamples: trial.stimulusOffsetSamples,
                    samplingRate: samplingRate,
                    length: length
                ) else { continue }
                let searchWindow = compatibleWindow(firstWindow, trialWindow: window)
                let estimate: (lag: Int, correlation: Double)
                switch alignmentMode {
                case .correlation, .matchedWavelet:
                    estimate = bestLag(
                        trial: trial.samples,
                        template: template,
                        window: searchWindow,
                        maxLagSamples: maxLagSamples
                    )
                case .peak:
                    estimate = peakLag(
                        trial: trial.samples,
                        template: template,
                        window: searchWindow,
                        maxLagSamples: maxLagSamples,
                        polarity: peakPolarity
                    )
                }
                currentShifts[index] = estimate.lag
                currentCorrelations[index] = estimate.correlation
                let delta = abs(estimate.lag - previousShifts[index])
                if delta > tolerance { changed += 1 }
                maxChange = max(maxChange, delta)
            }

            alignedTrials = zip(trials.map(\.samples), currentShifts).map { samples, shift in
                shiftEarlier(samples, by: shift)
            }
            // Matched-wavelet mode keeps the clean template as the alignment
            // target; correlation/peak modes refit the template to the aligned
            // average each pass.
            if !alignmentMode.usesFixedTemplate {
                template = average(alignedTrials, length: length)
            }
            let meanCorrelation = currentCorrelations.isEmpty
                ? 0
                : currentCorrelations.reduce(0, +) / Double(currentCorrelations.count)
            iterations.append(IterationSummary(
                iteration: iteration,
                changedTrialCount: changed,
                maxShiftChangeSamples: maxChange,
                meanCorrelation: meanCorrelation
            ))

            if changed == 0 {
                converged = true
                break
            }
            previousShifts = currentShifts
        }

        let shifts = currentShifts.enumerated().map { index, shift in
            TrialShift(
                id: index,
                trialIndex: index,
                sourceTimeSeconds: trials[index].sourceTimeSeconds,
                latencyShiftSamples: shift,
                latencyShiftMs: Double(shift) / samplingRate * 1000.0,
                correlation: currentCorrelations[index]
            )
        }

        return Result(
            shifts: shifts,
            alignedTrials: alignedTrials,
            initialTemplate: initialTemplate,
            finalTemplate: template,
            unalignedAverage: unalignedAverage,
            alignedAverage: average(alignedTrials, length: length),
            iterations: iterations,
            converged: converged
        )
    }

    private static func cwtPolarity(for polarity: PeakPolarity) -> CWTRidgeDetector.Polarity {
        switch polarity {
        case .positive: return .positive
        case .negative: return .negative
        case .either: return .either
        }
    }

    // MARK: - Windowing

    private static func sampleRange(
        startMs: Double,
        endMs: Double,
        stimulusOffsetSamples: Int,
        samplingRate: Double,
        length: Int
    ) -> Range<Int>? {
        guard length > 0 else { return nil }
        let startSample = stimulusOffsetSamples + Int((startMs / 1000.0 * samplingRate).rounded())
        let endSample = stimulusOffsetSamples + Int((endMs / 1000.0 * samplingRate).rounded())
        let lower = max(min(startSample, endSample), 0)
        let upper = min(max(startSample, endSample), length - 1)
        guard lower <= upper else { return nil }
        return lower..<(upper + 1)
    }

    private static func compatibleWindow(_ firstWindow: Range<Int>, trialWindow: Range<Int>) -> Range<Int> {
        let lower = max(firstWindow.lowerBound, trialWindow.lowerBound)
        let upper = min(firstWindow.upperBound, trialWindow.upperBound)
        return lower < upper ? lower..<upper : trialWindow
    }

    // MARK: - Lag search

    private static func bestLag(
        trial: [Float],
        template: [Float],
        window: Range<Int>,
        maxLagSamples: Int
    ) -> (lag: Int, correlation: Double) {
        var bestLag = 0
        var bestCorrelation = -Double.infinity

        for lag in (-maxLagSamples)...maxLagSamples {
            let correlation = normalizedCorrelation(trial: trial, template: template, window: window, lag: lag)
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        if !bestCorrelation.isFinite {
            return (0, 0)
        }
        return (bestLag, bestCorrelation)
    }

    private static func peakLag(
        trial: [Float],
        template: [Float],
        window: Range<Int>,
        maxLagSamples: Int,
        polarity: PeakPolarity
    ) -> (lag: Int, correlation: Double) {
        guard let templatePeak = peakSample(in: template, window: window, polarity: polarity),
              let trialPeak = peakSample(in: trial, window: window, polarity: polarity) else {
            return bestLag(trial: trial, template: template, window: window, maxLagSamples: maxLagSamples)
        }
        let rawLag = trialPeak - templatePeak
        let lag = min(max(rawLag, -maxLagSamples), maxLagSamples)
        let correlation = normalizedCorrelation(trial: trial, template: template, window: window, lag: lag)
        return (lag, correlation.isFinite ? correlation : 0)
    }

    private static func peakSample(in trace: [Float], window: Range<Int>, polarity: PeakPolarity) -> Int? {
        var bestIndex: Int?
        var bestScore = -Double.infinity
        for index in window where trace.indices.contains(index) {
            let value = Double(trace[index])
            guard value.isFinite else { continue }
            let score: Double
            switch polarity {
            case .positive:
                score = value
            case .negative:
                score = -value
            case .either:
                score = abs(value)
            }
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Correlates `template[i]` with `trial[i + lag]`. Positive lag means the
    /// trial's component is later than the template.
    private static func normalizedCorrelation(
        trial: [Float],
        template: [Float],
        window: Range<Int>,
        lag: Int
    ) -> Double {
        var trialValues: [Double] = []
        var templateValues: [Double] = []
        trialValues.reserveCapacity(window.count)
        templateValues.reserveCapacity(window.count)

        for i in window {
            let j = i + lag
            guard template.indices.contains(i), trial.indices.contains(j) else { continue }
            let x = Double(template[i])
            let y = Double(trial[j])
            guard x.isFinite, y.isFinite else { continue }
            templateValues.append(x)
            trialValues.append(y)
        }

        guard trialValues.count >= 3 else { return -Double.infinity }
        let meanTemplate = templateValues.reduce(0, +) / Double(templateValues.count)
        let meanTrial = trialValues.reduce(0, +) / Double(trialValues.count)
        var numerator = 0.0
        var templateSS = 0.0
        var trialSS = 0.0
        for i in trialValues.indices {
            let a = templateValues[i] - meanTemplate
            let b = trialValues[i] - meanTrial
            numerator += a * b
            templateSS += a * a
            trialSS += b * b
        }
        let denominator = sqrt(templateSS * trialSS)
        guard denominator > 1e-12 else { return -Double.infinity }
        return numerator / denominator
    }

    // MARK: - Trace operations

    /// Positive `shift` moves the waveform earlier: output[i] = input[i + shift].
    static func shiftEarlier(_ samples: [Float], by shift: Int) -> [Float] {
        guard shift != 0, !samples.isEmpty else { return samples }
        var out = [Float](repeating: 0, count: samples.count)
        for i in out.indices {
            let source = i + shift
            if samples.indices.contains(source) {
                out[i] = samples[source]
            }
        }
        return out
    }

    private static func average(_ traces: [[Float]], length: Int) -> [Float] {
        guard !traces.isEmpty, length > 0 else { return [] }
        var sums = [Double](repeating: 0, count: length)
        var counts = [Int](repeating: 0, count: length)
        for trace in traces where trace.count == length {
            for i in trace.indices {
                let value = Double(trace[i])
                guard value.isFinite else { continue }
                sums[i] += value
                counts[i] += 1
            }
        }
        return sums.indices.map { i in
            counts[i] > 0 ? Float(sums[i] / Double(counts[i])) : 0
        }
    }
}
