//
//  FastrCorrectorTests.swift
//  EVATests
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

import Testing
import Foundation
@testable import EVA

struct FastrCorrectorTests {

    // Build a synthetic EEG channel: small physiological signal + a large
    // repeating gradient artifact locked to evenly-spaced volume triggers.
    private func makeSyntheticChannel(spacing: Int, volumes: Int)
        -> (channel: [Float], triggers: [Int]) {
        let sampleCount = spacing * volumes
        func gradient(_ k: Int) -> Float { 80 * Float(sin(Double(k) * 0.4)) + 40 * Float(k % 11) }
        func physio(_ t: Int) -> Float { 6 * Float(sin(2 * .pi * 4 * Double(t) / 250)) }
        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount { channel[t] = physio(t) + gradient(t % spacing) }
        let triggers = (0..<volumes).map { $0 * spacing }
        return (channel, triggers)
    }

    private func rootMeanSquareDifference(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        guard !a.isEmpty else { return 0 }
        let squared = zip(a, b).reduce(0.0) { sum, pair in
            let difference = Double(pair.0 - pair.1)
            return sum + difference * difference
        }
        return (squared / Double(a.count)).squareRoot()
    }

    @Test func reducesGradientArtifactPower() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)

        var config = FastrCorrector.Config()
        config.upsampleFactor = 2     // keep test fast
        config.numberOfSlices = 1
        config.averagingWindow = 20
        config.subSampleAlignment = false
        config.obs = .off
        config.anc = false

        let result = try FastrCorrector.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result.count == 1)
        #expect(result[0].count == channel.count)

        // Variance in the interior should drop substantially after correction.
        func variance(_ x: ArraySlice<Float>) -> Double {
            let arr = Array(x).map(Double.init)
            let m = arr.reduce(0, +) / Double(arr.count)
            return arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(arr.count)
        }
        let lo = spacing * 4
        let hi = channel.count - spacing * 4
        let before = variance(channel[lo..<hi])
        let after = variance(result[0][lo..<hi])
        #expect(after < before * 0.5)
    }

    @Test func tooFewTriggersThrows() {
        let config = FastrCorrector.Config()
        #expect(throws: (any Error).self) {
            _ = try FastrCorrector.correct(
                channels: [[0, 1, 2, 3]],
                volumeTriggers: [0],
                config: config,
                samplingRate: 250
            )
        }
    }

    @Test func preservesChannelCountAndLength() throws {
        let spacing = 100
        let volumes = 30
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.obs = .off

        let result = try FastrCorrector.correct(
            channels: [channel, channel, channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result.count == 3)
        for c in result { #expect(c.count == channel.count) }
    }

    // MARK: - Metal backend

    @Test func metalInterpolationMatchesCPUReference() throws {
        guard let metal = FastrMetalBackend.shared else { return }
        let input = (0..<257).map { index in
            Float(12 * sin(Double(index) * 0.071) + 0.2 * Double(index % 9))
        }
        let cpu = DSP.interp(input.map(Double.init), factor: 3)
        let gpu = try #require(metal.interpolate(input, factor: 3, subtractMean: false))
        #expect(gpu.count == cpu.count)
        let maxDifference = zip(cpu, gpu).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDifference < 0.0001)

        let inputMean = input.reduce(0, +) / Float(input.count)
        let centeredCPU = DSP.interp(input.map { Double($0 - inputMean) }, factor: 3)
        let centeredGPU = try #require(metal.interpolate(input, factor: 3, subtractMean: true))
        let centeredMaxDifference = zip(centeredCPU, centeredGPU).map { abs($0 - $1) }.max() ?? 0
        #expect(centeredMaxDifference < 0.0001)
    }

    @Test func metalBatchedKernelsMatchSingleChannelKernels() throws {
        guard let metal = FastrMetalBackend.shared else { return }
        var inputs: [[Float]] = []
        for channel in 0..<4 {
            var values: [Float] = []
            for sample in 0..<193 {
                let frequency = 0.031 + 0.004 * Double(channel)
                let value = 9 * sin(Double(sample) * frequency)
                    + Double(channel * 7) + 0.15 * Double(sample % 11)
                values.append(Float(value))
            }
            inputs.append(values)
        }

        for subtractMean in [false, true] {
            let batched = try #require(metal.interpolateChannels(
                inputs,
                factor: 3,
                subtractMean: subtractMean
            ))
            #expect(batched.count == inputs.count)
            for channel in inputs.indices {
                let single = try #require(metal.interpolate(
                    inputs[channel],
                    factor: 3,
                    subtractMean: subtractMean
                ))
                let maxDifference = zip(single, batched[channel]).map { abs($0 - $1) }.max() ?? 0
                #expect(maxDifference < 0.0001)
            }
        }

        let originals = inputs.map { $0.flatMap { [Double($0), Double($0)] } }
        var templates: [[Double]] = []
        var residuals: [[Double]] = []
        for channel in originals.indices {
            var template: [Double] = []
            var residual: [Double] = []
            for sample in originals[channel].indices {
                template.append(
                    0.08 * originals[channel][sample]
                        + 0.01 * Double(channel + sample % 5)
                )
                residual.append(0.02 * sin(Double(sample + channel) * 0.17))
            }
            templates.append(template)
            residuals.append(residual)
        }
        let targetCount = originals[0].count / 2
        let batchedCorrection = try #require(metal.correctAndDecimateChannels(
            original: originals,
            templateNoise: templates,
            residualNoise: residuals,
            factor: 2,
            targetCount: targetCount
        ))
        for channel in originals.indices {
            let single = try #require(metal.correctAndDecimate(
                original: originals[channel],
                templateNoise: templates[channel],
                residualNoise: residuals[channel],
                factor: 2,
                targetCount: targetCount
            ))
            let cleanDifference = zip(single.clean, batchedCorrection.clean[channel])
                .map { abs($0 - $1) }.max() ?? 0
            let noiseDifference = zip(single.noise, batchedCorrection.noise[channel])
                .map { abs($0 - $1) }.max() ?? 0
            #expect(cleanDifference < 0.0001)
            #expect(noiseDifference < 0.0001)
        }
    }

    @Test func fusedMetalTemplateNoiseMatchesReference() throws {
        guard let metal = FastrMetalBackend.shared else { return }
        let sampleCount = 96
        var channels = [[Double]]()
        for channel in 0..<2 {
            var values = [Double]()
            values.reserveCapacity(sampleCount)
            let frequency = 0.07 + 0.01 * Double(channel)
            for sample in 0..<sampleCount {
                let oscillation = 4 * sin(Double(sample) * frequency)
                let offset = Double(channel * 3)
                let ripple = 0.05 * Double(sample % 7)
                values.append(oscillation + offset + ripple)
            }
            channels.append(values)
        }
        let markers = [16, 36, 56, 76]
        let prePeak = 4
        let artifactLength = 9
        let targetStarts = markers.map { $0 - prePeak }
        let donorRows = [[1, 2], [0, 2], [], [1, 2]]
        let fixedAlpha = [false, true]

        let gpu = try #require(metal.buildTemplateNoiseChannels(
            data: channels,
            markers: markers,
            targetStarts: targetStarts,
            donorRows: donorRows,
            prePeak: prePeak,
            artifactLength: artifactLength,
            fixedAlpha: fixedAlpha,
            epochChunkSize: 2
        ))

        var expected = channels.map { _ in [Double](repeating: 0, count: sampleCount) }
        for channel in channels.indices {
            for epoch in markers.indices where !donorRows[epoch].isEmpty {
                let template = (0..<artifactLength).map { sample in
                    donorRows[epoch].reduce(0.0) { sum, donor in
                        sum + channels[channel][markers[donor] - prePeak + sample]
                    } / Double(donorRows[epoch].count)
                }
                let targetStart = targetStarts[epoch]
                let alpha: Double
                if fixedAlpha[channel] {
                    alpha = 1
                } else {
                    let numerator = (0..<artifactLength).reduce(0.0) { sum, sample in
                        sum + channels[channel][targetStart + sample] * template[sample]
                    }
                    let denominator = template.reduce(0.0) { $0 + $1 * $1 }
                    alpha = denominator == 0 ? 0 : numerator / denominator
                }
                for sample in 0..<artifactLength {
                    expected[channel][targetStart + sample] = alpha * template[sample]
                }
            }
        }

        #expect(gpu.count == expected.count)
        for channel in expected.indices {
            let maxDifference = zip(gpu[channel], expected[channel]).map { abs($0 - $1) }.max() ?? 0
            #expect(maxDifference < 0.0001)
        }
    }

    @Test func metalFastrCloselyMatchesCPUWithoutOBS() throws {
        let (channel, triggers) = makeSyntheticChannel(spacing: 120, volumes: 40)
        var cpuConfig = FastrCorrector.Config()
        cpuConfig.upsampleFactor = 2
        cpuConfig.numberOfSlices = 1
        cpuConfig.averagingWindow = 20
        cpuConfig.subSampleAlignment = false
        cpuConfig.obs = .off
        cpuConfig.anc = false

        var metalConfig = cpuConfig
        metalConfig.computeBackend = .metal
        let cpu = try FastrCorrector.correct(
            channels: [channel, channel], volumeTriggers: triggers,
            config: cpuConfig, samplingRate: 250
        )
        let gpu = try FastrCorrector.correct(
            channels: [channel, channel], volumeTriggers: triggers,
            config: metalConfig, samplingRate: 250
        )

        #expect(gpu.count == cpu.count)
        for channelIndex in cpu.indices {
            #expect(gpu[channelIndex].count == cpu[channelIndex].count)
            #expect(gpu[channelIndex].allSatisfy { $0.isFinite })
            #expect(rootMeanSquareDifference(cpu[channelIndex], gpu[channelIndex]) < 0.01)
        }
    }

    /// FACET's PCA-epoch subsample (`obsPCAEpochIndices`) was designed for
    /// volume-triggered data (numTrig in the hundreds). For slice-triggered
    /// data with many slices per volume, numTrig — and so the ~40% subsample
    /// — can reach into the thousands, and the OBS Gram-matrix
    /// eigendecomposition is O(p³) in epoch count. Uncapped, this scenario
    /// (30 volumes x 90 slices = 2700 epochs) would spend tens of seconds in
    /// a single LAPACK call; the cap in `prepareOBSFromFilteredResidual`
    /// should keep it fast regardless. This mostly guards against a
    /// regression reintroducing the uncapped cost, not a specific speed bound.
    @Test func obsPCAEpochCountIsCappedForHighSliceCounts() throws {
        let (channel, triggers) = makeSyntheticChannel(spacing: 180, volumes: 30)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.numberOfSlices = 90
        config.averagingWindow = 4
        config.subSampleAlignment = false
        config.obs = .auto
        config.anc = false

        let result = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: config, samplingRate: 250
        )[0]

        #expect(result.count == channel.count)
        #expect(result.allSatisfy { $0.isFinite })
    }

    @Test func metalFastrProcessesMultipleChannelBatches() throws {
        guard FastrMetalBackend.shared != nil else { return }
        let (base, triggers) = makeSyntheticChannel(spacing: 80, volumes: 24)
        let channels: [[Float]] = (0..<18).map { channel in
            let scale = Float(1 + 0.01 * Double(channel))
            return base.enumerated().map { sample, value in
                value * scale + Float(channel) * 0.2 * Float(sin(Double(sample) * 0.019))
            }
        }
        var cpuConfig = FastrCorrector.Config()
        cpuConfig.upsampleFactor = 2
        cpuConfig.averagingWindow = 12
        cpuConfig.subSampleAlignment = false
        cpuConfig.obs = .off

        var metalConfig = cpuConfig
        metalConfig.computeBackend = .metal

        // These synthetic channels are far too small to hit the real
        // memory-based batch size bound, so force a small batch size here to
        // exercise the multi-batch (and batch-pipelining) code path
        // deterministically instead of relying on memory pressure.
        FastrCorrector.debugBatchSizeOverride = 5
        defer { FastrCorrector.debugBatchSizeOverride = nil }

        let cpu = try FastrCorrector.correct(
            channels: channels,
            volumeTriggers: triggers,
            config: cpuConfig,
            samplingRate: 250
        )
        let gpu = try FastrCorrector.correct(
            channels: channels,
            volumeTriggers: triggers,
            config: metalConfig,
            samplingRate: 250
        )

        #expect(gpu.count == channels.count)
        for channel in channels.indices {
            #expect(gpu[channel].count == channels[channel].count)
            #expect(rootMeanSquareDifference(cpu[channel], gpu[channel]) < 0.02)
        }
    }

    @Test func metalFastrCloselyMatchesCPUWithOBS() throws {
        let (channel, triggers) = makeSyntheticChannel(spacing: 100, volumes: 32)
        var cpuConfig = FastrCorrector.Config()
        cpuConfig.upsampleFactor = 2
        cpuConfig.averagingWindow = 16
        cpuConfig.subSampleAlignment = false
        cpuConfig.obs = .auto
        cpuConfig.randomizeOBSEpochSelection = false
        cpuConfig.anc = false

        var metalConfig = cpuConfig
        metalConfig.computeBackend = .metal
        let cpu = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: cpuConfig, samplingRate: 250
        )[0]
        let gpu = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: metalConfig, samplingRate: 250
        )[0]

        #expect(gpu.count == cpu.count)
        #expect(gpu.allSatisfy { $0.isFinite })
        #expect(rootMeanSquareDifference(cpu, gpu) < 0.05)
    }

    /// `obsChunkSeconds` defaults to 60, but this synthetic recording (32
    /// volumes x 100 samples / 250 Hz = 12.8s) is short enough that it all
    /// falls into a single chunk regardless — the chunk-boundary logic in
    /// `obsChunkEpochIndices`/the per-chunk OBS fit accumulation is untested
    /// by `metalFastrCloselyMatchesCPUWithOBS` above. Force a short chunk
    /// duration here so the same recording splits into several real chunks,
    /// and confirm CPU and Metal still agree once chunk results are combined.
    @Test func metalFastrChunkedOBSMatchesCPUAcrossMultipleChunks() throws {
        let (channel, triggers) = makeSyntheticChannel(spacing: 100, volumes: 32)
        var cpuConfig = FastrCorrector.Config()
        cpuConfig.upsampleFactor = 2
        cpuConfig.averagingWindow = 16
        cpuConfig.subSampleAlignment = false
        cpuConfig.obs = .auto
        cpuConfig.randomizeOBSEpochSelection = false
        cpuConfig.anc = false
        cpuConfig.obsChunkSeconds = 2  // ~6 chunks over the 12.8s recording

        var metalConfig = cpuConfig
        metalConfig.computeBackend = .metal
        let cpu = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: cpuConfig, samplingRate: 250
        )[0]
        let gpu = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: metalConfig, samplingRate: 250
        )[0]

        #expect(gpu.count == cpu.count)
        #expect(gpu.allSatisfy { $0.isFinite })
        #expect(cpu.allSatisfy { $0.isFinite })
        #expect(rootMeanSquareDifference(cpu, gpu) < 0.05)
    }

    @Test func metalFastrLowPassMatchesCPUAcrossChannelBatch() throws {
        guard FastrMetalBackend.shared != nil else { return }
        let (base, triggers) = makeSyntheticChannel(spacing: 90, volumes: 28)
        let channels: [[Float]] = (0..<6).map { channel in
            let scale = Float(1 + 0.02 * Double(channel))
            return base.enumerated().map { sample, value in
                value * scale + Float(channel) * 0.15 * Float(sin(Double(sample) * 0.023))
            }
        }
        var cpuConfig = FastrCorrector.Config()
        cpuConfig.upsampleFactor = 2
        cpuConfig.averagingWindow = 14
        cpuConfig.subSampleAlignment = false
        cpuConfig.obs = .off
        cpuConfig.anc = false
        cpuConfig.lowPassHz = 30

        var metalConfig = cpuConfig
        metalConfig.computeBackend = .metal
        let cpu = try FastrCorrector.correct(
            channels: channels, volumeTriggers: triggers,
            config: cpuConfig, samplingRate: 250
        )
        let gpu = try FastrCorrector.correct(
            channels: channels, volumeTriggers: triggers,
            config: metalConfig, samplingRate: 250
        )

        #expect(gpu.count == channels.count)
        for channel in channels.indices {
            #expect(gpu[channel].count == cpu[channel].count)
            #expect(gpu[channel].allSatisfy { $0.isFinite })
            #expect(rootMeanSquareDifference(cpu[channel], gpu[channel]) < 0.05)
        }
    }

    @Test func metalFastrLowPassAndANCMatchesCPU() throws {
        guard FastrMetalBackend.shared != nil else { return }
        let (channel, triggers) = makeSyntheticChannel(spacing: 100, volumes: 32)
        var cpuConfig = FastrCorrector.Config()
        cpuConfig.upsampleFactor = 2
        cpuConfig.averagingWindow = 16
        cpuConfig.subSampleAlignment = false
        cpuConfig.obs = .off
        cpuConfig.anc = true
        cpuConfig.lowPassHz = 30

        var metalConfig = cpuConfig
        metalConfig.computeBackend = .metal
        let cpu = try FastrCorrector.correct(
            channels: [channel, channel], volumeTriggers: triggers,
            config: cpuConfig, samplingRate: 250
        )
        let gpu = try FastrCorrector.correct(
            channels: [channel, channel], volumeTriggers: triggers,
            config: metalConfig, samplingRate: 250
        )

        #expect(gpu.count == cpu.count)
        for channelIndex in cpu.indices {
            #expect(gpu[channelIndex].count == cpu[channelIndex].count)
            #expect(gpu[channelIndex].allSatisfy { $0.isFinite })
            #expect(rootMeanSquareDifference(cpu[channelIndex], gpu[channelIndex]) < 0.05)
        }
    }

    @Test func fusedMetalTemplatesMatchCPUForFacetAndMoosmann() throws {
        guard FastrMetalBackend.shared != nil else { return }
        let spacing = 96
        let volumes = 32
        let (base, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        let channels = [base, base.map { $0 * 1.03 + 0.2 }]

        var facet = FastrCorrector.Config()
        facet.upsampleFactor = 2
        facet.numberOfSlices = 4
        facet.averagingWindow = 12
        facet.useFacetAveragingWindow = true
        facet.subSampleAlignment = false
        facet.obs = .off

        var moosmann = FastrCorrector.Config()
        moosmann.upsampleFactor = 2
        moosmann.averagingWindow = 12
        moosmann.subSampleAlignment = false
        moosmann.obs = .off
        moosmann.templateScheme = .moosmann
        moosmann.motionThresholdMm = 0.5
        moosmann.motion = (0..<volumes).map { volume in
            sample(volume, (0, 0, 0, volume < volumes / 2 ? 0 : 4, 0, 0))
        }

        for cpuConfig in [facet, moosmann] {
            var metalConfig = cpuConfig
            metalConfig.computeBackend = .metal
            let cpu = try FastrCorrector.correct(
                channels: channels,
                volumeTriggers: triggers,
                config: cpuConfig,
                samplingRate: 250
            )
            let gpu = try FastrCorrector.correct(
                channels: channels,
                volumeTriggers: triggers,
                config: metalConfig,
                samplingRate: 250
            )
            for channel in channels.indices {
                #expect(rootMeanSquareDifference(cpu[channel], gpu[channel]) < 0.03)
            }
        }
    }

    @Test func metalFARMCloselyMatchesCPU() throws {
        guard FastrMetalBackend.shared != nil else { return }
        let (channel, triggers) = makeSyntheticChannel(spacing: 100, volumes: 32)
        var cpuConfig = FastrCorrector.Config()
        cpuConfig.upsampleFactor = 2
        cpuConfig.averagingWindow = 16
        cpuConfig.subSampleAlignment = false
        cpuConfig.templateScheme = .farm
        cpuConfig.obs = .off

        var metalConfig = cpuConfig
        metalConfig.computeBackend = .metal
        let cpu = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: cpuConfig, samplingRate: 250
        )[0]
        let gpu = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: metalConfig, samplingRate: 250
        )[0]

        #expect(gpu.count == cpu.count)
        #expect(gpu.allSatisfy { $0.isFinite })
        #expect(rootMeanSquareDifference(cpu, gpu) < 0.02)
    }

    @Test func excludedChannelSkipsOBSWithoutCrashing() throws {
        let spacing = 100
        let volumes = 30
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.obs = .auto
        config.excludedChannels = [1]

        let result = try FastrCorrector.correct(
            channels: [channel, channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result.count == 2)
        for c in result { #expect(c.allSatisfy { $0.isFinite }) }
    }

    // MARK: - Characterization (determinism & equivalence anchors)

    @Test func producesDeterministicOutput() throws {
        let (channel, triggers) = makeSyntheticChannel(spacing: 120, volumes: 36)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.obs = .auto
        let a = try FastrCorrector.correct(channels: [channel, channel],
                                           volumeTriggers: triggers, config: config,
                                           samplingRate: 250)
        let b = try FastrCorrector.correct(channels: [channel, channel],
                                           volumeTriggers: triggers, config: config,
                                           samplingRate: 250)
        // Bit-for-bit identical across runs (guards against accidental
        // nondeterminism from parallelism or unseeded state in a refactor).
        #expect(a == b)
    }

    @Test func emptyCensoringEqualsNoCensoring() throws {
        let (channel, triggers) = makeSyntheticChannel(spacing: 120, volumes: 36)
        var base = FastrCorrector.Config()
        base.upsampleFactor = 2
        base.obs = .off
        var withEmpty = base
        withEmpty.censoredVolumes = []   // explicit empty must be a no-op

        let a = try FastrCorrector.correct(channels: [channel], volumeTriggers: triggers,
                                           config: base, samplingRate: 250)
        let b = try FastrCorrector.correct(channels: [channel], volumeTriggers: triggers,
                                           config: withEmpty, samplingRate: 250)
        #expect(a == b)
    }

    @Test func neighborSchemeEqualsDefaultPipeline() throws {
        let (channel, triggers) = makeSyntheticChannel(spacing: 120, volumes: 36)
        var def = FastrCorrector.Config()
        def.upsampleFactor = 2
        def.obs = .off
        var neighbor = def
        neighbor.templateScheme = .neighbor   // the default scheme, stated explicitly

        let a = try FastrCorrector.correct(channels: [channel], volumeTriggers: triggers,
                                           config: def, samplingRate: 250)
        let b = try FastrCorrector.correct(channels: [channel], volumeTriggers: triggers,
                                           config: neighbor, samplingRate: 250)
        #expect(a == b)
    }

    @Test func facetWindowModeRunsEndToEnd() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)

        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.useFacetAveragingWindow = true
        config.subSampleAlignment = false
        config.obs = .off

        let result = try FastrCorrector.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result[0].count == channel.count)
        #expect(result[0].allSatisfy { $0.isFinite })

        func variance(_ x: ArraySlice<Float>) -> Double {
            let arr = Array(x).map(Double.init)
            let m = arr.reduce(0, +) / Double(arr.count)
            return arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(arr.count)
        }
        let lo = spacing * 4
        let hi = channel.count - spacing * 4
        #expect(variance(result[0][lo..<hi]) < variance(channel[lo..<hi]) * 0.5)
    }

    @Test func facetVolumeDonorRowsSaturateAtEdges() {
        let rows = FastrCorrector.facetTemporalDonorRows(
            numTrig: 20,
            halfWindow: 3,
            sliceTrigger: false
        )
        #expect(rows.count == 20)
        #expect(rows[0] == [1, 2, 3, 4, 5, 6, 7])
        #expect(rows[1] == rows[0])
        #expect(rows[7] == [3, 4, 5, 6, 7, 8, 9])
        #expect(rows[19] == rows[17])
        #expect(!rows[0].contains(0))
        #expect(rows[7].contains(7))
    }

    @Test func facetSliceDonorRowsUseAlternatingParity() {
        let rows = FastrCorrector.facetTemporalDonorRows(
            numTrig: 24,
            halfWindow: 3,
            sliceTrigger: true
        )
        #expect(rows[0] == [1, 3, 5, 7])
        #expect(rows[1] == [2, 4, 6, 8])
        #expect(rows[2] == rows[1])
        #expect(rows[9] == [6, 8, 10, 12])
        #expect(!rows[9].contains(9))
    }

    @Test func obsVolumeEpochIndicesAreContiguousLikeFacet() {
        #expect(FastrCorrector.obsPCAEpochIndices(numTrig: 8, sliceTrigger: false) == [2, 3, 4, 5, 6])
        #expect(FastrCorrector.obsPCAEpochIndices(numTrig: 10, sliceTrigger: true) == [1, 3, 6, 8])
    }

    @Test func obsRandomEpochIndicesFollowFacetPickSequence() {
        var sliceSteps = [3, 2, 3, 2, 3]
        let slice = FastrCorrector.obsPCAEpochIndices(
            numTrig: 12,
            sliceTrigger: true,
            randomized: true,
            randomStep: { sliceSteps.removeFirst() }
        )
        #expect(slice == [3, 5, 8, 10])

        var volumeSteps = [3, 2, 2, 3, 2]
        let volume = FastrCorrector.obsPCAEpochIndices(
            numTrig: 12,
            sliceTrigger: false,
            randomized: true,
            randomStep: { volumeSteps.removeFirst() }
        )
        #expect(volume == Array(3..<11))
    }

    @Test func ancHighPassCanFollowSliceTriggerRate() {
        let sliceTriggers = (0..<40).map { $0 * 10 } // 10 triggers in first second at fs=100 Hz.
        let fixed = FastrCorrector.ancHighPassFrequency(
            triggers: sliceTriggers,
            L: 1,
            samplingRate: 100,
            sliceTrigger: true,
            mode: .fixed2Hz
        )
        #expect(fixed == 2.0)

        let sliceDependent = FastrCorrector.ancHighPassFrequency(
            triggers: sliceTriggers,
            L: 1,
            samplingRate: 100,
            sliceTrigger: true,
            mode: .sliceTriggerDependent
        )
        #expect(abs(sliceDependent - 7.5) < 1e-9)

        let volumeFallback = FastrCorrector.ancHighPassFrequency(
            triggers: sliceTriggers,
            L: 1,
            samplingRate: 100,
            sliceTrigger: false,
            mode: .sliceTriggerDependent
        )
        #expect(volumeFallback == 2.0)
    }

    @Test func singleChannelMatchesMultiChannel() throws {
        // A channel's result must not depend on what other channels accompany it
        // (the shared aligner is computed from channel 0 only).
        let (channel, triggers) = makeSyntheticChannel(spacing: 120, volumes: 36)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.obs = .off
        let solo = try FastrCorrector.correct(channels: [channel], volumeTriggers: triggers,
                                              config: config, samplingRate: 250)
        let multi = try FastrCorrector.correct(channels: [channel, channel, channel],
                                               volumeTriggers: triggers, config: config,
                                               samplingRate: 250)
        #expect(solo[0] == multi[0])
        #expect(multi[0] == multi[2])
    }

    // MARK: - Signal preservation

    @Test func preservesNonArtifactSignal() throws {
        // Physio NOT locked to the TR grid must survive FASTR (template averaging
        // cancels it; OBS off so it can't be fitted away).
        let spacing = 120
        let volumes = 40
        let sampleCount = spacing * volumes
        // Physio NOT TR-locked, with an artifact of comparable magnitude (a
        // realistic regime where the template can be cleanly separated). A
        // refactor that starts destroying signal will drop this correlation.
        func physio(_ t: Int) -> Float { 10 * Float(sin(2 * .pi * Double(t) / 71.0)) }
        // Smooth (band-limited) artifact at frequencies well separated from the
        // physio, so it's near-orthogonal to the physio within an epoch (keeps
        // the amplitude-scaling step from leaking artifact) and resamples
        // cleanly. A destructive refactor still drops the correlation.
        func gradient(_ k: Int) -> Float { 15 * Float(sin(Double(k) * 0.6)) + 10 * Float(sin(Double(k) * 0.9 + 1)) }
        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount { channel[t] = physio(t) + gradient(t % spacing) }
        let triggers = (0..<volumes).map { $0 * spacing }

        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.numberOfSlices = 1
        config.subSampleAlignment = false
        config.obs = .off

        let result = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: config, samplingRate: 250
        )
        let lo = spacing * 6, hi = spacing * 34
        let clean = (lo..<hi).map { physio($0) }
        let got = Array(result[0][lo..<hi])
        // Conservative "signal not destroyed" floor. The current approximate
        // pipeline (windowed-sinc interp/decimate + AAS amplitude scaling) only
        // reaches ~0.5–0.7 here; a refactor that starts destroying signal drives
        // this toward 0. See TODO: investigate FASTR signal attenuation /
        // validate against a MATLAB reference. AAS has a stricter (0.85) guard.
        #expect(correlation(clean, got) > 0.5, "physiological signal was not preserved (corr=\(correlation(clean, got)))")
    }

    /// Pearson correlation between two equal-length Float vectors.
    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        let ma = a.reduce(0, +) / Float(a.count)
        let mb = b.reduce(0, +) / Float(b.count)
        var sa = 0.0, sb = 0.0, sab = 0.0
        for i in 0..<a.count {
            let da = Double(a[i] - ma), db = Double(b[i] - mb)
            sa += da * da; sb += db * db; sab += da * db
        }
        let denom = (sa * sb).squareRoot()
        return denom == 0 ? 0 : sab / denom
    }

    // MARK: - Motion censoring

    @Test func censoringIgnoresHighMotionDonorsButStillCorrectsThem() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)

        func variance(_ x: ArraySlice<Float>) -> Double {
            let arr = Array(x).map(Double.init)
            let m = arr.reduce(0, +) / Double(arr.count)
            return arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(arr.count)
        }

        for scheme in [FastrCorrector.TemplateScheme.neighbor, .farm] {
            for backend in [FastrCorrector.ComputeBackend.cpu, .metal] {
                var config = FastrCorrector.Config()
                config.upsampleFactor = 2
                config.numberOfSlices = 1
                config.obs = .off
                config.templateScheme = scheme
                config.computeBackend = backend
                config.censoredVolumes = [10, 11, 25]   // pretend these are high-motion

                let result = try FastrCorrector.correct(
                    channels: [channel], volumeTriggers: triggers,
                    config: config, samplingRate: 250
                )
                #expect(result[0].count == channel.count)
                #expect(result[0].allSatisfy { $0.isFinite })

                // Censored TRs remain correction targets even though they cannot
                // contribute to this or any neighboring artifact template.
                let s = triggers[25]
                let before = variance(channel[s..<(s + spacing)])
                let after = variance(result[0][s..<(s + spacing)])
                #expect(after < before * 0.6)
            }
        }
    }

    @Test func censoringEntireNeighborhoodFallsBackGracefully() throws {
        // Censor a long contiguous run so some epochs have no clean neighbors;
        // the fallback must keep the output finite (no empty-template crash).
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)

        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.obs = .off
        config.censoredVolumes = Set(5...35)

        let result = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: config, samplingRate: 250
        )
        #expect(result[0].allSatisfy { $0.isFinite })
    }

    // MARK: - Moosmann neighbor selection

    private func sample(_ id: Int, _ values: (Double, Double, Double, Double, Double, Double))
        -> MotionSample {
        MotionSample(id: id, roll: values.0, pitch: values.1, yaw: values.2,
                     dS: values.3, dL: values.4, dP: values.5)
    }

    @Test func moosmannReturnsNilWhenNoSupraThresholdMotion() {
        // Tiny, sub-threshold movements => no motion event => nil (caller uses a
        // plain moving average), matching m_rp_info's fallback.
        let motion = (0..<10).map { sample($0, (0, 0, 0, 0.001 * Double($0), 0, 0)) }
        let neighbors = FastrCorrector.moosmannVolumeNeighbors(
            motion: motion, volumeCount: 10, window: 4, thresholdMm: 0.5
        )
        #expect(neighbors == nil)
    }

    @Test func moosmannExcludesAndDoesNotCrossMotionEvent() {
        // 10 volumes, all near-stationary except a large translation jump at
        // volume 5 (speed >> threshold). Volume 5 should be excluded from every
        // template, and windows should not cross the barrier at 5.
        var motion: [MotionSample] = []
        for v in 0..<10 {
            let pos = v < 5 ? 0.0 : 5.0   // step of 5 mm between vol 4 and 5
            motion.append(sample(v, (0, 0, 0, pos, 0, 0)))
        }
        let neighbors = FastrCorrector.moosmannVolumeNeighbors(
            motion: motion, volumeCount: 10, window: 3, thresholdMm: 0.5
        )
        let n = try! #require(neighbors)
        // The high-motion volume is never used.
        #expect(n.allSatisfy { !$0.contains(5) })
        // A center to the left of the event stays left of it.
        #expect(n[2].allSatisfy { $0 < 5 })
        // A center to the right stays right of it.
        #expect(n[7].allSatisfy { $0 > 5 })
    }

    @Test func moosmannReturnsNilWithoutMotion() {
        let neighbors = FastrCorrector.moosmannVolumeNeighbors(
            motion: nil, volumeCount: 10, window: 4, thresholdMm: 0.5
        )
        #expect(neighbors == nil)
    }

    @Test func moosmannFrontPadsShorterMotion() {
        // 6 volumes, 4 motion rows => motion applies to trailing volumes (2..5),
        // padded volumes 0,1 are treated as motionless. A jump within the motion
        // produces a usable (non-nil) weighting.
        let motion = [
            sample(0, (0, 0, 0, 0, 0, 0)),
            sample(1, (0, 0, 0, 0, 0, 0)),
            sample(2, (0, 0, 0, 5, 0, 0)),   // jump => supra-threshold
            sample(3, (0, 0, 0, 5, 0, 0)),
        ]
        let neighbors = FastrCorrector.moosmannVolumeNeighbors(
            motion: motion, volumeCount: 6, window: 3, thresholdMm: 0.5
        )
        let n = try! #require(neighbors)
        #expect(n.count == 6)
        // The supra-threshold volume (motion row 2 -> volume index 4) is excluded.
        #expect(n.allSatisfy { !$0.contains(4) })
    }

    @Test func moosmannCanUseAllSixMotionParameters() {
        let motion = [
            sample(0, (0, 0, 0, 0, 0, 0)),
            sample(1, (3, 0, 0, 0, 0, 0)),
            sample(2, (3, 0, 0, 0, 0, 0)),
            sample(3, (3, 0, 0, 0, 0, 0)),
        ]
        let translationOnly = FastrCorrector.moosmannVolumeNeighbors(
            motion: motion, volumeCount: 4, window: 2, thresholdMm: 1.0,
            metric: .translationOnly, radiusMm: 50
        )
        #expect(translationOnly == nil)

        let allParameters = FastrCorrector.moosmannVolumeNeighbors(
            motion: motion, volumeCount: 4, window: 2, thresholdMm: 1.0,
            metric: .allParameters, radiusMm: 50
        )
        #expect(allParameters != nil)
    }

    // MARK: - FARM epoch selection

    @Test func bergenRSquareNeighborsIncludeSelfAndUseSquaredCorrelation() {
        let wave = [0.0, 1.0, 0.0, -1.0]
        let inverted = wave.map { -$0 }
        let unrelated = [1.0, 0.0, 1.0, 0.0]
        let neighbors = FastrCorrector.bergenRSquareEpochNeighbors(
            epochs: [wave, inverted, unrelated],
            select: 2
        )
        #expect(neighbors[0] == [0, 1])
        #expect(neighbors[1] == [0, 1])
    }

    @Test func farmSelectsMostCorrelatedEpochs() {
        // Epochs 0,2,4 share waveform A; epochs 1,3,5 share waveform B.
        let length = 32
        let waveA = (0..<length).map { sin(2 * .pi * Double($0) / Double(length)) }
        let waveB = (0..<length).map { cos(2 * .pi * Double($0) / Double(length)) }
        var epochs: [[Double]?] = []
        for s in 0..<6 { epochs.append(s % 2 == 0 ? waveA : waveB) }

        let neighbors = FastrCorrector.farmEpochNeighbors(
            epochs: epochs, select: 2, searchHalf: 10
        )
        // Epoch 0 (waveA) should pick other even epochs (waveA), never odd ones.
        #expect(neighbors[0].allSatisfy { $0 % 2 == 0 })
        #expect(!neighbors[0].contains(0))   // excludes itself
        // Epoch 1 (waveB) should pick other odd epochs.
        #expect(neighbors[1].allSatisfy { $0 % 2 == 1 })
    }

    @Test func farmFallsBackWhenNoCorrelatedEpoch() {
        // Each epoch is distinct random-ish noise => nothing correlates >= 0.9.
        var epochs: [[Double]?] = []
        for s in 0..<8 {
            epochs.append((0..<16).map { sin(Double(s * 13 + $0) * 1.7) })
        }
        let neighbors = FastrCorrector.farmEpochNeighbors(
            epochs: epochs, select: 3, searchHalf: 7, threshold: 0.999
        )
        // With a near-1 threshold, most epochs find no match => empty (fallback).
        #expect(neighbors.contains { $0.isEmpty })
    }

    @Test func farmCorrectionRunsEndToEnd() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.numberOfSlices = 1
        config.templateScheme = .farm
        config.obs = .off

        let result = try FastrCorrector.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result[0].count == channel.count)
        #expect(result[0].allSatisfy { $0.isFinite })

        // FARM should still reduce the gradient artifact power.
        func variance(_ x: ArraySlice<Float>) -> Double {
            let arr = Array(x).map(Double.init)
            let m = arr.reduce(0, +) / Double(arr.count)
            return arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(arr.count)
        }
        let lo = spacing * 4, hi = channel.count - spacing * 4
        #expect(variance(result[0][lo..<hi]) < variance(channel[lo..<hi]) * 0.5)
    }

    @Test func moosmannCorrectionRunsEndToEnd() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        // Motion: a stationary head with one large movement event midway, so the
        // Moosmann branch (not the moving-average fallback) is exercised.
        var motion: [MotionSample] = []
        for v in 0..<volumes {
            let pos = v < volumes / 2 ? 0.0 : 4.0
            motion.append(sample(v, (0, 0, 0, pos, 0, 0)))
        }
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.numberOfSlices = 1
        config.templateScheme = .moosmann
        config.motion = motion
        config.motionThresholdMm = 0.5
        config.obs = .off

        let result = try FastrCorrector.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result[0].count == channel.count)
        #expect(result[0].allSatisfy { $0.isFinite })
    }
}
