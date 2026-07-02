//
//  ArtifactTemplateViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the "Define Artifact" template-detection domain (waveform +
//  topography + trajectory matching, the defined-artifact list, and scan
//  state), extracted from WaveformView (REFACTOR.md — analysis-domain slice).
//  State-ownership extraction: the store owns the domain's state; WaveformView
//  still drives the scan/apply orchestration (engine `ArtifactTemplateDetector`
//  is L3).
//

import Combine
import SwiftUI

@MainActor
final class ArtifactTemplateViewModel: ObservableObject {
    // MARK: Sheet / definition
    @Published var showsSheet = false
    @Published var selectionRange: ClosedRange<Int>?
    @Published var clickedChannel: Int?
    @Published var type = DefinedArtifactType.ocular
    @Published var definedArtifactID: DefinedArtifact.ID?
    @Published var name = "Eye Blink"
    @Published var eventCode = "Eye Blink"
    @Published var definitionPanel = ArtifactDefinitionPanel.waveforms
    @Published var confirmedSource: ArtifactDefinitionResultSource?

    // MARK: Matching parameters
    @Published var channelScope = ArtifactTemplateChannelScope.clickedChannel
    @Published var customChannels = ""
    @Published var threshold = 0.70
    @Published var windowSeconds = 0.40
    @Published var downsampleRate = 250.0
    @Published var mergeWindowSeconds = 0.25
    @Published var polarity = ArtifactTemplatePolarity.same

    // MARK: Topography
    @Published var topographyMode = ArtifactTopographyMode.off
    @Published var topographyChannelScope = ArtifactTopographyChannelScope.allGood
    @Published var topographyChannelSetID: ChannelSet.ID?
    @Published var topographyTopN = 16
    @Published var topographyMetric = ArtifactTopographyMetric.pearson
    @Published var isRefreshingTopography = false
    @Published var topographyRefreshGeneration = 0

    // MARK: Trajectory
    @Published var trajectoryShiftSeconds = 0.05
    @Published var trajectoryScaleRange = 0.10
    @Published var trajectoryGFPWeighted = true
    @Published var trajectorySelectedFrame: ArtifactTrajectoryFrame?

    // MARK: Scan / run state
    @Published var lastScanSignature: ArtifactScanSignature?
    @Published var isApplying = false
    @Published var scanCompleted = 0
    @Published var scanTotal = 0
    @Published var result: ArtifactTemplateDetectionResult?
    @Published var selectedChannel: Int?
    @Published var statusMessage: String?

    // MARK: Defined-artifact list
    @Published var definedArtifacts: [DefinedArtifact] = []
    @Published var deletionRequest: DefinedArtifact.ID?
    @Published var deleteAllRequest = 0
    @Published var obsVarianceReportCache = [String: OBSPCAVarianceReport]()
}
