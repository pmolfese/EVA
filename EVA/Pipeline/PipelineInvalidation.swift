//
//  PipelineInvalidation.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  One definition of "what goes stale when a pipeline stage changes the signal".
//
//  ## The bug this closes
//
//  The cascade used to exist twice, and the two copies disagreed. Applying MRI
//  gradient correction cleared, in the **interactive** path (`WaveformView`):
//  ICA output, filter output, applied artifact cleaning, the artifact detection
//  token, epochs and segment health, and channel interpolations. The **headless**
//  path (`ProcessingCore`) cleared only ICA and filter output.
//
//  So a headless or replayed gradient step left stale epochs, stale
//  interpolations, and stale artifact cleaning that the interactive path removed
//  — a signal that silently contradicts the processing chain that produced it.
//  `REWIND.md` calls this out as a correctness hazard by construction, and REWIND
//  makes it sharper: every node navigation re-applies stages, so any divergence
//  between "applied interactively" and "re-applied from history" becomes a
//  wrong-data bug rather than a tidiness problem.
//
//  ## Shape
//
//  Free functions over explicitly-passed view models rather than methods on a
//  coordinator that owns them. The domain view models are `@State` on
//  `WaveformView` (they need `$vm` bindings, ~240 call sites), so moving
//  ownership was not worth it to reach this; passing them in gets one definition
//  without disturbing that. It also keeps every dependency of the cascade visible
//  in the signature — if a new stage needs invalidating, the compiler names every
//  call site that must supply it.
//
//  These are the *mechanical* cascades. `REWIND.md` work item 3 replaces them
//  with a derived one ("everything after node N is invalid"); until then this is
//  the single place to edit when a stage is added, instead of two that drift.
//

import SwiftUI

@MainActor
enum PipelineInvalidation {

    /// Clears everything derived from the epoched signal.
    ///
    /// Also clears the time selection and topomap cursor: both are expressed in
    /// sample indices of the *previous* signal, so keeping them would point at
    /// the wrong samples.
    static func epochsAndDerived(
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel,
        selection: WaveformSelectionModel
    ) {
        epoching.epochedSignal = nil
        epoching.epochSegments = []
        epoching.segmentedEpochSignal = nil
        epoching.segmentedEpochSegments = []
        epoching.isAveraged = false
        epoching.butterflyTopomapRelativeSample = nil
        epoching.psaExclusionSummary = PSAExclusionSummary()
        epoching.averagedDisplayMode = .waveform
        epoching.showsButterflyPlot = false
        epoching.showsOverlaidCategories = false
        epoching.epochBadChannelSummary.removeAll()
        epoching.epochBadChannelAllSegmentsSummary.removeAll()
        epoching.interpolatedChannelsBySegmentSummary.removeAll()
        epoching.skippedLabeledBadSegmentsSummary.removeAll()

        selection.selectedSampleRange = nil
        selection.dragSelectionStartSample = nil
        selection.dragSelectionEndSample = nil
        selection.topomapSample = nil

        segHealth.clearAnalysis(hide: true, clearLabels: true)
    }

    /// Drops channel interpolations and the cached composed signal.
    ///
    /// Interpolation recipes are defined against the donor channels of the signal
    /// that was current when they were made, so a stage that replaces the signal
    /// invalidates them.
    static func interpolations(store: RecordingStore) {
        store.channels.removeAllInterpolations()
        store.interpolatedSignalResolver.reset()
    }

    /// Clears an applied artifact-cleaning pass and the per-artifact records of it.
    ///
    /// Returns whether anything was actually applied, so callers can skip the
    /// heavier downstream invalidation when there was nothing to undo.
    @discardableResult
    static func appliedArtifactCleaning(
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel
    ) -> Bool {
        let hadCleaning = artifactVM.cleanedSignal != nil
            || template.definedArtifacts.contains { $0.appliedMethod != nil }

        artifactVM.cleanedSignal = nil
        artifactVM.cleaningIsEnabled = true
        artifactVM.cleaningSummaries = []
        artifactVM.cleaningProgress = nil
        artifactVM.cleaningStatusMessage = nil
        for index in template.definedArtifacts.indices {
            template.definedArtifacts[index].appliedMethod = nil
            template.definedArtifacts[index].cleanedAt = nil
        }
        return hadCleaning
    }

    /// Everything downstream of the **filter** stage.
    ///
    /// The processing chain is
    /// `raw → gradient → BCG → ICA → filter → artifact-clean → wavelet → interpolate`,
    /// so filtering changes the *input* to artifact cleaning and any applied
    /// cleaning is stale. It does not touch `filter.output` — the filter stage
    /// just produced that — nor ICA, which is upstream.
    static func downstreamOfFilterChange(
        store: RecordingStore,
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel
    ) {
        appliedArtifactCleaning(artifactVM: artifactVM, template: template)
        artifactVM.detectionRefreshToken += 1
        epochsAndDerived(epoching: epoching, segHealth: segHealth, selection: store.selection)
        interpolations(store: store)
    }

    /// Everything downstream of the **wavelet reduction** stage.
    ///
    /// Deliberately does *not* clear applied artifact cleaning: cleaning runs
    /// *before* wavelet reduction in the chain, so it is upstream and still
    /// valid. This is the one asymmetry with `downstreamOfFilterChange`, and it
    /// is intentional rather than an oversight — hence the explicit note.
    static func downstreamOfWaveletChange(
        store: RecordingStore,
        artifactVM: ArtifactViewModel,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel
    ) {
        artifactVM.detectionRefreshToken += 1
        epochsAndDerived(epoching: epoching, segHealth: segHealth, selection: store.selection)
        interpolations(store: store)
    }

    /// Everything downstream of a stage that replaces the **base** signal —
    /// MRI gradient correction, BCG correction, ICA cleaning.
    ///
    /// This is the cascade that the headless path was missing. Callers get the
    /// full set or none of it; there is no partial variant, because a partial
    /// one is what produced the divergence in the first place.
    static func downstreamOfBaseSignalChange(
        store: RecordingStore,
        ica: ICAViewModel,
        filter: FilterViewModel,
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel,
        clearsICA: Bool = true
    ) {
        // ICA is skipped when ICA itself is the stage that just ran — it would
        // otherwise discard the output it just produced.
        if clearsICA {
            ica.cleanedSignal = nil
            ica.decomposition = nil
        }

        filter.output = nil
        filter.pnsOutput = nil
        filter.pnsInputSignalType = nil

        appliedArtifactCleaning(artifactVM: artifactVM, template: template)
        artifactVM.detectionRefreshToken += 1

        epochsAndDerived(epoching: epoching, segHealth: segHealth, selection: store.selection)
        interpolations(store: store)
    }
}
