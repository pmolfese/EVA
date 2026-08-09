//
//  GradientCorrectorStagesTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  End-to-end coverage of the OBS and ANC stages inside the full corrector,
//  against the acceptance criteria in docs/provenance/fastr-functional-spec.md:
//  OBS off/auto/fixed, OBS reducing residual artifact without exploding on low-rank
//  or short recordings, and ANC being skipped or bounded when its reference is
//  unsuitable.
//

import Testing
import Foundation
@testable import EVA

struct GradientCorrectorStagesTests {

    private static let samplingRate = 1000.0
    private static let period = 100

    /// The part of the artifact that repeats identically — what template
    /// subtraction is able to remove.
    private func commonArtifact(_ position: Int) -> Float {
        let phase = Double(position % Self.period) / Double(Self.period)
        return Float(
            120 * sin(2 * .pi * phase)
            + 70 * sin(6 * .pi * phase + 0.6)
            + 45 * sin(10 * .pi * phase + 1.3)
        )
    }

    /// A second shape at a harmonic the common artifact does not use, so it is
    /// orthogonal to it over an epoch. Scaled differently in each volume, this is
    /// exactly the epoch-to-epoch variation that template subtraction cannot
    /// express and OBS is meant to catch.
    private func varyingArtifact(_ position: Int) -> Float {
        let phase = Double(position % Self.period) / Double(Self.period)
        return Float(60 * sin(4 * .pi * phase + 0.4))
    }

    private func physiology(_ sample: Int) -> Float {
        Float(6 * sin(2 * .pi * 7 * Double(sample) / Self.samplingRate))
    }

    private struct Recording {
        let channel: [Float]
        let physiology: [Float]
        let triggers: [Int]
        let sampleCount: Int
        let coveredRange: Range<Int>
    }

    /// - Parameter variation: Per-volume weight on the second artifact shape.
    /// - Parameter amplitudeDrift: Per-volume multiplier on the common artifact.
    private func makeRecording(
        volumes: Int,
        variation: (Int) -> Double = { _ in 0 },
        amplitudeDrift: (Int) -> Double = { _ in 1 }
    ) -> Recording {
        let period = Self.period
        let sampleCount = volumes * period + period
        var channel = [Float](repeating: 0, count: sampleCount)
        var clean = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            let volume = min(sample / period, volumes - 1)
            let position = sample - volume * period
            clean[sample] = physiology(sample)
            channel[sample] = clean[sample]
                + Float(amplitudeDrift(volume)) * commonArtifact(position)
                + Float(variation(volume)) * varyingArtifact(position)
        }
        return Recording(
            channel: channel,
            physiology: clean,
            triggers: (0..<volumes).map { $0 * period },
            sampleCount: sampleCount,
            coveredRange: 0..<(volumes * period)
        )
    }

    private func residual(_ corrected: [Float], _ recording: Recording) -> Double {
        var total = 0.0
        for index in recording.coveredRange {
            let d = Double(corrected[index]) - Double(recording.physiology[index])
            total += d * d
        }
        return (total / Double(recording.coveredRange.count)).squareRoot()
    }

    private func baseConfig(_ backend: GradientComputeBackend = .cpu) -> GradientCorrectionConfig {
        var config = GradientCorrectionConfig()
        config.averagingWindowBefore = 15
        config.averagingWindowAfter = 15
        config.computeBackend = backend
        // These recordings are far below the size at which a GPU round trip pays
        // for itself, and would otherwise fall back to the CPU and test nothing.
        config.metalMinimumWorkload = 0
        return config
    }

    /// Whether this machine can run the case. A Mac without a usable Metal device
    /// skips the GPU half rather than failing it.
    private func supports(_ backend: GradientComputeBackend) -> Bool {
        backend != .metal || GradientTemplateCorrector.isMetalAvailable
    }

    // MARK: - OBS

    @Test(arguments: GradientComputeBackend.allCases)
    func obsRemovesResidualStructureTemplateSubtractionCannot(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // The second shape's weight swings from volume to volume, so the averaged
        // template cannot represent it and a structured residual is left behind.
        let recording = makeRecording(volumes: 60, variation: { cos(0.9 * Double($0)) })

        let templateOnly = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: baseConfig(backend), samplingRate: Self.samplingRate
        )
        var withOBS = baseConfig(backend)
        withOBS.obs = .automatic
        let corrected = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: withOBS, samplingRate: Self.samplingRate
        )

        let before = residual(templateOnly.channels[0], recording)
        let after = residual(corrected.channels[0], recording)
        #expect(after < before * 0.5, "OBS residual \(after) vs template-only \(before)")
        #expect(!corrected.diagnostics.obsComponentCounts.isEmpty)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func obsOffAutomaticAndFixedAllProduceUsableOutput(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, variation: { cos(0.9 * Double($0)) })
        for mode in [GradientOBSMode.off, .automatic, .fixed(componentCount: 2)] {
            var config = baseConfig(backend)
            config.obs = mode
            let result = try GradientTemplateCorrector.correct(
                channels: [recording.channel], volumeTriggers: recording.triggers,
                config: config, samplingRate: Self.samplingRate
            )
            let finite = result.channels[0].allSatisfy { $0.isFinite }
            #expect(finite, "mode \(mode) produced non-finite output")
            #expect(result.channels[0].count == recording.sampleCount)
        }
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func fixedModeRemovesExactlyTheRequestedComponentCount(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, variation: { cos(0.9 * Double($0)) })
        var config = baseConfig(backend)
        config.obs = .fixed(componentCount: 3)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.obsComponentCounts.allSatisfy { $0 == 3 })
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func obsIsOffByDefault(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: baseConfig(backend), samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.obsComponentCounts.isEmpty)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func obsExcludedChannelsSkipTheStageButStillGetTemplateSubtraction(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, variation: { cos(0.9 * Double($0)) })
        var config = baseConfig(backend)
        config.obs = .automatic
        config.obsExcludedChannels = [1]

        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel, recording.channel],
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )
        // Both channels were corrected, but only channel 0 also had OBS applied.
        #expect(result.channels[0] != recording.channel)
        #expect(result.channels[1] != recording.channel)
        #expect(result.channels[0] != result.channels[1])
        #expect(residual(result.channels[0], recording) < residual(result.channels[1], recording))
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func obsChunksTheRecordingRatherThanFittingOneBasis(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 120, variation: { cos(0.9 * Double($0)) })
        var config = baseConfig(backend)
        config.obs = .fixed(componentCount: 2)
        // 100-sample epochs at 1000 Hz: four seconds is 40 epochs per chunk.
        config.obsChunkSeconds = 4
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.obsComponentCounts.count == 3)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func obsOnAShortRecordingDoesNotExplode(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // Only six epochs — below the minimum for a basis.
        let recording = makeRecording(volumes: 6, variation: { cos(0.9 * Double($0)) })
        var config = baseConfig(backend)
        config.obs = .automatic
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        let finite = result.channels[0].allSatisfy { $0.isFinite }
        #expect(finite)
        #expect(result.diagnostics.warnings.contains { warning in
            if case .obsChunkTooSmall = warning { return true }
            return false
        })
    }

    /// The case the residual-energy floor exists for. With a perfectly repeating
    /// artifact, template subtraction explains all of it and the residual is
    /// nothing but brain signal — which PCA will happily model and remove, since
    /// it has no way to tell signal structure from artifact structure. OBS has to
    /// stand down here rather than delete data.
    @Test(arguments: GradientComputeBackend.allCases)
    func obsStandsDownWhenTemplateSubtractionAlreadyExplainedTheArtifact(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40)
        var config = baseConfig(backend)
        config.obs = .automatic
        config.templateScaling = .unscaled
        let withOBS = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        var without = baseConfig(backend)
        without.templateScaling = .unscaled
        let plain = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: without, samplingRate: Self.samplingRate
        )

        #expect(withOBS.diagnostics.warnings.contains { warning in
            if case .obsResidualBelowFloor = warning { return true }
            return false
        })
        #expect(withOBS.diagnostics.obsComponentCounts.isEmpty)
        // Having stood down, OBS leaves the template-only result untouched.
        #expect(withOBS.channels[0] == plain.channels[0])
        #expect(residual(withOBS.channels[0], recording) < 1)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func loweringTheResidualFloorLetsOBSRunWhereItWouldOtherwiseStandDown(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40)
        var config = baseConfig(backend)
        config.obs = .automatic
        config.templateScaling = .unscaled
        config.obsResidualEnergyFloor = 0
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(!result.diagnostics.obsComponentCounts.isEmpty)
        let finite = result.channels[0].allSatisfy { $0.isFinite }
        #expect(finite)
    }

    // MARK: - ANC

    @Test(arguments: GradientComputeBackend.allCases)
    func ancReducesArtifactThatDriftsThroughTheScan(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // Unscaled subtraction cannot follow a slowly drifting artifact
        // amplitude, so a residual correlated with the removed estimate is left
        // for ANC to pick up.
        let recording = makeRecording(
            volumes: 80,
            amplitudeDrift: { 1 + 0.3 * sin(2 * .pi * Double($0) / 80) }
        )
        var config = baseConfig(backend)
        config.templateScaling = .unscaled

        let withoutANC = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        config.anc = true
        let withANC = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )

        #expect(withANC.diagnostics.ancAppliedChannels == [0])
        let before = residual(withoutANC.channels[0], recording)
        let after = residual(withANC.channels[0], recording)
        #expect(after < before, "ANC residual \(after) vs \(before)")
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func ancIsSkippedWhenTheArtifactEstimateCarriesNothing(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // A flat channel yields a flat artifact estimate, so there is no
        // reference to adapt against.
        let recording = makeRecording(volumes: 30)
        let flat = [Float](repeating: 0, count: recording.sampleCount)
        var config = baseConfig(backend)
        config.anc = true
        let result = try GradientTemplateCorrector.correct(
            channels: [flat], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.ancAppliedChannels.isEmpty)
        #expect(result.diagnostics.warnings.contains(
            .ancSkippedForUninformativeReference(channel: 0)
        ))
        #expect(result.channels[0] == flat)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func ancHighPassPoliciesBothRunEndToEnd(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40)
        for policy in GradientANC.HighPassPolicy.allCases {
            var config = baseConfig(backend)
            config.anc = true
            config.ancHighPass = policy
            let result = try GradientTemplateCorrector.correct(
                channels: [recording.channel], volumeTriggers: recording.triggers,
                config: config, samplingRate: Self.samplingRate
            )
            let finite = result.channels[0].allSatisfy { $0.isFinite }
            #expect(finite, "policy \(policy) produced non-finite output")
        }
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func ancIsOffByDefault(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: baseConfig(backend), samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.ancAppliedChannels.isEmpty)
    }

    // MARK: - Combined

    @Test(arguments: GradientComputeBackend.allCases)
    func obsAndAncTogetherStayFiniteAndDeterministic(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(
            volumes: 60,
            variation: { cos(0.9 * Double($0)) },
            amplitudeDrift: { 1 + 0.2 * sin(2 * .pi * Double($0) / 60) }
        )
        var config = baseConfig(backend)
        config.obs = .automatic
        config.anc = true
        config.subSampleAlignment = true
        config.upsampleFactor = 2

        let first = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        let second = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        let finite = first.channels[0].allSatisfy { $0.isFinite }
        #expect(finite)
        #expect(first.channels == second.channels)
        #expect(residual(first.channels[0], recording) < 20)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func theFullPipelineStillLeavesUncoveredSamplesUntouched(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // OBS adds to the artifact estimate and ANC subtracts a filtered
        // reference, so confirm the "nothing outside an epoch changes" guarantee
        // survives them. ANC filters the whole channel, so it necessarily
        // touches the tail — this checks the OBS path specifically.
        let recording = makeRecording(volumes: 20, variation: { cos(0.9 * Double($0)) })
        var config = baseConfig(backend)
        config.obs = .automatic
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        for sample in 2001..<recording.sampleCount {
            #expect(result.channels[0][sample] == recording.channel[sample],
                    "sample \(sample) was modified")
        }
    }

    // MARK: - Template-only channels

    /// `excludedChannels` passes a channel through untouched; these two skip a
    /// residual-modelling stage while still being corrected. Conflating the ideas
    /// is how a channel ends up either over-processed or not corrected at all.
    @Test(arguments: GradientComputeBackend.allCases)
    func ancExcludedChannelsAreStillCorrectedButNotAdapted(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }
        let recording = makeRecording(
            volumes: 80,
            amplitudeDrift: { 1 + 0.3 * sin(2 * .pi * Double($0) / 80) }
        )
        var config = baseConfig(backend)
        config.templateScaling = .unscaled
        config.anc = true
        config.ancExcludedChannels = [1]

        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel, recording.channel],
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )

        // Channel 0 adapted, channel 1 did not — and was not warned about either,
        // since it was never a candidate.
        #expect(result.diagnostics.ancAppliedChannels == [0])
        #expect(!result.diagnostics.warnings.contains(
            .ancSkippedForUninformativeReference(channel: 1)
        ))
        // Both were still corrected; they simply differ by what ANC removed.
        #expect(result.channels[0] != recording.channel)
        #expect(result.channels[1] != recording.channel)
        #expect(result.channels[0] != result.channels[1])
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func templateOnlyChannelsSkipBothResidualStages(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }
        let recording = makeRecording(volumes: 60, variation: { cos(0.9 * Double($0)) })
        var config = baseConfig(backend)
        config.obs = .automatic
        config.anc = true
        config.obsExcludedChannels = [1]
        config.ancExcludedChannels = [1]

        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel, recording.channel],
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )

        #expect(result.diagnostics.ancAppliedChannels == [0])
        // Template subtraction still ran on the skipped channel.
        #expect(result.channels[1] != recording.channel)
        #expect(result.channels[1].allSatisfy { $0.isFinite })
        // And the fully-processed channel is closer to the truth for it.
        #expect(residual(result.channels[0], recording) < residual(result.channels[1], recording))
    }

    /// Excluding every channel from ANC is the same as not asking for it.
    @Test func excludingEveryChannelFromANCLeavesTheTemplateResultAlone() throws {
        let recording = makeRecording(volumes: 40)
        var withoutANC = baseConfig()
        withoutANC.templateScaling = .unscaled

        var allExcluded = withoutANC
        allExcluded.anc = true
        allExcluded.ancExcludedChannels = [0]

        let plain = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: withoutANC, samplingRate: Self.samplingRate
        )
        let excluded = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: allExcluded, samplingRate: Self.samplingRate
        )
        #expect(excluded.channels[0] == plain.channels[0])
        #expect(excluded.diagnostics.ancAppliedChannels.isEmpty)
    }
}
