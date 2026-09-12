//
//  LAVIEngine.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Segment-aware Local Auto-correlated Vector Index reduction.
//

import Foundation

nonisolated enum LAVIEngine {
    static func analyze(
        input: RhythmicityInput,
        configuration: RhythmicityConfiguration,
        coefficientProvider: (any ComplexCoefficientProvider)? = nil,
        cancellation: RhythmicityCancellation = RhythmicityCancellation(),
        progress: (@Sendable (RhythmicityProgress) -> Void)? = nil
    ) throws -> LAVIAnalysisResult {
        try cancellation.check()
        progress?(
            RhythmicityProgress(
                fractionComplete: 0,
                phase: .validating,
                channelIndex: nil,
                frequencyHz: nil,
                completedTiles: 0,
                totalTiles: input.channels.count * configuration.frequenciesHz.count
            )
        )
        try validate(input: input, configuration: configuration)
        let resolvedCoefficientProvider: any ComplexCoefficientProvider
        if let coefficientProvider {
            resolvedCoefficientProvider = coefficientProvider
        } else {
            switch configuration.backend {
            case .directReferenceCPU:
                resolvedCoefficientProvider = DirectComplexCoefficientProvider()
            case .accelerateFFTCPU:
                resolvedCoefficientProvider = AccelerateFFTComplexCoefficientProvider(
                    policy: configuration.computePolicy
                )
            }
        }
        let totalTiles = input.channels.count * configuration.frequenciesHz.count
        var completedTiles = 0
        var channelResults: [LAVIChannelResult] = []
        var allWarnings: [RhythmicityWarning] = []

        progress?(
            RhythmicityProgress(
                fractionComplete: 0.03,
                phase: .transforming,
                channelIndex: nil,
                frequencyHz: nil,
                completedTiles: 0,
                totalTiles: totalTiles
            )
        )

        let hasSignificance: Bool
        if case .onDemand = configuration.significance {
            hasSignificance = true
        } else {
            hasSignificance = false
        }
        let channelSpan = 0.94 / Double(max(input.channels.count, 1))

        for (channelOrdinal, channel) in input.channels.enumerated() {
            try cancellation.check()
            let channelBase = 0.03 + Double(channelOrdinal) * channelSpan
            let transformShare = hasSignificance ? 0.42 : 0.88
            let finiteSelection = finiteRuns(
                samples: channel.samples,
                segments: input.segments
            )
            var channelWarnings: [RhythmicityWarning] = []
            if finiteSelection.excludedCount > 0 {
                channelWarnings.append(
                    .nonfiniteSamplesExcluded(
                        channelIndex: channel.channelIndex,
                        count: finiteSelection.excludedCount
                    )
                )
            }

            // Copy each finite run once. Frequency workers share these immutable
            // arrays rather than making a full signal copy for every tile.
            let finiteSignals = finiteSelection.ranges.map { Array(channel.samples[$0]) }
            let tileProgress = LAVITileProgressReporter(
                initialCompletedTiles: completedTiles,
                frequencyCount: configuration.frequenciesHz.count,
                channelBase: channelBase,
                channelSpan: channelSpan,
                transformShare: transformShare,
                channelIndex: channel.channelIndex,
                totalTiles: totalTiles,
                progress: progress
            )
            let frequencyResults = try analyzeFrequencies(
                finiteSignals: finiteSignals,
                samplingRate: input.samplingRate,
                channelIndex: channel.channelIndex,
                configuration: configuration,
                coefficientProvider: resolvedCoefficientProvider,
                cancellation: cancellation
            ) { frequency in
                tileProgress.completed(frequencyHz: frequency)
            }
            completedTiles += frequencyResults.count
            let values = frequencyResults.map(\.value)
            let pairCounts = frequencyResults.map(\.pairCount)
            let durations = frequencyResults.map(\.effectiveDurationSeconds)
            for result in frequencyResults {
                channelWarnings.append(contentsOf: result.warnings)
            }

            try cancellation.check()
            var significanceResolution: LAVISignificanceResolution?
            if case let .onDemand(significanceConfiguration) = configuration.significance {
                let completedObservedTiles = completedTiles
                progress?(
                    RhythmicityProgress(
                        fractionComplete: channelBase + channelSpan * 0.45,
                        phase: .estimatingAperiodicSpectrum,
                        channelIndex: channel.channelIndex,
                        frequencyHz: nil,
                        completedTiles: completedTiles,
                        totalTiles: totalTiles
                    )
                )
                significanceResolution = try LAVISignificanceProvider.resolve(
                    channel: channel,
                    input: input,
                    analysisConfiguration: configuration,
                    significanceConfiguration: significanceConfiguration,
                    coefficientProvider: resolvedCoefficientProvider,
                    cancellation: cancellation
                ) { completed, total in
                    let fraction = Double(completed) / Double(max(total, 1))
                    progress?(
                        RhythmicityProgress(
                            fractionComplete: channelBase + channelSpan * (0.48 + 0.47 * fraction),
                            phase: .generatingSignificance,
                            channelIndex: channel.channelIndex,
                            frequencyHz: nil,
                            completedTiles: completedObservedTiles,
                            totalTiles: totalTiles
                        )
                    )
                }
                if let count = significanceResolution?.surrogateSummary.nonconvergedCount,
                   count > 0 {
                    channelWarnings.append(
                        .iaaftSurrogatesDidNotConverge(
                            channelIndex: channel.channelIndex,
                            count: count
                        )
                    )
                }
            }
            progress?(
                RhythmicityProgress(
                    fractionComplete: channelBase + channelSpan * 0.97,
                    phase: .assigningBands,
                    channelIndex: channel.channelIndex,
                    frequencyHz: nil,
                    completedTiles: completedTiles,
                    totalTiles: totalTiles
                )
            )
            let abba = try ABBAEngine.detectBands(
                lavi: values,
                frequenciesHz: configuration.frequenciesHz,
                alphaAnchorHz: configuration.alphaAnchorHz,
                ribbon: significanceResolution?.ribbon
            )
            channelWarnings.append(contentsOf: abba.warnings)
            allWarnings.append(contentsOf: channelWarnings)
            channelResults.append(
                LAVIChannelResult(
                    channelIndex: channel.channelIndex,
                    channelName: channel.channelName,
                    frequenciesHz: configuration.frequenciesHz,
                    values: values,
                    validPairCounts: pairCounts,
                    effectiveDurationsSeconds: durations,
                    median: abba.median,
                    lowerSignificance: significanceResolution?.ribbon.lower,
                    upperSignificance: significanceResolution?.ribbon.upper,
                    significanceRibbon: significanceResolution?.ribbon,
                    aperiodicFit: significanceResolution?.aperiodicFit,
                    surrogateSummary: significanceResolution?.surrogateSummary,
                    bands: abba.bands,
                    warnings: channelWarnings
                )
            )
        }

        try cancellation.check()
        progress?(
            RhythmicityProgress(
                fractionComplete: 1,
                phase: .finished,
                channelIndex: nil,
                frequencyHz: nil,
                completedTiles: completedTiles,
                totalTiles: totalTiles
            )
        )
        return LAVIAnalysisResult(
            configuration: configuration,
            source: input.source,
            processingProvenance: input.processingProvenance,
            samplingRateHz: input.samplingRate,
            channels: channelResults,
            warnings: allWarnings
        )
    }

    private static func analyzeFrequencies(
        finiteSignals: [[Double]],
        samplingRate: Double,
        channelIndex: Int,
        configuration: RhythmicityConfiguration,
        coefficientProvider: any ComplexCoefficientProvider,
        cancellation: RhythmicityCancellation,
        completed: @escaping @Sendable (_ frequencyHz: Double) -> Void
    ) throws -> [LAVIFrequencyComputation] {
        let frequencies = configuration.frequenciesHz
        let usesProductionPool = configuration.backend == .accelerateFFTCPU
            && coefficientProvider is any RhythmicityProductionCoefficientProvider
        guard usesProductionPool else {
            var output: [LAVIFrequencyComputation] = []
            output.reserveCapacity(frequencies.count)
            for frequency in frequencies {
                let result = try analyzeFrequency(
                    finiteSignals: finiteSignals,
                    samplingRate: samplingRate,
                    frequencyHz: frequency,
                    channelIndex: channelIndex,
                    configuration: configuration,
                    coefficientProvider: coefficientProvider,
                    cancellation: cancellation
                )
                output.append(result)
                completed(frequency)
            }
            return output
        }

        let maximumKernelSamples = frequencies.map {
            LAVI2026Morlet.kernel(
                frequencyHz: $0,
                widthCycles: configuration.morletWidthCycles,
                samplingRate: samplingRate
            ).count
        }.max() ?? 1
        let workerCount = try RhythmicityProductionWorkPlanner.workerCount(
            workItemCount: frequencies.count,
            totalInputSamples: finiteSignals.reduce(0) { $0 + $1.count },
            longestRunSamples: finiteSignals.map(\.count).max() ?? 0,
            maximumKernelSamples: maximumKernelSamples,
            policy: configuration.computePolicy
        )
        let outcomes = LAVIFrequencyOutcomeStore(count: frequencies.count)
        let failures = LAVIFrequencyFailureStore()
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            var frequencyIndex = worker
            while frequencyIndex < frequencies.count {
                if failures.hasFailure { return }
                do {
                    try cancellation.check()
                    let frequency = frequencies[frequencyIndex]
                    let result = try analyzeFrequency(
                        finiteSignals: finiteSignals,
                        samplingRate: samplingRate,
                        frequencyHz: frequency,
                        channelIndex: channelIndex,
                        configuration: configuration,
                        coefficientProvider: coefficientProvider,
                        cancellation: cancellation
                    )
                    outcomes.store(result, at: frequencyIndex)
                    completed(frequency)
                } catch {
                    failures.record(error)
                    return
                }
                frequencyIndex += workerCount
            }
        }
        if let error = failures.first { throw error }
        let ordered = outcomes.orderedValues
        guard ordered.count == frequencies.count else {
            throw RhythmicityAnalysisError.incompleteFrequencyResults(
                expected: frequencies.count,
                actual: ordered.count
            )
        }
        return ordered
    }

    private static func analyzeFrequency(
        finiteSignals: [[Double]],
        samplingRate: Double,
        frequencyHz: Double,
        channelIndex: Int,
        configuration: RhythmicityConfiguration,
        coefficientProvider: any ComplexCoefficientProvider,
        cancellation: RhythmicityCancellation
    ) throws -> LAVIFrequencyComputation {
        try cancellation.check()
        var reduction = LAVIReduction()
        let exactLag = configuration.laviLagCycles * samplingRate / frequencyHz
        let wholeLag = Int(floor(exactLag))
        let lagFraction = exactLag - Double(wholeLag)
        for finiteSignal in finiteSignals {
            try cancellation.check()
            guard wholeLag + 1 < finiteSignal.count else { continue }
            let tile = try coefficientProvider.coefficients(
                signal: finiteSignal,
                samplingRate: samplingRate,
                frequencyHz: frequencyHz,
                widthCycles: configuration.morletWidthCycles,
                edgePolicy: configuration.edgePolicy,
                cancellation: cancellation
            )
            guard tile.real.count == finiteSignal.count,
                  tile.imaginary.count == finiteSignal.count else {
                throw RhythmicityAnalysisError.coefficientShapeMismatch(
                    expected: finiteSignal.count,
                    real: tile.real.count,
                    imaginary: tile.imaginary.count
                )
            }
            try accumulate(
                tile: tile,
                wholeLag: wholeLag,
                lagFraction: lagFraction,
                cancellation: cancellation,
                into: &reduction
            )
        }
        let rawValue = reduction.finalValue()
        var warnings: [RhythmicityWarning] = []
        if reduction.pairCount == 0 || !rawValue.isFinite {
            warnings.append(
                .insufficientValidDuration(
                    channelIndex: channelIndex,
                    frequencyHz: frequencyHz
                )
            )
        } else if rawValue < -1e-12 || rawValue > 1.0 + 1e-12 {
            warnings.append(
                .laviOutsideUnitInterval(
                    channelIndex: channelIndex,
                    frequencyHz: frequencyHz,
                    value: rawValue
                )
            )
        }
        return LAVIFrequencyComputation(
            value: unitClampedWithinTolerance(rawValue),
            pairCount: reduction.pairCount,
            effectiveDurationSeconds: Double(reduction.pairCount) / samplingRate,
            warnings: warnings
        )
    }

    @discardableResult
    static func validate(
        input: RhythmicityInput,
        configuration: RhythmicityConfiguration
    ) throws -> Int {
        guard !input.channels.isEmpty else { throw RhythmicityAnalysisError.noChannels }
        guard input.samplingRate.isFinite, input.samplingRate > 0 else {
            throw RhythmicityAnalysisError.invalidSamplingRate(input.samplingRate)
        }
        let sampleCount = input.channels[0].samples.count
        guard sampleCount > 0 else {
            throw RhythmicityAnalysisError.emptyChannel(
                channelIndex: input.channels[0].channelIndex
            )
        }
        for channel in input.channels.dropFirst() {
            guard !channel.samples.isEmpty else {
                throw RhythmicityAnalysisError.emptyChannel(channelIndex: channel.channelIndex)
            }
            guard channel.samples.count == sampleCount else {
                throw RhythmicityAnalysisError.mismatchedChannelLength(
                    channelIndex: channel.channelIndex,
                    expected: sampleCount,
                    actual: channel.samples.count
                )
            }
        }

        guard !input.segments.isEmpty else { throw RhythmicityAnalysisError.noSegments }
        var previousEnd: Int?
        for (index, segment) in input.segments.enumerated() {
            guard segment.startSample >= 0,
                  segment.endSample >= segment.startSample,
                  segment.endSample < sampleCount else {
                throw RhythmicityAnalysisError.invalidSegment(
                    index: index,
                    start: segment.startSample,
                    end: segment.endSample,
                    sampleCount: sampleCount
                )
            }
            if let previousEnd, segment.startSample <= previousEnd {
                throw RhythmicityAnalysisError.overlappingOrUnsortedSegments(index: index)
            }
            previousEnd = segment.endSample
        }

        guard !configuration.frequenciesHz.isEmpty else {
            throw RhythmicityAnalysisError.noFrequencies
        }
        let nyquist = input.samplingRate / 2.0
        for index in configuration.frequenciesHz.indices {
            let frequency = configuration.frequenciesHz[index]
            guard frequency.isFinite, frequency > 0 else {
                throw RhythmicityAnalysisError.invalidFrequency(index: index, value: frequency)
            }
            if index > 0, frequency <= configuration.frequenciesHz[index - 1] {
                throw RhythmicityAnalysisError.frequenciesNotStrictlyAscending(index: index)
            }
            guard frequency < nyquist else {
                throw RhythmicityAnalysisError.frequencyAtOrAboveNyquist(
                    index: index,
                    value: frequency,
                    nyquist: nyquist
                )
            }
        }
        guard configuration.morletWidthCycles.isFinite,
              configuration.morletWidthCycles > 0 else {
            throw RhythmicityAnalysisError.invalidMorletWidth(
                configuration.morletWidthCycles
            )
        }
        guard configuration.laviLagCycles.isFinite,
              configuration.laviLagCycles > 0 else {
            throw RhythmicityAnalysisError.invalidLAVILag(configuration.laviLagCycles)
        }
        if case let .onDemand(significance) = configuration.significance {
            try LAVISignificanceProvider.validate(significance)
        }
        if configuration.backend == .accelerateFFTCPU {
            try RhythmicityProductionWorkPlanner.validate(configuration.computePolicy)
        }
        return sampleCount
    }

    private static func finiteRuns(
        samples: [Double],
        segments: [RhythmicitySegment]
    ) -> (ranges: [Range<Int>], excludedCount: Int) {
        var ranges: [Range<Int>] = []
        var excludedCount = 0
        for segment in segments {
            var runStart: Int?
            for index in segment.startSample...segment.endSample {
                if samples[index].isFinite {
                    if runStart == nil { runStart = index }
                } else {
                    excludedCount += 1
                    if let start = runStart {
                        ranges.append(start..<index)
                        runStart = nil
                    }
                }
            }
            if let start = runStart {
                ranges.append(start..<(segment.endSample + 1))
            }
        }
        return (ranges, excludedCount)
    }

    private static func accumulate(
        tile: ComplexCoefficientTile,
        wholeLag: Int,
        lagFraction: Double,
        cancellation: RhythmicityCancellation,
        into reduction: inout LAVIReduction
    ) throws {
        guard wholeLag >= 0, wholeLag + 1 < tile.real.count else { return }
        let lower = max(tile.validSampleRange.lowerBound, 0)
        let upper = min(
            tile.real.count - wholeLag - 1,
            tile.validSampleRange.upperBound - wholeLag - 1
        )
        guard upper > lower else { return }

        for index in lower..<upper {
            if index & 0x3ff == 0 { try cancellation.check() }
            let firstReal = tile.real[index]
            let firstImaginary = tile.imaginary[index]
            let lowerReal = tile.real[index + wholeLag]
            let lowerImaginary = tile.imaginary[index + wholeLag]
            let upperReal = tile.real[index + wholeLag + 1]
            let upperImaginary = tile.imaginary[index + wholeLag + 1]
            let secondReal = (1.0 - lagFraction) * lowerReal + lagFraction * upperReal
            let secondImaginary = (1.0 - lagFraction) * lowerImaginary
                + lagFraction * upperImaginary
            guard firstReal.isFinite,
                  firstImaginary.isFinite,
                  secondReal.isFinite,
                  secondImaginary.isFinite else { continue }
            reduction.add(
                firstReal: firstReal,
                firstImaginary: firstImaginary,
                secondReal: secondReal,
                secondImaginary: secondImaginary
            )
        }
    }

    private static func unitClampedWithinTolerance(_ value: Double) -> Double {
        guard value.isFinite else { return .nan }
        if value > 1, value <= 1 + 1e-12 { return 1 }
        if value < 0, value >= -1e-12 { return 0 }
        return value
    }
}

private nonisolated struct LAVIFrequencyComputation: Sendable {
    var value: Double
    var pairCount: Int
    var effectiveDurationSeconds: Double
    var warnings: [RhythmicityWarning]
}

private nonisolated final class LAVIFrequencyOutcomeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LAVIFrequencyComputation?]

    init(count: Int) { values = [LAVIFrequencyComputation?](repeating: nil, count: count) }

    func store(_ value: LAVIFrequencyComputation, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    var orderedValues: [LAVIFrequencyComputation] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0 }
    }
}

private nonisolated final class LAVIFrequencyFailureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any Error)?

    var hasFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }

    var first: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ error: any Error) {
        lock.lock()
        if value == nil { value = error }
        lock.unlock()
    }
}

/// Serializes progress callbacks from the concurrent worker pool. The result
/// order remains frequency-indexed, while progress reflects completed work and
/// can never regress because of worker scheduling.
private nonisolated final class LAVITileProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let initialCompletedTiles: Int
    private let frequencyCount: Int
    private let channelBase: Double
    private let channelSpan: Double
    private let transformShare: Double
    private let channelIndex: Int
    private let totalTiles: Int
    private let progress: (@Sendable (RhythmicityProgress) -> Void)?
    private var completedCount = 0

    init(
        initialCompletedTiles: Int,
        frequencyCount: Int,
        channelBase: Double,
        channelSpan: Double,
        transformShare: Double,
        channelIndex: Int,
        totalTiles: Int,
        progress: (@Sendable (RhythmicityProgress) -> Void)?
    ) {
        self.initialCompletedTiles = initialCompletedTiles
        self.frequencyCount = frequencyCount
        self.channelBase = channelBase
        self.channelSpan = channelSpan
        self.transformShare = transformShare
        self.channelIndex = channelIndex
        self.totalTiles = totalTiles
        self.progress = progress
    }

    func completed(frequencyHz: Double) {
        lock.lock()
        completedCount += 1
        let fraction = Double(completedCount) / Double(max(frequencyCount, 1))
        progress?(
            RhythmicityProgress(
                fractionComplete: channelBase + channelSpan * transformShare * fraction,
                phase: .transforming,
                channelIndex: channelIndex,
                frequencyHz: frequencyHz,
                completedTiles: initialCompletedTiles + completedCount,
                totalTiles: totalTiles
            )
        )
        lock.unlock()
    }
}

private nonisolated struct CompensatedSum {
    private(set) var value = 0.0
    private var compensation = 0.0

    mutating func add(_ addition: Double) {
        let corrected = addition - compensation
        let next = value + corrected
        compensation = (next - value) - corrected
        value = next
    }
}

private nonisolated struct LAVIReduction {
    private var numeratorReal = CompensatedSum()
    private var numeratorImaginary = CompensatedSum()
    private var firstEnergy = CompensatedSum()
    private var secondEnergy = CompensatedSum()
    private(set) var pairCount = 0

    mutating func add(
        firstReal: Double,
        firstImaginary: Double,
        secondReal: Double,
        secondImaginary: Double
    ) {
        numeratorReal.add(firstReal * secondReal + firstImaginary * secondImaginary)
        numeratorImaginary.add(firstImaginary * secondReal - firstReal * secondImaginary)
        firstEnergy.add(firstReal * firstReal + firstImaginary * firstImaginary)
        secondEnergy.add(secondReal * secondReal + secondImaginary * secondImaginary)
        pairCount += 1
    }

    func finalValue() -> Double {
        guard pairCount > 0, firstEnergy.value > 0, secondEnergy.value > 0 else {
            return .nan
        }
        let numerator = hypot(numeratorReal.value, numeratorImaginary.value)
        return numerator / sqrt(firstEnergy.value * secondEnergy.value)
    }
}
