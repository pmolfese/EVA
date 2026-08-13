//
//  ArtifactViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
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
    /// Owns the in-flight detection run: only the newest may publish, and the
    /// cancellation path cannot silently skip clearing `isDetecting`.
    ///
    /// Replaces a hand-written request-id guard that shipped the intermittent
    /// "blinks never appear, spinner stuck on" bug. See `LatestOnlyRunner`.
    ///
    /// `@ObservationIgnored` because it is bookkeeping: no view reads it, and
    /// tracking it would invalidate views on every detection start.
    @ObservationIgnored let detectionRunner = LatestOnlyRunner()

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
        // Disown any in-flight detection so a run started for the recording being
        // closed cannot publish its results into the reused view model.
        detectionRunner.invalidate()
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
