//
//  SingleTrialAnalysisViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the "Single Trial Analysis" domain — extracts per-trial
//  amplitude/latency measures from the raw (pre-average) epochs a PSA
//  segmentation produced, while the file is still open. State-ownership
//  extraction: this VM holds selection/parameters/results; `WaveformView`
//  drives the actual computation via `SingleTrialAnalyzer` (L3).
//

import SwiftUI

/// Whether the analysis runs on one channel directly, or averages a channel
/// set (ROI) into a single series first.
enum SingleTrialChannelScope: String, CaseIterable, Identifiable {
    case singleChannel = "Single Channel"
    case channelSet = "Channel Set (ROI average)"

    var id: String { rawValue }
}

@MainActor
@Observable
final class SingleTrialAnalysisViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Presence
    var showsSheet = false

    // MARK: Selection
    var selectedCategory: String?
    var channelScope = SingleTrialChannelScope.singleChannel
    var selectedChannelIndex: Int?
    var selectedChannelSetID: ChannelSet.ID?
    var showsAllConditionsInButterfly = false

    // MARK: Analysis window (ms, relative to stimulus onset) — nil until the
    // user drag-selects a range on the averaged-trace picker.
    var windowStartMs: Double?
    var windowEndMs: Double?

    // MARK: Parameters
    var adaptiveHalfWidthMs = 10.0
    var splitCount = 2
    var outlierThresholdSD = 3.0
    var distributionChunkCount = 2

    // MARK: Result / run state
    var result: SingleTrialAnalyzer.Result?
    var statusMessage: String?
    var isRunning = false

    var hasWindow: Bool {
        guard let start = windowStartMs, let end = windowEndMs else { return false }
        return end > start
    }

    func resetForClose() {
        showsSheet = false
        selectedCategory = nil
        channelScope = .singleChannel
        selectedChannelIndex = nil
        selectedChannelSetID = nil
        showsAllConditionsInButterfly = false
        windowStartMs = nil
        windowEndMs = nil
        result = nil
        statusMessage = nil
        isRunning = false
    }
}
