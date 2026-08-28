//
//  PSAAveraging.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Committing an average of already-built epochs — "Average Current Epochs".
//
//  ## Why it is separate from the rest of PSA
//
//  `EpochingViewModel.buildAndPostProcess` covers segment → average →
//  post-process as one sequence, and both the interactive and headless paths use
//  it. This is the *other* entry point: the user already has raw epochs on
//  screen and asks for the average without re-segmenting. It has no step of its
//  own in `eva.xml` (averaging is a parameter of `segment`), so it never went
//  through the unified core — and it stayed on `WaveformView`, where the history
//  tree could not reach it even though it plainly changes the data.
//
//  Only the commit lives here. The averaging itself is already
//  `PSABuildResult.average` / `.postProcessed`, both free of any view, and the
//  caller keeps the cancellable tasks and session guard that wrap them — the
//  same split `ICAComponentRemoval` uses and for the same reason: the window
//  between "computed" and "still current" belongs to whoever owns the task.
//

import SwiftUI

@MainActor
enum PSAAveraging {

    /// Publishes an averaged result as the current epoched signal.
    ///
    /// `statusMessage` is composed by the caller: it is user-facing prose built
    /// from diagnostics the view already formats, and pushing that in here would
    /// drag the formatting along with it for no gain.
    static func commit(
        averaged display: PSABuildResult,
        sourceSegmentCount: Int,
        excludedSegmentCount: Int,
        statusMessage: String,
        epoching: EpochingViewModel,
        segHealth: SegmentHealthViewModel,
        store: RecordingStore
    ) {
        epoching.epochedSignal = display.signal
        epoching.epochSegments = display.segments
        epoching.isAveraged = true

        // Labels are kept, unlike a full epoch teardown: the segments the user
        // labelled are the ones that went into this average, so the labels still
        // describe something real.
        segHealth.clearAnalysis(hide: true, clearLabels: false)

        // Sample-indexed UI state refers to the pre-average signal's timeline,
        // which the averaged signal does not share.
        store.selection.selectedSampleRange = nil
        store.selection.dragSelectionStartSample = nil
        store.selection.dragSelectionEndSample = nil
        store.selection.topomapSample = nil
        epoching.butterflyTopomapRelativeSample = nil
        store.events.selectedEventCodes.removeAll()
        store.horizontalScrollPosition.scrollTo(x: 0)

        var summary = epoching.psaExclusionSummary
        // A raw-epoch build that never ran a rejection pass leaves this at zero;
        // everything that went in was accepted.
        if summary.acceptedEpochs == 0 {
            summary.acceptedEpochs = sourceSegmentCount
        }
        summary.skippedLabeledBadSegments = excludedSegmentCount
        summary.outputSegments = display.segments.count
        epoching.psaExclusionSummary = summary

        epoching.statusMessage = statusMessage
    }
}
