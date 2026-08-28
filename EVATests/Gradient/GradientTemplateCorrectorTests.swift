//
//  GradientTemplateCorrectorTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Written from the "Edge Cases" and "Acceptance Tests" sections of
//  docs/provenance/fastr-functional-spec.md. These tests are the acceptance
//  gate for the clean-room implementation; they were written from the spec, not
//  from the behavior of EVA's earlier ported corrector.
//

import Testing
import Foundation
@testable import EVA

struct GradientTemplateCorrectorTests {

    // MARK: - Synthetic recordings

    private static let samplingRate = 1000.0

    /// A gradient-like artifact waveform: three harmonics of the artifact period
    /// with unequal amplitudes and offset phases, so its autocorrelation has a
    /// sharp, unambiguous peak.
    private func gradientWave(_ position: Double, period: Int, phase: Double = 0) -> Float {
        let wrapped = position.truncatingRemainder(dividingBy: Double(period))
        let normalized = (wrapped < 0 ? wrapped + Double(period) : wrapped) / Double(period) + phase
        return Float(
            120 * sin(2 * .pi * normalized)
            + 70 * sin(6 * .pi * normalized + 0.6)
            + 45 * sin(10 * .pi * normalized + 1.3)
        )
    }

    /// Physiological signal at a frequency that is not a harmonic of the artifact
    /// period, so template averaging cannot mistake it for artifact.
    private func physiology(_ sample: Int, hz: Double = 7, amplitude: Double = 6) -> Float {
        Float(amplitude * sin(2 * .pi * hz * Double(sample) / Self.samplingRate))
    }

    private struct Recording {
        let channel: [Float]
        let physiology: [Float]
        let triggers: [Int]
        let sampleCount: Int
    }

    private func makeRecording(
        volumes: Int,
        period: Int,
        tailSamples: Int = 100,
        artifactScale: (Int) -> Double = { _ in 1 },
        artifactShift: (Int) -> Double = { _ in 0 },
        artifactPhase: (Int) -> Double = { _ in 0 }
    ) -> Recording {
        let sampleCount = volumes * period + tailSamples
        var channel = [Float](repeating: 0, count: sampleCount)
        var clean = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            let volume = min(sample / period, volumes - 1)
            let position = Double(sample - volume * period) - artifactShift(volume)
            let artifact = Float(artifactScale(volume))
                * gradientWave(position, period: period, phase: artifactPhase(volume))
            clean[sample] = physiology(sample)
            channel[sample] = clean[sample] + artifact
        }
        return Recording(
            channel: channel,
            physiology: clean,
            triggers: (0..<volumes).map { $0 * period },
            sampleCount: sampleCount
        )
    }

    private func rootMeanSquare(_ values: ArraySlice<Float>) -> Double {
        guard !values.isEmpty else { return 0 }
        let total = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (total / Double(values.count)).squareRoot()
    }

    private func rootMeanSquareDifference(_ a: [Float], _ b: [Float], over range: Range<Int>) -> Double {
        var total = 0.0
        for index in range {
            let difference = Double(a[index]) - Double(b[index])
            total += difference * difference
        }
        return (total / Double(range.count)).squareRoot()
    }

    private func correlation(_ a: [Float], _ b: [Float], over range: Range<Int>) -> Double {
        GradientDonorSelection.pearsonCorrelation(
            Array(a[range]),
            Array(b[range])
        )
    }

    private func defaultConfig(_ backend: GradientComputeBackend = .cpu) -> GradientCorrectionConfig {
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

    // MARK: - Contract

    @Test(arguments: GradientComputeBackend.allCases)
    func outputMatchesInputShapeAndOrder(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 20, period: 100)
        let channels = [recording.channel, recording.channel.map { $0 * 0.5 }, recording.channel.map { -$0 }]
        let result = try GradientTemplateCorrector.correct(
            channels: channels,
            volumeTriggers: recording.triggers,
            config: defaultConfig(backend),
            samplingRate: Self.samplingRate
        )
        #expect(result.channels.count == 3)
        for channel in result.channels {
            #expect(channel.count == recording.sampleCount)
        }
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func allOutputSamplesAreFiniteForFiniteInput(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel],
            volumeTriggers: recording.triggers,
            config: defaultConfig(backend),
            samplingRate: Self.samplingRate
        )
        #expect(result.channels[0].allSatisfy { $0.isFinite })
    }

    @Test func rejectsMalformedInput() {
        let triggers = [0, 100, 200]
        #expect(throws: GradientCorrectionError.noChannels) {
            _ = try GradientTemplateCorrector.correct(
                channels: [], volumeTriggers: triggers,
                config: GradientCorrectionConfig(), samplingRate: Self.samplingRate
            )
        }
        #expect(throws: GradientCorrectionError.emptyChannels) {
            _ = try GradientTemplateCorrector.correct(
                channels: [[]], volumeTriggers: triggers,
                config: GradientCorrectionConfig(), samplingRate: Self.samplingRate
            )
        }
        #expect(throws: GradientCorrectionError.mismatchedChannelLengths) {
            _ = try GradientTemplateCorrector.correct(
                channels: [[Float](repeating: 0, count: 400), [Float](repeating: 0, count: 300)],
                volumeTriggers: triggers,
                config: GradientCorrectionConfig(), samplingRate: Self.samplingRate
            )
        }
    }

    @Test func tooFewTriggersThrows() {
        let recording = makeRecording(volumes: 20, period: 100)
        #expect(throws: GradientCorrectionError.insufficientTriggers(1)) {
            _ = try GradientTemplateCorrector.correct(
                channels: [recording.channel], volumeTriggers: [0],
                config: GradientCorrectionConfig(), samplingRate: Self.samplingRate
            )
        }
    }

    @Test func rejectsInvalidConfiguration() {
        let recording = makeRecording(volumes: 20, period: 100)
        func attempt(_ mutate: (inout GradientCorrectionConfig) -> Void) throws {
            var config = GradientCorrectionConfig()
            mutate(&config)
            _ = try GradientTemplateCorrector.correct(
                channels: [recording.channel], volumeTriggers: recording.triggers,
                config: config, samplingRate: Self.samplingRate
            )
        }
        #expect(throws: GradientCorrectionError.self) { try attempt { $0.upsampleFactor = 0 } }
        #expect(throws: GradientCorrectionError.self) { try attempt { $0.numberOfSlices = 0 } }
        #expect(throws: GradientCorrectionError.self) { try attempt { $0.relativeTriggerPosition = 1.5 } }
    }

    // MARK: - Artifact reduction

    @Test(arguments: GradientComputeBackend.allCases)
    func temporalNeighborsSubstantiallyReducesArtifactPower(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, period: 100)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel],
            volumeTriggers: recording.triggers,
            config: defaultConfig(backend),
            samplingRate: Self.samplingRate
        )

        let covered = 0..<(40 * 100)
        let before = rootMeanSquareDifference(recording.channel, recording.physiology, over: covered)
        let after = rootMeanSquareDifference(result.channels[0], recording.physiology, over: covered)
        #expect(after < before * 0.1, "residual \(after) vs original artifact \(before)")
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func nonTRLockedSignalIsLargelyPreserved(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, period: 100)
        var config = defaultConfig(backend)
        config.templateScaling = .unscaled
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel],
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )

        let covered = 0..<(40 * 100)
        let r = correlation(result.channels[0], recording.physiology, over: covered)
        #expect(r > 0.98, "correlation with the clean signal was \(r)")

        let preserved = rootMeanSquare(result.channels[0][covered])
        let original = rootMeanSquare(recording.physiology[covered])
        #expect(preserved > original * 0.9 && preserved < original * 1.15,
                "amplitude \(preserved) vs \(original)")
    }

    /// Why the default is not a raw per-epoch fit. The scale is fitted from one
    /// 101-sample window, and over a window that short a 7 Hz rhythm is not
    /// orthogonal to a 10 Hz artifact fundamental — so part of the physiological
    /// signal is absorbed into the scale and subtracted with the artifact.
    /// Drift tracking medians that scatter away; all three modes remove the
    /// artifact, and they differ in what else they take with it.
    @Test(arguments: GradientComputeBackend.allCases)
    func rawPerEpochFittingCostsMoreSignalThanTheOtherModes(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, period: 100)
        let covered = 0..<(40 * 100)

        func correlationFor(_ scaling: GradientTemplateScaling) throws -> Double {
            var config = defaultConfig(backend)
            config.templateScaling = scaling
            let result = try GradientTemplateCorrector.correct(
                channels: [recording.channel], volumeTriggers: recording.triggers,
                config: config, samplingRate: Self.samplingRate
            )
            // Every mode must still remove essentially all of the artifact.
            let before = rootMeanSquareDifference(recording.channel, recording.physiology, over: covered)
            let after = rootMeanSquareDifference(result.channels[0], recording.physiology, over: covered)
            #expect(after < before * 0.1, "\(scaling) left \(after)")
            return correlation(result.channels[0], recording.physiology, over: covered)
        }

        let unscaled = try correlationFor(.unscaled)
        let drift = try correlationFor(.driftTracking)
        let raw = try correlationFor(.leastSquares)

        #expect(raw < drift, "raw fitting \(raw) should preserve less than drift tracking \(drift)")
        #expect(drift > 0.95, "drift tracking preserved only \(drift)")
        #expect(unscaled > 0.98, "unscaled preserved only \(unscaled)")
    }

    /// Worth stating explicitly, because it narrows what template scaling is
    /// actually for: a sustained amplitude change needs no scaling at all. Once
    /// the donor window has moved past the transition, the donors carry the new
    /// amplitude and the template is already right.
    @Test(arguments: GradientComputeBackend.allCases)
    func donorAveragingAloneTracksASustainedAmplitudeChange(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(
            volumes: 60, period: 100,
            artifactScale: { $0 >= 30 ? 1.5 : 1 }
        )
        var config = defaultConfig(backend)
        config.templateScaling = .unscaled
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        // Well clear of the transition on both sides. The donor window spans 15
        // epochs either way, so only volumes below 15 and above 45 have donors
        // drawn entirely from one side of the change.
        for region in [0..<1500, 4600..<5900] {
            let residual = rootMeanSquareDifference(
                result.channels[0], recording.physiology, over: region
            )
            #expect(residual < 5, "residual \(residual) in \(region)")
        }
    }

    /// What scaling is really for. At the start of a recording the donor window
    /// is one-sided, so when the artifact amplitude is trending the template is
    /// built from epochs that are systematically larger than the target — the
    /// edge bias the reference toolboxes cite as their reason for scaling at all.
    @Test(arguments: GradientComputeBackend.allCases)
    func driftTrackingCorrectsEdgeTemplateBias(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // Amplitude ramps steadily from 1x to 3x across the recording.
        let volumes = 60
        let recording = makeRecording(
            volumes: volumes, period: 100,
            artifactScale: { 1 + 2 * Double($0) / Double(volumes - 1) }
        )
        let edge = 0..<1000

        var unscaled = defaultConfig(backend)
        unscaled.templateScaling = .unscaled
        let plain = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: unscaled, samplingRate: Self.samplingRate
        )
        let tracked = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: defaultConfig(backend), samplingRate: Self.samplingRate
        )

        let plainResidual = rootMeanSquareDifference(plain.channels[0], recording.physiology, over: edge)
        let trackedResidual = rootMeanSquareDifference(tracked.channels[0], recording.physiology, over: edge)
        #expect(trackedResidual < plainResidual * 0.5,
                "drift tracking \(trackedResidual) vs unscaled \(plainResidual)")

        // The fitted scale compensates downward, because the one-sided donors are
        // drawn from later, larger-amplitude epochs.
        let first = try #require(tracked.diagnostics.epochs.first { $0.epoch == 0 })
        #expect(first.templateScale < 0.9, "edge scale was \(first.templateScale)")
    }

    /// A one-volume amplitude spike is not drift, and drift tracking treats it as
    /// scatter. `.leastSquares` is the mode for following a change that fast.
    @Test(arguments: GradientComputeBackend.allCases)
    func aSingleEpochAmplitudeSpikeNeedsRawFitting(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(
            volumes: 40, period: 100,
            artifactScale: { $0 == 20 ? 3 : 1 }
        )
        let outlier = 2000..<2100

        var raw = defaultConfig(backend)
        raw.templateScaling = .leastSquares
        let fitted = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: raw, samplingRate: Self.samplingRate
        )
        let fittedResidual = rootMeanSquareDifference(fitted.channels[0], recording.physiology, over: outlier)
        #expect(fittedResidual < 15, "raw fitting left \(fittedResidual) in the spike")
        let scale = try #require(fitted.diagnostics.epochs.first { $0.epoch == 20 }?.templateScale)
        #expect(abs(scale - 3) < 0.2, "template scale \(scale) should approach the 3x amplitude")

        let tracked = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: defaultConfig(backend), samplingRate: Self.samplingRate
        )
        let trackedResidual = rootMeanSquareDifference(tracked.channels[0], recording.physiology, over: outlier)
        #expect(trackedResidual > fittedResidual,
                "drift tracking should reject the one-epoch spike, left \(trackedResidual)")
    }

    // MARK: - Scale sanity guards

    @Test func implausibleFittedScalesAreRejected() {
        let range = GradientCorrectionConfig().templateScaleRange
        #expect(GradientTemplateCorrector.sanitizedScale(1.4, range: range) == 1.4)
        #expect(GradientTemplateCorrector.sanitizedScale(Double.nan, range: range) == nil)
        #expect(GradientTemplateCorrector.sanitizedScale(.infinity, range: range) == nil)
        #expect(GradientTemplateCorrector.sanitizedScale(-1.2, range: range) == nil)
        #expect(GradientTemplateCorrector.sanitizedScale(0, range: range) == nil)
        #expect(GradientTemplateCorrector.sanitizedScale(40, range: range) == nil)
        #expect(GradientTemplateCorrector.sanitizedScale(0.01, range: range) == nil)
    }

    @Test func scaleResolutionHonoursEachMode() {
        let fitted: [Double?] = [1.0, 1.1, 5.0, 0.9, nil, 1.05, 1.0]

        let unscaled = GradientTemplateCorrector.resolveScales(
            fitted: fitted, mode: .unscaled, smoothingEpochs: 5
        )
        #expect(unscaled == [1, 1, 1, 1, 1, 1, 1])

        let raw = GradientTemplateCorrector.resolveScales(
            fitted: fitted, mode: .leastSquares, smoothingEpochs: 5
        )
        #expect(raw == [1.0, 1.1, 5.0, 0.9, 1.0, 1.05, 1.0])

        // The 5.0 outlier is medianed away; the rejected fit falls back to 1.
        let tracked = GradientTemplateCorrector.resolveScales(
            fitted: fitted, mode: .driftTracking, smoothingEpochs: 5
        )
        #expect(tracked[2] < 1.2, "the outlier survived as \(tracked[2])")
        #expect(tracked[4] == 1)
    }

    @Test func driftTrackingPassesAStepChangeThrough() {
        let fitted: [Double?] = (0..<40).map { $0 < 20 ? 1.0 : 2.0 }
        let tracked = GradientTemplateCorrector.resolveScales(
            fitted: fitted, mode: .driftTracking, smoothingEpochs: 9
        )
        // A median passes a step sharply rather than ramping across it.
        #expect(tracked[10] == 1)
        #expect(tracked[30] == 2)
        #expect(tracked[19] == 1)
        #expect(tracked[20] == 2)
    }

    // MARK: - Boundaries

    @Test(arguments: GradientComputeBackend.allCases)
    func samplesOutsideCorrectedEpochsAreBitIdentical(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 20, period: 100, tailSamples: 100)
        for factor in [1, 2, 4] {
            var config = defaultConfig(backend)
            config.upsampleFactor = factor
            let result = try GradientTemplateCorrector.correct(
                channels: [recording.channel],
                volumeTriggers: recording.triggers,
                config: config,
                samplingRate: Self.samplingRate
            )
            // The final epoch covers through sample 2000; nothing past it is touched.
            for sample in 2001..<recording.sampleCount {
                #expect(result.channels[0][sample] == recording.channel[sample],
                        "factor \(factor) sample \(sample) was modified")
            }
        }
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func epochsRunningPastTheRecordingAreLeftUncorrectedAndReported(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // No tail: the last epoch needs one sample more than the recording has.
        // Alignment is disabled so the epoch cannot be rescued by shifting it
        // back into bounds, which is what the aligner does when it can.
        let recording = makeRecording(volumes: 20, period: 100, tailSamples: 0)
        var config = defaultConfig(backend)
        config.alignmentEnabled = false
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel],
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.warnings.contains(.epochOutOfBounds(epoch: 19)))
        let last = try #require(result.diagnostics.epochs.first { $0.epoch == 19 })
        #expect(!last.corrected)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func earlyAndLateEpochsAreStillCorrected(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, period: 100)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel],
            volumeTriggers: recording.triggers,
            config: defaultConfig(backend),
            samplingRate: Self.samplingRate
        )
        let first = try #require(result.diagnostics.epochs.first { $0.epoch == 0 })
        let last = try #require(result.diagnostics.epochs.first { $0.epoch == 39 })
        #expect(first.corrected)
        #expect(last.corrected)
        #expect(first.donorIndices.count == 30)
        #expect(last.donorIndices.count == 30)
        #expect(!first.donorIndices.contains(0))
    }

    // MARK: - Determinism and channel handling

    @Test(arguments: GradientComputeBackend.allCases)
    func repeatedRunsProduceIdenticalOutput(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        var config = defaultConfig(backend)
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
        #expect(first.channels == second.channels)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func singleChannelMatchesTheSameChannelInAMultiChannelRun(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        let quiet = recording.channel.map { $0 * 0.25 }
        let config = defaultConfig(backend)

        let alone = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        let together = try GradientTemplateCorrector.correct(
            channels: [recording.channel, quiet], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        // Channel 0 has the larger variance, so it is the alignment reference in
        // both runs and its correction must be identical.
        #expect(together.diagnostics.referenceChannel == 0)
        #expect(alone.channels[0] == together.channels[0])
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func excludedChannelsPassThroughUntouched(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        var config = defaultConfig(backend)
        config.excludedChannels = [1]
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel, recording.channel],
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )
        #expect(result.channels[1] == recording.channel)
        #expect(result.channels[0] != recording.channel)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func flatChannelIsLeftAloneWithADegenerateTemplateWarning(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 20, period: 100)
        let flat = [Float](repeating: 0, count: recording.sampleCount)
        let result = try GradientTemplateCorrector.correct(
            channels: [flat],
            volumeTriggers: recording.triggers,
            config: defaultConfig(backend),
            samplingRate: Self.samplingRate
        )
        #expect(result.channels[0] == flat)
        #expect(result.diagnostics.warnings.contains { warning in
            if case .degenerateTemplate = warning { return true }
            return false
        })
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func aFlatChannelAlongsideALiveOneDoesNotDisturbIt(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        let flat = [Float](repeating: 0, count: recording.sampleCount)
        let result = try GradientTemplateCorrector.correct(
            channels: [flat, recording.channel],
            volumeTriggers: recording.triggers,
            config: defaultConfig(backend),
            samplingRate: Self.samplingRate
        )
        #expect(result.channels[0] == flat)
        #expect(result.channels[1].allSatisfy { $0.isFinite })
        #expect(result.diagnostics.referenceChannel == 1)
    }

    // MARK: - Censoring

    @Test(arguments: GradientComputeBackend.allCases)
    func censoredVolumesAreCorrectedButNeverDonate(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(
            volumes: 40, period: 100,
            artifactScale: { $0 == 20 ? 4 : 1 }
        )
        var config = defaultConfig(backend)
        config.censoredVolumes = [20]
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel],
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )

        for epoch in result.diagnostics.epochs {
            #expect(!epoch.donorIndices.contains(20),
                    "epoch \(epoch.epoch) used the censored volume as a donor")
        }
        let censored = try #require(result.diagnostics.epochs.first { $0.epoch == 20 })
        #expect(censored.corrected, "a censored volume must still be corrected")
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func censoringEverythingNearbyStillTerminatesGracefully(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 12, period: 100)
        var config = defaultConfig(backend)
        config.censoredVolumes = Set(0..<12)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel],
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: Self.samplingRate
        )
        #expect(result.channels[0] == recording.channel)
        #expect(result.diagnostics.warnings.contains { warning in
            if case .noEligibleDonors = warning { return true }
            return false
        })
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func anEmptyCensorSetMatchesNoCensoringAtAll(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 20, period: 100)
        var censored = defaultConfig(backend)
        censored.censoredVolumes = []
        let a = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: censored, samplingRate: Self.samplingRate
        )
        let b = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: defaultConfig(backend), samplingRate: Self.samplingRate
        )
        #expect(a.channels == b.channels)
    }

    // MARK: - Motion

    private func motionWithEventAt(_ volume: Int, volumes: Int, magnitude: Double = 3) -> [MotionSample] {
        (0..<volumes).map { index in
            MotionSample(
                id: index, roll: 0, pitch: 0, yaw: 0,
                dS: index >= volume ? magnitude : 0, dL: 0, dP: 0
            )
        }
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func motionInformedFallsBackWhenNoMotionIsSupplied(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .motionInformed
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.warnings.contains(.motionUnavailableForScheme))
        #expect(result.channels[0].allSatisfy { $0.isFinite })
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func motionInformedFallsBackWhenNothingExceedsTheThreshold(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .motionInformed
        config.motion = (0..<30).map {
            MotionSample(id: $0, roll: 0, pitch: 0, yaw: 0, dS: 0.01, dL: 0, dP: 0)
        }
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.warnings.contains(.noSupraThresholdMotion))
        #expect(result.diagnostics.highMotionVolumes.isEmpty)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func motionInformedDonorsAvoidTheMotionEvent(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 60, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .motionInformed
        // Ten donors, so both sides of the event have enough motion-free
        // neighbors and the barrier never has to be relaxed.
        config.averagingWindowBefore = 5
        config.averagingWindowAfter = 5
        config.motion = motionWithEventAt(30, volumes: 60)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.highMotionVolumes == [30])

        let after = try #require(result.diagnostics.epochs.first { $0.epoch == 34 })
        #expect(after.donorIndices.allSatisfy { $0 > 30 })
        let before = try #require(result.diagnostics.epochs.first { $0.epoch == 26 })
        #expect(before.donorIndices.allSatisfy { $0 < 30 })
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func highMotionVolumesAreExcludedAsDonorsUnderAnyScheme(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // Spec deviation note: once motion is loaded, high-motion volumes are
        // censoring information even when the scheme is not motion-informed.
        let recording = makeRecording(volumes: 40, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .temporalNeighbors
        config.motion = motionWithEventAt(20, volumes: 40)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.highMotionVolumes == [20])
        for epoch in result.diagnostics.epochs {
            #expect(!epoch.donorIndices.contains(20))
        }
        let highMotion = try #require(result.diagnostics.epochs.first { $0.epoch == 20 })
        #expect(highMotion.corrected)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func aShortMotionFileIsFrontPaddedAndReported(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .motionInformed
        config.motion = motionWithEventAt(10, volumes: 28)
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.warnings.contains(.motionRowsFrontPadded(count: 2)))
        // The event moves two volumes later once the file is aligned.
        #expect(result.diagnostics.highMotionVolumes == [12])
    }

    // MARK: - Correlation-ranked strategies

    @Test(arguments: GradientComputeBackend.allCases)
    func correlationRankedRunsWithoutFallbackOnAPeriodicArtifact(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .correlationRanked
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(!result.diagnostics.warnings.contains { warning in
            if case .correlationDonorsFellBack = warning { return true }
            return false
        })
        let covered = 0..<(40 * 100)
        let before = rootMeanSquareDifference(recording.channel, recording.physiology, over: covered)
        let after = rootMeanSquareDifference(result.channels[0], recording.physiology, over: covered)
        #expect(after < before * 0.1)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func correlationRankedFallsBackWhenNothingMeetsTheThreshold(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .correlationRanked
        config.correlationThreshold = 0.99999
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.warnings.contains { warning in
            if case .correlationDonorsFellBack = warning { return true }
            return false
        })
        // Falling back still corrects the data.
        #expect(result.channels[0].allSatisfy { $0.isFinite })
        #expect(result.channels[0] != recording.channel)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func squaredCorrelationRankingRunsEndToEnd(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .squaredCorrelationRanked
        config.allowsSelfDonation = true
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.channels[0].allSatisfy { $0.isFinite })
        // Self-donation was explicitly requested, so the target may appear.
        let epoch = try #require(result.diagnostics.epochs.first { $0.epoch == 20 })
        #expect(epoch.donorIndices.contains(20))
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func squaredCorrelationExcludesTheTargetByDefault(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 40, period: 100)
        var config = defaultConfig(backend)
        config.templateScheme = .squaredCorrelationRanked
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        for epoch in result.diagnostics.epochs where epoch.corrected {
            #expect(!epoch.donorIndices.contains(epoch.epoch))
        }
    }

    // MARK: - Slices and upsampling

    @Test(arguments: GradientComputeBackend.allCases)
    func sliceLevelCorrectionReducesArtifactPower(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // Artifact repeats every 25 samples: four slices per 100-sample volume.
        let volumes = 40
        let sampleCount = volumes * 100 + 100
        var channel = [Float](repeating: 0, count: sampleCount)
        var clean = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            clean[sample] = physiology(sample)
            channel[sample] = clean[sample] + gradientWave(Double(sample % 25), period: 25)
        }

        var config = defaultConfig(backend)
        config.numberOfSlices = 4
        let result = try GradientTemplateCorrector.correct(
            channels: [channel],
            volumeTriggers: (0..<volumes).map { $0 * 100 },
            config: config,
            samplingRate: Self.samplingRate
        )

        #expect(result.diagnostics.epochCount == volumes * 4)
        #expect(result.diagnostics.period == 25)
        let covered = 0..<(volumes * 100)
        let before = rootMeanSquareDifference(channel, clean, over: covered)
        let after = rootMeanSquareDifference(result.channels[0], clean, over: covered)
        #expect(after < before * 0.15, "residual \(after) vs \(before)")
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func upsamplingStillReducesArtifactPower(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 30, period: 100)
        var config = defaultConfig(backend)
        config.upsampleFactor = 4
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        let covered = 0..<(30 * 100)
        let before = rootMeanSquareDifference(recording.channel, recording.physiology, over: covered)
        let after = rootMeanSquareDifference(result.channels[0], recording.physiology, over: covered)
        #expect(after < before * 0.1, "residual \(after) vs \(before)")
    }

    // MARK: - Alignment

    @Test(arguments: GradientComputeBackend.allCases)
    func alignmentRecoversAKnownPerEpochShift(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // Every epoch is on time except volume 15, whose artifact starts three
        // samples late.
        let recording = makeRecording(
            volumes: 40, period: 100,
            artifactShift: { $0 == 15 ? 3 : 0 }
        )
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: defaultConfig(backend), samplingRate: Self.samplingRate
        )
        let shifted = try #require(result.diagnostics.epochs.first { $0.epoch == 15 })
        #expect(shifted.integerShift == 3, "recovered shift \(shifted.integerShift)")
        let onTime = try #require(result.diagnostics.epochs.first { $0.epoch == 16 })
        #expect(onTime.integerShift == 0)
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func alignmentImprovesCorrectionWhenTriggersJitter(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let jitter: (Int) -> Double = { volume in Double((volume % 5) - 2) }
        let recording = makeRecording(volumes: 40, period: 100, artifactShift: jitter)
        let covered = 0..<(40 * 100)

        var without = defaultConfig(backend)
        without.alignmentEnabled = false
        let unaligned = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: without, samplingRate: Self.samplingRate
        )
        let aligned = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: defaultConfig(backend), samplingRate: Self.samplingRate
        )

        let unalignedResidual = rootMeanSquareDifference(unaligned.channels[0], recording.physiology, over: covered)
        let alignedResidual = rootMeanSquareDifference(aligned.channels[0], recording.physiology, over: covered)
        #expect(alignedResidual < unalignedResidual * 0.5,
                "aligned \(alignedResidual) vs unaligned \(unalignedResidual)")
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func subSampleAlignmentImprovesOnIntegerAlignmentAlone(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        // Half-sample offsets that integer alignment cannot represent.
        let recording = makeRecording(
            volumes: 40, period: 100,
            artifactShift: { $0.isMultiple(of: 2) ? 0 : 0.5 }
        )
        let covered = 0..<(40 * 100)

        let integerOnly = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: defaultConfig(backend), samplingRate: Self.samplingRate
        )
        var subSample = defaultConfig(backend)
        subSample.subSampleAlignment = true
        let refined = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: subSample, samplingRate: Self.samplingRate
        )

        let coarse = rootMeanSquareDifference(integerOnly.channels[0], recording.physiology, over: covered)
        let fine = rootMeanSquareDifference(refined.channels[0], recording.physiology, over: covered)
        #expect(fine < coarse, "sub-sample \(fine) should beat integer-only \(coarse)")
    }

    @Test(arguments: GradientComputeBackend.allCases)
    func disablingAlignmentLeavesEveryShiftAtZero(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 20, period: 100, artifactShift: { $0 == 5 ? 3 : 0 })
        var config = defaultConfig(backend)
        config.alignmentEnabled = false
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )
        #expect(result.diagnostics.epochs.allSatisfy { $0.integerShift == 0 })
        #expect(result.diagnostics.epochs.allSatisfy { $0.fractionalShift == 0 })
    }

    // MARK: - Progress

    /// Progress is reported per pipeline stage rather than per channel.
    ///
    /// It used to be per channel, which stopped being meaningful once the stages
    /// became batched: a batched backend corrects a whole tile of channels at
    /// once and has no per-channel boundary to report against. What the contract
    /// still guarantees — and what a progress bar actually needs — is that the
    /// sequence is non-empty, never goes backwards, and ends at exactly 1.
    @Test(arguments: GradientComputeBackend.allCases)
    func progressReachesOne(backend: GradientComputeBackend) throws {
        guard supports(backend) else { return }

        let recording = makeRecording(volumes: 20, period: 100)
        var reported: [Double] = []
        _ = try GradientTemplateCorrector.correct(
            channels: [recording.channel, recording.channel, recording.channel],
            volumeTriggers: recording.triggers,
            config: defaultConfig(backend),
            samplingRate: Self.samplingRate
        ) { reported.append($0) }
        #expect(!reported.isEmpty)
        #expect(reported.last == 1.0)
        #expect(reported == reported.sorted())
        #expect(reported.allSatisfy { $0 > 0 && $0 <= 1 })
    }
}
