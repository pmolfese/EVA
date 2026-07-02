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

@MainActor
final class SegmentHealthViewModel: ObservableObject {
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
}
