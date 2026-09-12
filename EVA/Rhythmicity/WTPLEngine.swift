//
//  WTPLEngine.swift
//  EVA
//
//  Shared, double-precision Within-Trial Phase Locking implementation used by
//  Rhythmicity Explorer and the optional Time-Frequency shortcut.
//  Method reference: Karvat et al. (2026), Nature Communications, 17, 7024.
//  https://doi.org/10.1038/s41467-026-73553-8
//

import Foundation

nonisolated enum WTPLEngine {
    static let methodVersion = "wtpl-paper-equation-2026-v1"

    static func analyze(
        trials: [[Double]],
        samplingRate: Double,
        plan: TFFrequencyPlan,
        lagCycles: [Double],
        baseline: WTPLBaselineSpec?,
        eventSampleIndex: Int = 0,
        coefficientProvider: any ComplexCoefficientProvider,
        edgePolicy: RhythmicityEdgePolicy = .validOnly,
        retainPerTrial: Bool,
        cancellation: RhythmicityCancellation = RhythmicityCancellation(),
        progress: (@Sendable (RhythmicityProgress) -> Void)? = nil
    ) throws -> WTPLResult {
        let sampleCount = try validate(
            trials: trials,
            samplingRate: samplingRate,
            plan: plan,
            lagCycles: lagCycles,
            baseline: baseline,
            eventSampleIndex: eventSampleIndex
        )
        let frequencyCount = plan.frequenciesHz.count
        var means = matrix(rows: frequencyCount, columns: sampleCount, value: 0)
        var moments = matrix(rows: frequencyCount, columns: sampleCount, value: 0)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: sampleCount), count: frequencyCount)
        var retained = retainPerTrial
            ? [[ [Double] ]](repeating: matrix(rows: frequencyCount, columns: sampleCount, value: .nan), count: trials.count)
            : nil
        let totalTiles = max(trials.count * frequencyCount, 1)
        var completedTiles = 0

        progress?(RhythmicityProgress(
            fractionComplete: 0, phase: .validating, channelIndex: nil,
            frequencyHz: nil, completedTiles: 0, totalTiles: totalTiles
        ))

        for trialIndex in trials.indices {
            try cancellation.check()
            for frequencyIndex in plan.frequenciesHz.indices {
                try cancellation.check()
                let frequency = plan.frequenciesHz[frequencyIndex]
                let tile = try coefficientProvider.coefficients(
                    signal: trials[trialIndex],
                    samplingRate: samplingRate,
                    frequencyHz: frequency,
                    widthCycles: plan.nCycles[frequencyIndex],
                    edgePolicy: edgePolicy,
                    cancellation: cancellation
                )
                guard tile.real.count == sampleCount, tile.imaginary.count == sampleCount else {
                    throw WTPLAnalysisError.coefficientShapeMismatch(
                        expected: sampleCount, real: tile.real.count, imaginary: tile.imaginary.count
                    )
                }

                let row = singleTrialValues(
                    tile: tile,
                    frequencyHz: frequency,
                    samplingRate: samplingRate,
                    lagCycles: lagCycles
                )
                for time in row.indices where row[time].isFinite {
                    let value = row[time]
                    counts[frequencyIndex][time] += 1
                    let count = Double(counts[frequencyIndex][time])
                    let delta = value - means[frequencyIndex][time]
                    means[frequencyIndex][time] += delta / count
                    moments[frequencyIndex][time] += delta * (value - means[frequencyIndex][time])
                }
                retained?[trialIndex][frequencyIndex] = row
                completedTiles += 1
                progress?(RhythmicityProgress(
                    fractionComplete: Double(completedTiles) / Double(totalTiles),
                    phase: .transforming,
                    channelIndex: nil,
                    frequencyHz: frequency,
                    completedTiles: completedTiles,
                    totalTiles: totalTiles
                ))
            }
        }

        var variance = matrix(rows: frequencyCount, columns: sampleCount, value: .nan)
        var warnings: [RhythmicityWarning] = []
        for frequency in 0..<frequencyCount {
            var hasValue = false
            for time in 0..<sampleCount {
                let count = counts[frequency][time]
                if count == 0 {
                    means[frequency][time] = .nan
                } else {
                    hasValue = true
                    variance[frequency][time] = count > 1
                        ? moments[frequency][time] / Double(count - 1) : .nan
                }
            }
            if !hasValue {
                let warning = RhythmicityWarning.wtplNoValidSamples(
                    frequencyHz: plan.frequenciesHz[frequency]
                )
                warnings.append(warning)
            }
        }

        var deltaWTPL: [[Double]]?
        var baselineWindowMs: ClosedRange<Double>?
        if let baseline {
            var delta = matrix(rows: frequencyCount, columns: sampleCount, value: .nan)
            for frequency in 0..<frequencyCount {
                let validBaseline = (baseline.startSample...baseline.endSample)
                    .map { means[frequency][$0] }
                    .filter(\.isFinite)
                guard !validBaseline.isEmpty else {
                    let warning = RhythmicityWarning.wtplBaselineUnavailable(
                        frequencyHz: plan.frequenciesHz[frequency]
                    )
                    warnings.append(warning)
                    continue
                }
                let reference = validBaseline.reduce(0, +) / Double(validBaseline.count)
                for time in 0..<sampleCount where means[frequency][time].isFinite {
                    delta[frequency][time] = means[frequency][time] - reference
                }
            }
            deltaWTPL = delta
            baselineWindowMs = (
                Double(baseline.startSample - eventSampleIndex) / samplingRate * 1_000
            )...(
                Double(baseline.endSample - eventSampleIndex) / samplingRate * 1_000
            )
        }

        let times = (0..<sampleCount).map {
            Double($0 - eventSampleIndex) / samplingRate * 1_000
        }
        progress?(RhythmicityProgress(
            fractionComplete: 1, phase: .finished, channelIndex: nil,
            frequencyHz: nil, completedTiles: totalTiles, totalTiles: totalTiles
        ))
        return WTPLResult(
            meanWTPL: means,
            deltaWTPL: deltaWTPL,
            perTrialWTPL: retained,
            frequenciesHz: plan.frequenciesHz,
            timesMs: times,
            validTrialCounts: counts,
            varianceWTPL: variance,
            trialCount: trials.count,
            baselineWindowMs: baselineWindowMs,
            lagCycles: lagCycles,
            warnings: warnings
        )
    }

    /// Shared single-trial reduction used by WTPL analyses and the burst
    /// detector. Keeping this here prevents the burst workflow from acquiring
    /// a subtly different signed-lag or interpolation convention.
    static func singleTrialValues(
        tile: ComplexCoefficientTile,
        frequencyHz: Double,
        samplingRate: Double,
        lagCycles: [Double]
    ) -> [Double] {
        var result = [Double](repeating: .nan, count: tile.real.count)
        for time in tile.real.indices where tile.validSampleRange.contains(time) {
            let centerMagnitude = hypot(tile.real[time], tile.imaginary[time])
            guard centerMagnitude.isFinite, centerMagnitude > Double.leastNormalMagnitude else { continue }
            let centerReal = tile.real[time] / centerMagnitude
            let centerImaginary = tile.imaginary[time] / centerMagnitude
            var relationReal = 0.0
            var relationImaginary = 0.0
            var isValid = true

            for lag in lagCycles {
                let position = Double(time) + lag / frequencyHz * samplingRate
                guard let lagged = interpolate(tile: tile, position: position) else {
                    isValid = false
                    break
                }
                let magnitude = hypot(lagged.real, lagged.imaginary)
                guard magnitude.isFinite, magnitude > Double.leastNormalMagnitude else {
                    isValid = false
                    break
                }
                let lagReal = lagged.real / magnitude
                let lagImaginary = lagged.imaginary / magnitude
                relationReal += centerReal * lagReal + centerImaginary * lagImaginary
                relationImaginary += centerImaginary * lagReal - centerReal * lagImaginary
            }
            guard isValid else { continue }
            let divisor = Double(lagCycles.count)
            result[time] = min(max(hypot(relationReal / divisor, relationImaginary / divisor), 0), 1)
        }
        return result
    }

    private static func interpolate(
        tile: ComplexCoefficientTile,
        position: Double
    ) -> (real: Double, imaginary: Double)? {
        guard position.isFinite else { return nil }
        let lower = Int(floor(position))
        let fraction = position - Double(lower)
        guard tile.validSampleRange.contains(lower) else { return nil }
        if fraction <= 1e-12 {
            return (tile.real[lower], tile.imaginary[lower])
        }
        let upper = lower + 1
        guard tile.validSampleRange.contains(upper) else { return nil }
        return (
            tile.real[lower] + fraction * (tile.real[upper] - tile.real[lower]),
            tile.imaginary[lower] + fraction * (tile.imaginary[upper] - tile.imaginary[lower])
        )
    }

    private static func validate(
        trials: [[Double]],
        samplingRate: Double,
        plan: TFFrequencyPlan,
        lagCycles: [Double],
        baseline: WTPLBaselineSpec?,
        eventSampleIndex: Int
    ) throws -> Int {
        guard !trials.isEmpty else { throw WTPLAnalysisError.noTrials }
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw WTPLAnalysisError.invalidSamplingRate(samplingRate)
        }
        let sampleCount = trials[0].count
        guard sampleCount > 0 else { throw WTPLAnalysisError.emptyTrial(index: 0) }
        for index in trials.indices {
            guard !trials[index].isEmpty else { throw WTPLAnalysisError.emptyTrial(index: index) }
            guard trials[index].count == sampleCount else {
                throw WTPLAnalysisError.mismatchedTrialLength(
                    index: index, expected: sampleCount, actual: trials[index].count
                )
            }
        }
        guard (0..<sampleCount).contains(eventSampleIndex) else {
            throw WTPLAnalysisError.invalidEventSample(index: eventSampleIndex, sampleCount: sampleCount)
        }
        guard !plan.frequenciesHz.isEmpty,
              plan.frequenciesHz.count == plan.nCycles.count,
              zip(plan.frequenciesHz, plan.nCycles).allSatisfy({
                  $0.0.isFinite && $0.0 > 0 && $0.1.isFinite && $0.1 > 0
              }),
              zip(plan.frequenciesHz, plan.frequenciesHz.dropFirst()).allSatisfy(<)
        else { throw WTPLAnalysisError.invalidFrequencyPlan }
        let nyquist = samplingRate / 2
        for (index, frequency) in plan.frequenciesHz.enumerated() where frequency >= nyquist {
            throw WTPLAnalysisError.frequencyAtOrAboveNyquist(index: index, value: frequency, nyquist: nyquist)
        }
        guard !lagCycles.isEmpty else { throw WTPLAnalysisError.invalidLag(index: 0, value: .nan) }
        for (index, lag) in lagCycles.enumerated() where !lag.isFinite || lag == 0 {
            throw WTPLAnalysisError.invalidLag(index: index, value: lag)
        }
        if let baseline,
           baseline.startSample < 0 || baseline.endSample < baseline.startSample || baseline.endSample >= sampleCount {
            throw WTPLAnalysisError.invalidBaseline(
                start: baseline.startSample, end: baseline.endSample, sampleCount: sampleCount
            )
        }
        return sampleCount
    }

    private static func matrix(rows: Int, columns: Int, value: Double) -> [[Double]] {
        [[Double]](repeating: [Double](repeating: value, count: columns), count: rows)
    }
}
