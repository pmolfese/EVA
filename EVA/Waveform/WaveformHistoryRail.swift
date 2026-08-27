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

import AppKit
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
        /// The one term that is a *count* rather than a state: threshold values
        /// are parameters, and this signature deliberately carries none, so a
        /// retuned detector would otherwise change nothing observable here and
        /// never reach the history at all. Bumped only when the sheet commits,
        /// so a drag does not mint a node per tick. See
        /// `ArtifactViewModel.thresholdConfigCommits` (ROADMAP RW-1 item 5).
        var thresholdConfigCommits: Int
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
            detectsMovements: detectsEyeMovementArtifacts,
            thresholdConfigCommits: artifactVM.thresholdConfigCommits
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
    /// Returns false when the node has no snapshot: this is the instant path
    /// only. Callers reach it through `requestNavigation(to:)`, which falls back
    /// to `reDeriveHistory` for a node that can honestly be rebuilt and refuses
    /// for one that cannot, rather than silently showing a state that is only
    /// partly the one asked for.
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
        // Set from the path totally, nil included: leaving a commit in place
        // while standing on a node before it is what makes the re-derived script
        // walk the pointer past the node just clicked. The epoch caches the
        // snapshot restores already hold the right samples, so this only has to
        // make the *decision* agree with them.
        epoching.committedTrialExclusion = lights.trialExclusion
        epoching.trialExclusionResolution = nil

        for node in path {
            guard let step = node.step else { continue }
            switch step.operation {
            case .mriGradientCorrection: gradient.apply(parameters: step.parameters)
            case .filter: filter.apply(parameters: step.parameters)
            case .icaClean: ica.apply(parameters: step.parameters)
            case .waveletReduce: wavelet.apply(parameters: step.parameters)
            case .segment: epoching.apply(parameters: step.parameters)
            // Threshold values are part of what the node *is* (they are in its
            // content hash), so navigating to one has to put them back — the
            // detector re-runs off them, and leaving the last-typed values in
            // place would show one node's events under another node's label.
            case .thresholdArtifactDetection:
                artifactVM.blinkThresholdConfig = .fromFlatParameters(
                    step.parameters, prefix: "blink", base: artifactVM.blinkThresholdConfig)
                artifactVM.movementThresholdConfig = .fromFlatParameters(
                    step.parameters, prefix: "movement", base: artifactVM.movementThresholdConfig)
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
        guard let target = EVAHistory.segmentationBuildParent(along: path) else { return nil }

        // A node the file arrived with cannot be reached: the steps in
        // `onDiskPrefix` produced the bytes *before* this session opened them,
        // so there is no snapshot for any of them but the tip, and re-deriving
        // is not available either — the replay source is `recording.signal`,
        // which for an already-processed file is the prefix's *output*, not its
        // input. Refusing is the honest answer; the menu says so rather than
        // silently doing something else. `isReachable` is the same rule every
        // other navigation entry point asks (`reDerivationSource(for:)`).
        guard model.isReachable(target.id, availability: currentReplayPayloadAvailability())
        else { return nil }
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
    ///
    /// A snapshot-less click supersedes any rebuild already running: the older
    /// task is cancelled here, and `LatestOnlyRunner` makes sure it publishes
    /// nothing even if it finishes anyway (RW-1 item 2).
    func requestNavigation(to id: EVAHistoryNodeID) {
        if recordingStore.processingHistory.hasSnapshot(for: id) {
            navigateHistory(to: id)
            return
        }
        historyReDeriveTask?.cancel()
        historyReDeriveTask = Task { await reDeriveHistory(to: id) }
    }

    /// Rebuilds an evicted node's pipeline state by replaying its steps against
    /// the signal this session loaded, then navigates to it.
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
    /// cleaning whose payload sidecar isn't on disk, or a channel interpolation
    /// on a package with no electrode geometry to re-solve it from — is refused
    /// up front rather than silently re-derived without that step, which would
    /// serve a plausible-looking wrong signal. Those nodes stay reachable
    /// only while their snapshot is still cached.
    ///
    /// ## Source, not just steps (RW-1 item 1)
    ///
    /// The replay input is `recording.signal`, which for an already-processed
    /// file is the output of the steps in `eva.xml`, not the recording before
    /// them. Replaying the node's *whole* path against it would apply every
    /// on-disk step a second time — a double filter, a double reference, a
    /// double correction, silently. `reDerivationSource(for:)` owns that rule:
    /// it hands back only the steps downstream of the on-disk prefix, and
    /// refuses outright for a node at or inside the prefix, whose input this
    /// session never had.
    ///
    /// ## Only the newest run commits (RW-1 item 2)
    ///
    /// Rebuilds are minutes long on a large recording, and clicking three rows
    /// in a row starts three of them. The work runs through
    /// `historyReDeriveRunner`, so a superseded run publishes nothing, and the
    /// commit re-checks the recording, the node, and the source signal's
    /// revision before it moves the window — a rebuild whose file was closed or
    /// whose source was reprocessed under it must not land.
    @MainActor
    func reDeriveHistory(to id: EVAHistoryNodeID) async {
        let model = recordingStore.processingHistory
        guard model.history.node(id) != nil, let rawSignal = recording.signal else { return }

        let source = model.reDerivationSource(
            for: id, availability: currentReplayPayloadAvailability()
        )
        guard case .loadedSignal(let steps) = source else {
            channelStatusMessage = source.unavailableReason?.message
            channelStatusIsError = true
            return
        }

        let icaPayload = ICAReplayPayload.read(fromPackage: recording.packageURL)
        let artifactPayload = ArtifactReplayPayload.read(fromPackage: recording.packageURL)

        // Identity of what this rebuild is *for*, captured before the first
        // suspension point and checked again at the commit.
        let recordingKey = recording.packageName
        let sourceRevision = rawSignal.dataRevision
        // Measured, not estimated: this is the only place EVA learns what a
        // node actually costs to produce, and the rail shows no cost hint at
        // all for a node that has never been timed (ROADMAP RW-1 item 7).
        let startedAt = Date()

        isReDerivingHistory = true

        let outcome = await recordingStore.historyReDeriveRunner.run("historyReDerive") { () -> PipelineSnapshot? in
            await deriveSnapshot(
                steps: steps,
                from: rawSignal,
                icaPayload: icaPayload,
                artifactPayload: artifactPayload
            )
        }

        let derived: PipelineSnapshot?
        switch outcome {
        case .superseded:
            // A newer rebuild owns `isReDerivingHistory` and the window now.
            // Touching either would blank a spinner for work still running.
            return
        case .cancelled:
            isReDerivingHistory = false
            return
        case .completed(let value):
            isReDerivingHistory = false
            derived = value
        }

        guard let snapshot = derived else {
            // Something in the path stopped the walk after the pre-check passed
            // — a compatibility mismatch against this signal, most likely.
            // Nothing was touched in the live window, so there's nothing to
            // undo; just say so.
            channelStatusMessage = "Couldn't fully rebuild this point in the history."
            channelStatusIsError = true
            return
        }

        // Commit-safety: the window may have moved on while this ran. Being the
        // newest *run* is not enough — the newest run can still be for a file
        // that has since closed, a node discarded by an abandoned future, or a
        // source signal that was reprocessed underneath it.
        guard recording.packageName == recordingKey,
              recording.signal?.dataRevision == sourceRevision,
              model.history.node(id) != nil,
              recordingStore.processingHistory === model
        else {
            channelStatusMessage = "Discarded a rebuild that finished after this window moved on."
            channelStatusIsError = false
            return
        }

        // Move the pointer, file the freshly-derived snapshot under it (so the
        // next visit is instant), and restore it into the live models — the
        // same restore path an ordinary cached navigation takes.
        // `beginNavigation` returns nil here (no snapshot cached yet); it's
        // called for its side effects — moving the pointer and setting
        // `isNavigating`, which `storeSnapshot` needs so it files under `id`.
        _ = model.beginNavigation(to: id)
        model.recordComputeCost(Date().timeIntervalSince(startedAt), for: id)
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

    /// Runs `steps` against `source` in a throwaway pipeline and captures the
    /// result, or `nil` if the walk could not finish. Publishes nothing: the
    /// caller decides whether this rebuild is still the one the window wants.
    @MainActor
    private func deriveSnapshot(
        steps: [EVAProcessingStep],
        from source: MFFSignalData,
        icaPayload: ICAReplayPayload?,
        artifactPayload: ArtifactReplayPayload?
    ) async -> PipelineSnapshot? {
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
            to: source,
            pnsSignal: recording.pnsSignal,
            icaPayload: icaPayload,
            artifactPayload: artifactPayload
        )
        guard result.remainingSteps.isEmpty else { return nil }

        return PipelineSnapshotting.capture(
            store: throwStore, gradient: throwGradient, bcg: throwBCG, ica: throwICA,
            filter: throwFilter, wavelet: throwWavelet, artifactVM: throwArtifact,
            template: throwTemplate, epoching: throwEpoching
        )
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
            // Without these a forked BrainVision/EDF/Persyst/BESA window cannot
            // read the sidecars this one was granted access to.
            securityScopedURLs: recording.securityScopedURLs,
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
            historyReDeriveTask?.cancel()
            historyReDeriveTask = Task {
                await reDeriveHistory(to: id)
                // Only fork if the re-derivation actually landed on the node.
                guard recordingStore.processingHistory.history.currentID == id else { return }
                forkAndReturn()
            }
        }
    }

    /// What *this* recording brings to a replay, beyond the script it is being
    /// given: its own ICA and artifact sidecars, and electrode coordinates for
    /// re-solving a recorded interpolation.
    ///
    /// Read from the file being processed, never from the file the script came
    /// from — that asymmetry is the safety property. A script copied from
    /// another subject arrives with none of this, so every subject-specific step
    /// correctly stays a decision (ROADMAP RW-1 item 6).
    func currentReplayPayloadAvailability() -> ReplayPayloadAvailability {
        var availability = ReplayPayloadAvailability(
            hasICAPayload: ICAReplayPayload.read(fromPackage: recording.packageURL) != nil,
            hasArtifactPayload: ArtifactReplayPayload.read(fromPackage: recording.packageURL) != nil,
            hasElectrodeGeometry: !(electrodeGeometry?.positions.isEmpty ?? true)
        )
        // A recorded reviewed exclusion is "resolved from this file's own
        // record" exactly when this file's segments still answer to its keys —
        // which is a question about the segments in hand, not about a sidecar.
        if let script = EVAProcessingScriptXML.read(fromPackage: recording.packageURL) {
            availability.resolvedTrialExclusionStepIDs = TrialExclusionResolver.resolvableStepIDs(
                in: script,
                segments: epoching.segmentedEpochSegments.isEmpty
                    ? epoching.epochSegments
                    : epoching.segmentedEpochSegments
            )
        }
        return availability
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
        var digests: [EVAProcessingStep.Operation: String] = [:]
        if ica.cleanedSignal != nil, let payload = ICAComponentRemoval.stagedPayload(ica) {
            digests[.icaClean] = EVAHistory.digest([payload.replayIdentityBytes.base64EncodedString()])
        }
        // Same reason as ICA, one level down: two reviewed exclusions can carry
        // identical criteria and remove different trials. The trial set is the
        // input, so it has to be in the hash (ROADMAP TW-5).
        if let step = epoching.committedTrialExclusion {
            digests[.trialExclusion] = EVAHistory.digest([
                step.trialExclusionIdentityBytes.base64EncodedString()
            ])
        }
        return digests
    }

    /// Rail rows, with the root's subtitle describing the recording itself the
    /// way the figure in `REWIND.md` does: `128 ch · 1000 Hz · 21:04`.
    var historyRailNodes: [HistoryRailNode] {
        recordingStore.processingHistory.railNodes(
            rawSubtitle: rawRecordingSummary,
            availability: currentReplayPayloadAvailability()
        )
    }

    /// Rename a history node — the operator's own name for a point, replacing
    /// the default step rendering (`EVAHistoryNode.displayLabel`).
    ///
    /// An `NSAlert` with a text field rather than a sheet: renaming is a
    /// one-field, one-answer question raised from a context menu inside a
    /// popover, and the window's single-sheet host (`WaveformSheetHost`) would
    /// have to dismiss that popover to present. Same choice, and the same
    /// AppKit prompt, that `confirmChannelRoleEditReset` already makes.
    ///
    /// An empty name clears the label rather than storing one, so "rename back
    /// to the default" needs no separate command.
    func beginRenamingHistoryNode(_ id: EVAHistoryNodeID) {
        let model = recordingStore.processingHistory
        guard let node = model.history.node(id) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename this point"
        alert.informativeText = "Give this point in the history a name. Leave it empty to go back to “\(node.defaultLabel)”."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = node.label ?? ""
        field.placeholderString = node.defaultLabel
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.setLabel(field.stringValue, for: id)
    }

    /// Pin or unpin a node's snapshot, reporting a refusal rather than
    /// silently doing nothing — the allowance exists so pinning cannot quietly
    /// disable the memory budget, which only works if the refusal is visible
    /// (ROADMAP RW-1 item 7).
    func togglePin(_ id: EVAHistoryNodeID) {
        let model = recordingStore.processingHistory
        switch model.setPinned(!model.isPinned(id), for: id) {
        case .pinned:
            channelStatusMessage = "Pinned — this point stays instant while the cache evicts others."
            channelStatusIsError = false
        case .unpinned:
            channelStatusMessage = "Unpinned."
            channelStatusIsError = false
        case .refused(let pinned, let allowance):
            channelStatusMessage = "Can't pin: pinned snapshots already hold \(RecordingHistoryModel.byteSummary(pinned)) of the \(RecordingHistoryModel.byteSummary(allowance)) allowed. Unpin another point first."
            channelStatusIsError = true
        }
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
