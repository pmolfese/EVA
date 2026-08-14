//
//  PipelineSnapshot.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Every stage output the pipeline is currently holding, as one value — so
//  clicking a node in the history rail can put the pipeline back exactly where
//  it was, instantly.
//
//  ## Why snapshots rather than re-derivation
//
//  `REWIND.md`'s core model says the step list is the truth and the signal is a
//  cache, which reads as "navigating means re-applying the steps". That is the
//  right model for *reproducing a package elsewhere* — it is what the payload and
//  batch work serves. It is the wrong model for **undo/redo inside a session**,
//  where re-running a gradient correction to answer a click is absurd when the
//  answer is still in memory.
//
//  So navigation restores; only a node whose snapshot has been evicted (or that
//  was never visited in this session) needs re-derivation. That inverts the
//  design's default and makes the common case free.
//
//  ## What this costs
//
//  Less than `REWIND.md`'s 614 MB-per-node figure implies. `MFFSignalData.data`
//  is `[[Float]]` — a Swift array, copy-on-write — so a snapshot holds a
//  *reference* to the same buffer the view model holds. Two nodes that share an
//  unchanged filter output share one allocation. Real memory is only spent on
//  signals nothing else references, i.e. the outputs of stages you have navigated
//  away from, which is exactly the thing worth keeping.
//
//  `estimatedBytes` measures that so a budget can be enforced without guessing —
//  see `RecordingHistoryModel`.
//
//  ## What is deliberately not here
//
//  **View-model parameters.** Restoring the filter's cutoffs, the ICA method, the
//  epoch window, and so on does not need a snapshot: the node's own path already
//  carries every step's parameters, and each view model already has
//  `apply(parameters:)` for exactly this. Duplicating them here would create a
//  second source of truth that could disagree with `eva.xml`.
//
//  **UI state.** Viewport, selection, sheet — those follow from the restore
//  rather than being part of it.
//

import SwiftUI

/// The pipeline's stage outputs and channel decisions at one point in history.
@MainActor
struct PipelineSnapshot {
    // Stage outputs, in canonical chain order.
    var gradientSignal: MFFSignalData?
    var gradientPNSSignal: MFFSignalData?
    var bcgSignal: MFFSignalData?
    var icaSignal: MFFSignalData?
    var filterOutput: MFFSignalData?
    var filterPNSOutput: MFFSignalData?
    var waveletSignal: MFFSignalData?
    var waveletIsEnabled: Bool = false
    var artifactCleanedSignal: MFFSignalData?
    var artifactCleaningIsEnabled: Bool = true
    /// The artifact definitions that produced `artifactCleanedSignal`.
    ///
    /// A decision like `badChannels`, not a sheet parameter — which is why it is
    /// here rather than restored from the step. `artifactClean`'s node address is
    /// computed from these, so defining another artifact and then navigating back
    /// would re-derive the old node with the *new* count and fork away from it.
    /// The step's parameters are a lossy summary and cannot rebuild them.
    var definedArtifacts: [DefinedArtifact] = []

    // Epoching.
    var epochedSignal: MFFSignalData?
    var epochSegments: [EpochSegment] = []
    var isAveraged: Bool = false
    var segmentedEpochSignal: MFFSignalData?
    var segmentedEpochSegments: [EpochSegment] = []

    // Channel decisions.
    var badChannels: Set<Int> = []
    var interpolationReplacements: [Int: [Float]] = [:]
    var interpolationSources: [Int: (indices: [Int], weights: [Float])] = [:]

    /// Rough resident size of the sample data this snapshot holds.
    ///
    /// Counts only what a snapshot can be *charged* for — the sample buffers.
    /// It deliberately over-counts shared storage: two snapshots referencing the
    /// same filter output each report its full size, because the alternative is
    /// tracking buffer identity across snapshots, and over-counting only makes
    /// the budget conservative. Under-counting would let memory grow past it.
    var estimatedBytes: Int {
        let signals = [
            gradientSignal, gradientPNSSignal, bcgSignal, icaSignal,
            filterOutput, filterPNSOutput, waveletSignal,
            artifactCleanedSignal, epochedSignal, segmentedEpochSignal
        ]
        var total = signals.compactMap { $0 }.reduce(0) { running, signal in
            running + signal.data.reduce(0) { $0 + $1.count * MemoryLayout<Float>.size }
        }
        total += interpolationReplacements.values.reduce(0) {
            $0 + $1.count * MemoryLayout<Float>.size
        }
        return total
    }
}

@MainActor
enum PipelineSnapshotting {

    /// Captures what the view models are holding right now.
    ///
    /// Free functions over explicitly-passed collaborators, matching
    /// `PipelineInvalidation` and `PipelineStageToggles`: every dependency stays
    /// visible in the signature, so adding a stage forces the compiler to name
    /// each call site that has to supply it — which is what stops a snapshot from
    /// silently omitting a stage and restoring a state that never existed.
    static func capture(
        store: RecordingStore,
        gradient: GradientViewModel,
        bcg: BCGDetectionViewModel,
        ica: ICAViewModel,
        filter: FilterViewModel,
        wavelet: WaveletReductionViewModel,
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel,
        epoching: EpochingViewModel
    ) -> PipelineSnapshot {
        PipelineSnapshot(
            gradientSignal: gradient.correctedSignal,
            gradientPNSSignal: gradient.correctedPNSSignal,
            bcgSignal: bcg.correctedSignal,
            icaSignal: ica.cleanedSignal,
            filterOutput: filter.output,
            filterPNSOutput: filter.pnsOutput,
            waveletSignal: wavelet.reducedSignal,
            waveletIsEnabled: wavelet.isEnabled,
            artifactCleanedSignal: artifactVM.cleanedSignal,
            artifactCleaningIsEnabled: artifactVM.cleaningIsEnabled,
            definedArtifacts: template.definedArtifacts,
            epochedSignal: epoching.epochedSignal,
            epochSegments: epoching.epochSegments,
            isAveraged: epoching.isAveraged,
            segmentedEpochSignal: epoching.segmentedEpochSignal,
            segmentedEpochSegments: epoching.segmentedEpochSegments,
            badChannels: store.channels.bad,
            interpolationReplacements: store.channels.interpolated,
            interpolationSources: store.channels.interpolationSources
        )
    }

    /// Puts the view models back into the captured state.
    ///
    /// Assignment order does not matter — nothing here triggers a cascade,
    /// because these are the *outputs* of stages rather than requests to run
    /// them. That is the property that makes restoring instant: no stage runs,
    /// no invalidation fires, and the derived signal the waveform draws follows
    /// from the values alone.
    ///
    /// Selection and the topomap cursor are cleared because they are sample
    /// indices into whichever signal was showing, and the restored signal may
    /// have a different length — the same reason
    /// `PipelineInvalidation.epochsAndDerived` clears them.
    static func restore(
        _ snapshot: PipelineSnapshot,
        store: RecordingStore,
        gradient: GradientViewModel,
        bcg: BCGDetectionViewModel,
        ica: ICAViewModel,
        filter: FilterViewModel,
        wavelet: WaveletReductionViewModel,
        artifactVM: ArtifactViewModel,
        template: ArtifactTemplateViewModel,
        segHealth: SegmentHealthViewModel,
        epoching: EpochingViewModel
    ) {
        gradient.correctedSignal = snapshot.gradientSignal
        gradient.correctedPNSSignal = snapshot.gradientPNSSignal
        bcg.correctedSignal = snapshot.bcgSignal
        ica.cleanedSignal = snapshot.icaSignal
        filter.output = snapshot.filterOutput
        filter.pnsOutput = snapshot.filterPNSOutput
        wavelet.reducedSignal = snapshot.waveletSignal
        wavelet.isEnabled = snapshot.waveletIsEnabled
        artifactVM.cleanedSignal = snapshot.artifactCleanedSignal
        artifactVM.cleaningIsEnabled = snapshot.artifactCleaningIsEnabled
        template.definedArtifacts = snapshot.definedArtifacts

        epoching.epochedSignal = snapshot.epochedSignal
        epoching.epochSegments = snapshot.epochSegments
        epoching.isAveraged = snapshot.isAveraged
        epoching.segmentedEpochSignal = snapshot.segmentedEpochSignal
        epoching.segmentedEpochSegments = snapshot.segmentedEpochSegments

        store.channels.bad = snapshot.badChannels
        store.channels.replaceInterpolations(
            snapshot.interpolationReplacements,
            sources: snapshot.interpolationSources
        )

        store.selection.selectedSampleRange = nil
        store.selection.dragSelectionStartSample = nil
        store.selection.dragSelectionEndSample = nil
        store.selection.topomapSample = nil
        epoching.butterflyTopomapRelativeSample = nil

        // Artifact detection ran against whichever signal was showing, so its
        // events describe samples that may no longer be on screen.
        artifactVM.events = []
        artifactVM.detectionRefreshToken += 1

        // Segment health is a verdict about a specific set of segments, and
        // navigating changes which segments exist. Leaving it up lets it
        // silently re-score into a different universe: step back from `segment`
        // to `filter` and `epochSegments` empties, so `analysisSegments` falls
        // through to fixed continuous windows with different IDs — a different
        // question, presented as an answer to the old one.
        //
        // It came out **green**, and structurally so. Nearly every metric is
        // scored *relative to this recording's own distribution*, which makes
        // the median window good by construction; the one decisive absolute
        // metric is artifact overlap, and the line above just emptied it. So a
        // stale panel reported a clean recording using the strongest wording it
        // has, at the exact moment it knew least.
        //
        // Hidden rather than merely cleared: `refreshSegmentHealthIfNeeded`
        // re-runs on any signature change while `shows` is true, so clearing
        // alone would recompute the same misleading verdict. This is the same
        // move it already makes for averaged signals, and the same rule as the
        // rest of this file — the light goes off when you leave the room. The
        // operator's own accept/reject labels are decisions, not derived state,
        // so they survive and reappear when the segments do.
        segHealth.clearAnalysis(hide: true, clearLabels: false)
    }
}
