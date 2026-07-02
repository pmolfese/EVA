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
    init() {
        method = BCGDetectionMethod(rawValue: ProcessingDefaults.shared.bcgDefaultMethodRaw) ?? .periodicity
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

    // MARK: Run / refine state
    @Published var isRunning = false
    @Published var status: String?
    @Published var refinedTemplate: [Float]?
    @Published var refinedKeptCount: Int?
    @Published var isRefining = false
    @Published var rejectFraction = 0.20
}
