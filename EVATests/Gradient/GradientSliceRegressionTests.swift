import Foundation
import Testing
@testable import EVA

struct GradientSliceRegressionTests {
    @Test(arguments: GradientComputeBackend.allCases)
    func protectedTargetsKeepFixedDonorsWhenTheResponseChanges(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }
        let groups = 3, period = 32, volumes = 40, tr = groups * period
        let target = 20 * groups + 1, start = target * period
        let raw = (0..<(volumes * tr)).map { sample -> Float in
            let phase = 2 * Double.pi * Double(sample % period) / Double(period)
            return Float(100 * (sample / tr % 2 == 0 ? sin(phase) : cos(phase)))
        }
        var augmented = raw
        for offset in 0..<period {
            augmented[start + offset] += Float(300 * cos(2 * .pi * Double(offset) / Double(period)))
        }
        var c = config(backend, groups: groups)
        c.templateScheme = .correlationRanked
        c.averagingWindowBefore = 3; c.averagingWindowAfter = 3
        c.minimumCorrelatedDonors = 2; c.correlationThreshold = 0.5
        c.correlationSearchWindow = 10
        c.donorPolicy = GradientDonorPolicy(protectedIntervals: [Double(start) / 1000..<Double(start + period) / 1000], minimumDonors: 3)
        let triggers = (0..<volumes).map { $0 * tr }
        let before = try GradientTemplateCorrector.correct(channels: [raw], volumeTriggers: triggers, config: c, samplingRate: 1000)
        let beforeProbe = try GradientTemplateCorrector.correct(channels: [augmented], volumeTriggers: triggers, config: c, samplingRate: 1000)
        #expect(before.diagnostics.epochs[target].donorIndices != beforeProbe.diagnostics.epochs[target].donorIndices)
        #expect(before.diagnostics.protectedTemporalTargets.isEmpty)

        c.donorPolicy?.useTemporalDonorsForProtectedTargets = true
        let after = try GradientTemplateCorrector.correct(channels: [raw], volumeTriggers: triggers, config: c, samplingRate: 1000)
        let afterProbe = try GradientTemplateCorrector.correct(channels: [augmented], volumeTriggers: triggers, config: c, samplingRate: 1000)
        let protected = Set(after.diagnostics.protectedTemporalTargets)
        #expect(protected.contains(target))
        var temporalConfig = c; temporalConfig.templateScheme = .temporalNeighbors
        let temporal = try GradientTemplateCorrector.correct(channels: [raw], volumeTriggers: triggers, config: temporalConfig, samplingRate: 1000)
        for epoch in after.diagnostics.epochs {
            #expect(epoch.corrected)
            #expect(epoch.donorIndices == afterProbe.diagnostics.epochs[epoch.epoch].donorIndices)
            #expect(epoch.donorIndices.allSatisfy { !protected.contains($0) && $0 % groups == epoch.slicePosition })
            if protected.contains(epoch.epoch) {
                #expect(epoch.donorIndices == temporal.diagnostics.epochs[epoch.epoch].donorIndices)
                #expect(!after.diagnostics.warnings.contains(.correlationDonorsFellBack(epoch: epoch.epoch)))
            } else {
                #expect(epoch.donorIndices == before.diagnostics.epochs[epoch.epoch].donorIndices)
            }
        }
        for sample in raw.indices {
            let recovered = afterProbe.channels[0][sample] - after.channels[0][sample]
            #expect(abs(recovered - (augmented[sample] - raw[sample])) < 0.001)
        }
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func protectedSelectionRespectsPaddingAndCannotBypassDonorMinimum(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }
        let groups = 3, period = 40, tr = groups * period, volumes = 40
        let input = (0..<(volumes * tr)).map { Float(100 * sin(2 * .pi * Double($0 % period) / Double(period))) }
        var c = config(backend, groups: groups)
        c.templateScheme = .correlationRanked
        c.correlationThreshold = 2 // Outside protected targets, the normal fallback still applies.
        c.alignmentEnabled = true; c.alignmentSearchRadius = 2
        c.upsampleFactor = 2; c.subSampleAlignment = true
        let target = 15 * groups, onset = Double(target * period + period + 5) / 1000
        c.donorPolicy = GradientDonorPolicy(protectedIntervals: [onset..<(onset + 0.001)], minimumDonors: 4,
                                           useTemporalDonorsForProtectedTargets: true)
        let triggers = (0..<volumes).map { $0 * tr }
        let result = try GradientTemplateCorrector.correct(channels: [input], volumeTriggers: triggers, config: c, samplingRate: 1000)
        // Protection begins beyond the nominal target epoch, inside the padded
        // extraction/interpolation support. It must still control selection.
        #expect(result.diagnostics.protectedTemporalTargets.contains(target))
        #expect(!result.diagnostics.warnings.contains(.correlationDonorsFellBack(epoch: target)))
        #expect(result.diagnostics.warnings.contains { if case .correlationDonorsFellBack = $0 { true } else { false } })

        c.alignmentEnabled = false; c.subSampleAlignment = false; c.upsampleFactor = 1
        c.donorPolicy?.protectedIntervals = [0..<Double(input.count) / 1000]
        let starved = try GradientTemplateCorrector.correct(channels: [input], volumeTriggers: triggers, config: c, samplingRate: 1000)
        #expect(starved.channels[0] == input)
        #expect(starved.diagnostics.epochs.allSatisfy { !$0.corrected && $0.donorIndices.isEmpty })
        #expect(!starved.diagnostics.warnings.contains { if case .correlationDonorsFellBack = $0 { true } else { false } })

        c.donorPolicy?.protectedIntervals = []
        let empty = try GradientTemplateCorrector.correct(channels: [input], volumeTriggers: triggers, config: c, samplingRate: 1000)
        c.donorPolicy?.useTemporalDonorsForProtectedTargets = false
        let disabled = try GradientTemplateCorrector.correct(channels: [input], volumeTriggers: triggers, config: c, samplingRate: 1000)
        #expect(empty.channels == disabled.channels)
        #expect(empty.diagnostics.protectedTemporalTargets.isEmpty)
    }

    private func config(_ backend: GradientComputeBackend, groups: Int) -> GradientCorrectionConfig {
        var config = GradientCorrectionConfig()
        config.computeBackend = backend
        config.metalMinimumWorkload = 0
        config.numberOfSlices = groups
        config.alignmentEnabled = false
        config.subSampleAlignment = false
        config.templateScaling = .unscaled
        config.obs = .off
        config.anc = false
        return config
    }

    private func supports(_ backend: GradientComputeBackend) -> Bool {
        backend != .metal || GradientTemplateCorrector.isMetalAvailable
    }

    private func motion(_ volumes: Int, event: Int? = nil) -> [MotionSample] {
        (0..<volumes).map { volume in
            MotionSample(id: volume, roll: 0, pitch: 0, yaw: 0,
                         dS: volume == event ? 3 : 0, dL: 0, dP: 0)
        }
    }

    @Test(arguments: GradientComputeBackend.allCases, [5, 30])
    func distinctGroupArtifactsUseMatchingDonorsIncludingFallbacks(
        backend: GradientComputeBackend, groups: Int
    ) throws {
        guard supports(backend) else { return }
        let volumes = 40, period = 40, tr = groups * period
        let input = (0..<(volumes * tr)).map { sample -> Float in
            let group = (sample / period) % groups
            let phase = Double(sample % period) / Double(period)
            return Float(100 * sin(2 * .pi * Double(group % 3 + 1) * phase))
        }
        for mode in 0..<5 {
            var config = config(backend, groups: groups)
            config.censoredVolumes = [2]
            switch mode {
            case 1: config.templateScheme = .motionInformed // Missing motion fallback.
            case 2:
                config.templateScheme = .motionInformed
                config.motion = motion(volumes) // No supra-threshold motion fallback.
            case 3:
                config.templateScheme = .motionInformed
                config.motion = motion(volumes, event: 20)
            case 4:
                config.templateScheme = .correlationRanked
                config.correlationThreshold = 2 // Force correlation fallback.
            default: break
            }
            let result = try GradientTemplateCorrector.correct(
                channels: [input], volumeTriggers: (0..<volumes).map { $0 * tr },
                config: config, samplingRate: 1000)
            #expect(result.diagnostics.epochs.count == volumes * groups)
            for epoch in result.diagnostics.epochs {
                #expect(epoch.corrected)
                #expect(epoch.donorIndices.count == 30)
                #expect(epoch.donorIndices.allSatisfy { $0 % groups == epoch.slicePosition })
                #expect(epoch.donorIndices.allSatisfy { $0 / groups != 2 })
                #expect(!epoch.donorIndices.contains(epoch.epoch))
            }
            // Artifact-only fixture: the exact same group repeats every volume.
            let peakResidual = result.channels[0].map { abs($0) }.max() ?? 0
            #expect(peakResidual < 0.01, "mode \(mode), residual \(peakResidual)")
            if mode == 1 { #expect(result.diagnostics.warnings.contains(.motionUnavailableForScheme)) }
            if mode == 2 { #expect(result.diagnostics.warnings.contains(.noSupraThresholdMotion)) }
            if mode == 4 {
                #expect(result.diagnostics.warnings.contains(.correlationDonorsFellBack(epoch: groups * 10)))
            }
        }
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func emptyMotionDonorListFallsBackWithinTheGroup(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }
        let groups = 3, period = 40, tr = groups * period, volumes = 20
        let input = (0..<(volumes * tr)).map { Float(100 * cos(2 * .pi * Double($0 % period) / Double(period))) }
        var config = config(backend, groups: groups)
        config.templateScheme = .motionInformed
        config.motion = motion(volumes, event: 10)
        config.averagingWindowBefore = 1
        config.averagingWindowAfter = 0
        var policy = GradientDonorPolicy()
        policy.minimumDonors = 1
        // The initial motion-selected donor is volume 4, group 1. Exclude it
        // while leaving adjacent groups available to expose an ungrouped fallback.
        policy.protectedIntervals = [Double(4 * tr + period) / 1000..<Double(4 * tr + 2 * period) / 1000]
        config.donorPolicy = policy
        let result = try GradientTemplateCorrector.correct(
            channels: [input], volumeTriggers: (0..<volumes).map { $0 * tr },
            config: config, samplingRate: 1000)
        let epoch = try #require(result.diagnostics.epochs.first { $0.epoch == 5 * groups + 1 })
        #expect(epoch.corrected)
        #expect(epoch.donorIndices == [6 * groups + 1])
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func fractionalGroupSpacingKeepsTheRepeatingSamplingPhase(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }
        let groups = 30, tr = 1100, volumes = 40
        let input = (0..<(volumes * tr)).map { sample in
            Float(100 * sin(2 * .pi * Double(sample) * Double(groups) / Double(tr)))
        }
        let result = try GradientTemplateCorrector.correct(
            channels: [input], volumeTriggers: (0..<volumes).map { $0 * tr },
            config: config(backend, groups: groups), samplingRate: 1000)
        let interior = tr..<(input.count - tr)
        #expect(result.channels[0][interior].allSatisfy { abs($0) < 0.01 })
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func paddedEdgeIsUncorrectedInBothDataAndCoverage(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }
        let groups = 4, period = 40, tr = groups * period, volumes = 40
        let input = (0..<(volumes * tr)).map { Float(100 * cos(2 * .pi * Double($0 % period) / Double(period))) }
        var config = config(backend, groups: groups)
        config.alignmentEnabled = true
        config.alignmentSearchRadius = 2
        let result = try GradientTemplateCorrector.correct(
            channels: [input], volumeTriggers: (0..<volumes).map { $0 * tr },
            config: config, samplingRate: 1000)
        let first = try #require(result.diagnostics.epochs.first)
        #expect(first.epoch == 0)
        #expect(!first.corrected)
        #expect(first.donorIndices.isEmpty)
        #expect(result.diagnostics.warnings.contains(.epochOutOfBounds(epoch: 0)))
        #expect(Array(result.channels[0][0..<period]) == Array(input[0..<period]))
        #expect(result.diagnostics.epochs.count == groups * volumes)
        #expect(result.diagnostics.epochs.dropFirst().contains { $0.corrected })
        #expect(result.diagnostics.epochs.allSatisfy { !$0.donorIndices.contains(0) })
        let coverage = GradientCoverage.from(diagnostics: result.diagnostics, sampleCount: input.count)
        let edge = try #require(coverage.epochs.first)
        #expect(edge.status == .edge)
        #expect(edge.startSample == 0)
        #expect(edge.endSample == period)
    }

    @Test func memoryBudgetIncludesCorrelationAndOBSAndScalesWithUpsampling() {
        func plan(factor: Int) -> GradientBatchPlan {
            GradientBatchPlan(sampleCount: 100_000, upsampleFactor: factor,
                              epochCount: 1000, windowLength: 100 * factor,
                              windowStarts: [], fractionalShifts: [])
        }
        let native = GradientCPUBackend.maximumHostTileChannels(plan: plan(factor: 1))
        let upsampled = GradientCPUBackend.maximumHostTileChannels(plan: plan(factor: 10))
        let correlation = GradientCPUBackend.maximumHostTileChannels(
            plan: plan(factor: 1), correlationPairCount: 2_000_000)
        let obs = GradientCPUBackend.maximumHostTileChannels(
            plan: plan(factor: 1), obsSampleCounts: Array(repeating: 256, count: 30))
        #expect(native > upsampled)
        #expect(native > correlation)
        #expect(native > obs)
        #expect(GradientCPUBackend.maximumHostTileChannels(plan: plan(factor: 10), budgetBytes: 1) == 1)
        #expect(GradientCPUBackend.shared.maximumTileChannels(plan: plan(factor: 1)) <= ProcessInfo.processInfo.activeProcessorCount)
    }

    @Test func multipleCPUTilesMatchSeparateChannelRuns() throws {
        let groups = 3, period = 40, tr = groups * period, volumes = 35
        let config = config(.cpu, groups: groups)
        let plan = GradientBatchPlan(sampleCount: volumes * tr, upsampleFactor: 1,
                                     epochCount: volumes * groups, windowLength: period + 1,
                                     windowStarts: [], fractionalShifts: [])
        let channelCount = GradientCPUBackend.shared.maximumTileChannels(plan: plan) + 1
        let channels = (0..<channelCount).map { channel in
            (0..<(volumes * tr)).map { sample -> Float in
                let phase = 2 * Double.pi * Double(sample % period) / Double(period)
                return Float(Double(channel + 1) * sin(phase) + 0.1 * cos(Double(sample) * 0.071))
            }
        }
        let triggers = (0..<volumes).map { $0 * tr }
        let batched = try GradientTemplateCorrector.correct(
            channels: channels, volumeTriggers: triggers, config: config, samplingRate: 1000)
        #expect(batched.diagnostics.referenceChannel == channelCount - 1)
        #expect(batched.diagnostics.epochs.count == volumes * groups)
        for channel in channels.indices {
            let separate = try GradientTemplateCorrector.correct(
                channels: [channels[channel]], volumeTriggers: triggers, config: config, samplingRate: 1000)
            #expect(batched.channels[channel] == separate.channels[0])
        }
    }
}
