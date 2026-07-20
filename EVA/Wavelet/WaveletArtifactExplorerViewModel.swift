//
//  WaveletArtifactExplorerViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
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
    }
}
