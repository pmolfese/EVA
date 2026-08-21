//
//  PipelineStageToggles.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The "turn a stage off" actions — the ones that change the derived signal
//  without running any processing.
//
//  ## Why these five, and not the other thirty
//
//  `ROADMAP.md` B2 left one item open: re-rooting `ControlsBar`'s actions off
//  `WaveformView`, justified by `REWIND.md` rather than by performance ("an
//  action that lives on `WaveformView` is a stage the history tree cannot replay
//  headlessly"). Most of the toolbar's ~35 actions open a sheet or flip a display
//  flag; those are view concerns and belong on the view. **These five change what
//  the exported samples are**, which makes each of them a node in the history
//  tree — `REWIND.md` names one of them explicitly:
//
//  > "Turn artifact correction off" is a real node (it changes the data).
//
//  Same shape as `PipelineInvalidation`: free functions over explicitly-passed
//  collaborators rather than methods on something that owns them. The domain view
//  models are `@State` on `WaveformView` and need `$vm` bindings at ~240 call
//  sites, so moving *ownership* is not worth it to reach this — passing them in
//  gets one definition, keeps every dependency visible in the signature, and lets
//  the compiler name every call site when a new collaborator is needed.
//
//  What this buys immediately: these are testable, which as methods on a `View`
//  they were not. What it buys next: a headless path, and the history tree, can
//  reach them.
//

import SwiftUI

@MainActor
enum PipelineStageToggles {

    /// Switches between the wavelet-reduced signal and its input.
    ///
    /// Returns whether anything changed, so a caller that records history nodes
    /// can tell a real toggle from a no-op re-assert.
    @discardableResult
    static func setWaveletReductionEnabled(
        _ isEnabled: Bool,
        wavelet: WaveletReductionViewModel,
        store: RecordingStore,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel
    ) -> Bool {
        guard wavelet.reducedSignal != nil, wavelet.isEnabled != isEnabled else { return false }
        wavelet.isEnabled = isEnabled
        PipelineInvalidation.epochsAndDerived(
            epoching: epoching, segHealth: segHealth, selection: store.selection
        )
        PipelineInvalidation.interpolations(store: store)
        return true
    }

    /// Discards the wavelet reduction entirely, returning to its input signal.
    @discardableResult
    static func revertWaveletReduction(
        wavelet: WaveletReductionViewModel,
        artifactVM: ArtifactViewModel,
        store: RecordingStore,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel
    ) -> Bool {
        guard wavelet.reducedSignal != nil else { return false }
        wavelet.reducedSignal = nil
        wavelet.artifact = nil
        wavelet.result = nil
        wavelet.bandVarianceRetained = nil
        wavelet.statusMessage = "Reverted wavelet reduction."
        wavelet.candidates = []
        wavelet.selectedCandidateID = nil
        PipelineInvalidation.epochsAndDerived(
            epoching: epoching, segHealth: segHealth, selection: store.selection
        )
        PipelineInvalidation.interpolations(store: store)
        artifactVM.detectionRefreshToken += 1
        return true
    }

    /// Switches between the artifact-corrected signal and the uncorrected one.
    ///
    /// Note it does **not** invalidate interpolations, unlike the wavelet
    /// toggles. That asymmetry is deliberate and matches `PipelineInvalidation`'s
    /// own: cleaning sits between the filter and the wavelet stage in the chain.
    @discardableResult
    static func setArtifactCleaningEnabled(
        _ isEnabled: Bool,
        artifactVM: ArtifactViewModel,
        store: RecordingStore,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel
    ) -> Bool {
        guard artifactVM.cleanedSignal != nil, artifactVM.cleaningIsEnabled != isEnabled else {
            return false
        }
        artifactVM.cleaningIsEnabled = isEnabled
        PipelineInvalidation.epochsAndDerived(
            epoching: epoching, segHealth: segHealth, selection: store.selection
        )
        return true
    }

    /// Turns BCG detection off and removes what it contributed: its events and
    /// its defined artifact.
    @discardableResult
    static func disableBCGDetection(
        bcg: BCGDetectionViewModel,
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel
    ) -> Bool {
        guard bcg.detectsArtifacts else { return false }
        bcg.detectsArtifacts = false
        artifactVM.events = artifactVM.events.filter { $0.sourceFile != BCGDetector.sourceFile }
        template.definedArtifacts.removeAll { $0.id == bcg.definedArtifactID }
        bcg.refinedTemplate = nil
        bcg.refinedKeptCount = nil
        return true
    }

}
