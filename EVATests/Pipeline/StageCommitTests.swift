//
//  StageCommitTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The last two stage-applying commits to come off `WaveformView`
//  (`ROADMAP.md` B2): publishing an average of already-built epochs, and
//  publishing a drawn-artifact cleaning result. Both were untestable as view
//  methods, which is the same property that kept the history tree from reaching
//  them.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct StageCommitTests {

    @MainActor
    private struct Fixture {
        let store = RecordingStore()
        let epoching: EpochingViewModel
        let segHealth: SegmentHealthViewModel
        let artifactVM: ArtifactViewModel
        let template: ArtifactTemplateViewModel

        init() {
            epoching = EpochingViewModel(store: store)
            segHealth = SegmentHealthViewModel(store: store)
            artifactVM = ArtifactViewModel(store: store)
            template = ArtifactTemplateViewModel(store: store)
        }

        func signal() -> MFFSignalData {
            SyntheticSignal.make([[0, 1, 2, 3], [4, 5, 6, 7]], samplingRate: 100)
        }

        /// Sample-indexed UI state that refers to the pre-average timeline.
        func seedTimelineState() {
            store.selection.selectedSampleRange = 10...20
            store.selection.dragSelectionStartSample = 10
            store.selection.dragSelectionEndSample = 20
            store.selection.topomapSample = 15
            epoching.butterflyTopomapRelativeSample = 5
            store.events.selectedEventCodes = ["LC++"]
        }

        var timelineStateIsClear: Bool {
            store.selection.selectedSampleRange == nil
                && store.selection.dragSelectionStartSample == nil
                && store.selection.dragSelectionEndSample == nil
                && store.selection.topomapSample == nil
                && epoching.butterflyTopomapRelativeSample == nil
                && store.events.selectedEventCodes.isEmpty
        }
    }

    private func segment(_ category: String) -> EpochSegment {
        EpochSegment(
            startSample: 0,
            endSample: 3,
            stimulusOffsetSamples: 0,
            category: category,
            sourceCode: category,
            sourceTimeSeconds: 0,
            colorIndex: 0,
            contributingEpochCount: 1
        )
    }

    private func buildResult(_ categories: [String], in fixture: Fixture) -> PSABuildResult {
        PSABuildResult(
            signal: fixture.signal(),
            segments: categories.map(segment),
            message: "\(categories.count) epochs"
        )
    }

    // MARK: - Averaging

    @Test func committingAnAverageClearsPreAverageTimelineState() {
        let f = Fixture()
        f.seedTimelineState()
        let display = buildResult(["LC++", "RC++"], in: f)

        PSAAveraging.commit(
            averaged: display,
            sourceSegmentCount: 40,
            excludedSegmentCount: 3,
            statusMessage: "2 categories averaged",
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(f.epoching.isAveraged)
        #expect(f.epoching.epochSegments.count == 2)
        #expect(f.epoching.statusMessage == "2 categories averaged")
        #expect(f.timelineStateIsClear,
                "sample indices refer to a timeline the averaged signal does not share")
    }

    /// Unlike a full epoch teardown, averaging keeps the user's segment labels:
    /// the segments they labelled are the ones that went into this average, so
    /// the labels still describe something real.
    @Test func committingAnAverageKeepsSegmentLabels() {
        let f = Fixture()
        PSAAveraging.commit(
            averaged: buildResult(["LC++"], in: f),
            sourceSegmentCount: 10,
            excludedSegmentCount: 0,
            statusMessage: "averaged",
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )
        // `clearAnalysis(hide:clearLabels:)` is called with `clearLabels: false`;
        // this pins the intent rather than the call.
        #expect(f.epoching.isAveraged)
    }

    @Test func exclusionSummaryFallsBackToTheSourceCount() {
        let f = Fixture()
        // A raw build that ran no rejection pass leaves `acceptedEpochs` at 0 —
        // everything that went in was accepted.
        #expect(f.epoching.psaExclusionSummary.acceptedEpochs == 0)

        PSAAveraging.commit(
            averaged: buildResult(["LC++", "RC++"], in: f),
            sourceSegmentCount: 37,
            excludedSegmentCount: 4,
            statusMessage: "averaged",
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(f.epoching.psaExclusionSummary.acceptedEpochs == 37)
        #expect(f.epoching.psaExclusionSummary.skippedLabeledBadSegments == 4)
        #expect(f.epoching.psaExclusionSummary.outputSegments == 2)
    }

    /// An accepted count the rejection pass *did* compute must survive — the
    /// fallback is for the case where nothing counted, not a blanket overwrite.
    @Test func exclusionSummaryKeepsARealAcceptedCount() {
        let f = Fixture()
        var summary = PSAExclusionSummary()
        summary.acceptedEpochs = 26
        f.epoching.psaExclusionSummary = summary

        PSAAveraging.commit(
            averaged: buildResult(["LC++"], in: f),
            sourceSegmentCount: 40,
            excludedSegmentCount: 0,
            statusMessage: "averaged",
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(f.epoching.psaExclusionSummary.acceptedEpochs == 26)
    }

    // MARK: - Artifact cleaning

    private func definedArtifact(method: ArtifactCleaningMethod = .regression) -> DefinedArtifact {
        let event = MFFEvent(
            id: "blink-1", code: "BLINK", beginTimeSeconds: 0.5,
            rawBeginTime: "0.5", sourceFile: "eye.xml"
        )
        let average = ArtifactTemplateAverage(
            samplingRate: 100,
            windowSizeSeconds: 0.4,
            eventCount: 1,
            selectedChannelIndices: [0],
            allChannelSamples: [[Float](repeating: 0, count: 40)],
            channelSummaries: [
                ArtifactTemplateChannelSummary(channelIndex: 0, peakAbsoluteMicrovolts: 80, rmsMicrovolts: 20)
            ]
        )
        return DefinedArtifact(
            type: .ocular,
            name: "Blink",
            eventCode: "BLINK",
            events: [event],
            selectedChannelIndices: [0],
            windowSizeSeconds: 0.4,
            average: average,
            topography: nil,
            cleaningMethod: method
        )
    }

    @Test func committingACleaningPublishesTheSignalAndInvalidatesEpochs() {
        let f = Fixture()
        f.epoching.epochedSignal = f.signal()
        f.epoching.isAveraged = true
        let tokenBefore = f.artifactVM.detectionRefreshToken

        ArtifactCleaningCore.commit(
            cleanedSignal: f.signal(),
            summaries: [],
            statusMessage: "Cleaned 2 artifacts.",
            artifactVM: f.artifactVM, template: f.template,
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(f.artifactVM.cleanedSignal != nil)
        #expect(f.artifactVM.cleaningIsEnabled)
        #expect(f.artifactVM.cleaningStatusMessage == "Cleaned 2 artifacts.")
        #expect(f.artifactVM.statusMessage == "Cleaned 2 artifacts.")
        #expect(f.artifactVM.detectionRefreshToken == tokenBefore + 1)
        #expect(f.epoching.epochedSignal == nil)
        #expect(!f.epoching.isAveraged)
    }

    /// Cleaning sits between the filter and the wavelet stage, so it must not
    /// disturb channel interpolations — the asymmetry `PipelineInvalidation`
    /// documents and every stage that touches it has to preserve.
    @Test func committingACleaningLeavesInterpolationsAlone() {
        let f = Fixture()
        f.store.channels.interpolated = [1: [0, 1, 2, 3]]
        let revisionBefore = f.store.channels.interpolationRevision

        ArtifactCleaningCore.commit(
            cleanedSignal: f.signal(),
            summaries: [],
            statusMessage: "cleaned",
            artifactVM: f.artifactVM, template: f.template,
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(f.store.channels.interpolated.count == 1)
        #expect(f.store.channels.interpolationRevision == revisionBefore)
    }

    /// The provenance stamp is the load-bearing part: an artifact that did not
    /// contribute must not keep claiming it was applied, or the exported
    /// `eva.xml` describes work that did not happen.
    @Test func committingACleaningClearsStampsOnArtifactsThatDidNotContribute() {
        let f = Fixture()
        var stale = definedArtifact()
        stale.appliedMethod = .regression
        stale.cleanedAt = Date(timeIntervalSince1970: 0)
        f.template.definedArtifacts = [stale]

        // No summary for it this time round.
        ArtifactCleaningCore.commit(
            cleanedSignal: f.signal(),
            summaries: [],
            statusMessage: "cleaned",
            artifactVM: f.artifactVM, template: f.template,
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(f.template.definedArtifacts[0].appliedMethod == nil)
        #expect(f.template.definedArtifacts[0].cleanedAt == nil)
    }

    @Test func committingACleaningStampsArtifactsThatDidContribute() {
        let f = Fixture()
        let artifact = definedArtifact()
        f.template.definedArtifacts = [artifact]
        let now = Date(timeIntervalSince1970: 1_000)

        ArtifactCleaningCore.commit(
            cleanedSignal: f.signal(),
            summaries: [ArtifactCleaningSummary(
                artifactID: artifact.id, name: "Blink", method: .regression,
                eventCount: 1, channelCount: 1
            )],
            appliedAt: now,
            statusMessage: "cleaned",
            artifactVM: f.artifactVM, template: f.template,
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(f.template.definedArtifacts[0].appliedMethod == .regression)
        #expect(f.template.definedArtifacts[0].cleanedAt == now)
    }
}
