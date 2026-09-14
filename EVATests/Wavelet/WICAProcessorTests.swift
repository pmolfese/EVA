//
//  WICAProcessorTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct WICAProcessorTests {
    private let rate = 250.0
    private let count = 4_096

    private func fixture() -> MFFSignalData {
        var artifact = (0..<count).map { Float(0.15 * sin(Double($0) * 0.08)) }
        for sample in stride(from: 180, to: count, by: 430) { artifact[sample] += 30 }
        let brain = (0..<count).map {
            Float(2.0 * sin(2 * .pi * 10 * Double($0) / rate))
        }
        return SyntheticSignal.make([artifact, brain], samplingRate: rate)
    }

    private func identityDecomposition(for signal: MFFSignalData) -> ICADecomposition {
        ICADecomposition(
            sourceSignalPath: signal.signalURL.path,
            sourceSamplingRate: rate,
            analysisSamplingRate: rate,
            decimation: 1,
            fitFilter: nil,
            convergenceTolerance: 1e-12,
            minimumIterations: 1,
            finalChange: 0,
            varianceThreshold: 1,
            pcaVarianceRetained: 1,
            averageReference: false,
            channelCount: 2,
            sampleCount: count,
            componentCount: 2,
            iterations: 1,
            channelMeans: [0, 0],
            mixingMatrix: [[1, 0], [0, 1]],
            unmixingMatrix: [[1, 0], [0, 1]],
            componentMaps: [[1, 0], [0, 1]],
            componentSources: signal.data.map { $0.map(Double.init) },
            explainedVariance: [1, 1],
            pcaExplainedVariance: [1, 1]
        )
    }

    private func configuration(cores: Int = 1, batchSize: Int = 16) -> WICAConfiguration {
        var wavelet = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: rate)
        wavelet.levelCount = 6
        wavelet.useGPU = false
        return WICAConfiguration(wavelet: wavelet, coreCount: cores, componentBatchSize: batchSize)
    }

    @Test func selectiveWICALeavesUnselectedBrainComponentUntouched() throws {
        let signal = fixture()
        let result = try WICAProcessor.reduce(
            signal: signal,
            decomposition: identityDecomposition(for: signal),
            componentIndices: [0],
            configuration: configuration()
        )

        #expect(result.processedComponents == [0])
        #expect(result.cleaned.data[1] == signal.data[1])
        #expect(result.artifact.data[1].allSatisfy { $0 == 0 })
        #expect(result.cleaned.data[0] != signal.data[0])
        #expect(result.perComponent[0] != nil)
        #expect(result.cleanedComponentPreviews[0]?.count == count)
        #expect(result.cleanedComponentPreviews[1] == nil)
    }

    @Test func allComponentWICAMatchesChannelWaveletUpToICACentering() throws {
        let signal = fixture()
        let config = configuration(batchSize: 1)
        let wica = try WICAProcessor.reduce(
            signal: signal,
            decomposition: identityDecomposition(for: signal),
            componentIndices: [0, 1],
            configuration: config
        )
        let direct = WaveletReducer.reduce(
            signal: signal,
            channelIndices: [0, 1],
            configuration: config.wavelet,
            coreCount: 1
        )

        for channel in signal.data.indices {
            // ICA is fitted and activated on centered channels, so W-ICA keeps
            // each sensor's DC offset while channel-space wavelet reduction
            // places that offset in its deepest approximation/artifact band.
            // Apart from that single constant, identity mixing must produce the
            // same samples.
            let differences = zip(wica.cleaned.data[channel], direct.cleaned.data[channel])
                .map { Double($0) - Double($1) }
            let offset = differences.reduce(0, +) / Double(differences.count)
            let maximumCenteredDifference = differences.map { abs($0 - offset) }.max() ?? 0
            #expect(maximumCenteredDifference < 1e-5,
                    "channel \(channel) centered difference \(maximumCenteredDifference)")
        }
    }

    @Test func batchingDoesNotChangeTheResult() throws {
        let signal = fixture()
        let decomposition = identityDecomposition(for: signal)
        let separate = try WICAProcessor.reduce(
            signal: signal,
            decomposition: decomposition,
            componentIndices: [0, 1],
            configuration: configuration(batchSize: 1)
        )
        let together = try WICAProcessor.reduce(
            signal: signal,
            decomposition: decomposition,
            componentIndices: [0, 1],
            configuration: configuration(batchSize: 2)
        )

        for channel in signal.data.indices {
            let maximumDifference = zip(separate.cleaned.data[channel], together.cleaned.data[channel])
                .map { abs(Double($0) - Double($1)) }
                .max() ?? 0
            #expect(maximumDifference < 1e-5, "channel \(channel) difference \(maximumDifference)")
        }
    }

    @Test func selectiveWICAPreservesASharpBrainSourceWhileRemovingMixedArtifact() throws {
        // An exact two-source fixture makes the scientific distinction explicit:
        // the same sharp neural transient and sparse artifact appear in both
        // sensor channels. Channel-space wavelets cannot know which is which;
        // selective W-ICA receives an exact separation and thresholds only the
        // artifact source. This tests W-ICA's promised reconstruction behavior,
        // not ICA-identifiability or ICLabel accuracy (those require their own
        // simulator axes).
        var brain = (0..<count).map {
            Float(1.5 * sin(2 * .pi * 10 * Double($0) / rate))
        }
        let transientCenter = 2_000
        for offset in -60...60 {
            let x = Double(offset) / 18
            brain[transientCenter + offset] += Float(45 * (1 - x * x) * exp(-0.5 * x * x))
        }
        var artifact = [Float](repeating: 0, count: count)
        for center in stride(from: 250, to: count, by: 520) {
            for offset in -12...12 where center + offset >= 0 && center + offset < count {
                artifact[center + offset] += Float(55 * exp(-0.5 * pow(Double(offset) / 3, 2)))
            }
        }

        // x = A s; A is deliberately non-identity so each sensor contains both
        // sources. W below is its exact inverse.
        let clean = [
            brain,
            brain.map { 0.6 * $0 }
        ]
        let noisy = [
            zip(brain, artifact).map { $0 + 0.8 * $1 },
            zip(brain, artifact).map { 0.6 * $0 - 0.9 * $1 }
        ]
        let signal = SyntheticSignal.make(noisy, samplingRate: rate)
        var decomposition = identityDecomposition(for: signal)
        decomposition.mixingMatrix = [[1, 0.8], [0.6, -0.9]]
        decomposition.unmixingMatrix = [
            [0.6521739130434783, 0.5797101449275363],
            [0.4347826086956522, -0.7246376811594203]
        ]
        decomposition.componentMaps = [[1, 0.6], [0.8, -0.9]]

        var cfg = configuration()
        cfg.wavelet.thresholdScale = 1
        let selective = try WICAProcessor.reduce(
            signal: signal,
            decomposition: decomposition,
            componentIndices: [1],
            configuration: cfg
        ).cleaned.data
        let channelSpace = WaveletReducer.reduce(
            signal: signal,
            channelIndices: [0, 1],
            configuration: cfg.wavelet,
            coreCount: 1
        ).cleaned.data

        func variance(_ values: ArraySlice<Double>) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            return values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        }
        func preservation(_ corrected: [[Float]]) -> Double {
            let range = (transientCenter - 60)..<(transientCenter + 61)
            let truth = clean[0][range].map(Double.init)[...]
            let residual = zip(corrected[0][range], clean[0][range]).map {
                Double($0) - Double($1)
            }[...]
            return 1 - variance(residual) / variance(truth)
        }
        func artifactRemoval(_ corrected: [[Float]]) -> Double {
            let added = zip(noisy[0], clean[0]).map { Double($0) - Double($1) }[...]
            let residual = zip(corrected[0], clean[0]).map { Double($0) - Double($1) }[...]
            return 1 - variance(residual) / variance(added)
        }

        let selectivePreservation = preservation(selective)
        let channelPreservation = preservation(channelSpace)
        let selectiveRemoval = artifactRemoval(selective)
        #expect(selectivePreservation > 0.95, "selective preservation \(selectivePreservation)")
        #expect(selectivePreservation > channelPreservation + 0.20,
                "selective \(selectivePreservation), channel \(channelPreservation)")
        #expect(selectiveRemoval > 0.50, "selective artifact removal \(selectiveRemoval)")
    }

    @Test func emptySelectionIsRefused() {
        let signal = fixture()
        #expect(throws: WICAError.self) {
            try WICAProcessor.reduce(
                signal: signal,
                decomposition: identityDecomposition(for: signal),
                componentIndices: [],
                configuration: configuration()
            )
        }
    }
}
