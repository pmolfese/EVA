//
//  HistoryReDerivationSourceTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP RW-1 item 1 — on-disk-prefix navigation must be safe.
//
//  A processed MFF opens with its loaded samples already at the tip of
//  `eva.xml`: `recording.signal` is the *output* of the steps in `onDiskPrefix`,
//  not the recording before them. Re-derivation replays a node's steps against
//  that loaded signal, so replaying a whole path would apply every on-disk step
//  a second time — a double filter, a double reference, a double correction,
//  with nothing on screen to say so.
//
//  `RecordingHistoryModel.reDerivationSource(for:)` is the rule: the steps a
//  caller may replay are the ones *after* the prefix, and a node at or inside
//  the prefix has no available input at all and is refused. These tests pin
//  both halves, plus the numeric fact underneath them — that applying a step
//  twice really does produce different samples.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct HistoryReDerivationSourceTests {

    // The reported file's own eva.xml shape: filter → threshold detection →
    // interpolation, all baked into the loaded bytes. See
    // `RecordingHistoryOnDiskPrefixTests`.
    private func filterStep() -> EVAProcessingStep {
        EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "0.1", "lowPassHz": "30"])
    }

    private func referenceStep() -> EVAProcessingStep {
        EVAProcessingStep(
            operation: .reference,
            parameters: Rereferencing.parameters(scheme: .average, domain: .continuous, excluding: [])
        )
    }

    private func detectionStep() -> EVAProcessingStep {
        EVAProcessingStep(
            operation: .thresholdArtifactDetection,
            parameters: ["eyeBlink": "true", "eyeMovement": "true"]
        )
    }

    private func waveletStep() -> EVAProcessingStep {
        EVAProcessingStep(operation: .waveletReduce, parameters: ["strength": "2"])
    }

    /// A model for a file that arrived already filtered, referenced, and
    /// detected, with one live step applied this session.
    private func processedFileModel() -> RecordingHistoryModel {
        let model = RecordingHistoryModel()
        model.seedOnDiskPrefix(
            recordingKey: "josh_pilot.mff",
            steps: [filterStep(), referenceStep(), detectionStep()]
        )
        model.record(
            recordingKey: "josh_pilot.mff",
            script: EVAProcessingScript(steps: [waveletStep()])
        )
        return model
    }

    private func operations(of source: RecordingHistoryModel.ReDerivationSource)
    -> [EVAProcessingStep.Operation]? {
        guard case .loadedSignal(let steps) = source else { return nil }
        return steps.map(\.operation)
    }

    // MARK: - The double-apply the rule exists to prevent

    @Test("A live node re-derives from the loaded signal without replaying one on-disk step")
    func liveNodeReplaysOnlyItsOwnSteps() {
        let model = processedFileModel()
        let liveTip = model.history.currentID

        // The path *is* the whole lineage — that is what makes the naive
        // "replay path(to:)" version wrong.
        let wholePath = model.history.path(to: liveTip).compactMap { $0.step?.operation }
        #expect(wholePath == [.filter, .reference, .thresholdArtifactDetection, .waveletReduce])

        // What may actually be replayed is only what happened after the bytes
        // on disk were produced: no second filter, no second reference, no
        // second detection.
        #expect(operations(of: model.reDerivationSource(for: liveTip)) == [.waveletReduce])
    }

    @Test("Every reachable node's replay excludes the on-disk steps entirely")
    func noNodeEverReplaysAPrefixStep() {
        let model = processedFileModel()
        let prefixOperations: Set<EVAProcessingStep.Operation> =
            [.filter, .reference, .thresholdArtifactDetection]

        for row in model.railNodes(rawSubtitle: "raw") {
            let id = EVAHistoryNodeID(hex: row.id)
            guard let replayed = operations(of: model.reDerivationSource(for: id)) else { continue }
            #expect(
                replayed.allSatisfy { !prefixOperations.contains($0) },
                "\(row.title) would replay an on-disk step against its own output"
            )
        }
    }

    @Test("Applying a filter to already-filtered samples is not a no-op")
    func doubleFilteringChangesTheSamples() async throws {
        // The premise the whole item rests on: a second application is not
        // harmless, so a rebuild that quietly performs one serves a wrong
        // signal that still looks plausible.
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let store = RecordingStore()
        let core = ProcessingCore(
            store: store,
            filter: FilterViewModel(store: store),
            gradient: GradientViewModel(store: store),
            bcg: BCGDetectionViewModel(store: store),
            ica: ICAViewModel(store: store),
            artifactVM: ArtifactViewModel(store: store),
            epoching: EpochingViewModel(store: store),
            wavelet: WaveletReductionViewModel(store: store),
            template: ArtifactTemplateViewModel(store: store),
            segHealth: SegmentHealthViewModel(store: store)
        )

        var once = EVAProcessingScript()
        once.append(filterStep())
        let onceResult = await core.applyAutoSteps(once, to: signal)
        let onceOutput = try #require(onceResult.signal)

        let twiceResult = await core.applyAutoSteps(once, to: onceOutput)
        let twiceOutput = try #require(twiceResult.signal)

        #expect(twiceOutput.data[0] != onceOutput.data[0])
    }

    // MARK: - Nodes at or inside the prefix

    @Test("An interior on-disk node has no source and is not reachable")
    func interiorPrefixNodeIsUnavailable() {
        let model = processedFileModel()
        let path = model.history.currentPath

        // root, filter, reference, detection — everything up to and including
        // the on-disk tip. None of them has a snapshot in this fixture.
        for node in path.prefix(4) {
            #expect(
                model.reDerivationSource(for: node.id).unavailableReason == .producedBeforeThisSession,
                "\(node.displayLabel) claimed a source it does not have"
            )
            #expect(model.isReachable(node.id) == false)
        }
    }

    @Test("A cached snapshot still makes an on-disk node reachable")
    func snapshotKeepsAPrefixNodeReachable() {
        let model = RecordingHistoryModel()
        model.seedOnDiskPrefix(
            recordingKey: "josh_pilot.mff", steps: [filterStep(), detectionStep()]
        )
        // Opening the file snapshots the state it opened in — the prefix tip.
        model.storeSnapshot(PipelineSnapshot())
        let onDiskTip = model.history.currentID

        // Still not *re-derivable* — the rule does not change because a
        // snapshot exists — but reachable, which is what the rail asks.
        #expect(
            model.reDerivationSource(for: onDiskTip).unavailableReason == .producedBeforeThisSession
        )
        #expect(model.isReachable(onDiskTip))
    }

    @Test("The rail marks unreachable on-disk nodes so they are not offered as clicks")
    func railReportsReachability() {
        let model = processedFileModel()
        let rows = model.railNodes(rawSubtitle: "129 ch · 1000 Hz · 9:12")

        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })
        #expect(byTitle[HistoryStepSummary.title(for: .filter)]?.isReachable == false)
        #expect(byTitle[HistoryStepSummary.title(for: .reference)]?.isReachable == false)
        #expect(byTitle[HistoryStepSummary.title(for: .waveletReduce)]?.isReachable == true)
    }

    // MARK: - Files with no on-disk lineage

    @Test("Without an on-disk prefix the whole path is replayable, as before")
    func rawFileReplaysItsWholePath() {
        let model = RecordingHistoryModel()
        model.record(
            recordingKey: "raw_recording.mff",
            script: EVAProcessingScript(steps: [filterStep(), referenceStep(), waveletStep()])
        )

        #expect(
            operations(of: model.reDerivationSource(for: model.history.currentID))
            == [.filter, .reference, .waveletReduce]
        )
        // The root is the loaded signal itself: reachable, with nothing to replay.
        #expect(operations(of: model.reDerivationSource(for: model.history.rootID)) == [])
        #expect(model.isReachable(model.history.rootID))
    }

    @Test("A node whose lineage is not the on-disk prefix is refused rather than guessed")
    func offPrefixLineageIsUnavailable() {
        // A tree carried in from elsewhere (a decoded or copied history) whose
        // leading steps are not this file's prefix. The loaded signal is then
        // the wrong starting point for every node in it, and there is nothing
        // to subtract.
        let model = RecordingHistoryModel()
        model.seedOnDiskPrefix(recordingKey: "josh_pilot.mff", steps: [filterStep()])
        let foreign = EVAHistory(
            recordingKey: "josh_pilot.mff",
            script: EVAProcessingScript(steps: [waveletStep(), detectionStep()])
        )
        model.seedFork(RecordingHistoryModel.ForkSeed(
            recordingKey: "josh_pilot.mff",
            history: foreign,
            snapshots: [:],
            snapshotOrder: [],
            onDiskPrefix: [filterStep()],
            onDiskPayloadDigests: [:]
        ))

        #expect(
            model.reDerivationSource(for: model.history.currentID).unavailableReason
            == .lineageDoesNotMatchFile
        )
        #expect(model.isReachable(model.history.currentID) == false)
    }
}
