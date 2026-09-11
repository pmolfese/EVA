//
//  AccelerateFFTComplexCoefficientProviderTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct AccelerateFFTComplexCoefficientProviderTests {
    @Test func forcedMultiBlockCoefficientsMatchDirectOracle() throws {
        let samplingRate = 200.0
        let samples = (0..<2_049).map { index in
            let time = Double(index) / samplingRate
            return 0.8 * sin(2 * Double.pi * 7 * time + 0.2)
                + 0.3 * cos(2 * Double.pi * 31 * time)
                + 0.05 * sin(Double(index) * 0.731)
        }
        let policy = RhythmicityComputePolicy(
            memoryBudgetBytes: 128 * 1_024 * 1_024,
            maximumWorkerCount: 1,
            preferredOutputTileSamples: 64
        )
        let kernel = LAVI2026Morlet.kernel(
            frequencyHz: 7,
            widthCycles: 5,
            samplingRate: samplingRate
        )
        let plan = try RhythmicityProductionWorkPlanner.convolutionPlan(
            signalSamples: samples.count,
            kernelSamples: kernel.count,
            policy: policy
        )
        #expect(plan.blockCount > 2)
        #expect(plan.outputSamplesPerBlock < samples.count)

        for edgePolicy in [RhythmicityEdgePolicy.referenceSamePadding, .validOnly] {
            let direct = try DirectComplexCoefficientProvider().coefficients(
                signal: samples,
                samplingRate: samplingRate,
                frequencyHz: 7,
                widthCycles: 5,
                edgePolicy: edgePolicy,
                cancellation: RhythmicityCancellation()
            )
            let fft = try AccelerateFFTComplexCoefficientProvider(policy: policy).coefficients(
                signal: samples,
                samplingRate: samplingRate,
                frequencyHz: 7,
                widthCycles: 5,
                edgePolicy: edgePolicy,
                cancellation: RhythmicityCancellation()
            )
            let maximumError = zip(direct.real, fft.real).reduce(0.0) {
                max($0, abs($1.0 - $1.1))
            }
            let maximumImaginaryError = zip(direct.imaginary, fft.imaginary).reduce(0.0) {
                max($0, abs($1.0 - $1.1))
            }
            #expect(maximumError < 1e-11)
            #expect(maximumImaginaryError < 1e-11)
            #expect(fft.validSampleRange == direct.validSampleRange)
        }
    }

    @Test func fftEngineMatchesDirectAcrossSegmentsAndIgnoresUnselectedGap() throws {
        let samplingRate = 256.0
        var samples = (0..<1_800).map { index in
            let time = Double(index) / samplingRate
            return sin(2 * Double.pi * 10 * time)
                + 0.25 * sin(2 * Double.pi * 23 * time + Double(index / 180) * 0.4)
        }
        samples[340] = .nan
        let segments = [
            RhythmicitySegment(startSample: 0, endSample: 799, trialID: "first"),
            RhythmicitySegment(startSample: 900, endSample: 1_799, trialID: "second"),
        ]
        let originalInput = Self.input(samples: samples, samplingRate: samplingRate, segments: segments)
        var contaminated = samples
        for index in 800..<900 { contaminated[index] = Double(index) * 1_000_000 }
        let contaminatedInput = Self.input(
            samples: contaminated,
            samplingRate: samplingRate,
            segments: segments
        )
        var directConfiguration = RhythmicityPreset.paperLAVI2026Exploratory
        directConfiguration.backend = .directReferenceCPU
        directConfiguration.frequenciesHz = [6, 10, 23, 50]
        let direct = try LAVIEngine.analyze(
            input: originalInput,
            configuration: directConfiguration
        )

        var fftConfiguration = directConfiguration
        fftConfiguration.backend = .accelerateFFTCPU
        fftConfiguration.computePolicy = RhythmicityComputePolicy(
            memoryBudgetBytes: 128 * 1_024 * 1_024,
            maximumWorkerCount: 2,
            preferredOutputTileSamples: 128
        )
        let fft = try LAVIEngine.analyze(input: originalInput, configuration: fftConfiguration)
        var singleWorkerConfiguration = fftConfiguration
        singleWorkerConfiguration.computePolicy.maximumWorkerCount = 1
        let singleWorker = try LAVIEngine.analyze(
            input: originalInput,
            configuration: singleWorkerConfiguration
        )
        let gapChanged = try LAVIEngine.analyze(
            input: contaminatedInput,
            configuration: fftConfiguration
        )
        #expect(fft.channels[0].validPairCounts == direct.channels[0].validPairCounts)
        #expect(singleWorker.channels[0].values == fft.channels[0].values)
        #expect(gapChanged.channels[0].validPairCounts == fft.channels[0].validPairCounts)
        for index in fftConfiguration.frequenciesHz.indices {
            #expect(abs(fft.channels[0].values[index] - direct.channels[0].values[index]) < 1e-11)
            #expect(abs(gapChanged.channels[0].values[index] - fft.channels[0].values[index]) < 1e-14)
        }
    }

    @Test func workerPlannerRespectsBothMemoryAndExplicitCaps() throws {
        let policy = RhythmicityComputePolicy(
            memoryBudgetBytes: 16 * 1_024 * 1_024,
            maximumWorkerCount: 3,
            preferredOutputTileSamples: 4_096
        )
        let workers = try RhythmicityProductionWorkPlanner.workerCount(
            workItemCount: 47,
            totalInputSamples: 10_000,
            longestRunSamples: 10_000,
            maximumKernelSamples: 512,
            policy: policy
        )
        #expect(workers >= 1)
        #expect(workers <= 3)
        let plan = try RhythmicityProductionWorkPlanner.convolutionPlan(
            signalSamples: 10_000,
            kernelSamples: 512,
            policy: policy
        )
        let reserved = 10_000 * 8
            + RhythmicityProductionWorkPlanner.kernelCacheBudget(policy: policy)
            + workers * plan.estimatedWorkingSetBytes
        #expect(reserved <= policy.memoryBudgetBytes)

        let insufficient = RhythmicityComputePolicy(
            memoryBudgetBytes: 256 * 1_024,
            maximumWorkerCount: 3,
            preferredOutputTileSamples: 4_096
        )
        #expect(throws: RhythmicityFFTError.self) {
            try RhythmicityProductionWorkPlanner.workerCount(
                workItemCount: 47,
                totalInputSamples: 10_000,
                longestRunSamples: 10_000,
                maximumKernelSamples: 512,
                policy: insufficient
            )
        }
        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.frequenciesHz = [4]
        configuration.computePolicy = insufficient
        #expect(throws: RhythmicityFFTError.self) {
            try LAVIEngine.analyze(
                input: Self.input(
                    samples: (0..<10_000).map { sin(Double($0) * 0.03) },
                    samplingRate: 256
                ),
                configuration: configuration
            )
        }
    }

    @Test func engineWorkerPoolIsBoundedAndProgressNeverRegresses() throws {
        let probe = ProductionConcurrencyProbeProvider()
        let frequencies = [5.0, 7, 9, 12, 16, 22, 30, 40]
        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.backend = .accelerateFFTCPU
        configuration.frequenciesHz = frequencies
        configuration.edgePolicy = .referenceSamePadding
        configuration.computePolicy = RhythmicityComputePolicy(
            memoryBudgetBytes: 64 * 1_024 * 1_024,
            maximumWorkerCount: 2,
            preferredOutputTileSamples: 256
        )
        let progress = ProductionProgressRecorder()
        let samples = (0..<1_024).map { sin(Double($0) * 0.19) + 0.2 * cos(Double($0) * 0.37) }
        let result = try LAVIEngine.analyze(
            input: Self.input(samples: samples, samplingRate: 128),
            configuration: configuration,
            coefficientProvider: probe
        ) { progress.append($0) }
        #expect(result.channels[0].values.count == frequencies.count)
        #expect(probe.maximumConcurrentCalls == 2)
        #expect(progress.updates.last?.fractionComplete == 1)
        #expect(zip(progress.fractions, progress.fractions.dropFirst()).allSatisfy { $0 <= $1 })
        let transformUpdates = progress.updates.filter { $0.phase == .transforming && $0.frequencyHz != nil }
        #expect(transformUpdates.count == frequencies.count)
        #expect(transformUpdates.last?.completedTiles == frequencies.count)
    }

    @Test func cancellationBetweenOverlapSaveBlocksReturnsNoTile() {
        let cancellation = RhythmicityCancellation()
        let policy = RhythmicityComputePolicy(
            memoryBudgetBytes: 128 * 1_024 * 1_024,
            maximumWorkerCount: 1,
            preferredOutputTileSamples: 128
        )
        let provider = AccelerateFFTComplexCoefficientProvider(policy: policy) { completed, total in
            if completed == 1, total > 1 { cancellation.cancel() }
        }
        let samples = (0..<8_192).map { sin(Double($0) * 0.07) }
        #expect(throws: CancellationError.self) {
            try provider.coefficients(
                signal: samples,
                samplingRate: 256,
                frequencyHz: 8,
                widthCycles: 5,
                edgePolicy: .validOnly,
                cancellation: cancellation
            )
        }
    }

    @Test func fftIsFasterThanDirectOnRepresentativeLongKernel() throws {
        let samplingRate = 512.0
        let samples = (0..<32_768).map { index in
            let time = Double(index) / samplingRate
            return sin(2 * Double.pi * 4 * time)
                + 0.3 * cos(2 * Double.pi * 17 * time + 0.3)
        }
        let clock = ContinuousClock()
        let directStart = clock.now
        let direct = try DirectComplexCoefficientProvider().coefficients(
            signal: samples,
            samplingRate: samplingRate,
            frequencyHz: 4,
            widthCycles: 5,
            edgePolicy: .validOnly,
            cancellation: RhythmicityCancellation()
        )
        let directDuration = clock.now - directStart
        let fftStart = clock.now
        let fft = try AccelerateFFTComplexCoefficientProvider().coefficients(
            signal: samples,
            samplingRate: samplingRate,
            frequencyHz: 4,
            widthCycles: 5,
            edgePolicy: .validOnly,
            cancellation: RhythmicityCancellation()
        )
        let fftDuration = clock.now - fftStart
        let error = zip(direct.real, fft.real).reduce(0.0) { max($0, abs($1.0 - $1.1)) }
        print("Rhythmicity direct \(directDuration), FFT \(fftDuration), max error \(error)")
        #expect(error < 1e-11)
        #expect(fftDuration < directDuration)
    }

    @Test func benchmarksTwoMinuteFourChannelPaperProfile() throws {
        let samplingRate = 256.0
        let sampleCount = Int(samplingRate * 120)
        let channels = (0..<4).map { channel in
            RhythmicityChannelInput(
                channelIndex: channel,
                channelName: "E\(channel + 1)",
                samples: (0..<sampleCount).map { index in
                    let time = Double(index) / samplingRate
                    return sin(2 * Double.pi * (8 + Double(channel)) * time)
                        + 0.2 * cos(2 * Double.pi * 21 * time + Double(channel) * 0.3)
                }
            )
        }
        let input = RhythmicityInput.entireRecording(
            channels: channels,
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "m3-benchmark", displayName: "M3 Benchmark"),
            processingProvenance: .init(sourceRevision: "1")
        )
        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.computePolicy = RhythmicityComputePolicy(
            memoryBudgetBytes: 128 * 1_024 * 1_024,
            maximumWorkerCount: 4,
            preferredOutputTileSamples: 4_096
        )
        let clock = ContinuousClock()
        let start = clock.now
        let result = try LAVIEngine.analyze(input: input, configuration: configuration)
        let duration = clock.now - start
        print(
            "Rhythmicity 120 s × 4 channels × \(configuration.frequenciesHz.count) frequencies: "
                + "\(duration)"
        )
        #expect(result.channels.count == 4)
        #expect(result.channels.allSatisfy { $0.values.count == 47 })
        #expect(result.channels.allSatisfy { $0.values.allSatisfy(\.isFinite) })
        #expect(duration < .seconds(30))
    }

    private static func input(
        samples: [Double],
        samplingRate: Double,
        segments: [RhythmicitySegment]? = nil
    ) -> RhythmicityInput {
        let channel = RhythmicityChannelInput(
            channelIndex: 0,
            channelName: "E1",
            samples: samples
        )
        if let segments {
            return RhythmicityInput(
                channels: [channel],
                samplingRate: samplingRate,
                segments: segments,
                source: .init(recordingIdentity: "m3-test", displayName: "M3 Test"),
                processingProvenance: .init(sourceRevision: "1")
            )
        }
        return .entireRecording(
            channels: [channel],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "m3-test", displayName: "M3 Test"),
            processingProvenance: .init(sourceRevision: "1")
        )
    }
}

private nonisolated final class ProductionConcurrencyProbeProvider:
    RhythmicityProductionCoefficientProvider,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var activeCalls = 0
    private var peakCalls = 0

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakCalls
    }

    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile {
        try cancellation.check()
        lock.lock()
        activeCalls += 1
        peakCalls = max(peakCalls, activeCalls)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.01)
        lock.lock()
        activeCalls -= 1
        lock.unlock()
        try cancellation.check()
        return ComplexCoefficientTile(
            frequencyHz: frequencyHz,
            real: signal,
            imaginary: signal.indices.map { 0.1 * sin(Double($0) * frequencyHz / samplingRate) },
            validSampleRange: signal.indices
        )
    }
}

private nonisolated final class ProductionProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RhythmicityProgress] = []

    func append(_ update: RhythmicityProgress) {
        lock.lock()
        values.append(update)
        lock.unlock()
    }

    var updates: [RhythmicityProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var fractions: [Double] { updates.map(\.fractionComplete) }
}
