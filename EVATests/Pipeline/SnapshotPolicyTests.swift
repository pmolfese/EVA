//
//  SnapshotPolicyTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP RW-1 item 7 — the snapshot policy has to be true, not aspirational.
//
//  Three promises the rail was making that nothing kept: a pin badge no action
//  could set (and that eviction ignored anyway), a memory budget nobody could
//  see, and a cost hint with no measurement behind it. These tests pin the
//  versions that are now real:
//
//  - a pinned snapshot survives eviction, and pinning is **capped**, because an
//    unlimited exemption is not a policy — it is a way to switch the budget off
//    by accident;
//  - the cache reports what it holds;
//  - `computeCost` is measured or absent, and a row says nothing about time
//    until something has actually been timed;
//  - the supported-step matrix is one pure function, so a node that cannot be
//    rebuilt says so *before* the click rather than failing after it.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct SnapshotPolicyTests {

    // MARK: - Fixtures

    @MainActor
    private struct Pipeline {
        let store = RecordingStore()
        let filter: FilterViewModel
        init() { filter = FilterViewModel(store: store) }

        /// A snapshot holding `samples` floats on one channel — 4 bytes each,
        /// so the budget arithmetic in these tests is exact.
        func snapshot(samples: Int) -> PipelineSnapshot {
            var snapshot = PipelineSnapshot()
            snapshot.filterOutput = SyntheticSignal.make(
                [[Float](repeating: 1, count: samples)], samplingRate: 100
            )
            return snapshot
        }
    }

    private func advance(_ model: RecordingHistoryModel, steps: Int) {
        var script = EVAProcessingScript()
        for index in 0..<steps {
            script.append(EVAProcessingStep(operation: .filter, parameters: ["n": "\(index)"]))
        }
        model.record(recordingKey: "r", script: script)
    }

    // MARK: - Pinning

    @Test("A pinned snapshot survives eviction that takes an unpinned one")
    func pinnedSnapshotsAreExemptFromEviction() {
        let model = RecordingHistoryModel()
        let pipeline = Pipeline()
        // Room for two 4 KB snapshots, and a 5 KB pin allowance.
        model.snapshotByteBudget = 10_000

        advance(model, steps: 1)
        let pinned = model.history.currentID
        model.storeSnapshot(pipeline.snapshot(samples: 1_000))
        #expect(model.setPinned(true, for: pinned) == .pinned)

        advance(model, steps: 2)
        let unpinned = model.history.currentID
        model.storeSnapshot(pipeline.snapshot(samples: 1_000))
        advance(model, steps: 3)
        model.storeSnapshot(pipeline.snapshot(samples: 1_000))

        #expect(model.hasSnapshot(for: pinned), "a pin is an exemption from eviction")
        #expect(model.isPinned(pinned))
        #expect(!model.hasSnapshot(for: unpinned), "the unpinned neighbour went instead")
    }

    @Test("Unpinning returns the snapshot to the eviction queue")
    func unpinningRestoresOrdinaryEviction() {
        let model = RecordingHistoryModel()
        let pipeline = Pipeline()
        model.snapshotByteBudget = 6_000
        model.pinnedByteShare = 1

        advance(model, steps: 1)
        let node = model.history.currentID
        model.storeSnapshot(pipeline.snapshot(samples: 1_000))
        model.setPinned(true, for: node)
        #expect(model.setPinned(false, for: node) == .unpinned)

        advance(model, steps: 2)
        model.storeSnapshot(pipeline.snapshot(samples: 1_000))

        #expect(!model.hasSnapshot(for: node))
    }

    /// The reason the cap exists: without it, pinning every node is a way to
    /// disable the byte budget without ever being told you did.
    @Test("A pin past the allowance is refused, and says what it is holding")
    func pinningIsCapped() {
        let model = RecordingHistoryModel()
        let pipeline = Pipeline()
        model.snapshotByteBudget = 20_000
        model.pinnedByteShare = 0.5  // 10 KB of pins allowed

        var pinnedIDs: [EVAHistoryNodeID] = []
        for step in 1...3 {
            advance(model, steps: step)
            pinnedIDs.append(model.history.currentID)
            model.storeSnapshot(pipeline.snapshot(samples: 1_000))  // 4 KB each
        }

        #expect(model.setPinned(true, for: pinnedIDs[0]) == .pinned)
        #expect(model.setPinned(true, for: pinnedIDs[1]) == .pinned)

        // 8 KB pinned; a third 4 KB pin would be 12 KB against a 10 KB
        // allowance.
        let outcome = model.setPinned(true, for: pinnedIDs[2])
        #expect(outcome == .refused(pinnedBytes: 8_000, allowanceBytes: 10_000))
        #expect(model.isPinned(pinnedIDs[2]) == false)
    }

    /// A pin on a node whose snapshot is already gone costs nothing now, so
    /// refusing it would be refusing an intention rather than a cost.
    @Test("Pinning an evicted node is allowed")
    func pinningAnEvictedNodeCostsNothing() {
        let model = RecordingHistoryModel()
        model.snapshotByteBudget = 1
        model.pinnedByteShare = 0

        advance(model, steps: 1)
        let node = model.history.currentID
        #expect(model.hasSnapshot(for: node) == false)
        #expect(model.setPinned(true, for: node) == .pinned)
    }

    // MARK: - Budget reporting

    @Test("The cache says what it is holding")
    func cacheReportsOccupancy() {
        let model = RecordingHistoryModel()
        let pipeline = Pipeline()
        model.snapshotByteBudget = 1_000_000_000

        advance(model, steps: 1)
        model.storeSnapshot(pipeline.snapshot(samples: 250_000))  // 1 MB

        #expect(model.snapshotBytes == 1_000_000)
        #expect(model.snapshotBudgetSummary.contains("1 MB"))
        #expect(model.snapshotBudgetSummary.contains("1.0 GB"))
        #expect(model.snapshotBudgetSummary.contains("1 of \(model.snapshotCountLimit)"))
    }

    @Test("Byte summaries read in the unit a person would use")
    func byteSummaryFormatting() {
        #expect(RecordingHistoryModel.byteSummary(384_000_000) == "384 MB")
        #expect(RecordingHistoryModel.byteSummary(1_500_000_000) == "1.5 GB")
    }

    // MARK: - Measured cost

    @Test("Compute cost is recorded once and never overwritten by a cheaper visit")
    func computeCostIsFirstComputationOnly() {
        let model = RecordingHistoryModel()
        advance(model, steps: 1)
        let node = model.history.currentID

        #expect(model.computeCost(for: node) == nil, "unmeasured until something times it")
        model.recordComputeCost(12, for: node)
        model.recordComputeCost(0.2, for: node)
        #expect(model.computeCost(for: node) == 12)
    }

    /// The rail may only show a time it was told. An unmeasured node shows the
    /// plain "this recomputes it" text — never a guess from a table of stage
    /// names, which is the version `REWIND.md` rules out.
    @Test("A row offers a time only when one was measured")
    func rowShowsMeasuredCostOnly() {
        var node = HistoryRailNode(
            id: "abc", title: "filter", subtitle: "0.1–30 Hz",
            isCurrent: false, isPinned: false, isInstant: false
        )
        #expect(!HistoryRailNodeList.helpText(for: node).contains("took"))

        node.rebuildSeconds = 42
        let help = HistoryRailNodeList.helpText(for: node)
        #expect(help.contains("42 s"))

        // A cached row never advertises a rebuild at all.
        node.isInstant = true
        #expect(!HistoryRailNodeList.helpText(for: node).contains("Rebuild"))
    }

    @Test("Durations read as a person would say them")
    func durationFormatting() {
        #expect(HistoryRailNodeList.durationText(0.4) == "under a second")
        #expect(HistoryRailNodeList.durationText(42) == "42 s")
        #expect(HistoryRailNodeList.durationText(120) == "2 min")
        #expect(HistoryRailNodeList.durationText(135) == "2 min 15 s")
    }

    // MARK: - The supported-step matrix

    private func step(_ operation: EVAProcessingStep.Operation) -> EVAProcessingStep {
        EVAProcessingStep(operation: operation, replayable: false)
    }

    @Test("What can be rebuilt is one rule, and it depends on what the file carries")
    func supportedStepMatrix() {
        let nothing = ReplayPayloadAvailability.none
        let everything = ReplayPayloadAvailability(
            hasICAPayload: true, hasArtifactPayload: true, hasElectrodeGeometry: true
        )

        // Portable steps, and the ones carrying their own channel list.
        #expect(RecordingHistoryModel.firstNonReDerivableStep(
            in: [step(.filter), step(.reference), step(.segment), step(.markBad)],
            availability: nothing
        ) == nil)

        // Subject-specific, resolvable only from this file's own record.
        #expect(RecordingHistoryModel.firstNonReDerivableStep(
            in: [step(.icaClean)], availability: nothing
        ) == .icaClean)
        #expect(RecordingHistoryModel.firstNonReDerivableStep(
            in: [step(.icaClean)], availability: everything
        ) == nil)
        #expect(RecordingHistoryModel.firstNonReDerivableStep(
            in: [step(.interpolateChannels)], availability: nothing
        ) == .interpolateChannels)
        #expect(RecordingHistoryModel.firstNonReDerivableStep(
            in: [step(.interpolateChannels)], availability: everything
        ) == nil)

        // BCG has no re-derive path at all, whatever the file carries.
        #expect(RecordingHistoryModel.firstNonReDerivableStep(
            in: [step(.bcgDetection)], availability: everything
        ) == .bcgDetection)

        // The *first* blocker is reported, so the message names the step the
        // walk would actually stop at.
        #expect(RecordingHistoryModel.firstNonReDerivableStep(
            in: [step(.filter), step(.bcgDetection), step(.icaClean)], availability: nothing
        ) == .bcgDetection)
    }

    @Test("A node blocked by a step it cannot reproduce is unreachable, with a reason")
    func blockedNodeIsUnreachableBeforeTheClick() {
        let model = RecordingHistoryModel()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1"]))
        script.append(EVAProcessingStep(operation: .bcgDetection, replayable: false))
        script.append(EVAProcessingStep(operation: .waveletReduce, parameters: ["mode": "gentle"]))
        model.record(recordingKey: "r", script: script)

        let tip = model.history.currentID
        #expect(model.isReachable(tip) == false)
        #expect(
            model.reDerivationSource(for: tip).unavailableReason == .blockedStep(.bcgDetection)
        )

        // The row carries the message, so the rail can say it before the click.
        let row = model.railNodes(rawSubtitle: "raw").first { $0.id == tip.hex }
        #expect(row?.isReachable == false)
        #expect(row?.unreachableReason?.contains("BCG") == true)

        // A cached snapshot still reaches it — the matrix governs *rebuilding*,
        // not what is already in memory.
        model.storeSnapshot(PipelineSnapshot())
        #expect(model.isReachable(tip))
    }
}
