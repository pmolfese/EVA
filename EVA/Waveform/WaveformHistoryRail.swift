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
        guard let snapshot = historyModel.beginNavigation(to: id) else {
            // `beginNavigation` moved the pointer and set `isNavigating` even
            // when it found no snapshot to return. Leaving it set would wedge
            // `recordProcessingHistory` off for the rest of the session (it
            // guards on `!isNavigating`), so the refuse path has to clear it
            // too — it was previously only cleared by the `defer` below, which
            // never armed because the guard returned first (2026-08-16).
            historyModel.endNavigation()
            return false
        }
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
    func restoreStageSettings(along path: [EVAHistoryNode]) {
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

    // MARK: - Undo Segmentation

    /// The node "Undo Segmentation" moves to: the parent of the first `segment`
    /// node on the current path, backing up past the `reference` and `baseline`
    /// steps segmentation emits *ahead* of it (see `currentProcessingScript()`
    /// — epoch referencing and baseline correction are settings the upcoming
    /// `segment` consumes, so they are part of the same build and undoing the
    /// build has to leave them behind too).
    ///
    /// `nil` when there is nothing to undo, or when the target cannot honestly
    /// be reached — see `canUndoSegmentation`.
    ///
    /// ## Why undo is navigation and not a teardown
    ///
    /// It used to call `PipelineStageToggles.clearEpochs` and let the
    /// chain-signature observer notice, which produced the opposite of undo.
    /// `record()` re-derives the script from the live view models and `adopt`s
    /// it, and the post-teardown script is **not** a prefix of the pre-teardown
    /// one: PSA's escalation promotes persistently-bad channels to globally bad
    /// and interpolates them (`EpochingViewModel.escalate`), the teardown does
    /// not put `store.channels` back, and `ChannelDecisionSteps.inserted` puts
    /// `markBad`/`interpolateChannels` immediately *before* the first `segment`.
    /// So the chain forked at `markBad`, `apply` minted a fresh node, and the
    /// pointer landed on a new tip — undo visibly moving *forward* in the rail,
    /// leaving one junk branch (with its own snapshot) behind per undo.
    ///
    /// Navigating instead is what `EVAHistory`'s header asks for in as many
    /// words: an undo-shaped action is `stepBack()`, never an appended inverse.
    /// It also fixes a quieter half of the same bug — restoring the target
    /// node's snapshot puts the pre-segmentation bad-channel and interpolation
    /// state back, which the teardown silently left escalated, so undoing
    /// segmentation no longer leaves you with channels marked bad *by* the
    /// segmentation you just undid.
    var undoSegmentationTarget: EVAHistoryNodeID? {
        let model = recordingStore.processingHistory
        let path = model.history.currentPath
        guard let target = EVAHistory.segmentationBuildParent(along: path),
              let index = path.firstIndex(where: { $0.id == target.id })
        else { return nil }

        // A node the file arrived with cannot be reached: the steps in
        // `onDiskPrefix` produced the bytes *before* this session opened them,
        // so there is no snapshot for any of them but the tip, and re-deriving
        // is not available either — `reDeriveHistory` replays from
        // `recording.signal`, which for an already-processed file is the
        // prefix's *output*, not its input. Refusing is the honest answer; the
        // menu says so rather than silently doing something else.
        if !model.onDiskPrefix.isEmpty,
           index <= model.onDiskPrefix.count,
           !model.hasSnapshot(for: target.id) {
            return nil
        }
        return target.id
    }

    var canUndoSegmentation: Bool { undoSegmentationTarget != nil }

    /// Undo Segmentation: navigate to the node the segmentation was built from.
    ///
    /// The segment branch is left intact, so stepping forward again is a real
    /// round trip rather than a rebuild.
    func undoSegmentation() {
        guard let target = undoSegmentationTarget else { return }
        // Task handles are view lifecycle, not domain state — the restore has
        // no way to cancel an SNR pass still running against the epochs we are
        // navigating away from.
        snrTask?.cancel()
        snrTask = nil
        requestNavigation(to: target)
    }

    func stepHistoryBack() {
        guard let target = recordingStore.processingHistory.stepBackTarget else { return }
        requestNavigation(to: target)
    }

    func stepHistoryForward() {
        guard let target = recordingStore.processingHistory.stepForwardTarget else { return }
        requestNavigation(to: target)
    }

    // MARK: - Navigation with re-derivation fallback

    /// The single entry point the rail (click, step back/forward) routes
    /// through. Instant when the node still has a cached snapshot; otherwise
    /// re-derives it from its own step path — see `reDeriveHistory`.
    ///
    /// This is what makes navigation work on large recordings at all. A
    /// snapshot of one 257-channel signal is hundreds of MB and a full node's
    /// worth is multiple GB, so the byte budget (`RecordingHistoryModel`)
    /// evicts everything but the current node almost immediately and every
    /// other node became unclickable — the reported regression (2026-08-16).
    /// `REWIND.md` always named re-derivation as the answer for an evicted
    /// node ("the steps are all there"); this is it.
    func requestNavigation(to id: EVAHistoryNodeID) {
        if recordingStore.processingHistory.hasSnapshot(for: id) {
            navigateHistory(to: id)
            return
        }
        Task { await reDeriveHistory(to: id) }
    }

    /// Rebuilds an evicted node's pipeline state by replaying its step path
    /// from the raw recording, then navigates to it.
    ///
    /// Derived in a **throwaway** set of view models (a fresh `RecordingStore`
    /// and VM set, exactly as `HeadlessBatchProcessor` does), not the live
    /// ones, for one reason: a re-derivation that can only get partway must
    /// not leave the window's real display in a half-rebuilt state. Only a
    /// derivation that completes is committed — captured as a `PipelineSnapshot`,
    /// filed under the node so the next visit is instant, and restored into
    /// the live view models. A partial one changes nothing and says why.
    ///
    /// Faithfulness over reach: a path containing a step this cannot reproduce
    /// exactly — BCG (subject-specific, no re-derive path), ICA or artifact
    /// cleaning whose payload sidecar isn't on disk, or an explicit channel
    /// interpolation (`ProcessingCore` doesn't apply one) — is refused up
    /// front rather than silently re-derived without that step, which would
    /// serve a plausible-looking wrong signal. Those nodes stay reachable
    /// only while their snapshot is still cached.
    @MainActor
    func reDeriveHistory(to id: EVAHistoryNodeID) async {
        let model = recordingStore.processingHistory
        guard model.history.node(id) != nil, let rawSignal = recording.signal else { return }
        let path = model.history.path(to: id)
        let steps = path.compactMap(\.step)

        let icaPayload = ICAReplayPayload.read(fromPackage: recording.packageURL)
        let artifactPayload = ArtifactReplayPayload.read(fromPackage: recording.packageURL)
        if let blocker = firstNonReDerivableStep(
            in: steps, icaPayload: icaPayload, artifactPayload: artifactPayload
        ) {
            channelStatusMessage = "Can't rebuild this step (\(ReplayStepDisplay.label(for: blocker))) from disk — it stays reachable only while its data is still cached."
            channelStatusIsError = true
            return
        }

        isReDerivingHistory = true
        defer { isReDerivingHistory = false }

        let throwStore = RecordingStore()
        let throwFilter = FilterViewModel(store: throwStore)
        let throwGradient = GradientViewModel(store: throwStore)
        let throwICA = ICAViewModel(store: throwStore)
        let throwArtifact = ArtifactViewModel(store: throwStore)
        let throwEpoching = EpochingViewModel(store: throwStore)
        let throwWavelet = WaveletReductionViewModel(store: throwStore)
        let throwTemplate = ArtifactTemplateViewModel(store: throwStore)
        let throwSegHealth = SegmentHealthViewModel(store: throwStore)
        let throwBCG = BCGDetectionViewModel(store: throwStore)

        let core = ProcessingCore(
            store: throwStore,
            filter: throwFilter,
            gradient: throwGradient,
            ica: throwICA,
            artifactVM: throwArtifact,
            epoching: throwEpoching,
            wavelet: throwWavelet,
            template: throwTemplate,
            segHealth: throwSegHealth,
            electrodePositions: recording.electrodeGeometry?.positions ?? [:]
        )

        let result = await core.applyAutoSteps(
            EVAProcessingScript(steps: steps),
            to: rawSignal,
            pnsSignal: recording.pnsSignal,
            icaPayload: icaPayload,
            artifactPayload: artifactPayload
        )

        guard result.remainingSteps.isEmpty else {
            // Something in the path stopped the walk after the pre-check passed
            // — a compatibility mismatch against this signal, most likely.
            // Nothing was touched in the live window, so there's nothing to
            // undo; just say so.
            channelStatusMessage = "Couldn't fully rebuild this point in the history."
            channelStatusIsError = true
            return
        }

        let snapshot = PipelineSnapshotting.capture(
            store: throwStore, gradient: throwGradient, bcg: throwBCG, ica: throwICA,
            filter: throwFilter, wavelet: throwWavelet, artifactVM: throwArtifact,
            template: throwTemplate, epoching: throwEpoching
        )

        // Commit: move the pointer, file the freshly-derived snapshot under it
        // (so the next visit is instant), and restore it into the live models —
        // the same restore path an ordinary cached navigation takes.
        // `beginNavigation` returns nil here (no snapshot cached yet); it's
        // called for its side effects — moving the pointer and setting
        // `isNavigating`, which `storeSnapshot` needs so it files under `id`.
        _ = model.beginNavigation(to: id)
        model.storeSnapshot(snapshot)
        PipelineSnapshotting.restore(
            snapshot,
            store: recordingStore, gradient: gradient, bcg: bcg, ica: ica,
            filter: filter, wavelet: wavelet, artifactVM: artifactVM, template: template,
            segHealth: segHealth, epoching: epoching
        )
        restoreStageSettings(along: model.history.currentPath)
        model.endNavigation()
        channelStatusMessage = "Rebuilt and moved to \(model.history.current.displayLabel)."
        channelStatusIsError = false
    }

    /// The first step in `steps` that `reDeriveHistory` cannot reproduce
    /// exactly, or `nil` if the whole path is re-derivable. See that method
    /// for why each is excluded.
    private func firstNonReDerivableStep(
        in steps: [EVAProcessingStep],
        icaPayload: ICAReplayPayload?,
        artifactPayload: ArtifactReplayPayload?
    ) -> EVAProcessingStep.Operation? {
        for step in steps {
            switch step.operation {
            case .filter, .reference, .baseline, .segment, .waveletReduce,
                 .thresholdArtifactDetection, .mriGradientCorrection, .markBad:
                continue
            case .icaClean where icaPayload != nil:
                continue
            case .artifactClean where artifactPayload != nil:
                continue
            default:
                return step.operation
            }
        }
        return nil
    }

    /// "Fork to New Window" — REWIND.md "Forking to a new window". Opens a
    /// second window on this same file, starting from exactly what is on
    /// screen right now, so it can be edited independently from there.
    ///
    /// Memory copy, not reprocessing: everything pushed here is already in
    /// memory (the tree, the snapshot cache, the live view models' current
    /// outputs, the channel decisions), so nothing gets re-run. The one part
    /// that is not free is the file re-read — `MFFRecording` cannot be shared
    /// between the two windows, because `tearDownForClose()` nils out
    /// `signal`/`pnsSignal` on close, and closing window A must not be able
    /// to rip data out from under window B.
    func forkToNewWindow() {
        let historySeed = recordingStore.processingHistory.forkSeed()
        let liveSnapshot = capturePipelineSnapshot()
        PendingWindowForks.shared.push(PendingWindowForks.Payload(
            packageURL: recording.packageURL,
            historySeed: historySeed,
            liveSnapshot: liveSnapshot,
            channels: recordingStore.channels.copy()
        ))
        openWindow(id: "main")
    }

    /// Fork from a specific node rather than wherever the pointer currently
    /// is — the history rail's per-row "Fork to New Window" context menu
    /// (2026-08-16). Navigates to `id` first (re-deriving it if its snapshot
    /// was evicted, same as an ordinary click), forks from there, then — only
    /// if `id` wasn't already current — returns this window to whatever was
    /// showing before, so right-clicking a past node doesn't leave this
    /// window's own view sitting on it.
    func forkNode(_ id: EVAHistoryNodeID) {
        let previousCurrent = recordingStore.processingHistory.history.currentID

        func forkAndReturn() {
            forkToNewWindow()
            if previousCurrent != id {
                requestNavigation(to: previousCurrent)
            }
        }

        if recordingStore.processingHistory.hasSnapshot(for: id) {
            guard navigateHistory(to: id) else { return }
            forkAndReturn()
        } else {
            Task {
                await reDeriveHistory(to: id)
                // Only fork if the re-derivation actually landed on the node.
                guard recordingStore.processingHistory.history.currentID == id else { return }
                forkAndReturn()
            }
        }
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
