//
//  LAVISignificanceProvider.swift
//  EVA
//
//  On-demand, seed-controlled null ribbons for LAVI/ABBA inference.
//

import Foundation

nonisolated struct LAVISignificanceResolution: Sendable, Equatable {
    var ribbon: LAVISignificanceRibbon
    var aperiodicFit: AperiodicSpectrumFit
    var surrogateSummary: LAVISurrogateSummary
}

nonisolated enum LAVISignificanceError: Error, Sendable, Equatable, LocalizedError {
    case paperTailRequires200(repetitions: Int)
    case paperTailRequiresAlphaPoint05(Double)
    case profileCountMismatch(expected: Int, actual: Int, surrogate: Int)
    case nonfiniteProfile(surrogate: Int, frequency: Int)
    case noFiniteRuns

    var errorDescription: String? {
        switch self {
        case let .paperTailRequires200(repetitions):
            return "The fifth-order-statistic paper rule requires exactly 200 surrogates; received \(repetitions)."
        case let .paperTailRequiresAlphaPoint05(alpha):
            return "The fifth-order-statistic paper rule requires two-sided alpha 0.05; received \(alpha)."
        case let .profileCountMismatch(expected, actual, surrogate):
            return "Surrogate \(surrogate) contains \(actual) LAVI values; expected \(expected)."
        case let .nonfiniteProfile(surrogate, frequency):
            return "Surrogate \(surrogate) has no finite LAVI at frequency index \(frequency)."
        case .noFiniteRuns:
            return "Significance generation requires at least one finite selected signal run."
        }
    }
}

nonisolated enum LAVISignificanceProvider {
    static func resolve(
        channel: RhythmicityChannelInput,
        input: RhythmicityInput,
        analysisConfiguration: RhythmicityConfiguration,
        significanceConfiguration: LAVIOnDemandSignificanceConfiguration,
        coefficientProvider: any ComplexCoefficientProvider,
        cancellation: RhythmicityCancellation = RhythmicityCancellation(),
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) throws -> LAVISignificanceResolution {
        try validate(significanceConfiguration)
        let runs = finiteRuns(samples: channel.samples, segments: input.segments)
        guard !runs.isEmpty else { throw LAVISignificanceError.noFiniteRuns }
        try cancellation.check()
        let fit = try AperiodicSpectrumEstimator.estimate(
            samples: channel.samples,
            samplingRate: input.samplingRate,
            segments: runs,
            fitRangeHz: significanceConfiguration.aperiodicFitRangeHz,
            excludedRangesHz: significanceConfiguration.excludedFitRangesHz,
            cancellation: cancellation
        )
        let runWorkspaces = try runs.map { run in
            let values = Array(channel.samples[run]).sorted()
            let magnitudes = AperiodicSpectrumEstimator.targetFourierMagnitudes(
                sampleCount: values.count,
                samplingRate: input.samplingRate,
                fit: fit
            )
            return try IAAFTSurrogateGenerator.prepare(
                targetFourierMagnitudes: magnitudes,
                sortedValues: values
            )
        }
        var nullProfiles: [[Double]] = []
        var diagnostics: [IAAFTSurrogateDiagnostics] = []
        nullProfiles.reserveCapacity(significanceConfiguration.repetitions)
        diagnostics.reserveCapacity(significanceConfiguration.repetitions)

        var nullConfiguration = analysisConfiguration
        nullConfiguration.significance = .none
        for surrogateIndex in 0..<significanceConfiguration.repetitions {
            try cancellation.check()
            var samples = [Double](repeating: .nan, count: channel.samples.count)
            var runDiagnostics: [IAAFTSurrogateDiagnostics] = []
            for (runIndex, run) in runs.enumerated() {
                try cancellation.check()
                let seed = RhythmicitySeed.derived(
                    from: significanceConfiguration.seed,
                    channel: channel.channelIndex,
                    surrogate: surrogateIndex,
                    run: runIndex
                )
                let generated = try IAAFTSurrogateGenerator.generate(
                    workspace: runWorkspaces[runIndex],
                    seed: seed,
                    configuration: significanceConfiguration.iaaft,
                    cancellation: cancellation
                )
                samples.replaceSubrange(run, with: generated.values)
                runDiagnostics.append(generated.diagnostics)
            }
            let surrogateChannel = RhythmicityChannelInput(
                channelIndex: channel.channelIndex,
                channelName: channel.channelName,
                samples: samples,
                isInterpolated: channel.isInterpolated
            )
            let surrogateInput = RhythmicityInput(
                channels: [surrogateChannel],
                samplingRate: input.samplingRate,
                segments: input.segments,
                source: input.source,
                processingProvenance: input.processingProvenance
            )
            let result = try LAVIEngine.analyze(
                input: surrogateInput,
                configuration: nullConfiguration,
                coefficientProvider: coefficientProvider,
                cancellation: cancellation
            )
            nullProfiles.append(result.channels[0].values)
            diagnostics.append(
                aggregateDiagnostics(
                    runDiagnostics,
                    seed: RhythmicitySeed.derived(
                        from: significanceConfiguration.seed,
                        channel: channel.channelIndex,
                        surrogate: surrogateIndex,
                        run: 0
                    )
                )
            )
            progress?(surrogateIndex + 1, significanceConfiguration.repetitions)
        }

        var ribbon = try extractPaperRibbon(
            profiles: nullProfiles,
            frequenciesHz: analysisConfiguration.frequenciesHz,
            seed: significanceConfiguration.seed
        )
        let nonconverged = diagnostics.count { $0.status != .converged }
        ribbon.nonconvergedSurrogateCount = nonconverged
        return LAVISignificanceResolution(
            ribbon: ribbon,
            aperiodicFit: fit,
            surrogateSummary: LAVISurrogateSummary(
                seed: significanceConfiguration.seed,
                requestedCount: significanceConfiguration.repetitions,
                retainedCount: nullProfiles.count,
                nonconvergedCount: nonconverged,
                diagnostics: diagnostics,
                amplitudeDistribution: significanceConfiguration.amplitudeDistribution,
                nonconvergencePolicy: significanceConfiguration.nonconvergencePolicy
            )
        )
    }

    /// The paper fixes n=200, alpha=.05, and k=5 in each tail. Sorting makes
    /// those thresholds the fifth-lowest (index 4) and fifth-highest (index 195)
    /// observations at each frequency; no interpolated percentile is involved.
    static func extractPaperRibbon(
        profiles: [[Double]],
        frequenciesHz: [Double],
        seed: UInt64? = nil
    ) throws -> LAVISignificanceRibbon {
        guard profiles.count == 200 else {
            throw LAVISignificanceError.paperTailRequires200(repetitions: profiles.count)
        }
        var lower = [Double](repeating: .nan, count: frequenciesHz.count)
        var upper = [Double](repeating: .nan, count: frequenciesHz.count)
        for surrogate in profiles.indices {
            guard profiles[surrogate].count == frequenciesHz.count else {
                throw LAVISignificanceError.profileCountMismatch(
                    expected: frequenciesHz.count,
                    actual: profiles[surrogate].count,
                    surrogate: surrogate
                )
            }
        }
        for frequency in frequenciesHz.indices {
            var values: [Double] = []
            values.reserveCapacity(200)
            for surrogate in profiles.indices {
                let value = profiles[surrogate][frequency]
                guard value.isFinite else {
                    throw LAVISignificanceError.nonfiniteProfile(
                        surrogate: surrogate,
                        frequency: frequency
                    )
                }
                values.append(value)
            }
            values.sort()
            lower[frequency] = values[4]
            upper[frequency] = values[195]
        }
        return LAVISignificanceRibbon(
            lower: lower,
            upper: upper,
            frequenciesHz: frequenciesHz,
            source: .onDemandSurrogates,
            surrogateCount: 200,
            alpha: 0.05,
            tailRule: .fifthOrderStatisticPerFrequency,
            seed: seed
        )
    }

    static func validate(_ configuration: LAVIOnDemandSignificanceConfiguration) throws {
        guard configuration.repetitions == 200 else {
            throw LAVISignificanceError.paperTailRequires200(repetitions: configuration.repetitions)
        }
        guard abs(configuration.alpha - 0.05) < 1e-12 else {
            throw LAVISignificanceError.paperTailRequiresAlphaPoint05(configuration.alpha)
        }
        guard configuration.tailRule == .fifthOrderStatisticPerFrequency else {
            throw RhythmicityAnalysisError.invalidSignificanceConfiguration(
                "only the validated per-frequency fifth-order-statistic rule is inferential"
            )
        }
        guard configuration.amplitudeDistribution == .observedSamples else {
            throw RhythmicityAnalysisError.invalidSignificanceConfiguration(
                "paper-valid IAAFT requires the observed finite sample distribution"
            )
        }
        guard configuration.aperiodicFitRangeHz.lowerBound.isFinite,
              configuration.aperiodicFitRangeHz.upperBound.isFinite,
              configuration.aperiodicFitRangeHz.lowerBound > 0,
              configuration.aperiodicFitRangeHz.lowerBound
                < configuration.aperiodicFitRangeHz.upperBound else {
            throw RhythmicityAnalysisError.invalidSignificanceConfiguration(
                "aperiodic fit range must be finite, positive, and increasing"
            )
        }
        guard configuration.iaaft.errorThreshold.isFinite,
              configuration.iaaft.errorThreshold > 0,
              configuration.iaaft.speedThreshold.isFinite,
              configuration.iaaft.speedThreshold >= 0,
              configuration.iaaft.maximumIterations > 0 else {
            throw RhythmicityAnalysisError.invalidSignificanceConfiguration(
                "IAAFT thresholds and maximum iteration count are invalid"
            )
        }
    }

    private static func finiteRuns(
        samples: [Double],
        segments: [RhythmicitySegment]
    ) -> [Range<Int>] {
        var output: [Range<Int>] = []
        for segment in segments {
            var start: Int?
            for index in segment.startSample...segment.endSample {
                if samples[index].isFinite {
                    if start == nil { start = index }
                } else if let runStart = start {
                    output.append(runStart..<index)
                    start = nil
                }
            }
            if let runStart = start { output.append(runStart..<(segment.endSample + 1)) }
        }
        return output
    }

    private static func aggregateDiagnostics(
        _ values: [IAAFTSurrogateDiagnostics],
        seed: UInt64
    ) -> IAAFTSurrogateDiagnostics {
        let status: IAAFTConvergenceStatus
        if values.contains(where: { $0.status == .iterationLimit }) {
            status = .iterationLimit
        } else if values.contains(where: { $0.status == .stalled }) {
            status = .stalled
        } else {
            status = .converged
        }
        return IAAFTSurrogateDiagnostics(
            seed: seed,
            iterations: values.map(\.iterations).max() ?? 0,
            amplitudeError: values.map(\.amplitudeError).max() ?? .nan,
            spectralError: values.map(\.spectralError).max() ?? .nan,
            status: status
        )
    }
}
