//
//  EpochBadChannelDetectorTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation
import Testing
@testable import EVA

struct EpochBadChannelDetectorTests {

    private let thresholds = EpochBadChannelThresholds(
        minMicrovolts: -50, maxMicrovolts: 50,
        maxSlopeMicrovoltsPerSample: 20, maxAccelerationMicrovoltsPerSample: 15
    )

    @Test func flatCleanChannelIsNotBad() {
        let data: [[Float]] = [[Float](repeating: 1.0, count: 20)]
        let bad = EpochBadChannelDetector.detectBadChannels(in: data, range: 0..<20, thresholds: thresholds)
        #expect(bad.isEmpty)
    }

    @Test func amplitudeOutOfRangeFlagsChannel() {
        var channel = [Float](repeating: 1.0, count: 20)
        channel[10] = 80 // exceeds maxMicrovolts
        let data: [[Float]] = [channel]
        let bad = EpochBadChannelDetector.detectBadChannels(in: data, range: 0..<20, thresholds: thresholds)
        #expect(bad == [0])
    }

    @Test func sharpStepFlagsChannelViaSlope() {
        var channel = [Float](repeating: 0.0, count: 20)
        channel[10] = 30 // within min/max, but a 30µV single-sample step exceeds maxSlope
        let data: [[Float]] = [channel]
        let bad = EpochBadChannelDetector.detectBadChannels(in: data, range: 0..<20, thresholds: thresholds)
        #expect(bad == [0])
    }

    @Test func excludedChannelsAreNeverFlagged() {
        var channel = [Float](repeating: 1.0, count: 20)
        channel[10] = 80
        let data: [[Float]] = [channel]
        let bad = EpochBadChannelDetector.detectBadChannels(
            in: data, range: 0..<20, thresholds: thresholds, excluding: [0]
        )
        #expect(bad.isEmpty)
    }

    @Test func onlyEvaluatesWithinRange() {
        var channel = [Float](repeating: 1.0, count: 40)
        channel[35] = 80 // outside the evaluated range
        let data: [[Float]] = [channel]
        let bad = EpochBadChannelDetector.detectBadChannels(in: data, range: 0..<20, thresholds: thresholds)
        #expect(bad.isEmpty)
    }

    @Test func evidenceRetainsTheMetricsBehindTheDecision() {
        let channel: [Float] = [0, 2, 7, -4, 1]
        let evidence = EpochBadChannelDetector.evidence(in: channel, range: 0..<channel.count)
        #expect(evidence?.minimumMicrovolts == -4)
        #expect(evidence?.maximumMicrovolts == 7)
        #expect(evidence?.maximumSlopeMicrovoltsPerSample == 11)
        #expect(evidence?.maximumAccelerationMicrovoltsPerSample == 6)
    }

    @Test func interpolateReplacesOnlyTheFlaggedRange() {
        // Two good neighbors at antipodal-ish positions so the target's
        // interpolation weight is well-conditioned; values chosen so the
        // interpolated result is clearly different from the spike.
        // SphericalSpline.interpolationWeights requires >= 3 good channels.
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
        ]
        var target = [Float](repeating: 5.0, count: 10)
        target[5] = 999 // spike inside the epoch range
        var data: [[Float]] = [
            target,
            [Float](repeating: 2.0, count: 10),
            [Float](repeating: 3.0, count: 10),
            [Float](repeating: 4.0, count: 10),
        ]
        let untouchedBefore = data[0][0]

        EpochBadChannelDetector.interpolate(
            badChannels: [0], in: &data, range: 3..<8,
            positions: positions, excludingGloballyBad: []
        )

        // Outside the interpolated range, channel 0 is untouched.
        #expect(data[0][0] == untouchedBefore)
        #expect(data[0][9] == 5.0)
        // Inside the range, the spike is gone (replaced by a weighted blend of
        // the neighbors, nowhere near 999).
        #expect(data[0][5] < 100)
    }

    @Test func interpolateSkipsChannelsWithNoElectrodePosition() {
        var data: [[Float]] = [[Float](repeating: 999.0, count: 10)]
        EpochBadChannelDetector.interpolate(
            badChannels: [0], in: &data, range: 0..<10,
            positions: [:], excludingGloballyBad: []
        )
        #expect(data[0][0] == 999.0)
    }

    @Test func weightCacheMatchesUncachedResult() {
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
        ]
        let good = [1, 2, 3]
        let direct = SphericalSpline.interpolationWeights(target: 0, good: good, positions: positions)
        let cache = SphericalSplineWeightCache()
        let cached = cache.weights(target: 0, good: good, positions: positions)
        #expect(direct?.indices == cached?.indices)
        #expect(direct?.weights == cached?.weights)
    }

    @Test func weightCacheReturnsSameResultOnRepeatedLookup() {
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
        ]
        let cache = SphericalSplineWeightCache()
        let first = cache.weights(target: 0, good: [1, 2, 3], positions: positions)
        let second = cache.weights(target: 0, good: [1, 2, 3], positions: positions)
        #expect(first?.weights == second?.weights)
    }

    /// Shared-factorization batch solve (multiple targets, same good-set) must
    /// match solving each target independently — this is the correctness
    /// guarantee for the "factor once, solve many" optimization.
    @Test func batchWeightsMatchIndividualSolves() {
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
            4: SIMD3(0, -1, 0),
            5: SIMD3(0, 0, -1),
        ]
        let good = [0, 1, 2, 3]
        let targets = [4, 5]

        let batch = SphericalSpline.interpolationWeightsBatch(targets: targets, good: good, positions: positions)
        for target in targets {
            let individual = SphericalSpline.interpolationWeights(target: target, good: good, positions: positions)
            #expect(batch[target]?.indices == individual?.indices)
            let batchWeights = batch[target]?.weights ?? []
            let individualWeights = individual?.weights ?? []
            #expect(batchWeights.count == individualWeights.count)
            for (a, b) in zip(batchWeights, individualWeights) {
                #expect(abs(a - b) < 1e-9)
            }
        }
    }

    @Test func cacheBatchLookupMixesHitsAndMisses() {
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
            4: SIMD3(0, -1, 0),
            5: SIMD3(0, 0, -1),
        ]
        let good = [0, 1, 2, 3]
        let cache = SphericalSplineWeightCache()

        // Pre-warm the cache for target 4 only.
        _ = cache.weights(target: 4, good: good, positions: positions)

        // Batch lookup for [4 (cached), 5 (miss)] should still return both,
        // and the previously-cached entry should be unchanged.
        let warm = cache.weights(target: 4, good: good, positions: positions)
        let batch = cache.weights(targets: [4, 5], good: good, positions: positions)

        #expect(batch[4]?.weights == warm?.weights)
        #expect(batch[5] != nil)
    }

    @Test func interpolateWithCacheProducesSameResultAsWithout() {
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
        ]
        var target = [Float](repeating: 5.0, count: 10)
        target[5] = 999
        let baseData: [[Float]] = [
            target,
            [Float](repeating: 2.0, count: 10),
            [Float](repeating: 3.0, count: 10),
            [Float](repeating: 4.0, count: 10),
        ]

        var withoutCache = baseData
        EpochBadChannelDetector.interpolate(
            badChannels: [0], in: &withoutCache, range: 3..<8,
            positions: positions, excludingGloballyBad: []
        )

        var withCache = baseData
        let cache = SphericalSplineWeightCache()
        EpochBadChannelDetector.interpolate(
            badChannels: [0], in: &withCache, range: 3..<8,
            positions: positions, excludingGloballyBad: [], weightCache: cache
        )

        #expect(withoutCache[0] == withCache[0])
    }
}

struct PSABuildJobEpochRejectionTests {

    /// 4 channels x 1000 samples @ 100 Hz; channel 0 has a huge spike near
    /// t=2s (inside the first epoch), channels 1-3 are flat/clean. Two
    /// "stim" events at t=2s and t=5s, each with a 0.5s epoch (50 samples).
    private func makeJob(thresholds: EpochBadChannelThresholds) -> PSABuildJob {
        let samplingRate = 100.0
        let sampleCount = 1000
        var channel0 = [Float](repeating: 0, count: sampleCount)
        channel0[200] = 500 // spike inside the first epoch's window
        let data: [[Float]] = [
            channel0,
            [Float](repeating: 0, count: sampleCount),
            [Float](repeating: 0, count: sampleCount),
            [Float](repeating: 0, count: sampleCount),
        ]
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)

        let events = [
            MFFEvent(id: "e1", code: "stim", beginTimeSeconds: 2.0, rawBeginTime: "2.0", sourceFile: "test"),
            MFFEvent(id: "e2", code: "stim", beginTimeSeconds: 5.0, rawBeginTime: "5.0", sourceFile: "test"),
        ]
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
        ]

        return PSABuildJob(
            signal: signal,
            events: events,
            categoriesBySegmentValue: ["stim": ["stim"]],
            categoryRegexRules: [],
            timingMarkersBySegmentValue: [:],
            timingEventsBySegmentValue: [:],
            artifactEventsForRejection: [],
            artifactEventsForRejectionByLabel: [:],
            preSamples: 10,
            epochLength: 50,
            psaOffset: 0,
            sampleCount: sampleCount,
            colorIndices: ["stim": 0],
            skipIfContainsArtifact: false,
            artifactRejectionLabel: "",
            timingTolerance: 0.5,
            interpolatesBadChannelsPerEpoch: true,
            epochBadChannelThresholds: thresholds,
            electrodePositions: positions,
            globallyBadChannels: [],
            artifactRejectionWindow: nil
        )
    }

    @Test func spikedEpochIsInterpolatedWhenBelowRejectionThreshold() async {
        // 1 of 4 channels bad is well under a 50% rejection threshold.
        let thresholds = EpochBadChannelThresholds(
            minMicrovolts: -100, maxMicrovolts: 100,
            maxSlopeMicrovoltsPerSample: 50, maxAccelerationMicrovoltsPerSample: 50,
            maxBadChannelFraction: 0.5
        )
        let result = await makeJob(thresholds: thresholds).buildEpochs()
        #expect(result?.segments.count == 2) // both epochs kept
        #expect(result?.epochBadChannelCounts[0] == 1) // channel 0 flagged once
        #expect(result?.totalEpochsEvaluated == 2)
    }

    @Test func spikedEpochIsRejectedWhenAboveRejectionThreshold() async {
        // Same spike, but a 0% threshold means ANY bad channel rejects the epoch.
        let thresholds = EpochBadChannelThresholds(
            minMicrovolts: -100, maxMicrovolts: 100,
            maxSlopeMicrovoltsPerSample: 50, maxAccelerationMicrovoltsPerSample: 50,
            maxBadChannelFraction: 0
        )
        let result = await makeJob(thresholds: thresholds).buildEpochs()
        // Only the clean (t=5s) epoch survives; the spiked one is rejected.
        #expect(result?.segments.count == 1)
        #expect(result?.segments.first?.startSample == 0)
        #expect(result?.segments.first?.endSample == 49)
        #expect(result?.signal.data.first?.count == 50)
        #expect(result?.message.contains("rejected") == true)
        // Still counted toward the escalation tally even though rejected.
        #expect(result?.epochBadChannelCounts[0] == 1)
        #expect(result?.totalEpochsEvaluated == 2)
    }

    @Test func decisionMatrixModeDefersRejectionAndInterpolation() async {
        let thresholds = EpochBadChannelThresholds(
            minMicrovolts: -100, maxMicrovolts: 100,
            maxSlopeMicrovoltsPerSample: 50, maxAccelerationMicrovoltsPerSample: 50,
            maxBadChannelFraction: 0
        )
        var job = makeJob(thresholds: thresholds)
        job.defersBadChannelDecisions = true
        let result = await job.buildEpochs()
        #expect(result?.segments.count == 2)
        #expect(result?.rejectedForTooManyBadChannels == 0)
        #expect(result?.interpolatedChannelSegments.isEmpty == true)
        #expect(result?.epochBadChannelSegments[0] == [1])
        #expect(result?.suggestedRejectedEpochReasons[0]?.contains("Too many bad channels") == true)
        #expect(result?.signal.data[0].contains(500) == true)
    }

    @Test @MainActor func explicitMatrixDecisionsOverrideAutomaticThresholds() async {
        let thresholds = EpochBadChannelThresholds(
            minMicrovolts: -100, maxMicrovolts: 100,
            maxSlopeMicrovoltsPerSample: 50, maxAccelerationMicrovoltsPerSample: 50,
            maxBadChannelCount: 0, usesAbsoluteBadChannelCount: true
        )
        var job = makeJob(thresholds: thresholds)
        job.defersBadChannelDecisions = true
        guard let result = await job.buildEpochs() else {
            Issue.record("Expected deferred epoch build")
            return
        }
        let preparation = PSADecisionMatrixPreparation.make(
            signal: result.signal,
            segments: result.segments,
            thresholds: thresholds,
            detectorSegments: result.epochBadChannelSegments,
            recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions,
            globallyBadChannels: []
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        #expect(model.hasRecordingWideChannelHealth == false)
        #expect(model.channelHealthScopeLabel == "Fast Epoch-set Health")
        #expect(preparation.localFastGoodnessScores.count == result.segments.count)
        let spiked = PSADecisionCellID(channelIndex: 0, epochIndex: 0)
        #expect(model.resolvedCellDecision(spiked) == .interpolate)
        #expect(model.resolvedEpochDecision(0) == .reject)
        model.setCellDecision(.keep, for: spiked)
        model.setEpochDecision(.keep, epoch: 0)
        #expect(model.resolvedCellDecision(spiked) == .keep)
        #expect(model.resolvedEpochDecision(0) == .keep)
        model.setChannelDecision(.interpolate, channels: [1, 2])
        #expect(model.resolvedCellDecision(.init(channelIndex: 1, epochIndex: 1)) == .interpolate)
        #expect(model.resolvedCellDecision(.init(channelIndex: 2, epochIndex: 0)) == .interpolate)
        model.setEpochDecision(.reject, epoch: 1)
        #expect(model.categorySummaries.reduce(0) { $0 + $1.total } == result.segments.count)
        #expect(model.categorySummaries.reduce(0) { $0 + $1.kept } == model.keptEpochCount)
        let materialized = model.snapshot().materializedResult()
        #expect(materialized?.segments.count == 1)
        #expect(materialized?.signal.data[0].count == 50)
        #expect(materialized?.signal.data[0].contains(500) == true)
    }

    @Test @MainActor func fullChannelHealthReplacesFallbackPriorWithoutLosingDecisions() async {
        let thresholds = EpochBadChannelThresholds(
            minMicrovolts: -100, maxMicrovolts: 100,
            maxSlopeMicrovoltsPerSample: 50, maxAccelerationMicrovoltsPerSample: 50,
            maxBadChannelCount: 0, usesAbsoluteBadChannelCount: true
        )
        var job = makeJob(thresholds: thresholds)
        job.defersBadChannelDecisions = true
        guard let result = await job.buildEpochs() else {
            Issue.record("Expected deferred epoch build")
            return
        }
        var preparation = PSADecisionMatrixPreparation.make(
            signal: result.signal,
            segments: result.segments,
            thresholds: thresholds,
            detectorSegments: [:],
            recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions,
            globallyBadChannels: []
        )
        preparation.localFastGoodnessScores[0][0] = 20
        preparation.epochGoodnessScores[0] = 40
        preparation.epochSetChannelGoodnessScores[0] = 60
        let model = PSADecisionMatrixModel(preparation: preparation)
        let cell = PSADecisionCellID(channelIndex: 0, epochIndex: 0)
        model.setCellDecision(.keep, for: cell)

        #expect(model.integratedGoodness(channel: 0, epoch: 0) == 33)
        model.adoptRecordingChannelGoodness([0: 80, 1: 80, 2: 80, 3: 80], kind: .fastRecording)
        #expect(model.channelPriorKind == .fastRecording)
        #expect(model.channelHealthScopeLabel == "Fast Recording Health")
        #expect(model.integratedGoodness(channel: 0, epoch: 0) == 38)
        model.adoptRecordingChannelGoodness([0: 100, 1: 90, 2: 80, 3: 70])
        #expect(model.hasRecordingWideChannelHealth)
        #expect(model.channelHealthScopeLabel == "Overall Channel Health")
        #expect(model.integratedGoodness(channel: 0, epoch: 0) == 43)
        #expect(model.resolvedCellDecision(cell) == .keep)
    }

    @Test @MainActor func matrixStreamsProcessedEvidenceButMaterializesRawEpochs() async throws {
        var job = makeJob(thresholds: EpochBadChannelThresholds())
        job.defersBadChannelDecisions = true
        let result = try #require(await job.buildEpochs())
        var shiftedData = result.signal.data
        for channel in 1..<shiftedData.count {
            for sample in shiftedData[channel].indices {
                shiftedData[channel][sample] = 10 * sin(Float(sample) * 0.2)
            }
        }
        let sourceSignal = result.signal.replacingSamples(shiftedData)
        let preparation = PSADecisionMatrixPreparation.make(
            signal: sourceSignal,
            segments: result.segments,
            thresholds: job.epochBadChannelThresholds,
            detectorSegments: [:],
            recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions,
            globallyBadChannels: [],
            averageReference: true,
            baselineCorrect: false
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        for epoch in result.segments.indices {
            model.setEpochDecision(.keep, epoch: epoch)
            for channel in result.signal.data.indices {
                model.setCellDecision(.keep, for: .init(channelIndex: channel, epochIndex: epoch))
            }
        }

        #expect(preparation.sourceSignal.data == sourceSignal.data)
        let first = result.segments[0]
        let rawWaveform = Array(sourceSignal.data[0][first.startSample...first.endSample])
        #expect(preparation.reviewedWaveform(channel: 0, epoch: 0) != rawWaveform)
        #expect(preparation.rawEvidence.count == result.segments.count)
        let materialized = try #require(model.snapshot().materializedResult())
        #expect(materialized.signal.data == sourceSignal.data)
    }

    @Test func spikedEpochIsInterpolatedWhenBelowAbsoluteCountThreshold() async {
        // Same spike (1 of 4 channels bad), but expressed as a fixed count
        // rather than a fraction — 2 tolerated bad channels is still under.
        let thresholds = EpochBadChannelThresholds(
            minMicrovolts: -100, maxMicrovolts: 100,
            maxSlopeMicrovoltsPerSample: 50, maxAccelerationMicrovoltsPerSample: 50,
            maxBadChannelCount: 2, usesAbsoluteBadChannelCount: true
        )
        let result = await makeJob(thresholds: thresholds).buildEpochs()
        #expect(result?.segments.count == 2) // both epochs kept
        #expect(result?.epochBadChannelCounts[0] == 1)
        #expect(result?.totalEpochsEvaluated == 2)
    }

    @Test func spikedEpochIsRejectedWhenAboveAbsoluteCountThreshold() async {
        // Same spike, but a 0-channel absolute threshold rejects on any bad channel.
        let thresholds = EpochBadChannelThresholds(
            minMicrovolts: -100, maxMicrovolts: 100,
            maxSlopeMicrovoltsPerSample: 50, maxAccelerationMicrovoltsPerSample: 50,
            maxBadChannelCount: 0, usesAbsoluteBadChannelCount: true
        )
        let result = await makeJob(thresholds: thresholds).buildEpochs()
        #expect(result?.segments.count == 1)
        #expect(result?.segments.first?.startSample == 0)
        #expect(result?.segments.first?.endSample == 49)
        #expect(result?.signal.data.first?.count == 50)
        #expect(result?.message.contains("rejected") == true)
        #expect(result?.epochBadChannelCounts[0] == 1)
        #expect(result?.totalEpochsEvaluated == 2)
    }
}

/// Time-boxed artifact rejection: `PSABuildJob.artifactRejectionWindow`
/// restricts which part of the epoch an artifact has to fall in to reject it.
struct PSABuildJobArtifactWindowTests {

    /// Two −100…800 ms epochs: one around a stimulus at t = 2 s with an artifact
    /// 750 ms after it (the case that motivated the option), and a clean one at
    /// t = 6 s. The clean trial keeps the result non-nil — `buildEpochs` returns
    /// nil outright when nothing survives, which would hide the skip counts.
    private func makeJob(window: ClosedRange<Double>?) -> PSABuildJob {
        let samplingRate = 1000.0
        let sampleCount = 10_000
        let signal = SyntheticSignal.make(
            [[Float]](repeating: [Float](repeating: 0, count: sampleCount), count: 2),
            samplingRate: samplingRate
        )
        let stimulus = MFFEvent(
            id: "e1", code: "stim", beginTimeSeconds: 2.0, rawBeginTime: "2.0", sourceFile: "test")
        let cleanStimulus = MFFEvent(
            id: "e2", code: "stim", beginTimeSeconds: 6.0, rawBeginTime: "6.0", sourceFile: "test")
        let lateBlink = MFFEvent(
            id: "a1", code: "Eye Blink", beginTimeSeconds: 2.75, rawBeginTime: "2.75", sourceFile: "test")

        return PSABuildJob(
            signal: signal,
            events: [stimulus, cleanStimulus],
            categoriesBySegmentValue: ["stim": ["stim"]],
            categoryRegexRules: [],
            timingMarkersBySegmentValue: [:],
            timingEventsBySegmentValue: [:],
            artifactEventsForRejection: [lateBlink],
            artifactEventsForRejectionByLabel: ["Eye Blink": [lateBlink]],
            preSamples: 100,                       // −100 ms
            epochLength: 900,                      // −100…800 ms
            psaOffset: 0,
            sampleCount: sampleCount,
            colorIndices: ["stim": 0],
            skipIfContainsArtifact: true,
            artifactRejectionLabel: "artifacts",
            timingTolerance: 0.5,
            interpolatesBadChannelsPerEpoch: false,
            epochBadChannelThresholds: EpochBadChannelThresholds(),
            electrodePositions: [:],
            globallyBadChannels: [],
            artifactRejectionWindow: window
        )
    }

    /// Baseline: with no window the blink at 750 ms is inside the epoch, so the
    /// trial is lost — the behaviour the option exists to change.
    @Test func artifactAnywhereInTheEpochRejectsWithoutAWindow() async {
        let result = await makeJob(window: nil).buildEpochs()
        #expect(result?.segments.count == 1)   // only the clean trial survives
        #expect(result?.exclusionSummary.skippedArtifacts == 1)
        #expect(result?.exclusionSummary.skippedArtifactBreakdown["Eye Blink"] == 1)
    }

    @Test func decisionMatrixKeepsArtifactEpochVisibleButPremarkedRejected() async {
        var job = makeJob(window: nil)
        job.defersBadChannelDecisions = true
        let result = await job.buildEpochs()
        #expect(result?.segments.count == 2)
        #expect(result?.exclusionSummary.skippedArtifacts == 0)
        #expect(result?.suggestedRejectedEpochReasons[0]?.contains("Eye Blink") == true)
    }

    /// Time-boxed to −100…500 ms, the same blink is outside the window and the
    /// trial survives.
    @Test func artifactOutsideTheWindowKeepsTheEpoch() async {
        let result = await makeJob(window: -0.1...0.5).buildEpochs()
        #expect(result?.segments.count == 2)   // both trials kept
        #expect(result?.exclusionSummary.skippedArtifacts == 0)
        #expect(result?.exclusionSummary.skippedArtifactBreakdown.isEmpty == true)
    }

    /// A window that does contain the blink still rejects, so the option narrows
    /// rejection rather than disabling it.
    @Test func artifactInsideTheWindowStillRejects() async {
        let result = await makeJob(window: 0.7...0.8).buildEpochs()
        #expect(result?.segments.count == 1)
        #expect(result?.exclusionSummary.skippedArtifacts == 1)
    }

    /// The window is relative to the anchor, so its bounds are inclusive at the
    /// artifact's exact offset.
    @Test func windowBoundsAreInclusive() async {
        #expect(await makeJob(window: 0.75...0.75).buildEpochs()?.exclusionSummary.skippedArtifacts == 1)
        #expect(await makeJob(window: 0.0...0.749).buildEpochs()?.exclusionSummary.skippedArtifacts == 0)
    }

    /// A window wider than the epoch is intersected with it, so it behaves
    /// exactly like no window at all.
    @Test func windowWiderThanTheEpochBehavesLikeNoWindow() async {
        let result = await makeJob(window: -5.0...5.0).buildEpochs()
        #expect(result?.segments.count == 1)
        #expect(result?.exclusionSummary.skippedArtifacts == 1)
    }
}
