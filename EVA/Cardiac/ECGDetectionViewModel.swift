//
//  ECGDetectionViewModel.swift
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
//  L4 store for the ECG/QRS detection domain, extracted from WaveformView.
//  State-ownership extraction: the store holds the sheet's configuration,
//  algorithm-comparison results, and run state; WaveformView (via
//  ECGDetectionViews.swift) still drives the detection/preview orchestration
//  and reads/writes this store — same shape as `BCGDetectionViewModel`.
//

import SwiftUI

@MainActor
@Observable
final class ECGDetectionViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Enablement / sheet
    var isEnabled = false
    var showsSheet = false

    // MARK: Sources
    var selectedPNSChannels = Set<Int>()
    var proxyChannels = ""
    var proxyChannelSetID: ChannelSet.ID?

    // MARK: Detection parameters
    var algorithm = ECGDetectionAlgorithm.panTompkins
    var thresholdSD = 4.0
    var minimumRRSeconds = 0.30
    var polarity = ECGDetectionPolarity.either

    // MARK: Algorithm-comparison preview
    var isEstimating = false
    var algorithmResults: [ECGDetectionAlgorithm: ECGAlgorithmResult] = [:]

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
