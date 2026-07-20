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

import SwiftUI

@MainActor
@Observable
final class ArtifactViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
        let defaults = ProcessingDefaults.shared
        detectionMethod = defaults.artifactDetectionDefaultMethod
        blinkThresholdConfig = defaults.ocularBlinkThresholdConfig
        movementThresholdConfig = defaults.ocularMovementThresholdConfig
    }

    // MARK: Detection
    var detectionMethod = ArtifactDetectionMethod.threshold
    var events: [MFFEvent] = []
    var isDetecting = false
    var statusMessage: String?
    /// Bumped by upstream pipeline stages (filter/gradient) to force a re-detect.
    var detectionRefreshToken = 0

    // MARK: Threshold detector settings
    /// Two-tab config panel for the threshold-based ocular detector.
    var showsThresholdSheet = false
    var blinkThresholdConfig = EyeArtifactThresholdConfiguration.defaults(for: .blink)
    var movementThresholdConfig = EyeArtifactThresholdConfiguration.defaults(for: .movement)

    // MARK: Cleaning
    var showsCleaningSheet = false
    var isCleaning = false
    var cleaningStatusMessage: String?
    var cleaningSummaries: [ArtifactCleaningSummary] = []
    var cleaningProgress: ArtifactCleaningProgress?
    var cleanedSignal: MFFSignalData?
    var cleaningIsEnabled = true

    var isCleaningActive: Bool { cleanedSignal != nil }

    func resetForClose() {
        events = []
        isDetecting = false
        statusMessage = nil
        detectionRefreshToken += 1
        showsThresholdSheet = false
        showsCleaningSheet = false
        isCleaning = false
        cleaningStatusMessage = nil
        cleaningSummaries = []
        cleaningProgress = nil
        cleanedSignal = nil
        cleaningIsEnabled = true
    }
}
