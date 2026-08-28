//
//  GradientBackendParityTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The acceptance gate for the Metal backend, from the test plan in
//  docs/provenance/fastr-gpu-port-plan.md.
//
//  The CPU path is the definition of correct: a disagreement between the two is
//  never fixed by changing the CPU. Two kinds of agreement are asserted here, and
//  they are not the same kind.
//
//    - **Decisions must match exactly.** Donor sets, epoch shifts, OBS component
//      counts, which channels ANC ran on, high-motion volumes, and the set of
//      warnings raised. Any divergence is a design bug — it means a discrete
//      choice leaked onto the GPU, where a one-ULP difference can flip it.
//    - **Numbers must match within a documented tolerance.** Metal has no double,
//      so exact numerical parity is impossible and is not a goal. The bound is
//      expressed as a fraction of the artifact that was removed rather than as an
//      absolute, so it cannot silently weaken on larger-amplitude data.
//
//  Every test skips rather than fails on a machine with no usable Metal device.
//

import Testing
import Foundation
@testable import EVA

struct GradientBackendParityTests {

    private static let samplingRate = 1000.0

    private var metalAvailable: Bool { GradientTemplateCorrector.isMetalAvailable }

    // MARK: - Synthetic recordings

    private func gradientWave(_ position: Double, period: Int) -> Float {
        let wrapped = position.truncatingRemainder(dividingBy: Double(period))
        let normalized = (wrapped < 0 ? wrapped + Double(period) : wrapped) / Double(period)
        return Float(
            120 * sin(2 * .pi * normalized)
            + 70 * sin(6 * .pi * normalized + 0.6)
            + 45 * sin(10 * .pi * normalized + 1.3)
        )
    }

    private func varyingWave(_ position: Double, period: Int) -> Float {
        let phase = position.truncatingRemainder(dividingBy: Double(period)) / Double(period)
        return Float(60 * sin(4 * .pi * phase + 0.4))
    }

    private struct Recording {
        let channels: [[Float]]
        let triggers: [Int]
        let sampleCount: Int
        let artifactAmplitude: Double
    }

    /// A multi-channel recording where every channel carries the same artifact at
    /// a different amplitude, plus its own physiological rhythm and a slightly
    /// different epoch-to-epoch variation, so channels are not copies of each
    /// other and a channel-indexing mistake shows up.
    private func makeRecording(
        channels channelCount: Int,
        volumes: Int,
        period: Int = 100,
        tail: Int = 100,
        shift: (Int) -> Double = { _ in 0 }
    ) -> Recording {
        let sampleCount = volumes * period + tail
        var channels: [[Float]] = []
        var peak = 0.0
        for channel in 0..<channelCount {
            let gain = 1.0 - 0.15 * Double(channel % 5)
            let rhythm = 6.0 + Double(channel % 3)
            var samples = [Float](repeating: 0, count: sampleCount)
            for sample in 0..<sampleCount {
                let volume = min(sample / period, volumes - 1)
                let position = Double(sample - volume * period) - shift(volume)
                let artifact = Float(gain) * gradientWave(position, period: period)
                    + Float(gain * cos(0.9 * Double(volume))) * varyingWave(position, period: period)
                let physiology = Float(6 * sin(2 * .pi * rhythm * Double(sample) / Self.samplingRate))
                samples[sample] = artifact + physiology
                peak = max(peak, abs(Double(artifact)))
            }
            channels.append(samples)
        }
        return Recording(
            channels: channels,
            triggers: (0..<volumes).map { $0 * period },
            sampleCount: sampleCount,
            artifactAmplitude: peak
        )
    }

    private func config(
        _ backend: GradientComputeBackend,
        _ mutate: (inout GradientCorrectionConfig) -> Void = { _ in }
    ) -> GradientCorrectionConfig {
        var config = GradientCorrectionConfig()
        config.averagingWindowBefore = 15
        config.averagingWindowAfter = 15
        config.computeBackend = backend
        config.metalMinimumWorkload = 0
        mutate(&config)
        return config
    }

    private func run(
        _ recording: Recording,
        _ config: GradientCorrectionConfig
    ) throws -> GradientCorrectionResult {
        try GradientTemplateCorrector.correct(
            channels: recording.channels,
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )
    }

    // MARK: - Shared assertions

    /// Everything the two backends must agree on *exactly*.
    private func expectDecisionParity(
        _ cpu: GradientCorrectionResult,
        _ metal: GradientCorrectionResult,
        _ label: String
    ) {
        #expect(metal.diagnostics.computeBackend == .metal,
                "\(label): the GPU run silently fell back to the CPU, so this proves nothing")
        #expect(cpu.diagnostics.computeBackend == .cpu)

        #expect(cpu.diagnostics.epochCount == metal.diagnostics.epochCount, "\(label): epoch count")
        #expect(cpu.diagnostics.period == metal.diagnostics.period, "\(label): period")
        #expect(cpu.diagnostics.referenceChannel == metal.diagnostics.referenceChannel,
                "\(label): alignment reference channel")
        #expect(cpu.diagnostics.highMotionVolumes == metal.diagnostics.highMotionVolumes,
                "\(label): high-motion volumes")
        #expect(cpu.diagnostics.obsComponentCounts == metal.diagnostics.obsComponentCounts,
                "\(label): OBS component counts")
        #expect(cpu.diagnostics.ancAppliedChannels == metal.diagnostics.ancAppliedChannels,
                "\(label): channels ANC ran on")
        #expect(Set(cpu.diagnostics.warnings) == Set(metal.diagnostics.warnings),
                "\(label): warnings")

        #expect(cpu.diagnostics.epochs.count == metal.diagnostics.epochs.count, "\(label): epoch records")
        for (left, right) in zip(cpu.diagnostics.epochs, metal.diagnostics.epochs) {
            #expect(left.epoch == right.epoch, "\(label): epoch order")
            #expect(left.corrected == right.corrected, "\(label): epoch \(left.epoch) corrected")
            #expect(left.integerShift == right.integerShift, "\(label): epoch \(left.epoch) shift")
            #expect(left.donorIndices == right.donorIndices, "\(label): epoch \(left.epoch) donors")
        }
    }

    /// Corrected samples, as a fraction of the artifact the correction removed.
    ///
    /// float32 accumulation lands around 1e-7 relative, so 1e-5 of the artifact
    /// amplitude is roughly two orders of margin — tight enough that a real kernel
    /// bug cannot hide under it, loose enough not to be a flake.
    private func expectNumericalParity(
        _ cpu: GradientCorrectionResult,
        _ metal: GradientCorrectionResult,
        amplitude: Double,
        _ label: String
    ) {
        let rmsBound = amplitude * 1e-5
        let maxBound = amplitude * 1e-4
        for channel in cpu.channels.indices {
            let left = cpu.channels[channel]
            let right = metal.channels[channel]
            #expect(left.count == right.count)
            var total = 0.0
            var worst = 0.0
            for index in left.indices {
                let difference = abs(Double(left[index]) - Double(right[index]))
                total += difference * difference
                worst = max(worst, difference)
            }
            let rms = (total / Double(left.count)).squareRoot()
            #expect(rms < rmsBound,
                    "\(label): channel \(channel) RMS difference \(rms) exceeded \(rmsBound)")
            #expect(worst < maxBound,
                    "\(label): channel \(channel) max difference \(worst) exceeded \(maxBound)")
        }
    }

    private func expectParity(
        _ recording: Recording,
        _ label: String,
        _ mutate: (inout GradientCorrectionConfig) -> Void = { _ in }
    ) throws {
        let cpu = try run(recording, config(.cpu, mutate))
        let metal = try run(recording, config(.metal, mutate))
        expectDecisionParity(cpu, metal, label)
        expectNumericalParity(cpu, metal, amplitude: recording.artifactAmplitude, label)
    }

    // MARK: - Parity across the configuration space

    @Test func temporalNeighborsAgreeOnBothBackends() throws {
        guard metalAvailable else { return }
        try expectParity(makeRecording(channels: 8, volumes: 40), "temporal neighbors")
    }

    @Test func everyTemplateScalingModeAgrees() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(channels: 4, volumes: 40)
        for mode in GradientTemplateScaling.allCases {
            try expectParity(recording, "scaling \(mode)") { $0.templateScaling = mode }
        }
    }

    @Test func upsamplingAgrees() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(channels: 4, volumes: 30)
        for factor in [1, 2, 4] {
            try expectParity(recording, "upsample \(factor)") { $0.upsampleFactor = factor }
        }
    }

    @Test func subSampleAlignmentAgrees() throws {
        guard metalAvailable else { return }
        // Half-sample offsets, so the fractional-delay path is actually exercised
        // in both directions: onto the shared grid and back off it.
        let recording = makeRecording(
            channels: 4, volumes: 40,
            shift: { $0.isMultiple(of: 2) ? 0 : 0.5 }
        )
        try expectParity(recording, "sub-sample alignment") {
            $0.subSampleAlignment = true
            $0.upsampleFactor = 2
        }
    }

    @Test func sliceLevelEpochsAgree() throws {
        guard metalAvailable else { return }
        try expectParity(makeRecording(channels: 4, volumes: 40, period: 100), "four slices") {
            $0.numberOfSlices = 4
        }
    }

    @Test func correlationRankedDonorSetsAgreeExactly() throws {
        guard metalAvailable else { return }
        // The stage most at risk: the ranking is discrete, and a score computed to
        // a different last bit must not reorder it.
        let recording = makeRecording(channels: 4, volumes: 40)
        try expectParity(recording, "correlation-ranked") {
            $0.templateScheme = .correlationRanked
            $0.correlationThreshold = 0.8
        }
        try expectParity(recording, "squared-correlation-ranked") {
            $0.templateScheme = .squaredCorrelationRanked
            $0.allowsSelfDonation = true
        }
    }

    @Test func motionInformedDonorsAgree() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(channels: 4, volumes: 60)
        try expectParity(recording, "motion-informed") {
            $0.templateScheme = .motionInformed
            $0.averagingWindowBefore = 5
            $0.averagingWindowAfter = 5
            $0.motion = (0..<60).map { volume in
                MotionSample(
                    id: volume, roll: 0, pitch: 0, yaw: 0,
                    dS: volume >= 30 ? 3 : 0, dL: 0, dP: 0
                )
            }
        }
    }

    @Test func obsComponentCountsAgree() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(channels: 4, volumes: 60)
        try expectParity(recording, "OBS automatic") { $0.obs = .automatic }
        try expectParity(recording, "OBS fixed") { $0.obs = .fixed(componentCount: 3) }
    }

    @Test func ancAgrees() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(channels: 4, volumes: 60)
        try expectParity(recording, "ANC") {
            $0.anc = true
            $0.templateScaling = .unscaled
        }
    }

    @Test func theWholePipelineAgrees() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(
            channels: 6, volumes: 60,
            shift: { Double(($0 % 5) - 2) }
        )
        try expectParity(recording, "full pipeline") {
            $0.obs = .automatic
            $0.anc = true
            $0.subSampleAlignment = true
            $0.upsampleFactor = 2
            $0.excludedChannels = [3]
            $0.censoredVolumes = [17]
        }
    }

    // MARK: - Degenerate shapes

    /// Threadgroup tails and empty tiles are where GPU ports break, so the shapes
    /// that are not a comfortable multiple of anything get their own case.
    @Test func degenerateShapesAgree() throws {
        guard metalAvailable else { return }

        try expectParity(makeRecording(channels: 1, volumes: 40), "single channel")
        try expectParity(makeRecording(channels: 3, volumes: 12), "three channels, short")
        try expectParity(makeRecording(channels: 33, volumes: 12), "channel count off a power of two")
        try expectParity(makeRecording(channels: 2, volumes: 40, period: 37), "odd period")

        // No tail: the last epoch runs past the recording and must be reported,
        // not corrected, on both backends.
        try expectParity(makeRecording(channels: 2, volumes: 20, tail: 0), "epoch past the end") {
            $0.alignmentEnabled = false
        }
    }

    @Test func flatAndExcludedChannelsAgree() throws {
        guard metalAvailable else { return }
        var recording = makeRecording(channels: 4, volumes: 30)
        var channels = recording.channels
        channels[1] = [Float](repeating: 0, count: recording.sampleCount)
        recording = Recording(
            channels: channels,
            triggers: recording.triggers,
            sampleCount: recording.sampleCount,
            artifactAmplitude: recording.artifactAmplitude
        )
        try expectParity(recording, "flat and excluded") {
            $0.excludedChannels = [2]
            $0.obs = .automatic
        }
    }

    @Test func censoringEverythingAgrees() throws {
        guard metalAvailable else { return }
        try expectParity(makeRecording(channels: 2, volumes: 12), "everything censored") {
            $0.censoredVolumes = Set(0..<12)
        }
    }

    // MARK: - Guarantees the backend must not break

    @Test func theGPUPathIsDeterministic() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(channels: 6, volumes: 40, shift: { Double(($0 % 5) - 2) })
        let settings = config(.metal) {
            $0.obs = .automatic
            $0.anc = true
            $0.subSampleAlignment = true
            $0.upsampleFactor = 2
        }
        let first = try run(recording, settings)
        let second = try run(recording, settings)
        // Bit-identical, not approximately equal. Anything else means a
        // nondeterministic reduction order — an atomic add, most likely.
        #expect(first.channels == second.channels)
    }

    @Test func samplesOutsideCorrectedEpochsAreBitIdenticalOnTheGPU() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(channels: 4, volumes: 20, tail: 100)
        for factor in [1, 2, 4] {
            let result = try run(recording, config(.metal) {
                $0.upsampleFactor = factor
                $0.obs = .automatic
            })
            for channel in recording.channels.indices {
                for sample in 2001..<recording.sampleCount {
                    #expect(result.channels[channel][sample] == recording.channels[channel][sample],
                            "factor \(factor) channel \(channel) sample \(sample) was modified")
                }
            }
        }
    }

    /// Tiling is an implementation detail of the backend, not of the result. A
    /// channel corrected in a tile of one must come out the same as the same
    /// channel corrected alongside others.
    @Test func tilingDoesNotChangeTheResult() throws {
        guard metalAvailable else { return }
        let recording = makeRecording(channels: 5, volumes: 30)
        let together = try run(recording, config(.metal))
        let alone = try run(
            Recording(
                channels: [recording.channels[0]],
                triggers: recording.triggers,
                sampleCount: recording.sampleCount,
                artifactAmplitude: recording.artifactAmplitude
            ),
            config(.metal)
        )
        // Channel 0 has the largest gain, so it is the alignment reference in both.
        #expect(together.diagnostics.referenceChannel == 0)
        #expect(alone.channels[0] == together.channels[0])
    }

    /// A recording too small to be worth a GPU round trip runs on the CPU without
    /// the caller asking, and says so.
    @Test func smallRecordingsFallBackToTheCPU() throws {
        let recording = makeRecording(channels: 1, volumes: 12)
        var settings = config(.metal)
        settings.metalMinimumWorkload = .max
        let result = try run(recording, settings)
        #expect(result.diagnostics.computeBackend == .cpu)
    }
}
