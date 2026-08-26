//
//  PipelineSnapshotTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Undo/redo: `REWIND.md` work item 1's interactive half. Clicking a node
//  restores that point in the history from a snapshot rather than re-running the
//  chain, so the common case is instant.
//
//  The failure that matters here is **partial restore** — a stage the snapshot
//  forgot leaves the pipeline in a state that never existed, mixing one node's
//  filter output with another's ICA. That is silently wrong data, so the
//  round-trip test below checks every stage rather than a representative few.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct PipelineSnapshotTests {

    @MainActor
    private struct Pipeline {
        let store = RecordingStore()
        let gradient: GradientViewModel
        let bcg: BCGDetectionViewModel
        let ica: ICAViewModel
        let filter: FilterViewModel
        let wavelet: WaveletReductionViewModel
        let artifactVM: ArtifactViewModel
        let template: ArtifactTemplateViewModel
        let segHealth: SegmentHealthViewModel
        let epoching: EpochingViewModel

        init() {
            gradient = GradientViewModel(store: store)
            bcg = BCGDetectionViewModel(store: store)
            ica = ICAViewModel(store: store)
            filter = FilterViewModel(store: store)
            wavelet = WaveletReductionViewModel(store: store)
            artifactVM = ArtifactViewModel(store: store)
            template = ArtifactTemplateViewModel(store: store)
            segHealth = SegmentHealthViewModel(store: store)
            epoching = EpochingViewModel(store: store)
        }

        func capture() -> PipelineSnapshot {
            PipelineSnapshotting.capture(
                store: store, gradient: gradient, bcg: bcg, ica: ica,
                filter: filter, wavelet: wavelet, artifactVM: artifactVM, template: template,
                epoching: epoching
            )
        }

        func restore(_ snapshot: PipelineSnapshot) {
            PipelineSnapshotting.restore(
                snapshot,
                store: store, gradient: gradient, bcg: bcg, ica: ica,
                filter: filter, wavelet: wavelet, artifactVM: artifactVM, template: template,
                segHealth: segHealth, epoching: epoching
            )
        }
    }

    private func signal(_ marker: Float, channels: Int = 2, samples: Int = 64) -> MFFSignalData {
        SyntheticSignal.make(
            (0..<channels).map { channel in
                (0..<samples).map { _ in marker + Float(channel) }
            },
            samplingRate: 100
        )
    }

    private func segment(_ category: String) -> EpochSegment {
        EpochSegment(
            startSample: 0, endSample: 3, stimulusOffsetSamples: 0,
            category: category, sourceCode: category, sourceTimeSeconds: 0,
            colorIndex: 0, contributingEpochCount: 1
        )
    }

    /// Fills every stage with a distinguishable value, so a forgotten field
    /// cannot pass by coincidence.
    private func fillEveryStage(_ p: Pipeline) {
        p.gradient.correctedSignal = signal(1)
        p.gradient.correctedPNSSignal = signal(2)
        p.bcg.correctedSignal = signal(3)
        p.ica.cleanedSignal = signal(4)
        p.filter.output = signal(5)
        p.filter.pnsOutput = signal(6)
        p.wavelet.reducedSignal = signal(7)
        p.wavelet.isEnabled = true
        p.artifactVM.cleanedSignal = signal(8)
        p.artifactVM.cleaningIsEnabled = false
        p.epoching.epochedSignal = signal(9)
        p.epoching.epochSegments = [segment("LC++")]
        p.epoching.isAveraged = true
        p.epoching.segmentedEpochSignal = signal(10)
        p.epoching.segmentedEpochSegments = [segment("RC++"), segment("LI++")]
        p.store.channels.bad = [3, 11]
        p.store.channels.replaceInterpolations(
            [7: [1, 2, 3]],
            sources: [7: (indices: [1, 2], weights: [0.5, 0.5])]
        )
    }

    // MARK: - The load-bearing round trip

    /// Every stage comes back. A field the snapshot forgets would leave the
    /// pipeline mixing two nodes' outputs — wrong data with no error.
    @Test func everyStageSurvivesCaptureAndRestore() {
        let source = Pipeline()
        fillEveryStage(source)
        let snapshot = source.capture()

        let target = Pipeline()
        target.restore(snapshot)

        #expect(target.gradient.correctedSignal?.data[0].first == 1)
        #expect(target.gradient.correctedPNSSignal?.data[0].first == 2)
        #expect(target.bcg.correctedSignal?.data[0].first == 3)
        #expect(target.ica.cleanedSignal?.data[0].first == 4)
        #expect(target.filter.output?.data[0].first == 5)
        #expect(target.filter.pnsOutput?.data[0].first == 6)
        #expect(target.wavelet.reducedSignal?.data[0].first == 7)
        #expect(target.wavelet.isEnabled)
        #expect(target.artifactVM.cleanedSignal?.data[0].first == 8)
        #expect(!target.artifactVM.cleaningIsEnabled)
        #expect(target.epoching.epochedSignal?.data[0].first == 9)
        #expect(target.epoching.epochSegments.map(\.category) == ["LC++"])
        #expect(target.epoching.isAveraged)
        #expect(target.epoching.segmentedEpochSignal?.data[0].first == 10)
        #expect(target.epoching.segmentedEpochSegments.count == 2)
        #expect(target.store.channels.bad == [3, 11])
        #expect(target.store.channels.interpolated[7] == [1, 2, 3])
        #expect(target.store.channels.interpolationSources[7]?.indices == [1, 2])
    }

    /// Restoring an *empty* snapshot has to clear stages, not leave them — going
    /// back to `raw` means the filter output is gone, not stale.
    @Test func restoringAnEmptySnapshotClearsEveryStage() {
        let p = Pipeline()
        let empty = Pipeline().capture()
        fillEveryStage(p)

        p.restore(empty)

        #expect(p.gradient.correctedSignal == nil)
        #expect(p.bcg.correctedSignal == nil)
        #expect(p.ica.cleanedSignal == nil)
        #expect(p.filter.output == nil)
        #expect(p.wavelet.reducedSignal == nil)
        #expect(p.artifactVM.cleanedSignal == nil)
        #expect(p.epoching.epochedSignal == nil)
        #expect(p.epoching.epochSegments.isEmpty)
        #expect(!p.epoching.isAveraged)
        #expect(p.store.channels.bad.isEmpty)
        #expect(p.store.channels.interpolated.isEmpty)
    }

    /// Sample-indexed UI state refers to whichever signal was showing, and the
    /// restored one may be a different length.
    /// Segment health is a verdict about a segment set that navigation changes.
    /// Left up, it silently re-scores continuous windows and — because nearly
    /// every metric is relative to the recording's own distribution, and the one
    /// absolute one is artifact overlap, which restore has just emptied — comes
    /// back green. Reported as "going from segments to filtered re-runs the
    /// segment quality check and marks the whole recording green."
    @Test func restoringTakesDownTheSegmentHealthVerdict() {
        let p = Pipeline()
        p.segHealth.shows = true
        p.segHealth.signature = "stale"
        p.segHealth.setQualityLabel(SegmentQualityLabel.bad, for: "epoch-3")

        p.restore(PipelineSnapshot())

        #expect(p.segHealth.shows == false)
        #expect(p.segHealth.analysis == nil)
        #expect(p.segHealth.signature == nil)
        // Accept/reject marks are the operator's decisions, not derived state,
        // so they survive and reappear when their segments do.
        #expect(p.segHealth.qualityLabels["epoch-3"] == SegmentQualityLabel.bad)
    }

    @Test func restoringClearsSampleIndexedUIState() {
        let p = Pipeline()
        p.store.selection.selectedSampleRange = 10...20
        p.store.selection.topomapSample = 15
        p.epoching.butterflyTopomapRelativeSample = 5
        let tokenBefore = p.artifactVM.detectionRefreshToken

        p.restore(Pipeline().capture())

        #expect(p.store.selection.selectedSampleRange == nil)
        #expect(p.store.selection.topomapSample == nil)
        #expect(p.epoching.butterflyTopomapRelativeSample == nil)
        #expect(p.artifactVM.events.isEmpty)
        #expect(p.artifactVM.detectionRefreshToken == tokenBefore + 1,
                "detection ran against a signal that may no longer be showing")
    }

    @Test func estimatedBytesCountsTheSampleData() {
        let p = Pipeline()
        #expect(p.capture().estimatedBytes == 0)

        p.filter.output = signal(1, channels: 4, samples: 1_000)
        let bytes = p.capture().estimatedBytes
        #expect(bytes == 4 * 1_000 * MemoryLayout<Float>.size)
    }

    // MARK: - Storage, budget, and the navigation guard

    private func history(_ model: RecordingHistoryModel, steps: [EVAProcessingStep.Operation]) {
        var script = EVAProcessingScript()
        for (index, operation) in steps.enumerated() {
            script.append(EVAProcessingStep(operation: operation, parameters: ["n": "\(index)"]))
        }
        model.record(recordingKey: "r", script: script)
    }

    @Test func snapshotsAreFiledUnderTheCurrentNode() {
        let model = RecordingHistoryModel()
        let p = Pipeline()
        history(model, steps: [.filter])
        p.filter.output = signal(1)
        model.storeSnapshot(p.capture())

        let filterNode = model.history.currentID
        #expect(model.hasSnapshot(for: filterNode))
        #expect(model.snapshot(for: filterNode)?.filterOutput?.data[0].first == 1)
        #expect(!model.hasSnapshot(for: model.history.rootID), "root was never visited")
    }

    /// Over budget, the oldest go — but never the current node, because that is
    /// the state on screen and dropping it makes away-and-back slow for nothing.
    @Test func evictionDropsOldestButKeepsTheCurrentNode() {
        let model = RecordingHistoryModel()
        let p = Pipeline()
        p.filter.output = signal(1, channels: 1, samples: 1_000)   // 4 KB
        model.snapshotByteBudget = 6_000

        history(model, steps: [.filter])
        let first = model.history.currentID
        model.storeSnapshot(p.capture())

        history(model, steps: [.filter, .segment])
        let second = model.history.currentID
        model.storeSnapshot(p.capture())

        #expect(!model.hasSnapshot(for: first), "the oldest was evicted")
        #expect(model.hasSnapshot(for: second), "the current node is exempt")
    }

    /// Restoring changes every stage output, which trips the observer that folds
    /// the chain back into the tree. Without the guard, that observer would move
    /// the pointer straight to the tip and undo the navigation.
    @Test func recordingIsSuppressedWhileNavigating() {
        let model = RecordingHistoryModel()
        history(model, steps: [.filter])
        let filterNode = model.history.currentID
        history(model, steps: [.filter, .segment])
        let tip = model.history.currentID
        #expect(model.history.currentID == tip)

        _ = model.beginNavigation(to: filterNode)
        #expect(model.isNavigating)
        #expect(model.history.currentID == filterNode)

        // The observer fires mid-restore with the *old* chain still derivable.
        history(model, steps: [.filter, .segment])
        #expect(model.history.currentID == filterNode, "navigation must survive the observer")

        model.endNavigation()
        #expect(!model.isNavigating)
    }

    /// The bug that made undo look destructive: the rail rendered only
    /// `currentPath`, so stepping back to `raw` hid every step after it. The
    /// nodes were still in the tree and redo still worked — but nothing on
    /// screen said so, which is indistinguishable from having lost them.
    @Test func railKeepsShowingDescendantsAfterSteppingBack() {
        let model = RecordingHistoryModel()
        history(model, steps: [.filter])
        let filterNode = model.history.currentID
        history(model, steps: [.filter, .artifactClean])

        #expect(model.railNodes(rawSubtitle: "raw").count == 3)

        _ = model.beginNavigation(to: model.history.rootID)
        model.endNavigation()

        let rows = model.railNodes(rawSubtitle: "raw")
        #expect(rows.count == 3, "stepping back must not hide what comes after")
        #expect(rows.filter(\.isCurrent).map(\.title) == ["raw"])
        #expect(rows.filter { !$0.isOnCurrentPath }.count == 2,
                "the steps ahead are off-path, not gone")
        #expect(model.canStepForward, "redo is available")
        #expect(model.stepForwardTarget == filterNode)
    }

    /// A replacement after undo discards the abandoned descendant, leaving the
    /// ordinary one-window rail linear. Deliberate alternatives live in forked
    /// recording windows instead of as hidden siblings here.
    @Test func railStaysLinearWhenAnUndoneStepIsReplaced() {
        let model = RecordingHistoryModel()
        history(model, steps: [.filter, .segment])
        #expect(model.railNodes(rawSubtitle: "raw").allSatisfy { $0.depth == 0 })

        // Go back and take a different second step — a real fork.
        let filterNode = model.railNodes(rawSubtitle: "raw")[1].id
        _ = model.beginNavigation(to: EVAHistoryNodeID(hex: filterNode))
        model.endNavigation()
        var forked = EVAProcessingScript()
        forked.append(EVAProcessingStep(operation: .filter, parameters: ["n": "0"]))
        forked.append(EVAProcessingStep(operation: .waveletReduce, parameters: ["n": "9"]))
        model.record(recordingKey: "r", script: forked)

        let rows = model.railNodes(rawSubtitle: "raw")
        #expect(rows.count == 3, "root, filter, and only the replacement step")
        #expect(rows.allSatisfy { $0.depth == 0 })
        #expect(rows.last?.title == "wavelet reduction")
    }

    /// The budget is a fraction of this machine, not a constant. A flat 2 GB was
    /// several snapshots on a small Mac and nothing on a large one — and it made
    /// the app swap on a 129-channel recording, where one signal is ~276 MB.
    @Test func theDefaultBudgetScalesWithPhysicalMemory() {
        let budget = RecordingHistoryModel.defaultSnapshotByteBudget
        #expect(budget >= 384_000_000)
        #expect(budget <= 3_000_000_000)
        #expect(budget <= Int(ProcessInfo.processInfo.physicalMemory) / 4,
                "must stay well clear of what the live pipeline needs")
    }

    /// Size is not the only way to accumulate. A short recording can produce
    /// hundreds of nodes without ever approaching the byte budget.
    @Test func theCountLimitEvictsEvenWhenSnapshotsAreTiny() {
        let model = RecordingHistoryModel()
        let p = Pipeline()
        model.snapshotCountLimit = 3
        p.filter.output = signal(1, channels: 1, samples: 4)

        let operations: [EVAProcessingStep.Operation] = [
            .filter, .waveletReduce, .thresholdArtifactDetection,
            .markBad, .segment, .average
        ]
        for depth in 1...operations.count {
            var script = EVAProcessingScript()
            for (index, operation) in operations.prefix(depth).enumerated() {
                script.append(EVAProcessingStep(operation: operation, parameters: ["n": "\(index)"]))
            }
            model.record(recordingKey: "r", script: script)
            model.storeSnapshot(p.capture())
        }

        #expect(model.snapshotCount <= 3)
        #expect(model.hasSnapshot(for: model.history.currentID), "current is exempt")
    }

    @Test func replacingAnUndoneBranchDiscardsItsSnapshots() {
        let model = RecordingHistoryModel()
        let p = Pipeline()
        var oldScript = EVAProcessingScript()
        oldScript.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "0.1"]))
        model.record(recordingKey: "r", script: oldScript)
        let oldFilter = model.history.currentID
        model.storeSnapshot(p.capture())

        model.record(recordingKey: "r", script: EVAProcessingScript())
        #expect(model.hasSnapshot(for: oldFilter), "undo keeps the redo snapshot")

        var replacement = EVAProcessingScript()
        replacement.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1"]))
        model.record(recordingKey: "r", script: replacement)

        #expect(model.history.node(oldFilter) == nil)
        #expect(!model.hasSnapshot(for: oldFilter))
    }

    @Test func navigatingToAnUnknownNodeDoesNothing() {
        let model = RecordingHistoryModel()
        history(model, steps: [.filter])
        let before = model.history.currentID

        let snapshot = model.beginNavigation(to: EVAHistoryNodeID(hex: "deadbeef"))

        #expect(snapshot == nil)
        #expect(!model.isNavigating)
        #expect(model.history.currentID == before)
    }

    /// Step targets drive the transport buttons' enabled state.
    @Test func stepTargetsFollowTheCurrentNode() {
        let model = RecordingHistoryModel()
        history(model, steps: [.filter])
        let filterNode = model.history.currentID
        history(model, steps: [.filter, .segment])

        #expect(model.canStepBack)
        #expect(model.stepBackTarget == filterNode)
        #expect(!model.canStepForward, "already at the tip")

        _ = model.beginNavigation(to: filterNode)
        model.endNavigation()
        #expect(model.canStepForward)
    }
}
