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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

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
            globallyBadChannels: []
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
