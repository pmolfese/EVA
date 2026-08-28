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

    /// The `detectionRefreshToken` value the last *completed* detection ran at,
    /// or `nil` if no detector has produced a verdict for this recording.
    ///
    /// Kept as a token rather than a `Bool` so it invalidates itself: every
    /// upstream stage that changes the signal already bumps
    /// `detectionRefreshToken`, and a verdict about the old signal is not a
    /// verdict about the new one. See `hasAssessedArtifacts`.
    private(set) var completedDetectionToken: Int?

    /// Whether artifact detection has produced a verdict describing the signal
    /// as it stands now.
    ///
    /// `events.isEmpty` cannot answer this: it is equally true of "the detectors
    /// ran and this recording is clean" and "nothing has looked yet". Segment
    /// Health scored those identically — as perfect — until ROADMAP RW-1 item 16.
    var hasAssessedArtifacts: Bool { completedDetectionToken == detectionRefreshToken }

    /// Records that a detection run finished and published, whatever it found.
    func recordCompletedDetection() {
        completedDetectionToken = detectionRefreshToken
    }

    // MARK: Threshold detector settings
    /// Two-tab config panel for the threshold-based ocular detector.
    var showsThresholdSheet = false
    var blinkThresholdConfig = EyeArtifactThresholdConfiguration.defaults(for: .blink)
    var movementThresholdConfig = EyeArtifactThresholdConfiguration.defaults(for: .movement)
    /// How many times the threshold configuration has been *committed*.
    ///
    /// The sheet's controls are bound live, so detection re-runs as you drag —
    /// but the processing history must not. Recording every intermediate value
    /// would mint a node per slider tick, and recording none (what the chain
    /// signature did, since it carries no parameters and thresholds produce no
    /// signal of their own) meant a threshold change never reached `eva.xml`'s
    /// lineage at all. Bumping this once when the sheet commits is the middle
    /// answer ROADMAP RW-1 item 5 asks for: one history state per deliberate
    /// edit. A commit whose values did not actually change costs nothing — the
    /// tree is content-addressed, so the identical script resolves to the node
    /// already current.
    var thresholdConfigCommits = 0

    /// Commits the current threshold configuration to the processing history.
    /// Called when the ocular threshold sheet is dismissed or reset.
    func commitThresholdConfiguration() {
        thresholdConfigCommits += 1
    }

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
        completedDetectionToken = nil
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
