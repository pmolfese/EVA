//
//  PipelineStageTogglesTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The five "turn a stage off" actions, which until this extraction were methods
//  on `WaveformView` and therefore untestable at all — the same reason the
//  history tree could not reach them (`ROADMAP.md` B2's surviving item).
//
//  These assert the *contract*: that a toggle invalidates what depends on it, and
//  that a no-op stays a no-op. The no-op cases matter more than they look —
//  `REWIND.md` records a node per data-changing action, so a toggle that reports
//  a change it did not make would grow the tree on every redundant click.
//

import Testing
@testable import EVA

@MainActor
struct PipelineStageTogglesTests {

    @MainActor
    private struct Fixture {
        let store: RecordingStore
        let wavelet: WaveletReductionViewModel
        let artifactVM: ArtifactViewModel
        let template: ArtifactTemplateViewModel
        let epoching: EpochingViewModel
        let segHealth: SegmentHealthViewModel
        let bcg: BCGDetectionViewModel

        init() {
            store = RecordingStore()
            wavelet = WaveletReductionViewModel(store: store)
            artifactVM = ArtifactViewModel(store: store)
            template = ArtifactTemplateViewModel(store: store)
            epoching = EpochingViewModel(store: store)
            segHealth = SegmentHealthViewModel(store: store)
            bcg = BCGDetectionViewModel(store: store)
        }

        /// Downstream state a signal change must invalidate.
        func seedDownstreamState() {
            epoching.epochedSignal = signal()
            epoching.isAveraged = true
            epoching.showsButterflyPlot = true
            epoching.showsOverlaidCategories = true
            store.selection.topomapSample = 1_000
            store.selection.selectedSampleRange = 10...20
        }

        func signal() -> MFFSignalData {
            SyntheticSignal.make([[0, 1, 2, 3]], samplingRate: 100)
        }

        var downstreamIsClear: Bool {
            epoching.epochedSignal == nil
                && !epoching.isAveraged
                && !epoching.showsButterflyPlot
                && !epoching.showsOverlaidCategories
                && store.selection.topomapSample == nil
                && store.selection.selectedSampleRange == nil
        }
    }

    // MARK: - Wavelet

    @Test func disablingWaveletReductionInvalidatesDownstream() {
        let f = Fixture()
        f.wavelet.reducedSignal = f.signal()
        f.wavelet.isEnabled = true
        f.seedDownstreamState()

        let changed = PipelineStageToggles.setWaveletReductionEnabled(
            false, wavelet: f.wavelet, store: f.store,
            epoching: f.epoching, segHealth: f.segHealth
        )

        #expect(changed)
        #expect(!f.wavelet.isEnabled)
        #expect(f.downstreamIsClear)
    }

    /// Re-asserting the value already in effect must change nothing and report
    /// nothing — otherwise the history tree gains a node per redundant click.
    @Test func reassertingTheWaveletStateIsANoOp() {
        let f = Fixture()
        f.wavelet.reducedSignal = f.signal()
        f.wavelet.isEnabled = true
        f.seedDownstreamState()

        let changed = PipelineStageToggles.setWaveletReductionEnabled(
            true, wavelet: f.wavelet, store: f.store,
            epoching: f.epoching, segHealth: f.segHealth
        )

        #expect(!changed)
        #expect(f.epoching.isAveraged, "a no-op must not invalidate anything")
    }

    /// With nothing reduced there is nothing to toggle between.
    @Test func togglingWaveletWithNoReductionIsANoOp() {
        let f = Fixture()
        f.seedDownstreamState()

        let changed = PipelineStageToggles.setWaveletReductionEnabled(
            true, wavelet: f.wavelet, store: f.store,
            epoching: f.epoching, segHealth: f.segHealth
        )

        #expect(!changed)
        #expect(f.epoching.isAveraged)
    }

    @Test func revertingWaveletReductionDropsItsOutputAndRefreshesDetection() {
        let f = Fixture()
        f.wavelet.reducedSignal = f.signal()
        f.wavelet.result = nil
        f.seedDownstreamState()
        let tokenBefore = f.artifactVM.detectionRefreshToken

        let changed = PipelineStageToggles.revertWaveletReduction(
            wavelet: f.wavelet, artifactVM: f.artifactVM, store: f.store,
            epoching: f.epoching, segHealth: f.segHealth
        )

        #expect(changed)
        #expect(f.wavelet.reducedSignal == nil)
        #expect(f.wavelet.artifact == nil)
        #expect(f.wavelet.candidates.isEmpty)
        #expect(f.wavelet.selectedCandidateID == nil)
        #expect(f.downstreamIsClear)
        #expect(f.artifactVM.detectionRefreshToken == tokenBefore + 1,
                "artifact detection ran against the reduced signal and must re-run")
    }

    @Test func revertingWithNothingToRevertIsANoOp() {
        let f = Fixture()
        f.seedDownstreamState()
        let tokenBefore = f.artifactVM.detectionRefreshToken

        let changed = PipelineStageToggles.revertWaveletReduction(
            wavelet: f.wavelet, artifactVM: f.artifactVM, store: f.store,
            epoching: f.epoching, segHealth: f.segHealth
        )

        #expect(!changed)
        #expect(f.epoching.isAveraged)
        #expect(f.artifactVM.detectionRefreshToken == tokenBefore)
    }

    // MARK: - Artifact cleaning

    /// `REWIND.md` names this one directly: "turn artifact correction off" is a
    /// real node, because it changes the data.
    @Test func togglingArtifactCleaningInvalidatesEpochs() {
        let f = Fixture()
        f.artifactVM.cleanedSignal = f.signal()
        f.artifactVM.cleaningIsEnabled = true
        f.seedDownstreamState()

        let changed = PipelineStageToggles.setArtifactCleaningEnabled(
            false, artifactVM: f.artifactVM, store: f.store,
            epoching: f.epoching, segHealth: f.segHealth
        )

        #expect(changed)
        #expect(!f.artifactVM.cleaningIsEnabled)
        #expect(f.downstreamIsClear)
    }

    /// The asymmetry `PipelineInvalidation` documents: cleaning sits between the
    /// filter and the wavelet stage, so toggling it does not disturb channel
    /// interpolations the way the wavelet toggles do.
    @Test func togglingArtifactCleaningLeavesInterpolationsAlone() {
        let f = Fixture()
        f.artifactVM.cleanedSignal = f.signal()
        f.artifactVM.cleaningIsEnabled = true
        f.store.channels.interpolated = [3: [0, 1, 2, 3]]
        let revisionBefore = f.store.channels.interpolationRevision

        PipelineStageToggles.setArtifactCleaningEnabled(
            false, artifactVM: f.artifactVM, store: f.store,
            epoching: f.epoching, segHealth: f.segHealth
        )

        #expect(f.store.channels.interpolated.count == 1)
        #expect(f.store.channels.interpolationRevision == revisionBefore)
    }

    @Test func togglingCleaningWithNothingCleanedIsANoOp() {
        let f = Fixture()
        f.seedDownstreamState()

        let changed = PipelineStageToggles.setArtifactCleaningEnabled(
            true, artifactVM: f.artifactVM, store: f.store,
            epoching: f.epoching, segHealth: f.segHealth
        )

        #expect(!changed)
        #expect(f.epoching.isAveraged)
    }

    // MARK: - BCG

    @Test func disablingBCGRemovesOnlyItsOwnContributions() {
        let f = Fixture()
        f.bcg.detectsArtifacts = true
        f.bcg.refinedKeptCount = 42
        let mine = MFFEvent(
            id: "bcg-1", code: "BCG", beginTimeSeconds: 1,
            rawBeginTime: "1", sourceFile: BCGDetector.sourceFile
        )
        let theirs = MFFEvent(
            id: "blink-2", code: "blink", beginTimeSeconds: 2,
            rawBeginTime: "2", sourceFile: "eye.xml"
        )
        f.artifactVM.events = [mine, theirs]

        let changed = PipelineStageToggles.disableBCGDetection(
            bcg: f.bcg, artifactVM: f.artifactVM, template: f.template
        )

        #expect(changed)
        #expect(!f.bcg.detectsArtifacts)
        #expect(f.bcg.refinedTemplate == nil)
        #expect(f.bcg.refinedKeptCount == nil)
        #expect(f.artifactVM.events.map(\.code) == ["blink"],
                "another detector's events must survive")
    }

    @Test func disablingBCGWhenAlreadyOffIsANoOp() {
        let f = Fixture()
        f.artifactVM.events = [
            MFFEvent(id: "blink-2", code: "blink", beginTimeSeconds: 2, rawBeginTime: "2", sourceFile: "eye.xml")
        ]

        let changed = PipelineStageToggles.disableBCGDetection(
            bcg: f.bcg, artifactVM: f.artifactVM, template: f.template
        )

        #expect(!changed)
        #expect(f.artifactVM.events.count == 1)
    }

    /// The id has to be stable for the lifetime of the detector's output, or
    /// disabling looks for an artifact that is no longer keyed the way it was
    /// stored. It used to be a `let … = UUID()` on the `WaveformView` struct.
    @Test func theDefinedArtifactIDIsStablePerViewModel() {
        let store = RecordingStore()
        let bcg = BCGDetectionViewModel(store: store)
        #expect(bcg.definedArtifactID == bcg.definedArtifactID)
        #expect(BCGDetectionViewModel(store: store).definedArtifactID != bcg.definedArtifactID,
                "two detectors must not collide on one artifact")
    }

    // MARK: - Undo Segmentation

    @Test func clearEpochsDropsEpochsAndEverythingDerived() {
        let f = Fixture()
        f.seedDownstreamState()
        f.epoching.averageSNRByCategory = ["LC++": SNRMetrics()]
        f.epoching.isComputingAverageSNR = true
        f.epoching.statusMessage = "4 categories averaged"
        f.store.events.selectedEventCodes = ["LC++", "RC++"]

        PipelineStageToggles.clearEpochs(
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(f.downstreamIsClear)
        #expect(f.epoching.averageSNRByCategory.isEmpty)
        #expect(!f.epoching.isComputingAverageSNR)
        #expect(f.epoching.statusMessage == nil)
        #expect(f.store.events.selectedEventCodes.isEmpty,
                "undoing segmentation abandons the chosen conditions too")
    }

    /// The drift this extraction exposed: the old inline `clearEpochs` re-listed
    /// the epoch teardown by hand and had fallen out of step with the shared
    /// cascade — it never cleared `showsOverlaidCategories`. Latent, because the
    /// panel is also gated on `isAveraged`, but re-segmenting after an undo could
    /// bring back a panel the user had not asked for.
    @Test func clearEpochsClearsTheOverlaidCategoriesFlag() {
        let f = Fixture()
        f.epoching.showsOverlaidCategories = true

        PipelineStageToggles.clearEpochs(
            epoching: f.epoching, segHealth: f.segHealth, store: f.store
        )

        #expect(!f.epoching.showsOverlaidCategories)
    }
}
