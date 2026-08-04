//
//  ArtifactTemplateViewModel.swift
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
//  L4 store for the "Define Artifact" template-detection domain (waveform +
//  topography + trajectory matching, the defined-artifact list, and scan
//  state), extracted from WaveformView (REFACTOR.md — analysis-domain slice).
//  State-ownership extraction: the store owns the domain's state; WaveformView
//  still drives the scan/apply orchestration (engine `ArtifactTemplateDetector`
//  is L3).
//

import SwiftUI

@MainActor
@Observable
final class ArtifactTemplateViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Sheet / definition
    var showsSheet = false
    var selectionRange: ClosedRange<Int>?
    var clickedChannel: Int?
    var type = DefinedArtifactType.ocular
    var definedArtifactID: DefinedArtifact.ID?
    var name = "Eye Blink"
    var eventCode = "Eye Blink"
    var definitionPanel = ArtifactDefinitionPanel.waveforms
    var confirmedSource: ArtifactDefinitionResultSource?

    // MARK: Matching parameters
    var channelScope = ArtifactTemplateChannelScope.clickedChannel
    var customChannels = ""
    var threshold = 0.70
    var windowSeconds = 0.40
    var downsampleRate = 250.0
    var mergeWindowSeconds = 0.25
    var mergeBehavior = ArtifactTemplateMergeBehavior.discard
    var waveformStretchRange = 0.0
    var polarity = ArtifactTemplatePolarity.same

    // MARK: Topography
    var topographyMode = ArtifactTopographyMode.off
    var topographyChannelScope = ArtifactTopographyChannelScope.allGood
    var topographyChannelSetID: ChannelSet.ID?
    var topographyTopN = 16
    var topographyMetric = ArtifactTopographyMetric.pearson
    var isRefreshingTopography = false
    var topographyRefreshGeneration = 0

    // MARK: Continuous scan (single-map modes only — see ArtifactTopographyScanStyle)
    var topographyScanStyle = ArtifactTopographyScanStyle.windowed
    var continuousMinDurationSeconds = 0.05
    var continuousMaxDurationSeconds = 0.0
    var continuousSmoothingSeconds = 0.08

    // MARK: Trajectory
    var trajectoryShiftSeconds = 0.05
    var trajectoryScaleRange = 0.0
    var trajectoryGFPWeighted = true
    /// `frameIndex` values (see `ArtifactTrajectoryFrame.id`) of map-sequence
    /// frames the user has removed because they don't fit the artifact —
    /// excluded from spatial-correlation scoring, not just hidden from display.
    var trajectoryExcludedFrameIndices: Set<Int> = []
    /// Whether "Save JSON…" should include map-sequence frames the user
    /// removed via the frame strip. Off by default: a removed frame no longer
    /// contributes to scoring, so leaving it out of the exported reference
    /// keeps the file consistent with what was actually matched against.
    var trajectorySaveJSONIncludesRemovedFrames = false

    // MARK: Scan / run state
    var lastScanSignature: ArtifactScanSignature?
    var isApplying = false
    var scanCompleted = 0
    var scanTotal = 0
    var result: ArtifactTemplateDetectionResult?
    var selectedChannel: Int?
    var statusMessage: String?

    // MARK: Defined-artifact list
    var definedArtifacts: [DefinedArtifact] = []
    var deletionRequest: DefinedArtifact.ID?
    var deleteAllRequest = 0
    var obsVarianceReportCache = [String: OBSPCAVarianceReport]()
    /// Precomputed hover-preview data, keyed by `ArtifactCleaningPreview.cacheKey`.
    /// Populated right after Apply finishes (see `applyArtifactCleaning(to:)`)
    /// so hovering the preview button is a lookup, not a live recompute.
    var cleaningPreviewCache = [String: ArtifactCleaningPreviewData]()

    func resetForClose() {
        showsSheet = false
        selectionRange = nil
        clickedChannel = nil
        definedArtifactID = nil
        confirmedSource = nil
        isRefreshingTopography = false
        topographyRefreshGeneration += 1
        trajectoryExcludedFrameIndices = []
        trajectorySaveJSONIncludesRemovedFrames = false
        lastScanSignature = nil
        isApplying = false
        scanCompleted = 0
        scanTotal = 0
        result = nil
        selectedChannel = nil
        statusMessage = nil
        definedArtifacts = []
        deletionRequest = nil
        obsVarianceReportCache.removeAll()
        cleaningPreviewCache.removeAll()
    }
}
