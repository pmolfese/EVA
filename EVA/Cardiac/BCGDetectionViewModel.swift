//
//  BCGDetectionViewModel.swift
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
//  L4 store for the ballistocardiogram (BCG) detection domain, extracted from
//  WaveformView (REFACTOR.md — analysis-domain slice). State-ownership
//  extraction: holds the method selection, parameters, channel-set restriction,
//  and run/refine state; WaveformView still drives the detection orchestration
//  (engines `BCGDetector` / `RWaveDetector` are L3).
//

import SwiftUI

nonisolated struct BCGAlgorithmResult: Sendable, Equatable {
    let count: Int
    let bpm: Double?
}

@MainActor
@Observable
final class BCGDetectionViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
        method = ProcessingDefaults.shared.bcgDefaultMethod
    }

    // MARK: Presence / sheet
    var detectsArtifacts = false
    var showsSheet = false

    // MARK: Method + shared output
    var method = BCGDetectionMethod.periodicity
    var eventCode = "BCG"
    var windowSeconds = 0.700
    var thresholdSD = 2.5

    // MARK: Heart-rate / band parameters
    var minHR: Double = 40
    var maxHR: Double = 120
    var powerMinHz = 0.8
    var powerMaxHz = 1.5
    var qrsLagMs = 300.0

    // MARK: Spatial-PCA parameters
    var pcaComponents = 1
    var spatialWhiten = false
    var slidingNormalize = true
    var respAdaptive = true

    // MARK: Channel restriction
    var channelSetID: ChannelSet.ID?

    // MARK: CWL regression (direct-correction method — see BCGDetectionMethod.cwlRegression)
    var selectedCWLChannels = Set<Int>()
    var cwlUseEVAFastCWR = false
    var cwlDelayMs = 21.0
    var cwlLagRangeMinMs = -50.0
    var cwlLagRangeMaxMs = 150.0
    var cwlLagStepMs = 10.0
    var cwlWindowSeconds = 4.0
    /// Target rate for the internal CWL regression pass. 0 means full rate.
    var cwlDownsampleTargetHz = 0.0
    var cwlDownsampleFilter = CWLCorrector.DownsampleFilter.windowedSinc
    var cwlUpsampleToOriginalHz = false
    var correctedSignal: MFFSignalData?

    // MARK: Run / refine state
    var isRunning = false
    var progress: Double?
    var status: String?
    var refinedTemplate: [Float]?
    var refinedKeptCount: Int?
    var isRefining = false
    var rejectFraction = 0.20

    // MARK: Algorithm-comparison preview
    var isEstimating = false
    var algorithmResults: [BCGDetectionMethod: BCGAlgorithmResult] = [:]

    func resetForClose() {
        detectsArtifacts = false
        showsSheet = false
        isRunning = false
        progress = nil
        status = nil
        refinedTemplate = nil
        refinedKeptCount = nil
        isRefining = false
        isEstimating = false
        algorithmResults = [:]
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
