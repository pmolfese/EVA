//
//  PipelineInvalidationTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Guards the cascade that used to exist twice and disagree with itself: applying
//  a base-signal stage cleared epochs, interpolations, and artifact cleaning in
//  `WaveformView`, but only ICA and filter output in `ProcessingCore`. A headless
//  or replayed run therefore kept stale downstream state.
//
//  These assert the *contract* rather than the implementation, so they keep
//  holding when `REWIND.md` work item 3 replaces the mechanical cascade with a
//  derived one.
//

import Testing
@testable import EVA

@MainActor
struct PipelineInvalidationTests {

    private func makeStore() -> RecordingStore { RecordingStore() }

    private func makeSignal() -> MFFSignalData {
        SyntheticSignal.make([[0, 1, 2, 3]], samplingRate: 100)
    }

    @Test func baseSignalChangeClearsEveryDownstreamStage() {
        let store = makeStore()
        let ica = ICAViewModel(store: store)
        let filter = FilterViewModel(store: store)
        let artifactVM = ArtifactViewModel(store: store)
        let template = ArtifactTemplateViewModel(store: store)
        let epoching = EpochingViewModel(store: store)
        let segHealth = SegmentHealthViewModel(store: store)

        // Downstream state that a base-signal change must invalidate.
        epoching.isAveraged = true
        epoching.showsButterflyPlot = true
        store.selection.topomapSample = 1_000
        store.selection.selectedSampleRange = 10...20
        let tokenBefore = artifactVM.detectionRefreshToken

        PipelineInvalidation.downstreamOfBaseSignalChange(
            store: store,
            ica: ica,
            filter: filter,
            artifactVM: artifactVM,
            template: template,
            epoching: epoching,
            segHealth: segHealth
        )

        #expect(ica.cleanedSignal == nil)
        #expect(ica.decomposition == nil)
        #expect(filter.output == nil)
        #expect(filter.pnsOutput == nil)
        #expect(artifactVM.cleanedSignal == nil)

        // The half the headless path used to miss.
        #expect(epoching.epochedSignal == nil)
        #expect(epoching.segmentedEpochSignal == nil)
        #expect(epoching.segmentedEpochSegments.isEmpty)
        #expect(!epoching.isAveraged)
        #expect(!epoching.showsButterflyPlot)
        #expect(store.channels.interpolated.isEmpty)
        #expect(
            artifactVM.detectionRefreshToken > tokenBefore,
            "artifact detection must be re-triggered when the base signal changes"
        )
    }

    /// Selection and topomap cursor are sample indices into the *previous*
    /// signal, so they must not survive a stage that replaces it.
    @Test func epochInvalidationClearsSampleIndexedSelectionState() {
        let store = makeStore()
        let epoching = EpochingViewModel(store: store)
        let segHealth = SegmentHealthViewModel(store: store)

        store.selection.selectedSampleRange = 100...200
        store.selection.dragSelectionStartSample = 100
        store.selection.dragSelectionEndSample = 200
        store.selection.topomapSample = 150

        PipelineInvalidation.epochsAndDerived(
            epoching: epoching,
            segHealth: segHealth,
            selection: store.selection
        )

        #expect(store.selection.selectedSampleRange == nil)
        #expect(store.selection.dragSelectionStartSample == nil)
        #expect(store.selection.dragSelectionEndSample == nil)
        #expect(store.selection.topomapSample == nil)
    }

    @Test func interpolationInvalidationClearsRecipesAndResolver() {
        let store = makeStore()
        store.channels.setInterpolation(
            target: 0,
            replacement: [0, 1, 2],
            sourceIndices: [1, 2],
            sourceWeights: [0.5, 0.5]
        )
        #expect(!store.channels.interpolated.isEmpty)

        PipelineInvalidation.interpolations(store: store)

        #expect(store.channels.interpolated.isEmpty)
        #expect(store.channels.interpolationSources.isEmpty)
    }

    /// Reports whether anything was applied, so callers can skip the heavier
    /// downstream work when there was nothing to undo.
    @Test func appliedCleaningReportsWhetherThereWasAnythingToClear() {
        let store = makeStore()
        let artifactVM = ArtifactViewModel(store: store)
        let template = ArtifactTemplateViewModel(store: store)

        #expect(
            PipelineInvalidation.appliedArtifactCleaning(artifactVM: artifactVM, template: template) == false,
            "nothing applied yet"
        )

        artifactVM.cleanedSignal = makeSignal()
        #expect(
            PipelineInvalidation.appliedArtifactCleaning(artifactVM: artifactVM, template: template) == true
        )
        #expect(artifactVM.cleanedSignal == nil)
        #expect(artifactVM.cleaningIsEnabled)
    }

    /// Filtering changes the *input* to artifact cleaning, so applied cleaning
    /// is stale — but the filter's own output must survive.
    @Test func filterChangeClearsAppliedCleaningButKeepsFilterOutput() {
        let store = makeStore()
        let filter = FilterViewModel(store: store)
        let artifactVM = ArtifactViewModel(store: store)
        let template = ArtifactTemplateViewModel(store: store)
        let epoching = EpochingViewModel(store: store)
        let segHealth = SegmentHealthViewModel(store: store)

        filter.output = makeSignal()
        artifactVM.cleanedSignal = makeSignal()
        epoching.isAveraged = true

        PipelineInvalidation.downstreamOfFilterChange(
            store: store,
            artifactVM: artifactVM,
            template: template,
            epoching: epoching,
            segHealth: segHealth
        )

        #expect(filter.output != nil, "the filter stage just produced this")
        #expect(artifactVM.cleanedSignal == nil, "cleaning runs on the filter's output")
        #expect(!epoching.isAveraged)
    }

    /// The asymmetry with the filter cascade, and the reason both exist:
    /// artifact cleaning runs *before* wavelet reduction in the chain
    /// (`… → filter → artifact-clean → wavelet → …`), so it is upstream of
    /// wavelet and must survive.
    @Test func waveletChangeLeavesUpstreamArtifactCleaningIntact() {
        let store = makeStore()
        let artifactVM = ArtifactViewModel(store: store)
        let epoching = EpochingViewModel(store: store)
        let segHealth = SegmentHealthViewModel(store: store)

        artifactVM.cleanedSignal = makeSignal()
        epoching.isAveraged = true
        store.selection.topomapSample = 42
        let tokenBefore = artifactVM.detectionRefreshToken

        PipelineInvalidation.downstreamOfWaveletChange(
            store: store,
            artifactVM: artifactVM,
            epoching: epoching,
            segHealth: segHealth
        )

        #expect(
            artifactVM.cleanedSignal != nil,
            "artifact cleaning is upstream of wavelet reduction and must not be cleared"
        )
        #expect(!epoching.isAveraged)
        #expect(store.selection.topomapSample == nil)
        #expect(artifactVM.detectionRefreshToken > tokenBefore)
    }

    /// ICA must be able to run the cascade without discarding the output it just
    /// produced.
    @Test func icaOutputIsPreservedWhenICAIsTheStageThatRan() {
        let store = makeStore()
        let ica = ICAViewModel(store: store)
        let filter = FilterViewModel(store: store)
        let artifactVM = ArtifactViewModel(store: store)
        let template = ArtifactTemplateViewModel(store: store)
        let epoching = EpochingViewModel(store: store)
        let segHealth = SegmentHealthViewModel(store: store)

        ica.cleanedSignal = makeSignal()
        filter.output = makeSignal()

        PipelineInvalidation.downstreamOfBaseSignalChange(
            store: store,
            ica: ica,
            filter: filter,
            artifactVM: artifactVM,
            template: template,
            epoching: epoching,
            segHealth: segHealth,
            clearsICA: false
        )

        #expect(ica.cleanedSignal != nil, "ICA's own output must survive its own cascade")
        #expect(filter.output == nil, "everything downstream of ICA is still stale")
    }
}
