//
//  GradientDonorSelectionTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Covers the "Donor Strategies" section of the FASTR-family functional spec.
//

import Testing
import Foundation
@testable import EVA

struct GradientDonorSelectionTests {

    private func motion(_ displacements: [Double]) -> [MotionSample] {
        displacements.enumerated().map { index, value in
            MotionSample(id: index, roll: 0, pitch: 0, yaw: 0, dS: value, dL: 0, dP: 0)
        }
    }

    private func layout(volumes: Int, period: Int = 100, slices: Int = 1) throws -> GradientEpochLayout {
        try GradientEpochLayout.build(
            volumeTriggers: (0..<volumes).map { $0 * period },
            sampleCount: volumes * period + period,
            slicesPerVolume: slices,
            upsampleFactor: 1,
            relativeTriggerPosition: 0
        )
    }

    // MARK: - Temporal neighbors

    @Test func temporalDonorsAreTheNearestEpochsAndExcludeTheTarget() {
        let donors = GradientDonorSelection.nearestTemporalDonors(
            target: 10, epochCount: 40, desired: 4,
            allowsSelfDonation: false, isEligible: { _ in true }
        )
        #expect(donors == [8, 9, 11, 12])
        #expect(!donors.contains(10))
    }

    @Test func temporalDonorsSaturateAtTheStartOfTheRecording() {
        // Spec permits either edge policy; this implementation saturates, so a
        // target at index 0 still receives its full donor count, all from later.
        let donors = GradientDonorSelection.nearestTemporalDonors(
            target: 0, epochCount: 40, desired: 4,
            allowsSelfDonation: false, isEligible: { _ in true }
        )
        #expect(donors == [1, 2, 3, 4])
    }

    @Test func temporalDonorsSaturateAtTheEndOfTheRecording() {
        let donors = GradientDonorSelection.nearestTemporalDonors(
            target: 39, epochCount: 40, desired: 4,
            allowsSelfDonation: false, isEligible: { _ in true }
        )
        #expect(donors == [35, 36, 37, 38])
    }

    @Test func temporalDonorsSkipIneligibleEpochsAndReachFurtherOut() {
        // Blocking 8, 9, and 11 makes the search walk outward: offset 1 and 2
        // yield only 12, offset 3 yields 7 and 13, and offset 4 yields 6 — the
        // left candidate is tried first, so 6 completes the set before 14.
        let blocked: Set<Int> = [8, 9, 11]
        let donors = GradientDonorSelection.nearestTemporalDonors(
            target: 10, epochCount: 40, desired: 4,
            allowsSelfDonation: false, isEligible: { !blocked.contains($0) }
        )
        #expect(donors == [6, 7, 12, 13])
    }

    @Test func temporalDonorsPreferTheEarlierOfTwoEquidistantCandidates() {
        let donors = GradientDonorSelection.nearestTemporalDonors(
            target: 10, epochCount: 40, desired: 1,
            allowsSelfDonation: false, isEligible: { _ in true }
        )
        #expect(donors == [9])
    }

    @Test func selfDonationIsOffByDefaultAndOptIn() {
        let without = GradientDonorSelection.nearestTemporalDonors(
            target: 5, epochCount: 20, desired: 3,
            allowsSelfDonation: false, isEligible: { _ in true }
        )
        #expect(!without.contains(5))

        let with = GradientDonorSelection.nearestTemporalDonors(
            target: 5, epochCount: 20, desired: 3,
            allowsSelfDonation: true, isEligible: { _ in true }
        )
        #expect(with.contains(5))
    }

    @Test func noEligibleEpochsYieldsNoDonors() {
        let donors = GradientDonorSelection.nearestTemporalDonors(
            target: 5, epochCount: 20, desired: 4,
            allowsSelfDonation: false, isEligible: { _ in false }
        )
        #expect(donors.isEmpty)
    }

    // MARK: - Motion magnitude

    @Test func motionMagnitudeIsFramewiseAndStartsAtZero() {
        let magnitudes = GradientDonorSelection.motionMagnitudes(
            motion: motion([0, 0, 0, 2, 2, 2]),
            metric: .translationOnly,
            radiusMm: 50
        )
        // The event is the *change* at volume 3, not the sustained offset after it.
        #expect(magnitudes[0] == 0)
        #expect(magnitudes[3] == 2)
        #expect(magnitudes[4] == 0)
    }

    @Test func allParameterMetricIncludesRotationsAsArcLength() {
        var samples = motion([0, 0, 0])
        samples[1] = MotionSample(id: 1, roll: 1, pitch: 0, yaw: 0, dS: 0, dL: 0, dP: 0)
        samples[2] = MotionSample(id: 2, roll: 1, pitch: 0, yaw: 0, dS: 0, dL: 0, dP: 0)

        let translations = GradientDonorSelection.motionMagnitudes(
            motion: samples, metric: .translationOnly, radiusMm: 50
        )
        #expect(translations.allSatisfy { $0 == 0 })

        let all = GradientDonorSelection.motionMagnitudes(
            motion: samples, metric: .allParameters, radiusMm: 50
        )
        // One degree on a 50 mm sphere is about 0.87 mm of arc.
        #expect(abs(all[1] - (Double.pi / 180 * 50)) < 1e-9)
        #expect(all[2] == 0)
    }

    @Test func highMotionVolumesAreThoseAboveThreshold() {
        let volumes = GradientDonorSelection.highMotionVolumes(
            motion: motion([0, 0, 0, 3, 3, 3, 3.1]),
            metric: .translationOnly,
            thresholdMm: 0.5,
            radiusMm: 50
        )
        #expect(volumes == [3])
    }

    // MARK: - Motion file alignment

    @Test func shortMotionFileIsFrontPadded() {
        let result = GradientDonorSelection.alignMotionToVolumes(
            motion: motion([1, 2, 3]),
            volumeCount: 5
        )
        #expect(result.samples.count == 5)
        #expect(result.samples[0].dS == 0)
        #expect(result.samples[1].dS == 0)
        #expect(result.samples[2].dS == 1)
        #expect(result.warnings.contains(.motionRowsFrontPadded(count: 2)))
    }

    @Test func longMotionFileIsTruncated() {
        let result = GradientDonorSelection.alignMotionToVolumes(
            motion: motion([1, 2, 3, 4, 5]),
            volumeCount: 3
        )
        #expect(result.samples.count == 3)
        #expect(result.warnings.contains(.motionRowsTruncated(count: 2)))
    }

    @Test func matchingMotionFileIsLeftAlone() {
        let result = GradientDonorSelection.alignMotionToVolumes(
            motion: motion([1, 2, 3]),
            volumeCount: 3
        )
        #expect(result.samples.count == 3)
        #expect(result.warnings.isEmpty)
    }

    // MARK: - Motion-informed donors

    @Test func motionInformedSelectionReturnsNilWithoutSupraThresholdMotion() {
        let selection = GradientDonorSelection.motionInformedDonorVolumes(
            volumeCount: 20, highMotion: [], censored: [], desired: 4
        )
        #expect(selection == nil)
    }

    @Test func motionInformedDonorsNeverIncludeAHighMotionVolume() throws {
        let selection = try #require(GradientDonorSelection.motionInformedDonorVolumes(
            volumeCount: 20, highMotion: [10], censored: [], desired: 4
        ))
        for donors in selection.donors {
            #expect(!donors.contains(10))
        }
    }

    @Test func motionInformedDonorsDoNotCrossAMotionEventWhenTheyDoNotHaveTo() throws {
        let selection = try #require(GradientDonorSelection.motionInformedDonorVolumes(
            volumeCount: 40, highMotion: [20], censored: [], desired: 4
        ))
        // Volume 22 sits after the event; all its donors should too.
        #expect(selection.donors[22].allSatisfy { $0 > 20 })
        // Volume 18 sits before it.
        #expect(selection.donors[18].allSatisfy { $0 < 20 })
        #expect(!selection.crossedBarrier.contains(22))
    }

    @Test func motionInformedDonorsCrossABarrierRatherThanUnderAverage() throws {
        // Volume 1 is boxed in: events at 0 and 3 leave only volume 2 nearby.
        let selection = try #require(GradientDonorSelection.motionInformedDonorVolumes(
            volumeCount: 20, highMotion: [0, 3], censored: [], desired: 4
        ))
        #expect(selection.donors[1].count == 4)
        #expect(selection.crossedBarrier.contains(1))
        #expect(!selection.donors[1].contains(0))
        #expect(!selection.donors[1].contains(3))
    }

    @Test func censoredVolumesAreSkippedWithoutActingAsBarriers() throws {
        let selection = try #require(GradientDonorSelection.motionInformedDonorVolumes(
            volumeCount: 20, highMotion: [15], censored: [5, 6], desired: 4
        ))
        #expect(!selection.donors[7].contains(5))
        #expect(!selection.donors[7].contains(6))
        // A censored volume is skipped over, so donors still reach past it.
        #expect(selection.donors[7].contains(4))
    }

    // MARK: - Correlation

    @Test func pearsonCorrelationHandlesTheStandardCases() {
        let a: [Float] = [1, 2, 3, 4, 5]
        #expect(abs(GradientDonorSelection.pearsonCorrelation(a, a) - 1) < 1e-9)
        #expect(abs(GradientDonorSelection.pearsonCorrelation(a, a.map { -$0 }) + 1) < 1e-9)
        #expect(GradientDonorSelection.pearsonCorrelation(a, [1, 1, 1, 1, 1]) == 0)
        #expect(GradientDonorSelection.pearsonCorrelation(a, []) == 0)
    }

    @Test func correlationRankingPrefersTheMostSimilarEpochs() throws {
        let layout = try layout(volumes: 30)
        // Every epoch is a sinusoid; epochs 3, 7, and 25 match the target's phase,
        // the rest are shifted away from it.
        let matching: Set<Int> = [3, 7, 25]
        func waveform(_ epoch: Int) -> [Float]? {
            let phase = (epoch == 10 || matching.contains(epoch)) ? 0.0 : 1.9
            return (0..<64).map { Float(sin(2 * .pi * Double($0) / 64 + phase)) }
        }

        let result = GradientDonorSelection.correlationRankedDonors(
            target: 10, layout: layout, waveform: waveform, isEligible: { _ in true },
            squared: false, threshold: 0.9, minimumQualified: 2, desired: 3,
            searchWindow: 240, allowsSelfDonation: false
        )
        #expect(!result.fellBack)
        #expect(result.donors == [3, 7, 25])
    }

    @Test func correlationRankingFallsBackWhenTooFewEpochsQualify() throws {
        let layout = try layout(volumes: 30)
        func waveform(_ epoch: Int) -> [Float]? {
            let phase = Double(epoch) * 1.37
            return (0..<64).map { Float(sin(2 * .pi * Double($0) / 64 + phase)) }
        }
        let result = GradientDonorSelection.correlationRankedDonors(
            target: 10, layout: layout, waveform: waveform, isEligible: { _ in true },
            squared: false, threshold: 0.99, minimumQualified: 4, desired: 6,
            searchWindow: 240, allowsSelfDonation: false
        )
        #expect(result.fellBack)
        #expect(result.donors.isEmpty)
    }

    @Test func squaredCorrelationRanksAntiCorrelatedEpochsAsHighly() throws {
        let layout = try layout(volumes: 30)
        // Epoch 4 is the exact inverse of the target; epoch 5 is uncorrelated.
        func waveform(_ epoch: Int) -> [Float]? {
            let base = (0..<64).map { Float(sin(2 * .pi * Double($0) / 64)) }
            switch epoch {
            case 10, 4: return epoch == 4 ? base.map { -$0 } : base
            default: return (0..<64).map { Float(sin(2 * .pi * Double($0) / 64 + 1.57)) }
            }
        }
        let result = GradientDonorSelection.correlationRankedDonors(
            target: 10, layout: layout, waveform: waveform, isEligible: { _ in true },
            squared: true, threshold: 0.9, minimumQualified: 1, desired: 1,
            searchWindow: 240, allowsSelfDonation: false
        )
        #expect(result.donors == [4])
        #expect(!result.fellBack)
    }

    @Test func squaredCorrelationAdmitsTheTargetOnlyWhenSelfDonationIsRequested() throws {
        let layout = try layout(volumes: 30)
        func waveform(_ epoch: Int) -> [Float]? {
            (0..<64).map { Float(sin(2 * .pi * Double($0) / 64 + Double(epoch))) }
        }
        let without = GradientDonorSelection.correlationRankedDonors(
            target: 10, layout: layout, waveform: waveform, isEligible: { _ in true },
            squared: true, threshold: 0, minimumQualified: 1, desired: 3,
            searchWindow: 240, allowsSelfDonation: false
        )
        #expect(!without.donors.contains(10))

        let with = GradientDonorSelection.correlationRankedDonors(
            target: 10, layout: layout, waveform: waveform, isEligible: { _ in true },
            squared: true, threshold: 0, minimumQualified: 1, desired: 3,
            searchWindow: 240, allowsSelfDonation: true
        )
        #expect(with.donors.contains(10))
    }

    @Test func correlationCandidatesRespectEligibility() throws {
        let layout = try layout(volumes: 30)
        func waveform(_ epoch: Int) -> [Float]? {
            (0..<64).map { Float(sin(2 * .pi * Double($0) / 64)) }
        }
        let blocked: Set<Int> = [9, 11]
        let result = GradientDonorSelection.correlationRankedDonors(
            target: 10, layout: layout, waveform: waveform, isEligible: { !blocked.contains($0) },
            squared: true, threshold: 0, minimumQualified: 1, desired: 4,
            searchWindow: 240, allowsSelfDonation: false
        )
        #expect(!result.donors.contains(9))
        #expect(!result.donors.contains(11))
    }

    @Test func correlationSearchWindowBoundsTheCandidatePool() throws {
        let layout = try layout(volumes: 100)
        func waveform(_ epoch: Int) -> [Float]? {
            (0..<64).map { Float(sin(2 * .pi * Double($0) / 64)) }
        }
        let result = GradientDonorSelection.correlationRankedDonors(
            target: 50, layout: layout, waveform: waveform, isEligible: { _ in true },
            squared: true, threshold: 0, minimumQualified: 1, desired: 100,
            searchWindow: 3, allowsSelfDonation: false
        )
        #expect(result.donors.allSatisfy { abs($0 - 50) <= 3 })
    }
}
