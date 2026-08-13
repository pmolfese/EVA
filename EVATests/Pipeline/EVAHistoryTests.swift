//
//  EVAHistoryTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  `EVAHistory` is content-addressed, so its identity rules are load-bearing in a
//  way ordinary data structures are not: if two different processing states hash
//  to one ID, the tree serves one node's cached signal for the other's and the
//  user sees the wrong data with no error. Most of what is pinned here is
//  identity, not bookkeeping.
//

import Testing
import Foundation
@testable import EVA

struct EVAHistoryTests {

    private func step(
        _ operation: EVAProcessingStep.Operation,
        _ parameters: [String: String] = [:]
    ) -> EVAProcessingStep {
        EVAProcessingStep(operation: operation, parameters: parameters)
    }

    private func filterStep(high: String = "0.1", low: String = "40") -> EVAProcessingStep {
        step(.filter, ["highPassHz": high, "lowPassHz": low])
    }

    // MARK: - Shape

    @Test func startsAtARootWithNoSteps() {
        let history = EVAHistory(recordingKey: "subject-01.mff")
        #expect(history.count == 1)
        #expect(history.current.isRoot)
        #expect(history.current.step == nil)
        #expect(history.currentScript.steps.isEmpty)
        #expect(!history.canStepBack)
        #expect(!history.canStepForward)
        #expect(history.current.displayLabel == "raw")
    }

    @Test func differentRecordingsNeverShareANode() {
        var a = EVAHistory(recordingKey: "subject-01.mff")
        var b = EVAHistory(recordingKey: "subject-02.mff")
        #expect(a.rootID != b.rootID)

        let inA = a.apply(filterStep())
        let inB = b.apply(filterStep())
        #expect(inA != inB, "identical steps on different recordings must not collide")
    }

    @Test func applyBuildsALinearChain() {
        var history = EVAHistory(recordingKey: "r")
        history.apply(step(.mriGradientCorrection, ["trSeconds": "2.0"]))
        history.apply(filterStep())
        history.apply(step(.segment, ["preMs": "-100"]))

        #expect(history.count == 4)
        #expect(history.currentPath.count == 4)
        #expect(history.currentScript.steps.map(\.operation) == [.mriGradientCorrection, .filter, .segment])
    }

    // MARK: - Identity

    /// The same step at the same parent is the same node. This is what makes
    /// "replay must never recompute when a valid cache exists" true by
    /// construction rather than by policy.
    @Test func applyDeduplicatesAnIdenticalStep() {
        var history = EVAHistory(recordingKey: "r")
        let first = history.apply(filterStep())
        history.stepBack()
        let second = history.apply(filterStep())

        #expect(first == second)
        #expect(history.count == 2, "re-applying the same step must not create a second node")
        #expect(history.children(of: history.rootID).count == 1)
    }

    /// The other half of the deduplication story, and the one `REWIND.md` gets
    /// wrong. An "off" step followed by an "on" step is a *different* ancestry
    /// from having done neither, so it does not collapse — which is why a toggle
    /// has to be implemented as `stepBack()`, not as appending an inverse step.
    @Test func togglingViaAnInverseStepDoesNotDeduplicate() {
        var history = EVAHistory(recordingKey: "r")
        let off = history.apply(step(.artifactClean, ["cleaningEnabled": "false"]))
        let backOn = history.apply(step(.artifactClean, ["cleaningEnabled": "true"]))

        #expect(off != backOn)
        #expect(backOn != history.rootID)
        #expect(history.count == 3)

        // Whereas expressing the same intent as navigation costs nothing.
        var byNavigation = EVAHistory(recordingKey: "r")
        byNavigation.apply(step(.artifactClean, ["cleaningEnabled": "false"]))
        byNavigation.stepBack()
        #expect(byNavigation.currentID == byNavigation.rootID)
        #expect(byNavigation.count == 2)
    }

    @Test func changingAParameterForks() {
        var history = EVAHistory(recordingKey: "r")
        let wide = history.apply(filterStep(high: "0.1", low: "40"))
        history.stepBack()
        let narrow = history.apply(filterStep(high: "1", low: "30"))

        #expect(wide != narrow)
        #expect(history.children(of: history.rootID).count == 2)
        #expect(history.currentID == narrow, "a fork makes the new branch current")
        #expect(history.node(wide) != nil, "the old branch survives — fork is non-destructive")
    }

    @Test func parameterOrderDoesNotAffectIdentity() {
        var a = EVAHistory(recordingKey: "r")
        var b = EVAHistory(recordingKey: "r")
        let one = a.apply(step(.filter, ["highPassHz": "0.1", "lowPassHz": "40", "notch": "true"]))
        let two = b.apply(step(.filter, ["notch": "true", "lowPassHz": "40", "highPassHz": "0.1"]))
        #expect(one == two)
    }

    /// Identity must ignore the step's UUID and timestamp, or every node is
    /// unique and nothing ever deduplicates or hits a cache.
    @Test func identityIgnoresStepIDAndTimestamp() {
        var history = EVAHistory(recordingKey: "r")
        var early = filterStep()
        early.appliedAt = Date(timeIntervalSince1970: 0)
        var late = filterStep()
        late.appliedAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(early.id != late.id)

        let a = history.idFor(step: early, parent: history.rootID)
        let b = history.idFor(step: late, parent: history.rootID)
        #expect(a == b)
    }

    /// A step's `note`, `rejections`, and `replayable` flag describe or classify
    /// the step; none of them is an input to the computation.
    @Test func identityIgnoresProseAndResults() {
        let history = EVAHistory(recordingKey: "r")
        var plain = step(.average)
        var annotated = step(.average)
        annotated.note = "recorded for provenance"
        annotated.replayable = false
        annotated.rejections = [CategoryRejection(category: "LC", total: 40, included: 26, reasons: ["blink": 14])]

        #expect(history.idFor(step: plain, parent: history.rootID)
                == history.idFor(step: annotated, parent: history.rootID))
        plain.note = nil
    }

    /// The payload digest is part of identity: two ICA removals that differ only
    /// in which components were excluded are different nodes.
    @Test func identityTracksThePayloadDigest() {
        let history = EVAHistory(recordingKey: "r")
        let base = step(.icaClean, ["averageReference": "true"])
        let a = history.idFor(step: base, parent: history.rootID, payloadDigest: "aaaa")
        let b = history.idFor(step: base, parent: history.rootID, payloadDigest: "bbbb")
        let none = history.idFor(step: base, parent: history.rootID)

        #expect(a != b)
        #expect(a != none)
    }

    /// Length-prefixed hashing, not separator-joined. Two parameter sets that
    /// differ only in where a boundary falls must not collide — that would make
    /// the tree serve one node's cached signal for another's.
    @Test func fieldBoundariesCannotBeForged() {
        let history = EVAHistory(recordingKey: "r")
        let split = history.idFor(step: step(.filter, ["a": "x", "b": "y"]), parent: history.rootID)
        let merged = history.idFor(step: step(.filter, ["a": "x\u{1F}b\u{1F}y"]), parent: history.rootID)
        let alsoMerged = history.idFor(step: step(.filter, ["ab": "xy"]), parent: history.rootID)

        #expect(split != merged)
        #expect(split != alsoMerged)
    }

    @Test func identityCoversTheWholeAncestry() {
        var viaGradient = EVAHistory(recordingKey: "r")
        viaGradient.apply(step(.mriGradientCorrection, ["trSeconds": "2.0"]))
        let filteredAfterGradient = viaGradient.apply(filterStep())

        var direct = EVAHistory(recordingKey: "r")
        let filteredDirectly = direct.apply(filterStep())

        #expect(filteredAfterGradient != filteredDirectly,
                "the same filter on different upstream data is a different node")
    }

    // MARK: - Navigation

    @Test func stepBackAndForwardAreARoundTrip() {
        var history = EVAHistory(recordingKey: "r")
        history.apply(filterStep())
        let tip = history.apply(step(.segment))

        let wentBack = history.stepBack()
        #expect(wentBack)
        #expect(history.currentID != tip)
        let wentForward = history.stepForward()
        #expect(wentForward)
        #expect(history.currentID == tip)
    }

    /// With two branches, forward must retrace the one the user came down —
    /// not whichever happens to be first.
    @Test func stepForwardFollowsTheBranchLastVisited() {
        var history = EVAHistory(recordingKey: "r")
        let wide = history.apply(filterStep(high: "0.1", low: "40"))
        history.stepBack()
        let narrow = history.apply(filterStep(high: "1", low: "30"))
        #expect(history.children(of: history.rootID).map(\.id) == [wide, narrow])

        // Sitting on the second-created branch, back-then-forward returns here.
        history.stepBack()
        let retracedNarrow = history.stepForward()
        #expect(retracedNarrow)
        #expect(history.currentID == narrow)

        // Explicitly visiting the first branch re-points forward at it.
        let visitedWide = history.navigate(to: wide)
        #expect(visitedWide)
        history.stepBack()
        let retracedWide = history.stepForward()
        #expect(retracedWide)
        #expect(history.currentID == wide)
    }

    @Test func navigateRecordsEveryEdgeOnThePath() {
        var history = EVAHistory(recordingKey: "r")
        history.apply(filterStep())
        let deep = history.apply(step(.segment))
        history.navigate(to: history.rootID)

        // Two step-forwards from the root must reach the deep node again,
        // because navigating there recorded both edges.
        let firstHop = history.stepForward()
        let secondHop = history.stepForward()
        #expect(firstHop)
        #expect(secondHop)
        #expect(history.currentID == deep)
    }

    @Test func navigateRejectsAnUnknownNode() {
        var history = EVAHistory(recordingKey: "r")
        let before = history.currentID
        let moved = history.navigate(to: EVAHistoryNodeID(hex: "deadbeef"))
        #expect(!moved)
        #expect(history.currentID == before)
    }

    @Test func stepBackStopsAtTheRoot() {
        var history = EVAHistory(recordingKey: "r")
        history.apply(filterStep())
        let toRoot = history.stepBack()
        let pastRoot = history.stepBack()
        #expect(toRoot)
        #expect(!pastRoot)
        #expect(history.currentID == history.rootID)
    }

    // MARK: - Pruning

    @Test func deleteBranchRemovesTheSubtree() {
        var history = EVAHistory(recordingKey: "r")
        let keep = history.apply(filterStep(high: "0.1", low: "40"))
        history.stepBack()
        let discard = history.apply(filterStep(high: "1", low: "30"))
        history.apply(step(.segment))
        history.apply(step(.average))
        #expect(history.count == 5)

        history.navigate(to: keep)
        let pruned = history.deleteBranch(discard)
        #expect(pruned)
        #expect(history.count == 2)
        #expect(history.node(discard) == nil)
        #expect(history.children(of: history.rootID).map(\.id) == [keep])
    }

    /// Pruning the ground you are standing on has no sensible answer, so it is
    /// refused rather than silently relocating the user.
    @Test func deleteBranchRefusesTheRootCurrentAndAncestors() {
        var history = EVAHistory(recordingKey: "r")
        let middle = history.apply(filterStep())
        let tip = history.apply(step(.segment))

        let prunedRoot = history.deleteBranch(history.rootID)
        let prunedCurrent = history.deleteBranch(tip)
        let prunedAncestor = history.deleteBranch(middle)
        #expect(!prunedRoot)
        #expect(!prunedCurrent, "current node")
        #expect(!prunedAncestor, "ancestor of current")
        #expect(history.count == 3)
    }

    /// A remembered forward edge pointing into a pruned subtree would send
    /// `stepForward()` to a node that no longer exists.
    @Test func deleteBranchClearsRememberedEdgesIntoIt() {
        var history = EVAHistory(recordingKey: "r")
        let keep = history.apply(filterStep(high: "0.1", low: "40"))
        history.stepBack()
        let discard = history.apply(filterStep(high: "1", low: "30"))

        history.navigate(to: history.rootID)   // forward edge now points at `discard`
        #expect(history.forwardChild == discard)
        history.navigate(to: keep)
        let pruned = history.deleteBranch(discard)
        #expect(pruned)

        history.navigate(to: history.rootID)
        #expect(history.forwardChild == keep)
        let movedForward = history.stepForward()
        #expect(movedForward)
        #expect(history.currentID == keep)
    }

    // MARK: - Annotations

    @Test func annotationsDoNotMoveANode() {
        var history = EVAHistory(recordingKey: "r")
        let id = history.apply(filterStep())
        history.setLabel("ERP band", for: id)
        history.setPinned(true, for: id)
        history.recordComputeCost(42, for: id)

        #expect(history.node(id)?.id == id, "renaming or pinning must not change identity")
        #expect(history.node(id)?.displayLabel == "ERP band")
        #expect(history.node(id)?.isPinned == true)

        history.setLabel("   ", for: id)
        #expect(history.node(id)?.displayLabel == "Band-pass / Line-noise Filter",
                "a blank label falls back to the step rendering")
    }

    /// The stored figure is what it cost to *compute* the node, so a later
    /// (cheap, cached) report must not overwrite it.
    @Test func computeCostRecordsOnlyTheFirstMeasurement() {
        var history = EVAHistory(recordingKey: "r")
        let id = history.apply(filterStep())
        history.recordComputeCost(31.5, for: id)
        history.recordComputeCost(0.002, for: id)
        #expect(history.node(id)?.computeCost == 31.5)
    }

    // MARK: - Persistence (work item 6)

    @Test func roundTripsThroughJSON() throws {
        var history = EVAHistory(recordingKey: "subject-01.mff")
        history.apply(step(.mriGradientCorrection, ["trSeconds": "2.0"]))
        let branchPoint = history.currentID
        history.apply(filterStep(high: "0.1", low: "40"))
        let pinned = history.apply(step(.icaClean, ["averageReference": "true"]), payloadDigest: "abc123")
        history.setPinned(true, for: pinned)
        history.recordComputeCost(88, for: pinned)
        history.navigate(to: branchPoint)
        history.apply(filterStep(high: "1", low: "30"))

        let encoded = try EVAHistory.encoder().encode(history)
        let decoded = try EVAHistory.decoder().decode(EVAHistory.self, from: encoded)

        #expect(decoded == history)
        #expect(decoded.count == history.count)
        #expect(decoded.currentID == history.currentID)
        #expect(decoded.node(pinned)?.isPinned == true)
        #expect(decoded.node(pinned)?.computeCost == 88)
        #expect(decoded.node(pinned)?.payloadDigest == "abc123")
        // Forward navigation survives the round trip.
        #expect(decoded.forwardChild == history.forwardChild)
    }

    @Test func decodingRejectsADanglingCurrentPointer() throws {
        var history = EVAHistory(recordingKey: "r")
        history.apply(filterStep())
        var json = String(decoding: try EVAHistory.encoder().encode(history), as: UTF8.self)
        json = json.replacingOccurrences(of: history.currentID.hex, with: "0000")
        // Only the pointer is corrupted, not the node's own id — otherwise the
        // node would simply be renamed and the file would stay self-consistent.
        json = json.replacingOccurrences(of: "\"id\" : \"0000\"", with: "\"id\" : \"\(history.currentID.hex)\"")

        #expect(throws: DecodingError.self) {
            _ = try EVAHistory.decoder().decode(EVAHistory.self, from: Data(json.utf8))
        }
    }

    /// The persisted node list is parent-before-child, so the file reads
    /// top-down and a node is never encountered before its parent.
    @Test func encodedNodesAreOrderedParentsFirst() throws {
        var history = EVAHistory(recordingKey: "r")
        history.apply(filterStep())
        history.apply(step(.segment))
        history.navigate(to: history.rootID)
        history.apply(step(.waveletReduce, ["level": "5"]))

        let object = try JSONSerialization.jsonObject(with: EVAHistory.encoder().encode(history)) as? [String: Any]
        let nodes = try #require(object?["nodes"] as? [[String: Any]])

        var seen = Set<String>()
        for node in nodes {
            if let parent = node["parent"] as? String {
                #expect(seen.contains(parent), "child encoded before its parent")
            }
            seen.insert(try #require(node["id"] as? String))
        }
        #expect(nodes.count == history.count)
    }

    // MARK: - The script the tree derives

    /// `currentScript` is the tree's answer to "the chain order is knowledge held
    /// in three places". Navigating changes it; nothing has to be kept in sync.
    @Test func currentScriptFollowsTheCurrentNode() {
        var history = EVAHistory(recordingKey: "r")
        history.apply(step(.mriGradientCorrection, ["trSeconds": "2.0"]))
        history.apply(filterStep())
        history.apply(step(.segment))
        #expect(history.currentScript.steps.count == 3)

        history.stepBack()
        #expect(history.currentScript.steps.map(\.operation) == [.mriGradientCorrection, .filter])

        history.navigate(to: history.rootID)
        #expect(history.currentScript.steps.isEmpty)
    }
}
