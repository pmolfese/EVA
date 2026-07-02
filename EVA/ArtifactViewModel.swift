//
//  ArtifactViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the artifact detection + cleaning domain, extracted from
//  WaveformView (REFACTOR.md slice 5). State-ownership extraction: the store
//  holds detection method/events, cleaning state, and the cleaned output;
//  WaveformView still drives the detection/cleaning orchestration. (The separate
//  "Define Artifact" template domain is slice 10, not here.)
//

import Combine
import SwiftUI

@MainActor
final class ArtifactViewModel: ObservableObject {
    // MARK: Detection
    @Published var detectionMethod = ArtifactDetectionMethod.threshold
    @Published var events: [MFFEvent] = []
    @Published var isDetecting = false
    @Published var statusMessage: String?
    /// Bumped by upstream pipeline stages (filter/gradient) to force a re-detect.
    @Published var detectionRefreshToken = 0

    // MARK: Threshold detector settings
    /// Two-tab config panel for the threshold-based ocular detector.
    @Published var showsThresholdSheet = false
    @Published var blinkThresholdConfig = EyeArtifactThresholdConfiguration.defaults(for: .blink)
    @Published var movementThresholdConfig = EyeArtifactThresholdConfiguration.defaults(for: .movement)

    // MARK: Cleaning
    @Published var showsCleaningSheet = false
    @Published var isCleaning = false
    @Published var cleaningStatusMessage: String?
    @Published var cleaningSummaries: [ArtifactCleaningSummary] = []
    @Published var cleaningProgress: ArtifactCleaningProgress?
    @Published var cleanedSignal: MFFSignalData?
    @Published var cleaningIsEnabled = true

    var isCleaningActive: Bool { cleanedSignal != nil }
}
