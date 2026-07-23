//
//  ProcessingCoreTests.swift
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
//  Coverage for the headless apply-core (TODO.md Priority 1 / REFACTOR.md item
//  E): applying a script's auto steps with no view must produce the same
//  output as the interactive VM path, and must stop (not skip) at the first
//  step it doesn't yet support so chain order is never violated.
//

import Testing
import Foundation
@testable import EVA

struct ProcessingCoreTests {

    @MainActor
    private func makeCore() -> ProcessingCore {
        let store = RecordingStore()
        return ProcessingCore(
            store: store,
            filter: FilterViewModel(store: store),
            gradient: GradientViewModel(store: store),
            ica: ICAViewModel(store: store),
            artifactVM: ArtifactViewModel(store: store),
            epoching: EpochingViewModel(store: store),
            wavelet: WaveletReductionViewModel(store: store)
        )
    }

    @MainActor
    @Test func filterOnlyScriptAppliesHeadlessly() async throws {
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: [
            "highPassHz": "1.0", "lowPassHz": "40.0"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        let output = try #require(result.signal)
        #expect(output.data.count == signal.data.count)
        #expect(output.data.first?.count == signal.data.first?.count)
        // Filtering must actually change the samples, not pass the input through.
        #expect(output.data[0] != signal.data[0])
    }

    @MainActor
    @Test func thresholdDetectionStepConfiguresArtifactVMWithNoSignalChange() async throws {
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .thresholdArtifactDetection, parameters: [
            "blink.amplitudeMinMicrovolts": "60"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        #expect(core.artifactVM.detectionMethod == .threshold)
        #expect(core.artifactVM.blinkThresholdConfig.amplitudeMinMicrovolts == 60)
        // No transform step ran, so the signal passes through unchanged.
        #expect(result.signal?.data[0] == signal.data[0])
    }

    @MainActor
    @Test func stopsAtFirstUnsupportedStepPreservingOrder() async throws {
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .bcgDetection, parameters: [:]))
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))

        let result = await core.applyAutoSteps(script, to: signal)

        // Must stop BEFORE filter, even though filter alone is supported, because
        // running it out of order (skipping the unsupported BCG step ahead of
        // it) would silently produce a wrong pipeline.
        #expect(result.remainingSteps.count == 2)
        #expect(result.remainingSteps.first?.operation == .bcgDetection)
        #expect(result.signal?.data[0] == signal.data[0]) // untouched
    }

    @MainActor
    @Test func waveletStepAppliesHeadlessly() async throws {
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .waveletReduce, parameters: [
            "mode": "Continuous EEG"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        #expect(core.wavelet.reducedSignal != nil)
        #expect(!core.wavelet.isRunning)
        let output = try #require(result.signal)
        #expect(output.data.count == signal.data.count)
    }

    @MainActor
    @Test func filterThenWaveletChainHeadlessly() async throws {
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))
        script.append(EVAProcessingStep(operation: .waveletReduce, parameters: [
            "mode": "Continuous EEG"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        // Wavelet must have run on the filtered signal, not the raw one.
        let filterOnly = try #require(core.filter.output)
        let final = try #require(result.signal)
        #expect(final.data[0] != filterOnly.data[0])
    }

    /// A channel = slow physiological signal + a large gradient artifact
    /// repeating every TR, with synthetic TR-marker events — mirrors
    /// `GradientRemoverTests.removesPeriodicGradientArtifact`'s construction.
    private func periodicGradientSignal(spacing: Int = 100, nTR: Int = 20) -> MFFSignalData {
        let sampleCount = spacing * nTR
        func gradient(_ k: Int) -> Float { 50 * Float(sin(Double(k) * 0.3)) + 30 * Float(k % 7) }
        func physio(_ t: Int) -> Float { 5 * Float(sin(2 * .pi * 3 * Double(t) / 1000)) }
        let samplingRate = 1000.0

        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount {
            channel[t] = physio(t) + gradient(t % spacing)
        }
        let triggers = stride(from: 0, to: sampleCount, by: spacing)
        let events = triggers.enumerated().map { i, sample in
            MFFEvent(id: "tr\(i)", code: "TR", beginTimeSeconds: Double(sample) / samplingRate,
                     rawBeginTime: "\(sample)", sourceFile: "test")
        }
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/synthetic.bin"),
            signalType: "EEG",
            numberOfChannels: 1,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: events,
            data: [channel]
        )
    }

    @MainActor
    @Test func gradientCorrectionRemovesPeriodicArtifactHeadlessly() async throws {
        let signal = periodicGradientSignal()
        let core = makeCore()
        core.gradient.trMarkerCode = "TR"

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .mriGradientCorrection,
                                         parameters: ["method": "AAS", "trMarkerCode": "TR"]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        let output = try #require(result.signal)
        #expect(core.gradient.correctedSignal != nil)
        #expect(!core.gradient.isProcessing)
        #expect(core.gradient.statusIsError == false)

        // The residual gradient energy in the interior should be much smaller
        // than the original, matching GradientRemoverTests' own threshold.
        let spacing = 100
        let lo = spacing * 5, hi = spacing * 15
        let originalEnergy = (lo..<hi).reduce(0.0) { $0 + Double(signal.data[0][$1] * signal.data[0][$1]) }
        let residualEnergy = (lo..<hi).reduce(0.0) { $0 + Double(output.data[0][$1] * output.data[0][$1]) }
        #expect(residualEnergy < originalEnergy * 0.2, "gradient not substantially removed")
    }

    @MainActor
    @Test func gradientThenFilterChainHeadlessly() async throws {
        let signal = periodicGradientSignal()
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .mriGradientCorrection,
                                         parameters: ["method": "AAS", "trMarkerCode": "TR"]))
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        // Filter's output must have been computed on the gradient-corrected
        // signal, not the raw one — the two differ substantially.
        let gradientOnly = try #require(core.gradient.correctedSignal)
        let final = try #require(result.signal)
        #expect(final.data[0] != gradientOnly.data[0])
    }

    /// One channel of noise with a repeating "stim" event every `spacing`
    /// samples, each followed by a distinctive bump — enough events/samples
    /// for a PSA epoch window (`preSamples` before, `epochLength` after) to
    /// fit comfortably between triggers.
    private func stimSignal(spacing: Int = 1000, nEvents: Int = 8, samplingRate: Double = 500) -> MFFSignalData {
        let sampleCount = spacing * (nEvents + 1)
        var state: UInt64 = 12345
        func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1
            return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
        }
        var channel = [Float](repeating: 0, count: sampleCount)
        for i in channel.indices { channel[i] = noise() }
        let triggers = (1...nEvents).map { $0 * spacing }
        for trigger in triggers {
            for k in 0..<40 where trigger + k < sampleCount {
                channel[trigger + k] += 50 * Float(sin(Double(k) * 0.3))
            }
        }
        let events = triggers.enumerated().map { i, sample in
            MFFEvent(id: "stim\(i)", code: "stim", beginTimeSeconds: Double(sample) / samplingRate,
                     rawBeginTime: "\(sample)", sourceFile: "test")
        }
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/synthetic.bin"),
            signalType: "EEG",
            numberOfChannels: 1,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: events,
            data: [channel]
        )
    }

    /// `stimSignal` widened to `channelCount` channels: channel 0 keeps the
    /// bump (whose trailing >25 µV/sample edge trips the per-epoch bad-channel
    /// detector), the rest are flat/quiet — so exactly one channel flags per
    /// epoch.
    private func stimSignalMultiChannel(channelCount: Int = 4, spacing: Int = 1000, nEvents: Int = 8, samplingRate: Double = 500) -> MFFSignalData {
        let base = stimSignal(spacing: spacing, nEvents: nEvents, samplingRate: samplingRate)
        let sampleCount = spacing * (nEvents + 1)
        var data = base.data // [channel 0 with the bump]
        for _ in 1..<channelCount {
            data.append([Float](repeating: 0, count: sampleCount))
        }
        return MFFSignalData(
            signalURL: base.signalURL,
            signalType: "EEG",
            numberOfChannels: channelCount,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: base.events,
            data: data
        )
    }

    @MainActor
    @Test func segmentStepBuildsEpochsWithoutAveraging() async throws {
        let signal = stimSignal()
        let core = makeCore()

        var script = EVAProcessingScript()
        // Flag off: this test verifies pure segmentation, not per-epoch
        // bad-channel rejection (which a 1-channel synthetic signal can't
        // meaningfully exercise). Pinned so a future default/threshold change
        // can't silently invalidate it again.
        script.append(EVAProcessingStep(operation: .segment, parameters: [
            "eventCodes": "stim", "preStimulusMs": "40", "postStimulusMs": "120",
            "average": "false", "interpolateBadChannelsPerEpoch": "false"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        #expect(core.epoching.isAveraged == false)
        #expect(core.epoching.epochSegments.count == 8) // one per stim event
        #expect(result.signal != nil)
    }

    @MainActor
    @Test func lowChannelCountSegmentSurvivesPerEpochBadChannelFloor() async throws {
        // Regression guard for the `max(1, …)` floor in PSABuildJob.buildEpochs.
        // With per-epoch interpolation ON (the default) and a 4-channel net,
        // `maxBadChannelFraction * 4 = 0.4` rounds to 0. Before the floor, any
        // epoch containing even one flagged channel — here channel 0's abrupt
        // bump edge, one flag per epoch — was rejected, so *every* epoch was
        // dropped and headless segmentation silently produced nothing. The floor
        // keeps single-flag epochs. Note: the flag is left at its `true` default
        // here on purpose (unlike the segmentation tests above, which pin it off).
        let signal = stimSignalMultiChannel()
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .segment, parameters: [
            "eventCodes": "stim", "preStimulusMs": "40", "postStimulusMs": "120", "average": "false"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        #expect(core.epoching.epochSegments.count == 8) // all epochs survive the single flag
        #expect(result.signal != nil)
    }

    @MainActor
    @Test func segmentStepWithAveragingProducesOneEpochPerCategory() async throws {
        let signal = stimSignal()
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .segment, parameters: [
            "eventCodes": "stim", "preStimulusMs": "40", "postStimulusMs": "120",
            "average": "true", "interpolateBadChannelsPerEpoch": "false"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        #expect(core.epoching.isAveraged == true)
        #expect(core.epoching.epochSegments.count == 1) // one category ("stim") averaged
        #expect(result.signal != nil)
    }

    @MainActor
    @Test func filterThenSegmentChainHeadlessly() async throws {
        let signal = stimSignal()
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))
        script.append(EVAProcessingStep(operation: .segment, parameters: [
            "eventCodes": "stim", "preStimulusMs": "40", "postStimulusMs": "120",
            "average": "true", "interpolateBadChannelsPerEpoch": "false"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.isEmpty)
        #expect(core.epoching.isAveraged == true)
        #expect(result.signal != nil)
        // The filter step must have actually run first (its output is the
        // segmentation source) — confirm the pre-segment filtered signal exists.
        #expect(core.filter.output != nil)
    }

    @MainActor
    @Test func segmentStepWithNoMatchingEventsStopsWithoutCrashing() async throws {
        let signal = stimSignal()
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .segment, parameters: [
            "eventCodes": "nonexistent", "preStimulusMs": "40", "postStimulusMs": "120"
        ]))

        let result = await core.applyAutoSteps(script, to: signal)

        // Job construction fails validation (no matching events) — the step
        // is reported back as unhandled rather than silently dropped.
        #expect(result.remainingSteps.count == 1)
        #expect(result.remainingSteps.first?.operation == .segment)
    }

    @MainActor
    @Test func stopsAtDecisionStep() async throws {
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))
        script.append(EVAProcessingStep(operation: .icaClean, parameters: [:]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.count == 1)
        #expect(result.remainingSteps.first?.operation == .icaClean)
        // The leading filter step still applied.
        #expect(result.signal?.data[0] != signal.data[0])
    }

    /// The compatibility pre-flight safety net: a gradient step recorded with
    /// a TR-marker code the target file doesn't have must stop the run (not
    /// silently continue as if the correction had no-op'd).
    @MainActor
    @Test func stopsAtIncompatibleStepInsteadOfSilentlyNoOpping() async throws {
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let core = makeCore()

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .mriGradientCorrection,
                                         parameters: ["method": "AAS", "trMarkerCode": "NOT_A_REAL_CODE"]))
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.count == 2)
        #expect(result.remainingSteps.first?.operation == .mriGradientCorrection)
        #expect(!core.gradient.isProcessing)
        #expect(core.gradient.correctedSignal == nil) // never ran
        #expect(result.signal?.data[0] == signal.data[0]) // untouched, not silently passed through
    }
}
