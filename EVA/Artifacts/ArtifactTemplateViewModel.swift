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
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

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
    @Published var waveformStretchRange = 0.0
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
    @Published var trajectoryScaleRange = 0.0
    @Published var trajectoryGFPWeighted = true
    /// `frameIndex` values (see `ArtifactTrajectoryFrame.id`) of map-sequence
    /// frames the user has removed because they don't fit the artifact —
    /// excluded from spatial-correlation scoring, not just hidden from display.
    @Published var trajectoryExcludedFrameIndices: Set<Int> = []
    /// Whether "Save JSON…" should include map-sequence frames the user
    /// removed via the frame strip. Off by default: a removed frame no longer
    /// contributes to scoring, so leaving it out of the exported reference
    /// keeps the file consistent with what was actually matched against.
    @Published var trajectorySaveJSONIncludesRemovedFrames = false

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
    /// Precomputed hover-preview data, keyed by `ArtifactCleaningPreview.cacheKey`.
    /// Populated right after Apply finishes (see `applyArtifactCleaning(to:)`)
    /// so hovering the preview button is a lookup, not a live recompute.
    @Published var cleaningPreviewCache = [String: ArtifactCleaningPreviewData]()

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
