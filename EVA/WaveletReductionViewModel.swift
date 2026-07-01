//
//  WaveletReductionViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the wavelet-reduction (HAPPE-style) pipeline stage, extracted
//  from WaveformView (REFACTOR.md slice 3). State-ownership extraction: the
//  store holds the domain's parameters, run state, and reduced outputs;
//  WaveformView still drives the reduction orchestration.
//

import Combine
import SwiftUI

@MainActor
final class WaveletReductionViewModel: ObservableObject {
    // MARK: Results
    @Published var reducedSignal: MFFSignalData?
    @Published var artifact: MFFSignalData?
    @Published var result: WaveletReductionResult?
    @Published var bandVarianceRetained: Double?

    // MARK: Run state
    @Published var isEnabled = true
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var statusMessage: String?

    // MARK: UI state
    @Published var showsSheet = false

    // MARK: Parameters
    @Published var mode = WaveletReductionMode.continuousEEG
    @Published var config = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: 250)
    @Published var coreCount = WaveletReducer.defaultCoreCount
    @Published var candidates: [WaveletReductionCandidate] = []
    @Published var selectedCandidateID: String?

    var isActive: Bool { reducedSignal != nil }

    func clearResults() {
        reducedSignal = nil
        artifact = nil
        result = nil
        bandVarianceRetained = nil
        candidates = []
        selectedCandidateID = nil
    }

    var parameters: [String: String] {
        ["mode": String(describing: mode)]
    }
}
