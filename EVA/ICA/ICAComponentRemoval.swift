//
//  ICAComponentRemoval.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Applying an ICA component removal to the pipeline: the reconstruction plus the
//  downstream cascade, with no view involved.
//
//  ## Why
//
//  `removeSelectedICAComponents` lived on `WaveformView`, which made `icaClean`
//  a stage `ProcessingCore` could not perform — it hit the `default` case and
//  stopped, handing the file back as `.needsInput`. That is the shape every
//  headless/interactive divergence in this project has had: logic on the view, so
//  the headless path silently does less. `REWIND.md` sharpens it further, since a
//  stage the tree cannot re-apply is a node it cannot navigate to.
//
//  `ICAReplay.apply` was already the reconstruction half (byte-verified against
//  the live decomposition in `ICAReplayPayloadTests`). This is the other half:
//  what the *pipeline* does once the samples come back.
//
//  ## What is deliberately not here
//
//  **Re-applying the filter.** The interactive path recomputes `filter.output`
//  after a removal, because the user already had a filter applied to the old
//  base. In a script that is not this step's job — `currentProcessingScript()`
//  emits `filter` *after* `icaClean`, so a replay re-filters as its own next
//  step. Folding it in here would apply the filter twice on the headless path.
//
//  **Viewport, sheet, debug report, replay-gate resume.** View and session
//  concerns; they stay with the caller that has a view. Same split PSA
//  unification settled on — see `EpochingViewModel.buildAndPostProcess`.
//

import SwiftUI

@MainActor
enum ICAComponentRemoval {

    /// Reconstructs `signal` without the payload's excluded components and
    /// commits the result, including everything downstream that the new base
    /// signal invalidates.
    ///
    /// Throws rather than degrading: `ICAReplay.apply` refuses a channel-count
    /// mismatch and refuses to substitute a different activation copy if the
    /// fit filter cannot be rebuilt. Both would otherwise return *plausible but
    /// different* samples, which is worse than failing.
    @discardableResult
    static func apply(
        to signal: MFFSignalData,
        payload: ICAReplayPayload,
        ica: ICAViewModel,
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel,
        store: RecordingStore
    ) async throws -> MFFSignalData {
        let cleaned = try await ICAReplay.apply(to: signal, payload: payload)
        commit(
            cleaned: cleaned,
            ica: ica,
            artifactVM: artifactVM,
            template: template,
            epoching: epoching,
            segHealth: segHealth,
            store: store
        )
        return cleaned
    }

    /// The state cascade for a removal whose samples are already computed.
    ///
    /// Separate from `apply` because the interactive path computes the
    /// reconstruction inside its own cancellable task and re-checks the session
    /// before committing — it cannot hand that window to a shared function. Both
    /// paths run *this*, which is the part that was diverging.
    static func commit(
        cleaned: MFFSignalData,
        ica: ICAViewModel,
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel,
        store: RecordingStore
    ) {
        ica.cleanedSignal = cleaned
        PipelineInvalidation.appliedArtifactCleaning(artifactVM: artifactVM, template: template)
        // Detection ran against the pre-removal signal, so its events describe
        // samples that no longer exist.
        artifactVM.events = []
        artifactVM.detectionRefreshToken += 1
        PipelineInvalidation.epochsAndDerived(
            epoching: epoching, segHealth: segHealth, selection: store.selection
        )
        PipelineInvalidation.interpolations(store: store)
    }

    /// The payload for the removal currently staged in `ica`, or `nil` when
    /// there is no decomposition or nothing is excluded.
    ///
    /// One place that turns "what the sheet is showing" into the persisted form,
    /// so the interactive apply, the exported sidecar, and any future history
    /// node all describe the same removal.
    static func stagedPayload(_ ica: ICAViewModel) -> ICAReplayPayload? {
        guard let decomposition = ica.decomposition,
              !decomposition.excludedComponents.isEmpty else { return nil }
        return ICAReplayPayload(decomposition: decomposition, method: ica.method)
    }
}
