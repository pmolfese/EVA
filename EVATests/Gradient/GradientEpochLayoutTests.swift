//
//  GradientEpochLayoutTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Covers the "Epoch Model" section of the FASTR-family functional spec, plus its
//  trigger-related edge cases.
//

import Testing
import Foundation
@testable import EVA

struct GradientEpochLayoutTests {

    private func build(
        triggers: [Int],
        sampleCount: Int,
        slices: Int = 1,
        upsample: Int = 1,
        relative: Double = 0
    ) throws -> GradientEpochLayout {
        try GradientEpochLayout.build(
            volumeTriggers: triggers,
            sampleCount: sampleCount,
            slicesPerVolume: slices,
            upsampleFactor: upsample,
            relativeTriggerPosition: relative
        )
    }

    // MARK: - Trigger handling

    @Test func fewerThanTwoTriggersIsRejected() {
        #expect(throws: GradientCorrectionError.insufficientTriggers(0)) {
            _ = try build(triggers: [], sampleCount: 1000)
        }
        #expect(throws: GradientCorrectionError.insufficientTriggers(1)) {
            _ = try build(triggers: [100], sampleCount: 1000)
        }
    }

    @Test func triggersAreSortedAndDeduplicated() throws {
        let layout = try build(triggers: [300, 100, 200, 100], sampleCount: 1000)
        #expect(layout.triggers == [100, 200, 300])
    }

    @Test func triggersOutsideTheRecordingAreDropped() throws {
        let layout = try build(triggers: [-50, 100, 200, 5000], sampleCount: 1000)
        #expect(layout.triggers == [100, 200])
    }

    // MARK: - Period

    @Test func periodIsTheMedianTriggerSpacing() throws {
        // Spacings 100, 100, 260, 100 — the median resists the one long gap that
        // a mean would be dragged toward.
        let layout = try build(triggers: [0, 100, 200, 460, 560], sampleCount: 1000)
        #expect(layout.period == 100)
    }

    @Test func unevenSpacingStillProducesAUsableLayout() throws {
        let layout = try build(triggers: [0, 97, 203, 300, 401], sampleCount: 600)
        #expect(layout.period == 100 || layout.period == 101 || layout.period == 97)
        #expect(layout.count == 5)
    }

    @Test func triggersTooCloseTogetherAreRejected() {
        #expect(throws: GradientCorrectionError.degenerateEpochGeometry) {
            _ = try build(triggers: [10, 11], sampleCount: 100)
        }
    }

    // MARK: - Window geometry

    @Test func relativeTriggerPositionSplitsTheWindow() throws {
        let atStart = try build(triggers: [0, 100, 200], sampleCount: 400, relative: 0)
        #expect(atStart.samplesBefore == 0)
        #expect(atStart.samplesAfter == 100)
        #expect(atStart.length == 101)

        let centered = try build(triggers: [0, 100, 200], sampleCount: 400, relative: 0.5)
        #expect(centered.samplesBefore == 50)
        #expect(centered.samplesAfter == 50)
        #expect(centered.length == 101)

        let quarter = try build(triggers: [0, 100, 200], sampleCount: 400, relative: 0.25)
        #expect(quarter.samplesBefore == 25)
        #expect(quarter.samplesAfter == 75)
    }

    @Test func windowStartIsNilWhenTheEpochLeavesTheRecording() throws {
        // 3 triggers at 0/100/200, window length 101, recording 250 samples.
        let layout = try build(triggers: [0, 100, 200], sampleCount: 250, relative: 0)
        #expect(layout.windowStart(of: 0) == 0)
        #expect(layout.windowStart(of: 1) == 100)
        // Epoch 2 would need samples 200..<301.
        #expect(layout.windowStart(of: 2) == nil)
    }

    @Test func windowStartAccountsForTheAlignmentShift() throws {
        let layout = try build(triggers: [0, 100, 200], sampleCount: 400, relative: 0)
        #expect(layout.windowStart(of: 0, shift: 5) == 5)
        // Shifting epoch 0 earlier walks off the front of the recording.
        #expect(layout.windowStart(of: 0, shift: -1) == nil)
    }

    // MARK: - Slices

    @Test func oneSliceKeepsVolumeLevelEpochs() throws {
        let layout = try build(triggers: [0, 100, 200], sampleCount: 400, slices: 1)
        #expect(layout.count == 3)
        #expect(layout.triggers == [0, 100, 200])
        #expect(layout.slicePosition == [0, 0, 0])
        #expect(layout.volumeIndex == [0, 1, 2])
    }

    @Test func multipleSlicesSubdivideEachVolumeInterval() throws {
        let layout = try build(triggers: [0, 100, 200], sampleCount: 400, slices: 4)
        // Each 100-sample volume splits into 4 slice epochs 25 samples apart.
        #expect(layout.triggers == [0, 25, 50, 75, 100, 125, 150, 175, 200, 225, 250, 275])
        #expect(layout.period == 25)
        #expect(layout.volumeIndex.prefix(4).allSatisfy { $0 == 0 })
        #expect(layout.slicePosition.prefix(4) == [0, 1, 2, 3])
    }

    @Test func theFinalVolumeReusesThePrecedingInterval() throws {
        let layout = try build(triggers: [0, 100], sampleCount: 300, slices: 2)
        // Volume 1 has no successor, so it borrows the 100-sample interval.
        #expect(layout.triggers == [0, 50, 100, 150])
    }

    @Test func sliceTriggersPastTheRecordingAreDropped() throws {
        let layout = try build(triggers: [0, 100], sampleCount: 160, slices: 4)
        // Volume 1's slices would land at 100/125/150/175; 175 is out of range.
        #expect(layout.triggers == [0, 25, 50, 75, 100, 125, 150])
    }

    @Test func sliceLookupResolvesVolumeAndSlicePosition() throws {
        let layout = try build(triggers: [0, 100, 200], sampleCount: 400, slices: 4)
        #expect(layout.epochIndex(volume: 0, slicePosition: 0) == 0)
        #expect(layout.epochIndex(volume: 1, slicePosition: 2) == 6)
        #expect(layout.epochIndex(volume: 2, slicePosition: 3) == 11)
        #expect(layout.epochIndex(volume: 9, slicePosition: 0) == nil)
    }

    // MARK: - Upsampling

    @Test func upsamplingScalesTriggersAndPeriod() throws {
        let layout = try build(triggers: [0, 100, 200], sampleCount: 400, upsample: 4)
        #expect(layout.triggers == [0, 400, 800])
        #expect(layout.period == 400)
        #expect(layout.samplesAfter == 400)
        #expect(layout.upsampledSampleCount == 1600)
    }
}
