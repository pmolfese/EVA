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

import CoreGraphics
import Foundation
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

    @MainActor
    private func makeInterpolationLimitReview() -> PSADecisionMatrixModel {
        let channelCount = 12
        let signal = SyntheticSignal.make(Array(repeating: Array(repeating: Float(1), count: 100), count: channelCount),
                                          samplingRate: 100)
        let segments = (0..<2).map { epoch in
            EpochSegment(startSample: epoch * 50, endSample: epoch * 50 + 49,
                         stimulusOffsetSamples: 10, category: "stim", sourceCode: "stim",
                         sourceTimeSeconds: Double(epoch), colorIndex: 0, contributingEpochCount: 1)
        }
        let positions = Dictionary(uniqueKeysWithValues: (0..<channelCount).map { channel in
            let angle = Double(channel) * 2 * Double.pi / Double(channelCount)
            return (channel, SIMD3<Double>(cos(angle), sin(angle), 0))
        })
        let thresholds = EpochBadChannelThresholds(maxBadChannelCount: 2, usesAbsoluteBadChannelCount: true)
        let preparation = PSADecisionMatrixPreparation.make(
            signal: signal, segments: segments, thresholds: thresholds,
            detectorSegments: [:], recordingChannelGoodness: [:], electrodePositions: positions,
            globallyBadChannels: [], segmentHealthGoodnessScores: [80, 100],
            suggestedRejectedEpochReasons: [0: ["Too many bad channels"], 1: ["Eye Blink"]]
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        model.setChannelDecision(.keep, channels: Set(0..<channelCount))
        for channel in [0, 4, 8] {
            model.setCellDecision(.interpolate, for: .init(channelIndex: channel, epochIndex: 0))
        }
        return model
    }

    @MainActor
    private func makeWaveformWithCachedReview() -> (WaveformView, PSADecisionMatrixModel) {
        let view = WaveformView(recording: MFFRecording(packageURL: URL(fileURLWithPath: "/tmp/psa-reopen-test.mff")),
                                userMarkers: [])
        let model = makeInterpolationLimitReview()
        view.epoching.averageReference = false
        view.epoching.baselineCorrected = false
        view.epoching.epochBadChannelThresholds = model.preparation.thresholds
        view.epoching.segmentedEpochSignal = model.preparation.signal
        view.epoching.segmentedEpochSegments = model.preparation.segments
        view.epoching.epochedSignal = model.preparation.signal
        view.epoching.epochSegments = model.preparation.segments
        view.epoching.decisionMatrix = model
        view.epoching.showsDecisionMatrix = true
        model.psaRejectionSettings = view.epoching.decisionMatrixRejectionSettings
        return (view, model)
    }

    @Test @MainActor func configureCancelShowReusesTheSameMatrixWithoutHealthWork() {
        let (view, model) = makeWaveformWithCachedReview()
        let cell = PSADecisionCellID(channelIndex: 4, epochIndex: 0)
        model.selectCell(cell)
        model.channelOrder = .goodness
        model.epochOrder = .goodness
        model.interpolationChannelLimit = 5
        model.setEpochDecision(.keep, epoch: 1)
        let reasons = model.suggestedRejectedEpochReasons

        view.openPSASheet(for: model.preparation.signal)
        #expect(view.epoching.showsSheet)
        #expect(!view.epoching.showsDecisionMatrix)
        #expect(!view.epoching.decisionMatrixNeedsRefresh)
        view.epoching.showsSheet = false // PSA Cancel dismisses configuration.
        view.averageCurrentEpochs() // Processing → Show Decision Matrix.

        #expect(view.epoching.decisionMatrix === model)
        #expect(view.epoching.showsDecisionMatrix)
        #expect(!view.epoching.showsSheet)
        #expect(!view.epoching.isApplying)
        #expect(!view.epoching.isAnalyzingDecisionMatrixChannelPrior)
        #expect(view.epoching.segmentingProgress == nil)
        #expect(view.epoching.phaseMessage == nil)
        #expect(model.selectedCell == cell)
        #expect(model.channelOrder == .goodness && model.epochOrder == .goodness)
        #expect(model.interpolationChannelLimit == 5)
        #expect(model.epochOverrides[1] == .keep)
        #expect(model.suggestedRejectedEpochReasons == reasons)
    }

    @Test @MainActor func openingConfigureDoesNotClearRealEvidenceInvalidation() {
        let (view, model) = makeWaveformWithCachedReview()
        view.epoching.decisionMatrixNeedsRefresh = true
        view.openPSASheet(for: model.preparation.signal)
        #expect(view.epoching.decisionMatrixNeedsRefresh)
        view.epoching.baselineCorrected = true
        #expect(!model.preparation.matchesCurrentReviewInputs(
            signal: model.preparation.signal, segments: model.preparation.segments,
            averageReference: false, baselineCorrect: true,
            globallyBadChannels: [], thresholds: model.preparation.thresholds
        ))
    }

    @Test @MainActor func changingOnlyArtifactWindowRefreshesRulesWithoutRebuildingHealth() {
        let (view, model) = makeWaveformWithCachedReview()
        model.setChannelDecision(.keep, channels: Set(0..<12))
        model.setEpochDecision(.keep, epoch: 1)
        let event = MFFEvent(id: "late-blink", code: "blink", beginTimeSeconds: 0.3,
                             rawBeginTime: "0.3", sourceFile: "test")
        let artifact = DefinedArtifact(type: .ocular, name: "Late blink", eventCode: "blink",
                                       events: [event], selectedChannelIndices: [0], windowSizeSeconds: 0.1,
                                       average: nil, topography: nil, cleaningMethod: .doNothing)
        view.template.definedArtifacts = [artifact]
        view.epoching.skippedDefinedArtifactIDs = [artifact.id]
        view.refreshDecisionMatrixRejectionContext(model, segments: model.preparation.segments,
                                                  sourceSignal: model.preparation.signal)
        #expect(model.rejectionReasons(for: 0) == ["Late blink"])
        #expect(model.resolvedEpochDecision(0) == .reject)

        view.epoching.limitsArtifactRejectionWindow = true
        view.epoching.artifactRejectionWindowStart = -0.1
        view.epoching.artifactRejectionWindowEnd = 0.1
        view.averageCurrentEpochs()
        #expect(view.epoching.decisionMatrix === model)
        #expect(model.resolvedEpochDecision(0) == .keep)
        #expect(model.rejectionReasons(for: 0).isEmpty)
        #expect(model.epochGoodness(0) == 80)
        #expect(model.epochOverrides[1] == .keep)
        #expect(!view.epoching.isApplying && view.epoching.phaseMessage == nil)
    }

    @Test @MainActor func interpolationLimitUpdatesReviewAndMaterializationWithoutRescanning() throws {
        let model = makeInterpolationLimitReview()
        #expect(model.interpolationChannelLimit == 2)
        #expect(model.badChannelCount(epoch: 0) == 3)
        #expect(model.resolvedEpochDecision(0) == .reject) // Warm caches before moving the slider.
        #expect(model.interpolationFeasibilityReason(epoch: 0)?.contains("limit is 2") == true)
        #expect(model.rejectionReasons(for: 0).contains("Too many bad channels"))

        model.interpolationChannelLimit = 3
        #expect(model.interpolationFeasibilityReason(epoch: 0) == nil)
        #expect(model.resolvedEpochDecision(0) == .keep)
        #expect(model.rejectionReasons(for: 0).isEmpty)
        #expect(model.resolvedEpochDecision(1) == .reject) // Blink rule is independent.
        let snapshot = model.snapshot()
        #expect(snapshot.interpolationChannelLimit == 3)
        let result = try #require(snapshot.materializedResult())
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.sourceTimeSeconds == 0)
        #expect(model.preparation.thresholds.maxBadChannelCount == 2)

        model.epochRejectionHealthThreshold = 90
        #expect(model.resolvedEpochDecision(0) == .reject) // Health rule is independent too.
        #expect(model.rejectionReasons(for: 0) == ["Segment Health"])
        #expect(model.snapshot().materializedResult() == nil)
        model.epochRejectionHealthThreshold = 0
        model.interpolationChannelLimit = 2
        #expect(model.resolvedEpochDecision(0) == .reject)
        #expect(model.snapshot().materializedResult() == nil)

        let restored = PSADecisionMatrixModel(preparation: model.preparation)
        restored.restoreManualDecisions(from: model)
        #expect(restored.interpolationChannelLimit == 2)
        model.interpolationChannelLimit = 5
        restored.restoreManualDecisions(from: model)
        #expect(restored.interpolationChannelLimit == 5)
    }

    @Test @MainActor func countLimitDoesNotBypassGeometrySafety() {
        let model = makeInterpolationLimitReview()
        model.setChannelDecision(.interpolate, channels: [0, 1, 2, 3])
        model.interpolationChannelLimit = 12
        #expect(model.interpolationFeasibilityReason(epoch: 0)?.contains("contiguous cluster") == true)
        #expect(model.resolvedEpochDecision(0) == .reject)
        model.setChannelDecision(.interpolate, channels: Set(0..<12))
        #expect(model.interpolationFeasibilityReason(epoch: 0)?.contains("Too few positioned donor") == true)
        #expect(model.resolvedEpochDecision(0) == .reject)
    }

    @Test @MainActor func healthHoversExplainScoresDecisionsAndScopeWithoutSelecting() {
        let model = makeInterpolationLimitReview()
        let epoch = model.healthHoverSummary(for: .epoch(0))
        #expect(epoch.contains("Segment Health: 80%"))
        #expect(epoch.contains("Excluded from average"))
        #expect(epoch.contains("limit 2"))
        #expect(model.healthHoverSummary(for: .channel(0)).contains("not whole-recording Channel Health"))
        model.adoptRecordingChannelGoodness(Dictionary(uniqueKeysWithValues: (0..<12).map { ($0, 95) }))
        #expect(model.healthHoverSummary(for: .channel(0)).contains("Overall Channel Health: 95%"))
        model.interpolationChannelLimit = 3
        #expect(model.healthHoverSummary(for: .epoch(0)).contains("Kept for average"))
        #expect(model.healthHoverSummary(for: nil).isEmpty)
        #expect(model.selectedCell == nil)
        #expect(model.selectedEpochs.isEmpty && model.selectedChannels.isEmpty)
    }

    @Test func healthHoverHitTestingFollowsSortingAndPinnedScrollOffsets() {
        let overview = PSAMatrixHealthHoverLayout(
            channels: [5, 2], epochs: [8, 3], gridOrigin: CGPoint(x: 74, y: 42),
            cellSize: CGSize(width: 50, height: 20),
            channelHealthBounds: CGRect(x: 61, y: 42, width: 11, height: 40),
            epochHealthBounds: CGRect(x: 74, y: 29, width: 100, height: 11)
        )
        #expect(overview.target(at: CGPoint(x: 64, y: 65)) == .channel(2))
        #expect(overview.target(at: CGPoint(x: 140, y: 32)) == .epoch(3))
        #expect(overview.target(at: CGPoint(x: 140, y: 65)) == nil) // Body is click-only.
        let detail = PSAMatrixHealthHoverLayout(
            channels: [5, 2, 7, 1], epochs: [8, 3, 9, 6], gridOrigin: CGPoint(x: 164, y: 76),
            cellSize: CGSize(width: 28, height: 24),
            channelHealthBounds: CGRect(x: 160, y: 124, width: 42, height: 200),
            epochHealthBounds: CGRect(x: 220, y: 78, width: 200, height: 18)
        )
        #expect(detail.target(at: CGPoint(x: 175, y: 130)) == .channel(7))
        #expect(detail.target(at: CGPoint(x: 230, y: 85)) == .epoch(9))
        #expect(detail.target(at: CGPoint(x: 175, y: 85)) == nil) // Pinned corner.
    }

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

    @Test @MainActor func floatingReviewCanRescueExcludedTrialsWithoutMutatingSource() async throws {
        let thresholds = EpochBadChannelThresholds()
        var job = makeJob(thresholds: thresholds)
        job.defersBadChannelDecisions = true
        let built = try #require(await job.buildEpochs())
        let originalData = built.signal.data
        let preparation = PSADecisionMatrixPreparation.make(
            signal: built.signal, segments: built.segments, thresholds: thresholds,
            detectorSegments: [:], recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions, globallyBadChannels: [],
            segmentHealthGoodnessScores: [100, 100]
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        model.setChannelDecision(.keep, channels: Set(0..<built.signal.numberOfChannels))
        model.setEpochDecision(.keep, epoch: 0)
        model.setEpochDecision(.reject, epoch: 1)
        let excluded = try #require(model.snapshot().materializedResult())
        #expect(excluded.segments.count == 1)
        #expect(model.preparation.segments.count == 2)
        #expect(model.preparation.sourceSignal.data == originalData)

        model.setEpochDecision(.keep, epoch: 1)
        let rescued = try #require(model.snapshot().materializedResult())
        #expect(rescued.segments.count == 2)
        #expect(rescued.signal.data == originalData)
        #expect(model.preparation.sourceSignal.data == originalData)
        let averaged = try #require(rescued.average(colorIndices: [:]))
        #expect(averaged.segments.reduce(0) { $0 + $1.contributingEpochCount } == 2)
    }

    @Test @MainActor func waveformEditsOverrideEarlierMatrixChoicesAndStayLocal() async throws {
        let thresholds = EpochBadChannelThresholds()
        var job = makeJob(thresholds: thresholds)
        job.defersBadChannelDecisions = true
        let built = try #require(await job.buildEpochs())
        let preparation = PSADecisionMatrixPreparation.make(
            signal: built.signal, segments: built.segments, thresholds: thresholds,
            detectorSegments: [:], recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions, globallyBadChannels: [],
            segmentHealthGoodnessScores: [100, 100]
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        model.setChannelDecision(.keep, channels: Set(0..<built.signal.numberOfChannels))
        model.setEpochDecision(.keep, epoch: 0)
        model.setEpochDecision(.keep, epoch: 1)
        #expect(model.keptEpochCount == 2) // Warm the shared decision cache.

        model.applyWaveformQualityLabel(.bad, epoch: 0)
        #expect(model.resolvedEpochDecision(0) == .reject)
        #expect(model.keptEpochCount == 1)
        #expect(model.categorySummaries.reduce(0) { $0 + $1.kept } == 1)
        model.setEpochDecision(.keep, epoch: 0) // A later matrix edit wins.
        #expect(model.resolvedEpochDecision(0) == .keep)
        model.applyWaveformQualityLabel(.bad, epoch: 0) // So does a later waveform edit.
        #expect(model.resolvedEpochDecision(0) == .reject)
        model.applyWaveformQualityLabel(.good, epoch: 0)
        #expect(model.resolvedEpochDecision(0) == .keep)
        #expect(model.keptEpochCount == 2)
        model.applyWaveformQualityLabel(nil, epoch: 0)
        #expect(model.epochOverrides[0] == nil)
        #expect(!model.trustedEpochHealth.contains(0))

        let cell = PSADecisionCellID(channelIndex: 1, epochIndex: 1)
        model.setCellDecision(.interpolate, for: cell)
        #expect(model.resolvedCellDecision(cell) == .interpolate)
        #expect(model.resolvedCellDecision(.init(channelIndex: 1, epochIndex: 0)) == .keep)
        #expect(model.preparation.sourceSignal.data == built.signal.data)
        model.setCellDecision(.keep, for: cell)
        #expect(model.resolvedCellDecision(cell) == .keep)
        model.setCellDecision(.automatic, for: .init(channelIndex: 0, epochIndex: 0))
        model.recordingInterpolatedChannels = [0, 2]
        #expect(model.resolvedCellDecision(.init(channelIndex: 0, epochIndex: 0)) == .keep)
        #expect(model.isChannelInterpolatedAcrossAllEpochs(2))
        #expect(model.resolvedCellDecision(.init(channelIndex: 2, epochIndex: 1)) == .keep)
        // An already-applied recording repair is display provenance, not an
        // instruction to interpolate those samples a second time.
        let materialized = try #require(model.snapshot().materializedResult())
        #expect(materialized.signal.data[2] == built.signal.data[2])
    }

    @Test @MainActor func rebuildingFloatingReviewPreservesDecisionsByTrialIdentity() async throws {
        let thresholds = EpochBadChannelThresholds()
        var job = makeJob(thresholds: thresholds)
        job.defersBadChannelDecisions = true
        let built = try #require(await job.buildEpochs())
        let preparation = PSADecisionMatrixPreparation.make(
            signal: built.signal, segments: built.segments, thresholds: thresholds,
            detectorSegments: [:], recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions, globallyBadChannels: [],
            segmentHealthGoodnessScores: [100, 100]
        )
        let original = PSADecisionMatrixModel(preparation: preparation)
        original.channelOrder = .goodness
        original.epochOrder = .category
        original.setEpochDecision(.reject, epoch: 0)
        original.setCellDecision(.interpolate, for: .init(channelIndex: 1, epochIndex: 1))
        var reordered = preparation
        reordered.segments.swapAt(0, 1)
        let restored = PSADecisionMatrixModel(preparation: reordered)
        restored.restoreManualDecisions(from: original)
        #expect(restored.epochOverrides[1] == .reject)
        #expect(restored.epochOverrides[0] == nil)
        #expect(restored.cellOverrides[.init(channelIndex: 1, epochIndex: 0)] == .interpolate)
        #expect(restored.channelOrder == .goodness)
        #expect(restored.epochOrder == .category)
        #expect(!preparation.matchesCurrentReviewInputs(
            signal: built.signal, segments: reordered.segments,
            averageReference: false, baselineCorrect: false,
            globallyBadChannels: [], thresholds: thresholds
        ))
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
            globallyBadChannels: [],
            segmentHealthGoodnessScores: [100, 100]
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
        #expect(model.isChannelInterpolatedAcrossAllEpochs(1))
        #expect(model.isChannelInterpolatedAcrossAllEpochs(2))
        #expect(!model.isChannelInterpolatedAcrossAllEpochs(3))
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
            globallyBadChannels: [],
            segmentHealthGoodnessScores: [100, 100]
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

    @Test @MainActor func matrixCanOrderBothAxesByGoodness() async throws {
        var job = makeJob(thresholds: EpochBadChannelThresholds())
        job.defersBadChannelDecisions = true
        let result = try #require(await job.buildEpochs())
        var preparation = PSADecisionMatrixPreparation.make(
            signal: result.signal,
            segments: result.segments,
            thresholds: job.epochBadChannelThresholds,
            detectorSegments: [:],
            recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions,
            globallyBadChannels: [],
            segmentHealthGoodnessScores: [92, 38]
        )
        preparation.epochSetChannelGoodnessScores = [80, 25, 70, 95]
        let model = PSADecisionMatrixModel(preparation: preparation)

        model.channelOrder = .goodness
        model.epochOrder = .goodness

        #expect(model.orderedChannels == [1, 2, 0, 3])
        #expect(model.orderedEpochs == [1, 0])
    }

    @Test @MainActor func manualGoodTrustsSegmentHealthButNotArtifactRules() async throws {
        var job = makeJob(thresholds: EpochBadChannelThresholds())
        job.defersBadChannelDecisions = true
        let result = try #require(await job.buildEpochs())
        let preparation = PSADecisionMatrixPreparation.make(
            signal: result.signal,
            segments: result.segments,
            thresholds: job.epochBadChannelThresholds,
            detectorSegments: [:],
            recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions,
            globallyBadChannels: [],
            segmentHealthGoodnessScores: [20, 100]
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        model.epochRejectionHealthThreshold = 55
        for channel in 0..<result.signal.numberOfChannels {
            model.setCellDecision(.keep, for: .init(channelIndex: channel, epochIndex: 0))
        }

        #expect(model.resolvedEpochDecision(0) == .reject)
        #expect(model.rejectionReasons(for: 0) == ["Segment Health"])

        model.trustEpochHealth(0)
        #expect(model.resolvedEpochDecision(0) == .keep)

        model.suggestEpochRejection(0, reason: "Eye Blink")
        #expect(model.resolvedEpochDecision(0) == .reject)
        #expect(model.rejectionReasons(for: 0) == ["Eye Blink"])
    }

    @Test @MainActor func rejectionSummaryCountsOverlappingReasons() async throws {
        var job = makeJob(thresholds: EpochBadChannelThresholds())
        job.defersBadChannelDecisions = true
        let result = try #require(await job.buildEpochs())
        let preparation = PSADecisionMatrixPreparation.make(
            signal: result.signal,
            segments: result.segments,
            thresholds: job.epochBadChannelThresholds,
            detectorSegments: [:],
            recordingChannelGoodness: [:],
            electrodePositions: job.electrodePositions,
            globallyBadChannels: [],
            segmentHealthGoodnessScores: [20, 100],
            suggestedRejectedEpochReasons: [
                0: ["Eye Blink"],
                1: ["Eye Blink", "Eye Movement"]
            ]
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        model.epochRejectionHealthThreshold = 55

        let counts = Dictionary(uniqueKeysWithValues: model.rejectionReasonSummaries.map {
            ($0.reason, $0.count)
        })
        #expect(counts["Eye Blink"] == 2)
        #expect(counts["Eye Movement"] == 1)
        #expect(counts["Segment Health"] == 1)
        #expect(model.rejectedEpochCount == 2)

        // The area inspector must describe only its selected trials, with the
        // same overlapping reasons used by the whole-matrix summary.
        let selected = Dictionary(uniqueKeysWithValues: model.rejectionReasonSummaries(for: [1]).map {
            ($0.reason, $0.count)
        })
        #expect(selected["Eye Blink"] == 1)
        #expect(selected["Eye Movement"] == 1)
        #expect(selected["Segment Health"] == nil)
        #expect(model.rejectionReasonSummaries(for: []).isEmpty)

        // Cell Keep is not epoch Keep: artifact and health exclusions remain.
        for epoch in 0..<2 {
            for channel in 0..<result.signal.numberOfChannels {
                model.setCellDecision(.keep, for: .init(channelIndex: channel, epochIndex: epoch))
            }
        }
        #expect(model.rejectedEpochCount == 2)
        model.setEpochDecision(.keep, epochs: [1])
        #expect(model.resolvedEpochDecision(1) == .keep)
        #expect(model.rejectionReasonSummaries(for: [1]).isEmpty)
        #expect(model.rejectedEpochCount == 1)

        model.setEpochDecision(.reject, epochs: [1])
        #expect(model.rejectionReasonSummaries(for: [1]).map(\.reason) == ["Manual rejection"])
        model.setEpochDecision(.automatic, epochs: [1])
        #expect(Set(model.rejectionReasonSummaries(for: [1]).map(\.reason)) == ["Eye Blink", "Eye Movement"])
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
            baselineCorrect: false,
            segmentHealthGoodnessScores: [100, 100]
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        for epoch in result.segments.indices {
            model.setEpochDecision(.keep, epoch: epoch)
            for channel in result.signal.data.indices {
                model.setCellDecision(.keep, for: .init(channelIndex: channel, epochIndex: epoch))
            }
        }

        #expect(preparation.sourceSignal.data == sourceSignal.data)
        #expect(preparation.evidence[0][0] != preparation.rawEvidence[0][0])
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
