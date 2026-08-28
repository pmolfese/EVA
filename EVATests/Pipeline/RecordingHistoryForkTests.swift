//
//  RecordingHistoryForkTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  REWIND.md "Forking to a new window": `RecordingHistoryModel.forkSeed()`/
//  `seedFork(_:)` are what makes a fork "memory copy, not reprocessing" —
//  the new window gets the *whole* tree and snapshot cache, not just the
//  current node, and the two are independent from the moment of the copy.
//
//  These tests exist to pin exactly that independence: `EVAHistory` and the
//  snapshot dictionary are value types, so the isolation guarantee is "did
//  the assignment actually happen," not any explicit defensive-copy code —
//  which is easy to believe works and easy to accidentally break by
//  introducing a reference somewhere later. `ChannelModel.copy()`'s tests
//  are the same shape for the one place the fork *does* need explicit
//  copying, because that one is a reference type.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct RecordingHistoryForkTests {

    private func filterStep() -> EVAProcessingStep {
        EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "0.1"])
    }

    private func waveletStep() -> EVAProcessingStep {
        EVAProcessingStep(operation: .waveletReduce, parameters: ["strength": "2"])
    }

    // MARK: - ForkSeed round-trip

    @Test("A fork seed carries the whole tree, not just the current node")
    func forkSeedCarriesWholeTree() {
        let source = RecordingHistoryModel()
        source.record(recordingKey: "subject.mff", script: EVAProcessingScript(steps: [filterStep()]))
        let filterNode = source.history.currentID
        source.record(
            recordingKey: "subject.mff",
            script: EVAProcessingScript(steps: [filterStep(), waveletStep()])
        )
        let waveletNode = source.history.currentID
        source.storeSnapshot(PipelineSnapshot())

        let target = RecordingHistoryModel()
        target.seedFork(source.forkSeed())

        #expect(target.history == source.history)
        #expect(target.history.node(filterNode) != nil)
        #expect(target.history.node(waveletNode) != nil)
        #expect(target.hasSnapshot(for: waveletNode))
    }

    @Test("A fork seed carries the on-disk prefix too, so a forked window of a processed file still shows its lineage")
    func forkSeedCarriesOnDiskPrefix() {
        let source = RecordingHistoryModel()
        source.seedOnDiskPrefix(recordingKey: "subject.mff", steps: [filterStep()])
        source.record(
            recordingKey: "subject.mff",
            script: EVAProcessingScript(steps: [waveletStep()])
        )

        let target = RecordingHistoryModel()
        target.seedFork(source.forkSeed())

        let operations = target.history.currentPath.compactMap { $0.step?.operation }
        #expect(operations == [.filter, .waveletReduce])
    }

    @Test("After the fork, the two histories are independent — a struct copy, not a shared reference")
    func forkedHistoriesDivergeIndependently() {
        let source = RecordingHistoryModel()
        source.record(recordingKey: "subject.mff", script: EVAProcessingScript(steps: [filterStep()]))
        let sharedTip = source.history.currentID

        let target = RecordingHistoryModel()
        target.seedFork(source.forkSeed())

        // Each window now applies a *different* next step.
        source.record(
            recordingKey: "subject.mff",
            script: EVAProcessingScript(steps: [filterStep(), waveletStep()])
        )
        target.record(
            recordingKey: "subject.mff",
            script: EVAProcessingScript(steps: [filterStep(), EVAProcessingStep(operation: .markBad)])
        )

        #expect(source.history.currentID != target.history.currentID)
        // Both still agree on the shared prefix from before the fork.
        #expect(source.history.current.parent == sharedTip)
        #expect(target.history.current.parent == sharedTip)
        // The source's own new node must not have leaked into the target.
        #expect(target.history.node(source.history.currentID) == nil)
    }

    @Test("Two windows that independently apply the same next step land on the same node id")
    func identicalPostForkStepsHashIdentically() {
        let source = RecordingHistoryModel()
        source.record(recordingKey: "subject.mff", script: EVAProcessingScript(steps: [filterStep()]))

        let target = RecordingHistoryModel()
        target.seedFork(source.forkSeed())

        let script = EVAProcessingScript(steps: [filterStep(), waveletStep()])
        source.record(recordingKey: "subject.mff", script: script)
        target.record(recordingKey: "subject.mff", script: script)

        // Content-addressed, not object-identity-based: the same step at the
        // same parent hashes the same way in both independently-copied trees.
        #expect(source.history.currentID == target.history.currentID)
    }

    // MARK: - ChannelModel.copy()

    @Test("copy() carries bad, hidden, and interpolation state")
    func channelModelCopyCarriesDecisions() {
        let original = ChannelModel()
        original.bad = [3, 7]
        original.hidden = [12]
        original.setInterpolation(target: 3, replacement: [1, 2, 3], sourceIndices: [1, 2], sourceWeights: [0.5, 0.5])

        let clone = original.copy()

        #expect(clone.bad == [3, 7])
        #expect(clone.hidden == [12])
        #expect(clone.interpolated[3] == [1, 2, 3])
        #expect(clone.interpolationSources[3]?.indices == [1, 2])
    }

    @Test("copy() does not carry health results — session-only derived state")
    func channelModelCopyOmitsHealthResults() {
        let original = ChannelModel()
        original.healthResults[3] = ChannelHealthResult(
            channelIndex: 3, goodPercentage: 90, grade: .good, summary: "", metrics: []
        )
        original.showsHealth = true

        let clone = original.copy()

        #expect(clone.healthResults.isEmpty)
        #expect(clone.showsHealth == false)
    }

    @Test("copy() is a real, independent object — the whole reason it exists")
    func channelModelCopyIsIndependent() {
        let original = ChannelModel()
        original.bad = [1]

        let clone = original.copy()
        clone.bad.insert(2)

        // The mutation this test would catch: a fork that left the new
        // window's RecordingStore pointing at the *same* ChannelModel
        // instance, so marking a channel bad in one window would silently
        // mark it bad in the other too.
        #expect(original.bad == [1])
        #expect(clone.bad == [1, 2])
    }
}
