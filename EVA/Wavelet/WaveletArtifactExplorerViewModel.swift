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

import Combine
import SwiftUI

@MainActor
final class WaveletArtifactExplorerViewModel: ObservableObject {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Sheet / run state
    @Published var showsSheet = false
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var statusTitle = ""
    @Published var statusDetail = ""
    @Published var statusMessage: String?
    @Published var log: [WaveletArtifactExplorerLogLine] = []
    @Published var result: WaveletArtifactExplorerResult?
    /// Bumped on every scan start; a completing scan checks it still matches
    /// before publishing, so a stale (cancelled/superseded) run can't clobber
    /// a newer one's results.
    @Published var runGeneration = 0

    // MARK: Scan configuration
    @Published var pipeline = WaveletCleaningPipeline.eeg
    @Published var cleaningMode = WaveletCleaningMode.conservativeLocal
    @Published var intensity = WaveletCleaningMode.conservativeLocal.defaultIntensity
    @Published var channelScope = WaveletExplorerChannelScope.visibleGood
    @Published var downsampleRate = 250.0
    @Published var levelCount = 8
    @Published var thresholdScale = 1.0
    @Published var waveletFamily = WaveletCleaningFamily.bior44
    @Published var thresholdRule = WaveletCleaningThresholdRule.hard
    @Published var thresholdModel = WaveletCleaningThresholdModel.bayesShrink
    @Published var mergeWindowSeconds = 0.10
    @Published var minimumDurationSeconds = 0.02
    @Published var maximumCandidates = 80

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
