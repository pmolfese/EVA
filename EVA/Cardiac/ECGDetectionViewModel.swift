//
//  ECGDetectionViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the ECG/QRS detection domain, extracted from WaveformView.
//  State-ownership extraction: the store holds the sheet's configuration,
//  algorithm-comparison results, and run state; WaveformView (via
//  ECGDetectionViews.swift) still drives the detection/preview orchestration
//  and reads/writes this store — same shape as `BCGDetectionViewModel`.
//

import Combine
import SwiftUI

@MainActor
final class ECGDetectionViewModel: ObservableObject {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Enablement / sheet
    @Published var isEnabled = false
    @Published var showsSheet = false

    // MARK: Sources
    @Published var selectedPNSChannels = Set<Int>()
    @Published var proxyChannels = ""
    @Published var proxyChannelSetID: ChannelSet.ID?

    // MARK: Detection parameters
    @Published var algorithm = ECGDetectionAlgorithm.panTompkins
    @Published var thresholdSD = 4.0
    @Published var minimumRRSeconds = 0.30
    @Published var polarity = ECGDetectionPolarity.either

    // MARK: Algorithm-comparison preview
    @Published var isEstimating = false
    @Published var algorithmResults: [ECGDetectionAlgorithm: ECGAlgorithmResult] = [:]

    func resetForClose() {
        isEnabled = false
        showsSheet = false
        selectedPNSChannels.removeAll()
        proxyChannels = ""
        proxyChannelSetID = nil
        isEstimating = false
        algorithmResults = [:]
    }
}
