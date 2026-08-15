//
//  WaveformHistoryRail.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Glue between the live pipeline and the History rail: when the processing chain
//  changes, fold `currentProcessingScript()` into `RecordingHistoryModel`'s tree.
//
//  This is the one part of the rail that has to live on `WaveformView` — the
//  domain view models are its `@State`, and `currentProcessingScript()` already
//  reads all eight of them. The rail's *views* are standalone `Equatable` structs
//  taking values (`HistoryRailView`), per ROADMAP B5.
//
//  ## Why a signature rather than recording every pass
//
//  `currentProcessingScript()` walks eight view models and formats ~40 parameter
//  strings — cheap in isolation, but ROADMAP Priority 1 is emphatic that nothing
//  new belongs on the per-body-pass path, and `WaveformView`'s body runs at
//  pointer frequency during a selection drag. So the recording hangs off an
//  `.onChange` of a signature made only of `Bool`s and `UUID`s: whether each
//  stage has output, and the `dataRevision` of the signals that do.
//
//  `dataRevision` is what makes this correct rather than merely cheap. Re-running
//  a stage always produces new sample data and therefore a new revision, so a
//  re-apply with *different* parameters is caught even though the signature never
//  looks at a parameter. The reverse — a parameter edited without applying —
//  correctly changes nothing, because nothing about the signal changed either.
//

import SwiftUI

extension WaveformView {

    /// Identity of the processing chain: which stages are active and which exact
    /// sample data each produced. Deliberately no parameter values — see the
    /// file header.
    ///
    /// A `Hashable` struct of `UUID`s rather than a joined `String`. `.onChange`
    /// evaluates its value on **every body pass**, and `WaveformView`'s body runs
    /// at pointer frequency during a selection drag — so the first version built
    /// ten `uuidString`s, an array, and a joined string tens of times a second
    /// for a value that changes a handful of times per session. Comparing
    /// `UUID`s directly costs nothing and allocates nothing, which is the
    /// standard ROADMAP Priority 1 spent its length establishing.
    struct ProcessingChainSignature: Hashable {
        var raw: UUID?
        var gradient: UUID?
        var bcg: UUID?
        var ica: UUID?
        var filter: UUID?
        var wavelet: UUID?
        var epoched: UUID?
        var cleaningActive: Bool
        var cleaningEnabled: Bool
        var thresholdDetection: Bool
        var detectsBlinks: Bool
        var detectsMovements: Bool
    }

    var processingChainSignature: ProcessingChainSignature {
        ProcessingChainSignature(
            raw: recording.signal?.dataRevision,
            gradient: gradient.correctedSignal?.dataRevision,
            bcg: bcg.correctedSignal?.dataRevision,
            ica: ica.cleanedSignal?.dataRevision,
            filter: filter.output?.dataRevision,
            wavelet: wavelet.reducedSignal?.dataRevision,
            epoched: epoching.epochedSignal?.dataRevision,
            cleaningActive: artifactVM.isCleaningActive,
            cleaningEnabled: artifactVM.cleaningIsEnabled,
            // Threshold detection produces no signal of its own, so it needs its
            // own terms or its step would appear and disappear unnoticed.
            thresholdDetection: artifactVM.detectionMethod == .threshold,
            detectsBlinks: detectsEyeBlinkArtifacts,
            detectsMovements: detectsEyeMovementArtifacts
        )
    }

    /// Folds the current chain into the history tree. Safe to call redundantly:
    /// the model assigns only when the resulting tree actually differs, and
    /// re-adopting an unchanged chain resolves entirely to existing nodes.
    func recordProcessingHistory() {
        let historyModel = recordingStore.processingHistory
        guard !historyModel.isNavigating else { return }
        historyModel.record(
            recordingKey: recording.packageName,
            script: currentProcessingScript(),
            payloadDigests: currentPayloadDigests()
        )
        // Snapshot *after* recording, so it files under the node this state
        // produced rather than the one we came from.
        historyModel.storeSnapshot(capturePipelineSnapshot())
    }

    func capturePipelineSnapshot() -> PipelineSnapshot {
        PipelineSnapshotting.capture(
            store: recordingStore, gradient: gradient, bcg: bcg, ica: ica,
            filter: filter, wavelet: wavelet, artifactVM: artifactVM, template: template,
            epoching: epoching
        )
    }

    /// Navigates to `id` and puts the pipeline back into that state.
    ///
    /// Restores the *outputs* from the snapshot and the *settings* from the
    /// node's own path, so the sheets show the parameters that produced what is
    /// on screen rather than whatever was last typed. The two come from different
    /// places on purpose — the parameters are already in `eva.xml`, and copying
    /// them into the snapshot would create a second source of truth that could
    /// disagree with it.
    ///
    /// Returns false when the node has no snapshot. Re-deriving it is possible —
    /// the steps are all there — but that is the signal cache's job, and until it
    /// exists the honest answer is to refuse rather than to silently show a state
    /// that is only partly the one asked for.
    @discardableResult
    func navigateHistory(to id: EVAHistoryNodeID) -> Bool {
        let historyModel = recordingStore.processingHistory
        guard let snapshot = historyModel.beginNavigation(to: id) else { return false }
        defer { historyModel.endNavigation() }

        PipelineSnapshotting.restore(
            snapshot,
            store: recordingStore, gradient: gradient, bcg: bcg, ica: ica,
            filter: filter, wavelet: wavelet, artifactVM: artifactVM, template: template,
            segHealth: segHealth, epoching: epoching
        )
        restoreStageSettings(along: historyModel.history.currentPath)
        channelStatusMessage = "Moved to \(historyModel.history.current.displayLabel)."
        channelStatusIsError = false
        return true
    }

    /// Replays each step's recorded parameters into its view model, so the
    /// sheets agree with the signal.
    ///
    /// Settings that decide whether a step *exists* are handled separately and
    /// totally, because an absent step cannot say it is absent — leaving one set
    /// makes the observer re-derive a script that still contains the step and
    /// walk the pointer off the node just clicked. See `ReplaySettingsRestore`.
    private func restoreStageSettings(along path: [EVAHistoryNode]) {
        let lights = ReplaySettingsRestore.settings(for: path.compactMap(\.step))
        detectsEyeBlinkArtifacts = lights.detectsBlinks
        detectsEyeMovementArtifacts = lights.detectsMovements
        if lights.selectsThresholdMethod { artifactVM.detectionMethod = .threshold }
        filter.averageReference = lights.continuousReference != nil
        epoching.averageReference = lights.epochReference != nil
        epoching.baselineCorrected = lights.baselineCorrection

        for node in path {
            guard let step = node.step else { continue }
            switch step.operation {
            case .mriGradientCorrection: gradient.apply(parameters: step.parameters)
            case .filter: filter.apply(parameters: step.parameters)
            case .icaClean: ica.apply(parameters: step.parameters)
            case .waveletReduce: wavelet.apply(parameters: step.parameters)
            case .segment: epoching.apply(parameters: step.parameters)
            // BCG has no `apply(parameters:)` — its step is provenance-only and
            // its settings are subject-specific, so there is nothing to restore.
            default: break
            }
        }
    }

    func stepHistoryBack() {
        guard let target = recordingStore.processingHistory.stepBackTarget else { return }
        navigateHistory(to: target)
    }

    func stepHistoryForward() {
        guard let target = recordingStore.processingHistory.stepForwardTarget else { return }
        navigateHistory(to: target)
    }

    /// Subject-specific identity for the steps whose portable parameters do not
    /// determine their output.
    ///
    /// ICA is the case that matters: `eva.xml` records the fit settings, but two
    /// removals differing only in *which components were excluded* carry
    /// identical parameters. Without the operator's digest in the hash they would
    /// collapse to one node, and navigating to it would serve one removal's
    /// cached signal for the other's.
    private func currentPayloadDigests() -> [EVAProcessingStep.Operation: String] {
        guard ica.cleanedSignal != nil,
              let payload = ICAComponentRemoval.stagedPayload(ica) else { return [:] }
        return [.icaClean: EVAHistory.digest([payload.replayIdentityBytes.base64EncodedString()])]
    }

    /// Rail rows, with the root's subtitle describing the recording itself the
    /// way the figure in `REWIND.md` does: `128 ch · 1000 Hz · 21:04`.
    var historyRailNodes: [HistoryRailNode] {
        recordingStore.processingHistory.railNodes(rawSubtitle: rawRecordingSummary)
    }

    private var rawRecordingSummary: String {
        guard let signal = recording.signal else { return "not loaded" }
        var parts = ["\(signal.numberOfChannels) ch"]
        if signal.samplingRate > 0 {
            parts.append("\(Int(signal.samplingRate.rounded())) Hz")
        }
        if signal.duration > 0 {
            parts.append(Self.clockDuration(signal.duration))
        }
        return parts.joined(separator: " · ")
    }

    /// `21:04`, or `1:21:04` past an hour.
    static func clockDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
