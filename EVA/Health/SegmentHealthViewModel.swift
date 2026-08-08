//
//  SegmentHealthViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for the segment-health analysis domain, extracted from WaveformView
//  (REFACTOR.md — analysis-domain slice). State-ownership extraction: the store
//  holds the display toggles, analysis result, and run state; WaveformView still
//  drives the analysis orchestration (the engine `SegmentHealthAnalyzer` is L3).
//

import SwiftUI

/// User's manual "this segment is fine / this segment is garbage" call,
/// independent of the automated grade — set via the segment health band's
/// context menu or popover, consulted by PSA averaging's "Skip if labeled
/// Bad" option.
enum SegmentQualityLabel: String, Codable {
    case good, bad
}

@MainActor
@Observable
final class SegmentHealthViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Display
    var shows = false
    var showsMouseOver = false
    var showsDetails = false

    // MARK: Result / run state
    var analysis: SegmentHealthAnalysis?
    var isAnalyzing = false
    var progress = 0.0
    var statusMessage: String?
    var signature: String?
    @ObservationIgnored var task: Task<Void, Never>?

    // MARK: Menu request tokens
    var detailsRequest = 0
    var refreshRequest = 0

    // MARK: Manual quality labels
    /// Keyed by `SegmentHealthAnalyzer.segmentID`. Cleared on file switch along
    /// with `analysis` — segment IDs are derived from sample offsets, so a
    /// stale label could silently collide with an unrelated segment in a
    /// newly-opened recording.
    var qualityLabels: [String: SegmentQualityLabel] = [:]

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
