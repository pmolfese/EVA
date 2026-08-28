//
//  ArtifactCleaningCore.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Committing a drawn-artifact cleaning result to the pipeline.
//
//  The last of the stage-*applying* actions that lived on `WaveformView`
//  (`ROADMAP.md` B2's surviving item, continued from `PipelineStageToggles` and
//  `ICAComponentRemoval`). `ArtifactCleaner.cleanedSignal` was already
//  view-free; what was not was everything that happens to the pipeline once it
//  returns — which is the half that diverges when only one path has it.
//
//  ## What this does not do
//
//  It does **not** make `artifactClean` headless-replayable, and adding a
//  `ProcessingCore` case for it would be premature. Unlike ICA, whose operator
//  is a pair of matrices that `ICAReplayPayload` can carry, an artifact cleaning
//  is defined by hand-drawn templates that have no persisted form yet — that is
//  the remaining piece of `REWIND.md` work item 4. Until those round-trip
//  through the package, a headless run has nothing to re-apply, and the step
//  stays a decision.
//
//  So this extraction buys the two things that do not depend on that: the
//  cascade is testable, and it exists once rather than waiting to be copied.
//

import SwiftUI

@MainActor
enum ArtifactCleaningCore {

    /// Publishes a cleaning outcome and everything downstream of the new signal.
    ///
    /// Stamps `appliedMethod`/`cleanedAt` on the artifacts that actually
    /// contributed, and **clears them on the ones that did not** — an artifact
    /// whose method no longer removes anything must not keep claiming it was
    /// applied, or the export's provenance describes work that did not happen.
    static func commit(
        cleanedSignal: MFFSignalData,
        summaries: [ArtifactCleaningSummary],
        appliedAt now: Date = Date(),
        statusMessage: String,
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel,
        store: RecordingStore
    ) {
        artifactVM.cleanedSignal = cleanedSignal
        artifactVM.cleaningIsEnabled = true
        artifactVM.cleaningSummaries = summaries

        let summariesByID = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.artifactID, $0) }
        )
        for index in template.definedArtifacts.indices {
            let artifact = template.definedArtifacts[index]
            if summariesByID[artifact.id] != nil, artifact.cleaningMethod.removesArtifact {
                template.definedArtifacts[index].appliedMethod = artifact.cleaningMethod
                template.definedArtifacts[index].cleanedAt = now
            } else {
                template.definedArtifacts[index].appliedMethod = nil
                template.definedArtifacts[index].cleanedAt = nil
            }
        }

        artifactVM.cleaningStatusMessage = statusMessage
        artifactVM.statusMessage = statusMessage
        artifactVM.detectionRefreshToken += 1
        // Epochs only. Cleaning sits between the filter and the wavelet stage,
        // so it does not disturb channel interpolations — the same asymmetry
        // `PipelineInvalidation` documents and `PipelineStageToggles` preserves.
        PipelineInvalidation.epochsAndDerived(
            epoching: epoching, segHealth: segHealth, selection: store.selection
        )
    }
}
