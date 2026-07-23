//
//  RIDEAnalyzer.swift
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
//  Pure computation for a first Swift RIDE implementation. It separates
//  stimulus-locked S, latency-variable C, and optional response-locked R
//  components from channel-resolved single-trial ERP traces.
//

import Foundation

nonisolated enum RIDEAnalyzer {
    enum Component: String, CaseIterable, Identifiable, Sendable {
        case stimulus = "S"
        case central = "C"
        case response = "R"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .stimulus: "S"
            case .central: "C"
            case .response: "R"
            }
        }
    }

    enum LatencySource: String, CaseIterable, Identifiable, Sendable {
        case stimulusLocked = "Stimulus-locked"
        case estimated = "Estimate from data"
        case fixed = "Fixed latency"

        var id: String { rawValue }
    }

    enum CentralLatencySearchMode: String, CaseIterable, Identifiable, Sendable {
        case mostProbable = "Most probable"
        case largestPeak = "Largest peak"

        var id: String { rawValue }
    }

    struct ComponentWindow: Sendable {
        var startMs: Double
        var endMs: Double
    }

    struct TrialInput: Sendable {
        var sourceTimeSeconds: Double
        var stimulusOffsetSamples: Int
        var responseLatencyMs: Double?
        var samples: [Float]
    }

    struct Configuration: Sendable {
        var includesStimulusComponent = true
        var includesCentralComponent = true
        var includesResponseComponent = false
        var stimulusWindow = ComponentWindow(startMs: -100, endMs: 100)
        var centralWindow: ComponentWindow
        var responseWindow = ComponentWindow(startMs: 300, endMs: 700)
        var stimulusLatencySource = LatencySource.stimulusLocked
        var centralLatencySource = LatencySource.estimated
        var responseLatencySource = LatencySource.fixed
        var centralMaxLagMs = 100.0
        var fixedStimulusLatencyMs = 0.0
        var fixedCentralLatencyMs = 0.0
        var defaultResponseLatencyMs = 500.0
        var centralLatencySearchMode = CentralLatencySearchMode.mostProbable
        var maxIterations = 6
        var convergenceToleranceSamples = 0
    }

    struct ComponentWaveform: Identifiable, Sendable {
        var id: Component { component }
        var component: Component
        /// Component in its own locking frame: S stimulus-locked, C latency-locked,
        /// R response-locked.
        var lockedTemplate: [Float]
        /// Component averaged back in the stimulus-locked epoch frame.
        var stimulusLockedAverage: [Float]
    }

    struct TrialLatency: Identifiable, Sendable {
        var id: Int
        var trialIndex: Int
        var sourceTimeSeconds: Double
        var centralLatencyShiftSamples: Int?
        var centralLatencyShiftMs: Double?
        var centralCorrelation: Double?
        var responseLatencySamples: Int?
        var responseLatencyMs: Double?
    }

    struct IterationSummary: Identifiable, Sendable {
        var id: Int { iteration }
        var iteration: Int
        var changedCentralLatencyCount: Int
        var maxCentralLatencyChangeSamples: Int
        var meanCentralCorrelation: Double
        var unchangedCentralLatencyFraction: Double
        var improvedCentralCorrelationCount: Int
    }

    struct Result: Sendable {
        var components: [ComponentWaveform]
        var trialLatencies: [TrialLatency]
        var erpAverage: [Float]
        var centralAlignedAverage: [Float]?
        var responseAlignedAverage: [Float]?
        var reconstructionAverage: [Float]
        var residualAverage: [Float]
        var reconstructedTrials: [[Float]]
        var residualTrials: [[Float]]
        var iterations: [IterationSummary]
        var converged: Bool

        func component(_ component: Component) -> ComponentWaveform? {
            components.first { $0.component == component }
        }
    }

    static func decompose(
        trials: [TrialInput],
        samplingRate: Double,
        configuration: Configuration
    ) -> Result? {
        guard samplingRate > 0,
              configuration.maxIterations > 0,
              configuration.centralMaxLagMs >= 0,
              configuration.includesStimulusComponent
                || configuration.includesCentralComponent
                || configuration.includesResponseComponent,
              let first = trials.first,
              !first.samples.isEmpty else { return nil }

        let length = first.samples.count
        guard trials.allSatisfy({ $0.samples.count == length }) else { return nil }

        let responseLatencies = trials.map { trial -> Int? in
            guard configuration.includesResponseComponent else { return nil }
            let latencyMs: Double
            switch configuration.responseLatencySource {
            case .stimulusLocked:
                latencyMs = 0
            case .estimated, .fixed:
                latencyMs = trial.responseLatencyMs ?? configuration.defaultResponseLatencyMs
            }
            guard latencyMs.isFinite else { return nil }
            return Int((latencyMs / 1000.0 * samplingRate).rounded())
        }
        if configuration.includesResponseComponent, responseLatencies.contains(where: { $0 == nil }) {
            return nil
        }

        let erpAverage = average(trials.map(\.samples), length: length)
        let maxLagSamples = max(Int((configuration.centralMaxLagMs / 1000.0 * samplingRate).rounded()), 0)
        let tolerance = max(configuration.convergenceToleranceSamples, 0)
        let fixedStimulusLatency = Int((configuration.fixedStimulusLatencyMs / 1000.0 * samplingRate).rounded())
        let fixedCentralLatency = Int((configuration.fixedCentralLatencyMs / 1000.0 * samplingRate).rounded())
        let stimulusLatencies = [Int](repeating: configuration.stimulusLatencySource == .fixed ? fixedStimulusLatency : 0, count: trials.count)
        var centralLatencies = [Int](repeating: configuration.centralLatencySource == .fixed ? fixedCentralLatency : 0, count: trials.count)
        var centralCorrelations = [Double](repeating: 0, count: trials.count)
        var sTemplate = configuration.includesStimulusComponent ? erpAverage : [Float](repeating: 0, count: length)
        var cTemplate = [Float](repeating: 0, count: length)
        var rTemplate = [Float](repeating: 0, count: length)
        var iterations: [IterationSummary] = []
        var converged = !configuration.includesCentralComponent

        if configuration.includesCentralComponent, configuration.centralLatencySource == .estimated {
            let woody = WoodyAlignmentAnalyzer.align(
                trials: trials.map {
                    WoodyAlignmentAnalyzer.TrialInput(
                        sourceTimeSeconds: $0.sourceTimeSeconds,
                        stimulusOffsetSamples: $0.stimulusOffsetSamples,
                        samples: $0.samples
                    )
                },
                samplingRate: samplingRate,
                windowStartMs: configuration.centralWindow.startMs,
                windowEndMs: configuration.centralWindow.endMs,
                maxLagMs: configuration.centralMaxLagMs,
                maxIterations: 3,
                convergenceToleranceSamples: tolerance
            )
            centralLatencies = woody?.shifts.map(\.latencyShiftSamples) ?? centralLatencies
            centralCorrelations = woody?.shifts.map(\.correlation) ?? centralCorrelations
            cTemplate = windowedTemplate(
                woody?.finalTemplate ?? erpAverage,
                componentWindow: configuration.centralWindow,
                stimulusOffsetSamples: first.stimulusOffsetSamples,
                samplingRate: samplingRate
            )
        }

        var previousCentralLatencies = centralLatencies
        for iteration in 1...configuration.maxIterations {
            if configuration.includesStimulusComponent {
                sTemplate = estimateTemplate(
                    trials: trials,
                    length: length,
                    targetLatencies: stimulusLatencies,
                    stimulusLatencies: stimulusLatencies,
                    centralLatencies: centralLatencies,
                    responseLatencies: responseLatencies,
                    includeCentral: configuration.includesCentralComponent,
                    includeResponse: configuration.includesResponseComponent,
                    excluding: .stimulus,
                    sTemplate: sTemplate,
                    cTemplate: cTemplate,
                    rTemplate: rTemplate,
                    componentWindow: configuration.stimulusWindow,
                    samplingRate: samplingRate
                )
            }

            if configuration.includesCentralComponent {
                cTemplate = estimateTemplate(
                    trials: trials,
                    length: length,
                    targetLatencies: centralLatencies,
                    stimulusLatencies: stimulusLatencies,
                    centralLatencies: centralLatencies,
                    responseLatencies: responseLatencies,
                    includeCentral: true,
                    includeResponse: configuration.includesResponseComponent,
                    excluding: .central,
                    sTemplate: sTemplate,
                    cTemplate: cTemplate,
                    rTemplate: rTemplate,
                    componentWindow: configuration.centralWindow,
                    samplingRate: samplingRate
                )
            }

            if configuration.includesResponseComponent {
                rTemplate = estimateTemplate(
                    trials: trials,
                    length: length,
                    targetLatencies: responseLatencies.map { $0 ?? 0 },
                    stimulusLatencies: stimulusLatencies,
                    centralLatencies: centralLatencies,
                    responseLatencies: responseLatencies,
                    includeCentral: configuration.includesCentralComponent,
                    includeResponse: true,
                    excluding: .response,
                    sTemplate: sTemplate,
                    cTemplate: cTemplate,
                    rTemplate: rTemplate,
                    componentWindow: configuration.responseWindow,
                    samplingRate: samplingRate
                )
            }

            var changed = 0
            var maxChange = 0
            if configuration.includesCentralComponent, configuration.centralLatencySource == .estimated {
                var improvedCorrelationCount = 0
                for index in trials.indices {
                    guard let window = sampleRange(
                        startMs: configuration.centralWindow.startMs,
                        endMs: configuration.centralWindow.endMs,
                        stimulusOffsetSamples: trials[index].stimulusOffsetSamples,
                        samplingRate: samplingRate,
                        length: length
                    ) else { continue }
                    var residual = trials[index].samples
                    if configuration.includesStimulusComponent {
                        subtractInPlace(&residual, shiftLater(sTemplate, by: stimulusLatencies[index]))
                    }
                    if configuration.includesResponseComponent, let responseLatency = responseLatencies[index] {
                        subtractInPlace(&residual, shiftLater(rTemplate, by: responseLatency))
                    }
                    let estimate = bestLag(
                        trial: residual,
                        template: cTemplate,
                        window: window,
                        maxLagSamples: maxLagSamples,
                        currentLag: previousCentralLatencies[index],
                        searchMode: configuration.centralLatencySearchMode
                    )
                    if estimate.correlation > centralCorrelations[index] {
                        improvedCorrelationCount += 1
                    }
                    centralLatencies[index] = estimate.lag
                    centralCorrelations[index] = estimate.correlation
                    let delta = abs(estimate.lag - previousCentralLatencies[index])
                    if delta > tolerance { changed += 1 }
                    maxChange = max(maxChange, delta)
                }
                converged = changed == 0
                let meanCorrelation = centralCorrelations.isEmpty
                    ? 0
                    : centralCorrelations.reduce(0, +) / Double(centralCorrelations.count)
                let unchangedFraction = centralLatencies.isEmpty
                    ? 1
                    : Double(max(centralLatencies.count - changed, 0)) / Double(centralLatencies.count)
                iterations.append(IterationSummary(
                    iteration: iteration,
                    changedCentralLatencyCount: changed,
                    maxCentralLatencyChangeSamples: maxChange,
                    meanCentralCorrelation: meanCorrelation,
                    unchangedCentralLatencyFraction: unchangedFraction,
                    improvedCentralCorrelationCount: improvedCorrelationCount
                ))

            } else if configuration.includesCentralComponent {
                converged = true
                iterations.append(IterationSummary(
                    iteration: iteration,
                    changedCentralLatencyCount: 0,
                    maxCentralLatencyChangeSamples: 0,
                    meanCentralCorrelation: 0,
                    unchangedCentralLatencyFraction: 1,
                    improvedCentralCorrelationCount: 0
                ))
            }

            if converged { break }
            previousCentralLatencies = centralLatencies
        }

        let reconstructedTrials = trials.indices.map { index in
            reconstruct(
                length: length,
                centralLatency: centralLatencies[index],
                stimulusLatency: stimulusLatencies[index],
                responseLatency: responseLatencies[index],
                includeStimulus: configuration.includesStimulusComponent,
                includeCentral: configuration.includesCentralComponent,
                includeResponse: configuration.includesResponseComponent,
                sTemplate: sTemplate,
                cTemplate: cTemplate,
                rTemplate: rTemplate
            )
        }
        let residualTrials = zip(trials.map(\.samples), reconstructedTrials).map { observed, reconstructed in
            zip(observed, reconstructed).map { Float(Double($0) - Double($1)) }
        }

        var components: [ComponentWaveform] = []
        if configuration.includesStimulusComponent {
            components.append(ComponentWaveform(
                component: .stimulus,
                lockedTemplate: sTemplate,
                stimulusLockedAverage: average(
                    zip(stimulusLatencies, repeatElement(sTemplate, count: stimulusLatencies.count)).map { latency, template in
                        shiftLater(template, by: latency)
                    },
                    length: length
                )
            ))
        }
        if configuration.includesCentralComponent {
            components.append(ComponentWaveform(
                component: .central,
                lockedTemplate: cTemplate,
                stimulusLockedAverage: average(
                    zip([Int](centralLatencies), repeatElement(cTemplate, count: centralLatencies.count)).map { latency, template in
                        shiftLater(template, by: latency)
                    },
                    length: length
                )
            ))
        }
        if configuration.includesResponseComponent {
            let validResponseLatencies = responseLatencies.map { $0 ?? 0 }
            components.append(ComponentWaveform(
                component: .response,
                lockedTemplate: rTemplate,
                stimulusLockedAverage: average(
                    zip(validResponseLatencies, repeatElement(rTemplate, count: validResponseLatencies.count)).map { latency, template in
                        shiftLater(template, by: latency)
                    },
                    length: length
                )
            ))
        }

        let trialLatencies = trials.indices.map { index in
            TrialLatency(
                id: index,
                trialIndex: index,
                sourceTimeSeconds: trials[index].sourceTimeSeconds,
                centralLatencyShiftSamples: configuration.includesCentralComponent ? centralLatencies[index] : nil,
                centralLatencyShiftMs: configuration.includesCentralComponent
                    ? Double(centralLatencies[index]) / samplingRate * 1000.0
                    : nil,
                centralCorrelation: configuration.includesCentralComponent ? centralCorrelations[index] : nil,
                responseLatencySamples: responseLatencies[index],
                responseLatencyMs: responseLatencies[index].map { Double($0) / samplingRate * 1000.0 }
            )
        }

        return Result(
            components: components,
            trialLatencies: trialLatencies,
            erpAverage: erpAverage,
            centralAlignedAverage: configuration.includesCentralComponent
                ? average(zip(trials.map(\.samples), centralLatencies).map { samples, latency in
                    shiftEarlier(samples, by: latency)
                }, length: length)
                : nil,
            responseAlignedAverage: configuration.includesResponseComponent
                ? average(zip(trials.map(\.samples), responseLatencies.map { $0 ?? 0 }).map { samples, latency in
                    shiftEarlier(samples, by: latency)
                }, length: length)
                : nil,
            reconstructionAverage: average(reconstructedTrials, length: length),
            residualAverage: average(residualTrials, length: length),
            reconstructedTrials: reconstructedTrials,
            residualTrials: residualTrials,
            iterations: iterations,
            converged: converged
        )
    }

    // MARK: - Template estimation

    private static func estimateTemplate(
        trials: [TrialInput],
        length: Int,
        targetLatencies: [Int],
        stimulusLatencies: [Int],
        centralLatencies: [Int],
        responseLatencies: [Int?],
        includeCentral: Bool,
        includeResponse: Bool,
        excluding excludedComponent: Component,
        sTemplate: [Float],
        cTemplate: [Float],
        rTemplate: [Float],
        componentWindow: ComponentWindow,
        samplingRate: Double
    ) -> [Float] {
        let lockedResiduals = trials.indices.map { index in
            var residual = trials[index].samples
            if excludedComponent != .stimulus {
                subtractInPlace(&residual, shiftLater(sTemplate, by: stimulusLatencies[index]))
            }
            if includeCentral, excludedComponent != .central {
                subtractInPlace(&residual, shiftLater(cTemplate, by: centralLatencies[index]))
            }
            if includeResponse, excludedComponent != .response, let responseLatency = responseLatencies[index] {
                subtractInPlace(&residual, shiftLater(rTemplate, by: responseLatency))
            }
            return shiftEarlier(residual, by: targetLatencies[index])
        }
        let template = average(lockedResiduals, length: length)
        return windowedTemplate(
            template,
            componentWindow: componentWindow,
            stimulusOffsetSamples: trials.first?.stimulusOffsetSamples ?? 0,
            samplingRate: samplingRate
        )
    }

    private static func windowedTemplate(
        _ template: [Float],
        componentWindow: ComponentWindow,
        stimulusOffsetSamples: Int,
        samplingRate: Double
    ) -> [Float] {
        guard let window = sampleRange(
            startMs: componentWindow.startMs,
            endMs: componentWindow.endMs,
            stimulusOffsetSamples: stimulusOffsetSamples,
            samplingRate: samplingRate,
            length: template.count
        ) else { return template }
        var out = [Float](repeating: 0, count: template.count)
        for index in window where template.indices.contains(index) {
            out[index] = template[index]
        }
        return out
    }

    private static func reconstruct(
        length: Int,
        centralLatency: Int,
        stimulusLatency: Int,
        responseLatency: Int?,
        includeStimulus: Bool,
        includeCentral: Bool,
        includeResponse: Bool,
        sTemplate: [Float],
        cTemplate: [Float],
        rTemplate: [Float]
    ) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        if includeStimulus {
            addInPlace(&out, shiftLater(sTemplate, by: stimulusLatency))
        }
        if includeCentral {
            addInPlace(&out, shiftLater(cTemplate, by: centralLatency))
        }
        if includeResponse, let responseLatency {
            addInPlace(&out, shiftLater(rTemplate, by: responseLatency))
        }
        return out
    }

    // MARK: - Lag search

    private static func sampleRange(
        startMs: Double,
        endMs: Double,
        stimulusOffsetSamples: Int,
        samplingRate: Double,
        length: Int
    ) -> Range<Int>? {
        guard length > 0, endMs > startMs else { return nil }
        let startSample = stimulusOffsetSamples + Int((startMs / 1000.0 * samplingRate).rounded())
        let endSample = stimulusOffsetSamples + Int((endMs / 1000.0 * samplingRate).rounded())
        let lower = max(min(startSample, endSample), 0)
        let upper = min(max(startSample, endSample), length - 1)
        guard lower <= upper else { return nil }
        return lower..<(upper + 1)
    }

    private static func bestLag(
        trial: [Float],
        template: [Float],
        window: Range<Int>,
        maxLagSamples: Int,
        currentLag: Int,
        searchMode: CentralLatencySearchMode
    ) -> (lag: Int, correlation: Double) {
        var candidates: [(lag: Int, correlation: Double)] = []
        candidates.reserveCapacity(maxLagSamples * 2 + 1)
        for lag in (-maxLagSamples)...maxLagSamples {
            let correlation = normalizedCorrelation(trial: trial, template: template, window: window, lag: lag)
            if correlation.isFinite {
                candidates.append((lag, correlation))
            }
        }
        guard !candidates.isEmpty else { return (0, 0) }
        switch searchMode {
        case .largestPeak:
            let best = candidates.max { lhs, rhs in lhs.correlation < rhs.correlation } ?? (0, 0)
            return best
        case .mostProbable:
            let peakThreshold = (candidates.map(\.correlation).max() ?? 0) * 0.92
            let plausible = candidates.filter { $0.correlation >= peakThreshold }
            let best = plausible.min {
                let lhsDistance = abs($0.lag - currentLag)
                let rhsDistance = abs($1.lag - currentLag)
                if lhsDistance == rhsDistance { return $0.correlation > $1.correlation }
                return lhsDistance < rhsDistance
            } ?? candidates.max { lhs, rhs in lhs.correlation < rhs.correlation } ?? (0, 0)
            return best
        }
    }

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

    private static func shiftEarlier(_ samples: [Float], by shift: Int) -> [Float] {
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

    private static func shiftLater(_ samples: [Float], by shift: Int) -> [Float] {
        shiftEarlier(samples, by: -shift)
    }

    private static func addInPlace(_ target: inout [Float], _ source: [Float]) {
        guard target.count == source.count else { return }
        for i in target.indices {
            target[i] = Float(Double(target[i]) + Double(source[i]))
        }
    }

    private static func subtractInPlace(_ target: inout [Float], _ source: [Float]) {
        guard target.count == source.count else { return }
        for i in target.indices {
            target[i] = Float(Double(target[i]) - Double(source[i]))
        }
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
