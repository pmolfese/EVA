//
//  LAVISignificanceProvider.swift
//  EVA
//
//  On-demand, seed-controlled null ribbons for LAVI/ABBA inference.
//

import Foundation

nonisolated struct LAVISignificanceResolution: Sendable, Codable, Equatable {
    var ribbon: LAVISignificanceRibbon
    var aperiodicFit: AperiodicSpectrumFit
    var surrogateSummary: LAVISurrogateSummary
}

nonisolated enum LAVISignificanceProgressStage: Sendable, Equatable {
    case fittingAperiodicSpectrum
    case preparingIAAFT
    case generatingIAAFT
    case analyzingSurrogateLAVI
    case completedSurrogate
    case checkingCache
    case usingCachedResult
}

nonisolated struct LAVISignificanceProgress: Sendable, Equatable {
    var stage: LAVISignificanceProgressStage
    var completedSurrogates: Int
    var totalSurrogates: Int
    var currentSurrogate: Int? = nil
    var runIndex: Int? = nil
    var runCount: Int? = nil
    var iteration: Int? = nil
    var maximumIterations: Int? = nil
    var workerCount: Int? = nil
    var batchStartSurrogate: Int? = nil
    var batchEndSurrogate: Int? = nil
}

nonisolated enum LAVISignificanceError: Error, Sendable, Equatable, LocalizedError {
    case paperTailRequires200(repetitions: Int)
    case paperTailRequiresAlphaPoint05(Double)
    case profileCountMismatch(expected: Int, actual: Int, surrogate: Int)
    case nonfiniteProfile(surrogate: Int, frequency: Int)
    case incompleteSurrogateResults(expected: Int, actual: Int)
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
        case let .incompleteSurrogateResults(expected, actual):
            return "Significance generation produced \(actual) surrogate results; expected \(expected)."
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
        cache: LAVISignificanceCacheStore? = nil,
        cancellation: RhythmicityCancellation = RhythmicityCancellation(),
        progress: (@Sendable (LAVISignificanceProgress) -> Void)? = nil
    ) throws -> LAVISignificanceResolution {
        try validate(significanceConfiguration)
        let runs = finiteRuns(samples: channel.samples, segments: input.segments)
        guard !runs.isEmpty else { throw LAVISignificanceError.noFiniteRuns }
        try cancellation.check()
        if let cache {
            progress?(LAVISignificanceProgress(
                stage: .checkingCache,
                completedSurrogates: 0,
                totalSurrogates: significanceConfiguration.repetitions
            ))
            if let cached = try? cache.load(
                channel: channel,
                input: input,
                configuration: analysisConfiguration
            ), cachedResolutionIsValid(
                cached,
                analysisConfiguration: analysisConfiguration,
                significanceConfiguration: significanceConfiguration
            ) {
                progress?(LAVISignificanceProgress(
                    stage: .usingCachedResult,
                    completedSurrogates: significanceConfiguration.repetitions,
                    totalSurrogates: significanceConfiguration.repetitions
                ))
                return cached
            }
        }
        progress?(LAVISignificanceProgress(
            stage: .fittingAperiodicSpectrum,
            completedSurrogates: 0,
            totalSurrogates: significanceConfiguration.repetitions
        ))
        let fit = try AperiodicSpectrumEstimator.estimate(
            samples: channel.samples,
            samplingRate: input.samplingRate,
            segments: runs,
            fitRangeHz: significanceConfiguration.aperiodicFitRangeHz,
            excludedRangesHz: significanceConfiguration.excludedFitRangesHz,
            cancellation: cancellation
        )
        var workspaceDefinitions = runs.map { run in
            let values = Array(channel.samples[run]).sorted()
            let magnitudes = AperiodicSpectrumEstimator.targetFourierMagnitudes(
                sampleCount: values.count,
                samplingRate: input.samplingRate,
                fit: fit
            )
            return LAVISignificanceWorkspaceDefinition(
                targetFourierMagnitudes: magnitudes,
                sortedValues: values
            )
        }
        let usesAccelerateProvider = coefficientProvider is AccelerateFFTComplexCoefficientProvider
        let workerCount = LAVISignificanceWorkPlanner.workerCount(
            workItemCount: significanceConfiguration.repetitions,
            totalSamples: runs.reduce(0) { $0 + $1.count },
            longestRunSamples: runs.map(\.count).max() ?? 0,
            frequenciesHz: analysisConfiguration.frequenciesHz,
            samplingRate: input.samplingRate,
            widthCycles: analysisConfiguration.morletWidthCycles,
            policy: analysisConfiguration.computePolicy,
            includesCPUProfileAnalysis: usesAccelerateProvider
        )
        progress?(LAVISignificanceProgress(
            stage: .preparingIAAFT,
            completedSurrogates: 0,
            totalSurrogates: significanceConfiguration.repetitions,
            runCount: runs.count,
            workerCount: workerCount
        ))
        let workerContexts = try (0..<workerCount).map { _ in
            LAVISignificanceWorkerContext(
                workspaces: try workspaceDefinitions.map { definition in
                    try IAAFTSurrogateGenerator.prepare(
                        targetFourierMagnitudes: definition.targetFourierMagnitudes,
                        sortedValues: definition.sortedValues
                    )
                },
                coefficientProvider: workerCoefficientProvider(
                    basedOn: coefficientProvider,
                    policy: analysisConfiguration.computePolicy,
                    workerCount: workerCount
                )
            )
        }
        workspaceDefinitions.removeAll(keepingCapacity: false)
        var nullProfiles: [[Double]] = []
        var diagnostics: [IAAFTSurrogateDiagnostics] = []
        nullProfiles.reserveCapacity(significanceConfiguration.repetitions)
        diagnostics.reserveCapacity(significanceConfiguration.repetitions)

        var nullConfiguration = analysisConfiguration
        nullConfiguration.significance = .none
        let progressState = LAVISignificanceProgressState()
        if analysisConfiguration.backend == .metalGPU,
           let metalProvider = coefficientProvider as? RhythmicityMetalCoefficientProvider {
            try resolveMetalProfiles(
                channel: channel,
                input: input,
                runs: runs,
                configuration: nullConfiguration,
                significanceConfiguration: significanceConfiguration,
                workerContexts: workerContexts,
                workerCount: workerCount,
                metalProvider: metalProvider,
                cancellation: cancellation,
                progressState: progressState,
                progress: progress,
                profiles: &nullProfiles,
                diagnostics: &diagnostics
            )
        } else {
            let outcomes = LAVILockedArray<LAVISignificanceProfileOutcome>(
                count: significanceConfiguration.repetitions
            )
            let failures = LAVISignificanceFailureStore()
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                var surrogateIndex = worker
                while surrogateIndex < significanceConfiguration.repetitions {
                    if failures.hasFailure { return }
                    do {
                        let generated = try generateSurrogate(
                            surrogateIndex: surrogateIndex,
                            channel: channel,
                            runs: runs,
                            workspaces: workerContexts[worker].workspaces,
                            significanceConfiguration: significanceConfiguration,
                            workerCount: workerCount,
                            cancellation: cancellation,
                            progressState: progressState,
                            progress: progress
                        )
                        progress?(LAVISignificanceProgress(
                            stage: .analyzingSurrogateLAVI,
                            completedSurrogates: progressState.completedCount,
                            totalSurrogates: significanceConfiguration.repetitions,
                            currentSurrogate: surrogateIndex + 1,
                            workerCount: workerCount
                        ))
                        let profile = try analyzeCPUProfile(
                            generated.runs,
                            ranges: runs,
                            channel: channel,
                            input: input,
                            configuration: nullConfiguration,
                            coefficientProvider: workerContexts[worker].coefficientProvider,
                            cancellation: cancellation
                        )
                        outcomes.store(
                            LAVISignificanceProfileOutcome(
                                profile: profile,
                                diagnostics: generated.diagnostics
                            ),
                            at: surrogateIndex
                        )
                        let completed = progressState.completeOne()
                        progress?(LAVISignificanceProgress(
                            stage: .completedSurrogate,
                            completedSurrogates: completed,
                            totalSurrogates: significanceConfiguration.repetitions,
                            currentSurrogate: surrogateIndex + 1,
                            workerCount: workerCount
                        ))
                    } catch {
                        failures.record(error)
                        return
                    }
                    surrogateIndex += workerCount
                }
            }
            if let error = failures.first { throw error }
            let ordered = outcomes.orderedValues
            guard ordered.count == significanceConfiguration.repetitions else {
                throw LAVISignificanceError.incompleteSurrogateResults(
                    expected: significanceConfiguration.repetitions,
                    actual: ordered.count
                )
            }
            nullProfiles = ordered.map(\.profile)
            diagnostics = ordered.map(\.diagnostics)
        }

        var ribbon = try extractPaperRibbon(
            profiles: nullProfiles,
            frequenciesHz: analysisConfiguration.frequenciesHz,
            seed: significanceConfiguration.seed
        )
        let nonconverged = diagnostics.count { $0.status != .converged }
        ribbon.nonconvergedSurrogateCount = nonconverged
        let resolution = LAVISignificanceResolution(
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
        if let cache {
            try? cache.save(
                resolution,
                channel: channel,
                input: input,
                configuration: analysisConfiguration
            )
        }
        return resolution
    }

    private static func cachedResolutionIsValid(
        _ resolution: LAVISignificanceResolution,
        analysisConfiguration: RhythmicityConfiguration,
        significanceConfiguration: LAVIOnDemandSignificanceConfiguration
    ) -> Bool {
        let ribbon = resolution.ribbon
        let summary = resolution.surrogateSummary
        let fit = resolution.aperiodicFit
        let count = analysisConfiguration.frequenciesHz.count
        return ribbon.source == .onDemandSurrogates
            && ribbon.frequenciesHz == analysisConfiguration.frequenciesHz
            && ribbon.lower.count == count
            && ribbon.upper.count == count
            && ribbon.lower.allSatisfy(\.isFinite)
            && ribbon.upper.allSatisfy(\.isFinite)
            && ribbon.surrogateCount == significanceConfiguration.repetitions
            && ribbon.alpha == significanceConfiguration.alpha
            && ribbon.tailRule == significanceConfiguration.tailRule
            && ribbon.seed == significanceConfiguration.seed
            && ribbon.nonconvergedSurrogateCount == summary.nonconvergedCount
            && summary.seed == significanceConfiguration.seed
            && summary.requestedCount == significanceConfiguration.repetitions
            && summary.retainedCount == significanceConfiguration.repetitions
            && summary.diagnostics.count == significanceConfiguration.repetitions
            && summary.nonconvergedCount == summary.diagnostics.count(where: { $0.status != .converged })
            && summary.amplitudeDistribution == significanceConfiguration.amplitudeDistribution
            && summary.nonconvergencePolicy == significanceConfiguration.nonconvergencePolicy
            && fit.fitRangeHz == significanceConfiguration.aperiodicFitRangeHz
            && fit.excludedRangesHz == significanceConfiguration.excludedFitRangesHz
            && fit.frequenciesHz.count == fit.observedPower.count
            && fit.frequenciesHz.count == fit.fittedPower.count
    }

    private static func generateSurrogate(
        surrogateIndex: Int,
        channel: RhythmicityChannelInput,
        runs: [Range<Int>],
        workspaces: [IAAFTWorkspace],
        significanceConfiguration: LAVIOnDemandSignificanceConfiguration,
        workerCount: Int,
        cancellation: RhythmicityCancellation,
        progressState: LAVISignificanceProgressState,
        progress: (@Sendable (LAVISignificanceProgress) -> Void)?
    ) throws -> LAVISignificanceGeneratedSurrogate {
        try cancellation.check()
        var generatedRuns: [[Double]] = []
        var runDiagnostics: [IAAFTSurrogateDiagnostics] = []
        generatedRuns.reserveCapacity(runs.count)
        runDiagnostics.reserveCapacity(runs.count)
        for runIndex in runs.indices {
            try cancellation.check()
            let completed = progressState.completedCount
            progress?(LAVISignificanceProgress(
                stage: .generatingIAAFT,
                completedSurrogates: completed,
                totalSurrogates: significanceConfiguration.repetitions,
                currentSurrogate: surrogateIndex + 1,
                runIndex: runIndex + 1,
                runCount: runs.count,
                iteration: 0,
                maximumIterations: significanceConfiguration.iaaft.maximumIterations,
                workerCount: workerCount
            ))
            let seed = RhythmicitySeed.derived(
                from: significanceConfiguration.seed,
                channel: channel.channelIndex,
                surrogate: surrogateIndex,
                run: runIndex
            )
            let generated = try IAAFTSurrogateGenerator.generate(
                workspace: workspaces[runIndex],
                seed: seed,
                configuration: significanceConfiguration.iaaft,
                cancellation: cancellation,
                progress: { iteration, maximumIterations in
                    progress?(LAVISignificanceProgress(
                        stage: .generatingIAAFT,
                        completedSurrogates: progressState.completedCount,
                        totalSurrogates: significanceConfiguration.repetitions,
                        currentSurrogate: surrogateIndex + 1,
                        runIndex: runIndex + 1,
                        runCount: runs.count,
                        iteration: iteration,
                        maximumIterations: maximumIterations,
                        workerCount: workerCount
                    ))
                }
            )
            generatedRuns.append(generated.values)
            runDiagnostics.append(generated.diagnostics)
        }
        return LAVISignificanceGeneratedSurrogate(
            runs: generatedRuns,
            diagnostics: aggregateDiagnostics(
                runDiagnostics,
                seed: RhythmicitySeed.derived(
                    from: significanceConfiguration.seed,
                    channel: channel.channelIndex,
                    surrogate: surrogateIndex,
                    run: 0
                )
            )
        )
    }

    private static func analyzeCPUProfile(
        _ generatedRuns: [[Double]],
        ranges: [Range<Int>],
        channel: RhythmicityChannelInput,
        input: RhythmicityInput,
        configuration: RhythmicityConfiguration,
        coefficientProvider: any ComplexCoefficientProvider,
        cancellation: RhythmicityCancellation
    ) throws -> [Double] {
        guard ranges.count == generatedRuns.count else {
            throw LAVISignificanceError.incompleteSurrogateResults(
                expected: ranges.count,
                actual: generatedRuns.count
            )
        }
        var samples = [Double](repeating: .nan, count: channel.samples.count)
        for (range, values) in zip(ranges, generatedRuns) {
            samples.replaceSubrange(range, with: values)
        }
        let surrogateInput = RhythmicityInput(
            channels: [RhythmicityChannelInput(
                channelIndex: channel.channelIndex,
                channelName: channel.channelName,
                samples: samples,
                isInterpolated: channel.isInterpolated
            )],
            samplingRate: input.samplingRate,
            segments: input.segments,
            source: input.source,
            processingProvenance: input.processingProvenance
        )
        return try LAVIEngine.analyze(
            input: surrogateInput,
            configuration: configuration,
            coefficientProvider: coefficientProvider,
            cancellation: cancellation
        ).channels[0].values
    }

    private static func resolveMetalProfiles(
        channel: RhythmicityChannelInput,
        input: RhythmicityInput,
        runs: [Range<Int>],
        configuration: RhythmicityConfiguration,
        significanceConfiguration: LAVIOnDemandSignificanceConfiguration,
        workerContexts: [LAVISignificanceWorkerContext],
        workerCount: Int,
        metalProvider: RhythmicityMetalCoefficientProvider,
        cancellation: RhythmicityCancellation,
        progressState: LAVISignificanceProgressState,
        progress: (@Sendable (LAVISignificanceProgress) -> Void)?,
        profiles: inout [[Double]],
        diagnostics: inout [IAAFTSurrogateDiagnostics]
    ) throws {
        let capacity = try metalProvider.maximumLAVIBatchSize(
            runSampleCounts: runs.map(\.count),
            frequenciesHz: configuration.frequenciesHz,
            samplingRate: input.samplingRate,
            widthCycles: configuration.morletWidthCycles,
            requestedCount: significanceConfiguration.repetitions
        )
        let batchSize = min(capacity, max(workerCount * 4, 1))
        var batchStart = 0
        while batchStart < significanceConfiguration.repetitions {
            try cancellation.check()
            let currentBatchStart = batchStart
            let batchEnd = min(currentBatchStart + batchSize, significanceConfiguration.repetitions)
            let count = batchEnd - currentBatchStart
            let activeWorkers = min(workerCount, count)
            let generated = LAVILockedArray<LAVISignificanceGeneratedSurrogate>(count: count)
            let failures = LAVISignificanceFailureStore()
            DispatchQueue.concurrentPerform(iterations: activeWorkers) { worker in
                var localIndex = worker
                while localIndex < count {
                    if failures.hasFailure { return }
                    let surrogateIndex = currentBatchStart + localIndex
                    do {
                        let outcome = try generateSurrogate(
                            surrogateIndex: surrogateIndex,
                            channel: channel,
                            runs: runs,
                            workspaces: workerContexts[worker].workspaces,
                            significanceConfiguration: significanceConfiguration,
                            workerCount: workerCount,
                            cancellation: cancellation,
                            progressState: progressState,
                            progress: progress
                        )
                        generated.store(outcome, at: localIndex)
                    } catch {
                        failures.record(error)
                        return
                    }
                    localIndex += activeWorkers
                }
            }
            if let error = failures.first { throw error }
            let ordered = generated.orderedValues
            guard ordered.count == count else {
                throw LAVISignificanceError.incompleteSurrogateResults(
                    expected: count,
                    actual: ordered.count
                )
            }
            progress?(LAVISignificanceProgress(
                stage: .analyzingSurrogateLAVI,
                completedSurrogates: progressState.completedCount,
                totalSurrogates: significanceConfiguration.repetitions,
                currentSurrogate: currentBatchStart + 1,
                workerCount: workerCount,
                batchStartSurrogate: currentBatchStart + 1,
                batchEndSurrogate: batchEnd
            ))
            let batchProfiles = try metalProvider.laviProfiles(
                surrogateRuns: ordered.map(\.runs),
                samplingRate: input.samplingRate,
                frequenciesHz: configuration.frequenciesHz,
                widthCycles: configuration.morletWidthCycles,
                lagCycles: configuration.laviLagCycles,
                edgePolicy: configuration.edgePolicy,
                cancellation: cancellation
            )
            guard batchProfiles.count == count else {
                throw LAVISignificanceError.incompleteSurrogateResults(
                    expected: count,
                    actual: batchProfiles.count
                )
            }
            for localIndex in 0..<count {
                profiles.append(batchProfiles[localIndex])
                diagnostics.append(ordered[localIndex].diagnostics)
                let completed = progressState.completeOne()
                progress?(LAVISignificanceProgress(
                    stage: .completedSurrogate,
                    completedSurrogates: completed,
                    totalSurrogates: significanceConfiguration.repetitions,
                    currentSurrogate: currentBatchStart + localIndex + 1,
                    workerCount: workerCount,
                    batchStartSurrogate: currentBatchStart + 1,
                    batchEndSurrogate: batchEnd
                ))
            }
            batchStart = batchEnd
        }
    }

    private static func workerCoefficientProvider(
        basedOn provider: any ComplexCoefficientProvider,
        policy: RhythmicityComputePolicy,
        workerCount: Int
    ) -> any ComplexCoefficientProvider {
        let dividedPolicy = RhythmicityComputePolicy(
            memoryBudgetBytes: max(policy.memoryBudgetBytes / max(workerCount, 1), 1),
            maximumWorkerCount: 1,
            preferredOutputTileSamples: policy.preferredOutputTileSamples
        )
        if provider is AccelerateFFTComplexCoefficientProvider {
            return LAVISerialCoefficientProvider(
                base: AccelerateFFTComplexCoefficientProvider(policy: dividedPolicy)
            )
        }
        if provider is DirectComplexCoefficientProvider {
            return LAVISerialCoefficientProvider(base: DirectComplexCoefficientProvider())
        }
        return LAVISerialCoefficientProvider(base: provider)
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

nonisolated enum LAVISignificanceWorkPlanner {
    /// IAAFT retains target/rank arrays and creates several transform-sized
    /// temporaries per worker. The conservative estimate prevents the outer
    /// surrogate pool from multiplying those allocations past the global
    /// Rhythmicity memory allowance.
    static func workerCount(
        workItemCount: Int,
        totalSamples: Int,
        longestRunSamples: Int,
        frequenciesHz: [Double],
        samplingRate: Double,
        widthCycles: Double,
        policy: RhythmicityComputePolicy,
        includesCPUProfileAnalysis: Bool
    ) -> Int {
        guard workItemCount > 0 else { return 0 }
        let configuredMaximum = policy.maximumWorkerCount == 0
            ? evaMaxWorkers
            : min(policy.maximumWorkerCount, evaMaxWorkers)
        let maximum = max(min(workItemCount, configuredMaximum), 1)
        let iaaftBytes = saturatedProduct(max(totalSamples, 1), 128)
        let reconstructedSignalBytes = saturatedProduct(max(totalSamples, 1), 8)
        let maximumKernelSamples = frequenciesHz.map {
            LAVI2026Morlet.kernel(
                frequencyHz: $0,
                widthCycles: widthCycles,
                samplingRate: samplingRate
            ).count
        }.max() ?? 1

        for candidate in stride(from: maximum, through: 1, by: -1) {
            let perWorkerBudget = max(policy.memoryBudgetBytes / candidate, 1)
            var requiredBytes = iaaftBytes
            if includesCPUProfileAnalysis {
                let workerPolicy = RhythmicityComputePolicy(
                    memoryBudgetBytes: perWorkerBudget,
                    maximumWorkerCount: 1,
                    preferredOutputTileSamples: policy.preferredOutputTileSamples
                )
                guard let convolution = try? RhythmicityProductionWorkPlanner.convolutionPlan(
                    signalSamples: longestRunSamples,
                    kernelSamples: maximumKernelSamples,
                    policy: workerPolicy
                ) else { continue }
                let coefficientBytes = saturatedSum([
                    convolution.estimatedWorkingSetBytes,
                    RhythmicityProductionWorkPlanner.kernelCacheBudget(policy: workerPolicy),
                    reconstructedSignalBytes,
                ])
                requiredBytes = max(requiredBytes, coefficientBytes)
            }
            if requiredBytes <= perWorkerBudget { return candidate }
        }
        return 1
    }

    private static func saturatedProduct(_ left: Int, _ right: Int) -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(value)
            return result.overflow ? Int.max : result.partialValue
        }
    }
}

private nonisolated struct LAVISignificanceWorkspaceDefinition: Sendable {
    var targetFourierMagnitudes: [Double]
    var sortedValues: [Double]
}

private nonisolated struct LAVISignificanceGeneratedSurrogate: Sendable {
    var runs: [[Double]]
    var diagnostics: IAAFTSurrogateDiagnostics
}

private nonisolated struct LAVISignificanceProfileOutcome: Sendable {
    var profile: [Double]
    var diagnostics: IAAFTSurrogateDiagnostics
}

private nonisolated final class LAVISignificanceWorkerContext: @unchecked Sendable {
    let workspaces: [IAAFTWorkspace]
    let coefficientProvider: any ComplexCoefficientProvider

    init(
        workspaces: [IAAFTWorkspace],
        coefficientProvider: any ComplexCoefficientProvider
    ) {
        self.workspaces = workspaces
        self.coefficientProvider = coefficientProvider
    }
}

/// Hides the production-provider marker so each outer surrogate worker runs
/// frequencies serially instead of creating a nested worker pool.
private nonisolated struct LAVISerialCoefficientProvider: ComplexCoefficientProvider {
    let base: any ComplexCoefficientProvider

    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile {
        try base.coefficients(
            signal: signal,
            samplingRate: samplingRate,
            frequencyHz: frequencyHz,
            widthCycles: widthCycles,
            edgePolicy: edgePolicy,
            cancellation: cancellation
        )
    }
}

private nonisolated final class LAVILockedArray<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element?]

    init(count: Int) { values = [Element?](repeating: nil, count: count) }

    func store(_ value: Element, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    var orderedValues: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0 }
    }
}

private nonisolated final class LAVISignificanceProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0

    var completedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func completeOne() -> Int {
        lock.lock()
        completed += 1
        let value = completed
        lock.unlock()
        return value
    }
}

private nonisolated final class LAVISignificanceFailureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var error: (any Error)?

    var hasFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return error != nil
    }

    var first: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func record(_ value: any Error) {
        lock.lock()
        if error == nil { error = value }
        lock.unlock()
    }
}
