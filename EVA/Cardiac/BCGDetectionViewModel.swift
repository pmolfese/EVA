//
//  BCGDetectionViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the ballistocardiogram (BCG) detection domain, extracted from
//  WaveformView (REFACTOR.md — analysis-domain slice). State-ownership
//  extraction: holds the method selection, parameters, channel-set restriction,
//  and run/refine state; WaveformView still drives the detection orchestration
//  (engines `BCGDetector` / `RWaveDetector` are L3).
//

import Combine
import SwiftUI

@MainActor
final class BCGDetectionViewModel: ObservableObject {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
        method = ProcessingDefaults.shared.bcgDefaultMethod
    }

    // MARK: Presence / sheet
    @Published var detectsArtifacts = false
    @Published var showsSheet = false

    // MARK: Method + shared output
    @Published var method = BCGDetectionMethod.periodicity
    @Published var eventCode = "BCG"
    @Published var windowSeconds = 0.700
    @Published var thresholdSD = 2.5

    // MARK: Heart-rate / band parameters
    @Published var minHR: Double = 40
    @Published var maxHR: Double = 120
    @Published var powerMinHz = 0.8
    @Published var powerMaxHz = 1.5
    @Published var qrsLagMs = 300.0

    // MARK: Spatial-PCA parameters
    @Published var pcaComponents = 1
    @Published var spatialWhiten = false
    @Published var slidingNormalize = true
    @Published var respAdaptive = true

    // MARK: Channel restriction
    @Published var channelSetID: ChannelSet.ID?

    // MARK: CWL regression (direct-correction method — see BCGDetectionMethod.cwlRegression)
    @Published var selectedCWLChannels = Set<Int>()
    @Published var cwlUseEVAFastCWR = false
    @Published var cwlDelayMs = 21.0
    @Published var cwlLagRangeMinMs = -50.0
    @Published var cwlLagRangeMaxMs = 150.0
    @Published var cwlLagStepMs = 10.0
    @Published var cwlWindowSeconds = 4.0
    /// Target rate for the internal CWL regression pass. 0 means full rate.
    @Published var cwlDownsampleTargetHz = 0.0
    @Published var cwlDownsampleFilter = CWLCorrector.DownsampleFilter.windowedSinc
    @Published var cwlUpsampleToOriginalHz = false
    @Published var correctedSignal: MFFSignalData?

    // MARK: Run / refine state
    @Published var isRunning = false
    @Published var progress: Double?
    @Published var status: String?
    @Published var refinedTemplate: [Float]?
    @Published var refinedKeptCount: Int?
    @Published var isRefining = false
    @Published var rejectFraction = 0.20

    func resetForClose() {
        detectsArtifacts = false
        showsSheet = false
        isRunning = false
        progress = nil
        status = nil
        refinedTemplate = nil
        refinedKeptCount = nil
        isRefining = false
        correctedSignal = nil
    }

    // MARK: - eva.xml / log_eva bridge

    var parameters: [String: String] {
        var params: [String: String] = [
            "method": method.rawValue,
            "eventCode": eventCode,
            "windowSeconds": String(format: "%.6f", windowSeconds),
            "thresholdSD": String(format: "%.6f", thresholdSD),
            "minHR": String(format: "%.6f", minHR),
            "maxHR": String(format: "%.6f", maxHR),
            "powerMinHz": String(format: "%.6f", powerMinHz),
            "powerMaxHz": String(format: "%.6f", powerMaxHz),
            "qrsLagMs": String(format: "%.6f", qrsLagMs),
            "pcaComponents": "\(pcaComponents)",
            "spatialWhiten": "\(spatialWhiten)",
            "slidingNormalize": "\(slidingNormalize)",
            "respAdaptive": "\(respAdaptive)",
            "rejectFraction": String(format: "%.6f", rejectFraction),
            "cwlSelectedChannels": selectedCWLChannels.sorted().map { String($0 + 1) }.joined(separator: ","),
            "cwlUseEVAFastCWR": "\(cwlUseEVAFastCWR)",
            "cwlDelayMs": String(format: "%.6f", cwlDelayMs),
            "cwlLagRangeMinMs": String(format: "%.6f", cwlLagRangeMinMs),
            "cwlLagRangeMaxMs": String(format: "%.6f", cwlLagRangeMaxMs),
            "cwlLagStepMs": String(format: "%.6f", cwlLagStepMs),
            "cwlWindowSeconds": String(format: "%.6f", cwlWindowSeconds),
            "cwlDownsampleTargetHz": String(format: "%.6f", cwlDownsampleTargetHz),
            "cwlDownsampleFilter": cwlDownsampleFilter.rawValue,
            "cwlUpsampleToOriginalHz": "\(cwlUpsampleToOriginalHz)"
        ]
        if let channelSetID {
            params["channelSetID"] = channelSetID.uuidString
        }
        if let kept = refinedKeptCount {
            params["refinedKeptCount"] = "\(kept)"
        }
        return params
    }
}
