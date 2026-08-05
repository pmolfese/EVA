//
//  WaveletArtifactExplorerViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the wavelet artifact explorer domain (broad multiscale
//  scanning for transient artifact candidates), extracted from WaveformView.
//  State-ownership extraction: the store holds the scan configuration,
//  progress/log, and results; WaveformView (via WaveletArtifactExplorerViews.swift)
//  still drives the scan orchestration and reads/writes this store — same
//  shape as `WaveletReductionViewModel`, its plain-reduction sibling. The
//  scan's own `Task` handle stays on WaveformView (`waveletExplorerTask`),
//  matching every other domain's async work.
//

import SwiftUI

@MainActor
@Observable
final class WaveletArtifactExplorerViewModel {
    /// `sourceFile` stamped on every `MFFEvent` built from a scan candidate.
    /// Starts with "Continuous" so `MFFEvent.centerTimeSeconds` uses the
    /// onset+duration/2 convention (candidates carry a genuine start/end, not
    /// a pre-centered peak) — see `ArtifactCleaner.swift`'s `MFFEvent`
    /// extension for the two coexisting conventions. Also special-cased in
    /// `isCenteredArtifactDetectionEvent` so the waveform draws the duration
    /// highlight band as soon as a scan finds candidates, before any cleaning
    /// has been applied.
    static let candidateSourceFile = "Continuous Wavelet Explorer"

    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Sheet / run state
    var showsSheet = false
    var isRunning = false
    var progress = 0.0
    var statusTitle = ""
    var statusDetail = ""
    var statusMessage: String?
    var log: [WaveletArtifactExplorerLogLine] = []
    var result: WaveletArtifactExplorerResult?
    /// Bumped on every scan start; a completing scan checks it still matches
    /// before publishing, so a stale (cancelled/superseded) run can't clobber
    /// a newer one's results.
    var runGeneration = 0

    // MARK: Scan configuration
    var pipeline = WaveletCleaningPipeline.eeg
    var cleaningMode = WaveletCleaningMode.conservativeLocal
    var intensity = WaveletCleaningMode.conservativeLocal.defaultIntensity
    var channelScope = WaveletExplorerChannelScope.visibleGood
    var downsampleRate = 250.0
    var levelCount = 8
    var thresholdScale = 1.0
    var waveletFamily = WaveletCleaningFamily.bior44
    var thresholdRule = WaveletCleaningThresholdRule.hard
    var thresholdModel = WaveletCleaningThresholdModel.bayesShrink
    var mergeWindowSeconds = 0.10
    var minimumDurationSeconds = 0.02
    var maximumCandidates = 80

    // MARK: Apply (candidates → ArtifactCleaner)
    /// Candidate IDs the user has unchecked — everything else is included
    /// when Apply runs. Opt-out rather than opt-in so a fresh scan's results
    /// are all queued for cleaning by default.
    var excludedCandidateIDs: Set<String> = []
    /// The `DefinedArtifact` created by a previous Apply, so re-running Apply
    /// (after unchecking/rechecking candidates, or rescanning) updates that
    /// same artifact in place instead of piling up duplicates in
    /// `template.definedArtifacts`.
    var appliedArtifactID: UUID?
    var isApplying = false
    var applyStatusMessage: String?

    // MARK: Preview cache
    /// Populated right after a scan by `precomputeWaveletExplorerPreviews`
    /// (concurrent across candidates), keyed by `WaveletCleaningPreview
    /// .cacheKey`, so opening a candidate's hover preview is a lookup instead
    /// of a fresh wavelet decomposition. Falls back to computing on demand
    /// (`WaveletCleaningPreview.loadPreview`) on a miss — e.g. the precompute
    /// pass is still running, or got cancelled by a rescan.
    var previewCache: [String: WaveletCleaningPreviewResult] = [:]
    var isPrecomputingPreviews = false

    func resetForClose() {
        showsSheet = false
        isRunning = false
        progress = 0
        statusTitle = ""
        statusDetail = ""
        statusMessage = nil
        log = []
        result = nil
        runGeneration = 0
        excludedCandidateIDs = []
        appliedArtifactID = nil
        isApplying = false
        applyStatusMessage = nil
        previewCache = [:]
        isPrecomputingPreviews = false
    }
}
