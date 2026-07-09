//
//  SegmentHealthViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the segment-health analysis domain, extracted from WaveformView
//  (REFACTOR.md — analysis-domain slice). State-ownership extraction: the store
//  holds the display toggles, analysis result, and run state; WaveformView still
//  drives the analysis orchestration (the engine `SegmentHealthAnalyzer` is L3).
//

import Combine
import SwiftUI

/// User's manual "this segment is fine / this segment is garbage" call,
/// independent of the automated grade — set via the segment health band's
/// context menu or popover, consulted by PSA averaging's "Skip if labeled
/// Bad" option.
enum SegmentQualityLabel: String, Codable {
    case good, bad
}

@MainActor
final class SegmentHealthViewModel: ObservableObject {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Display
    @Published var shows = false
    @Published var showsMouseOver = false
    @Published var showsDetails = false

    // MARK: Result / run state
    @Published var analysis: SegmentHealthAnalysis?
    @Published var isAnalyzing = false
    @Published var progress = 0.0
    @Published var statusMessage: String?
    @Published var signature: String?
    @Published var task: Task<Void, Never>?

    // MARK: Menu request tokens
    @Published var detailsRequest = 0
    @Published var refreshRequest = 0

    // MARK: Manual quality labels
    /// Keyed by `SegmentHealthAnalyzer.segmentID`. Cleared on file switch along
    /// with `analysis` — segment IDs are derived from sample offsets, so a
    /// stale label could silently collide with an unrelated segment in a
    /// newly-opened recording.
    @Published var qualityLabels: [String: SegmentQualityLabel] = [:]

    func setQualityLabel(_ label: SegmentQualityLabel?, for segmentID: String) {
        qualityLabels[segmentID] = label
    }

    func clearAnalysis(hide: Bool = false, clearLabels: Bool = false) {
        task?.cancel()
        task = nil
        if hide {
            shows = false
            showsDetails = false
        }
        analysis = nil
        isAnalyzing = false
        progress = 0
        statusMessage = nil
        signature = nil
        if clearLabels {
            qualityLabels.removeAll()
        }
    }

    func resetForClose() {
        clearAnalysis(hide: true, clearLabels: true)
        shows = false
        showsMouseOver = false
    }
}
