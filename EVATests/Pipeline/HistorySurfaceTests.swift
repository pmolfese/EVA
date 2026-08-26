//
//  HistorySurfaceTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP RW-1 items 9 and 12 — the Mac surface over the history, and the fork
//  payload that made non-MFF forks fail.
//
//  Item 9's two halves are covered differently on purpose. ⌘Z/⇧⌘Z routing is a
//  menu wiring, and the part worth testing is the *value* the menu reads:
//  whether each direction is possible and what it is called, which is where a
//  bare "Undo" that silently does nothing would come from. The row actions are
//  covered by what the rail offers rather than by driving a context menu.
//
//  Item 12 is a payload round-trip. The bug it fixes could not be caught any
//  other way short of opening a BrainVision recording and forking it: the fork
//  simply dropped the sidecar access it had been granted, and the second window
//  failed to load a file the first one had open.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct HistorySurfaceTests {

    // MARK: - Item 9: undo/redo as navigation

    @Test("Undo and redo name the step they act on")
    func transportNamesItsSteps() {
        let transport = HistoryTransportActions(
            undoStepName: "filter",
            redoStepName: "segment",
            stepBack: {},
            stepForward: {}
        )
        #expect(transport.canUndo)
        #expect(transport.canRedo)
        #expect(transport.undoTitle == "Undo filter")
        #expect(transport.redoTitle == "Redo segment")
    }

    /// The state the menu is in for a freshly-opened recording: both items
    /// present, both disabled, neither claiming to undo anything.
    @Test("With nothing to undo the items are plain and disabled")
    func transportWithNothingToDo() {
        let transport = HistoryTransportActions(
            undoStepName: nil, redoStepName: nil, stepBack: {}, stepForward: {}
        )
        #expect(!transport.canUndo)
        #expect(!transport.canRedo)
        #expect(transport.undoTitle == "Undo")
        #expect(transport.redoTitle == "Redo")
    }

    /// Undo is pointer movement, not an appended inverse — the property
    /// `EVAHistory`'s header asks for. Stepping back and forward again must
    /// return to the same node, leaving the tree the size it was.
    @Test("Undo then redo is a round trip, not two more nodes")
    func undoIsNavigation() {
        let model = RecordingHistoryModel()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1"]))
        model.record(recordingKey: "r", script: script)
        script.append(EVAProcessingStep(operation: .segment, parameters: ["eventCodes": "stim"]))
        model.record(recordingKey: "r", script: script)

        let tip = model.history.currentID
        let count = model.history.count

        let back = try? #require(model.stepBackTarget)
        _ = model.beginNavigation(to: back!)
        model.endNavigation()
        #expect(model.history.currentID != tip)

        let forward = try? #require(model.stepForwardTarget)
        _ = model.beginNavigation(to: forward!)
        model.endNavigation()

        #expect(model.history.currentID == tip, "redo returns to where undo started")
        #expect(model.history.count == count, "and neither direction minted a node")
    }

    // MARK: - Item 9: which row actions are real

    /// Rename is offered on every node — a name is an annotation, and naming a
    /// point you can no longer visit is still useful. An empty name clears it
    /// rather than storing one, so "back to the default" needs no second
    /// command.
    @Test("Renaming a node replaces its default label, and clearing restores it")
    func renamingANode() {
        let model = RecordingHistoryModel()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1"]))
        model.record(recordingKey: "r", script: script)
        let node = model.history.currentID
        let defaultLabel = model.history.current.defaultLabel

        model.setLabel("before ICA", for: node)
        #expect(model.history.current.displayLabel == "before ICA")

        model.setLabel("   ", for: node)
        #expect(model.history.current.displayLabel == defaultLabel)
    }

    // MARK: - Item 12: a fork carries its file access

    /// The bug: the claiming window re-reads the recording for itself, and for
    /// BrainVision, EDF, Persyst, and BESA the data lives *beside* the header
    /// the package URL names. Forking one produced a window that failed to
    /// load — visibly, but for no reason the operator could act on.
    @Test("A fork payload carries the sidecar access the source window was granted")
    func forkPayloadCarriesSecurityScopes() {
        let header = URL(fileURLWithPath: "/tmp/subject.vhdr")
        let markers = URL(fileURLWithPath: "/tmp/subject.vmrk")
        let data = URL(fileURLWithPath: "/tmp/subject.eeg")
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)

        let payload = PendingWindowForks.Payload(
            packageURL: header,
            securityScopedURLs: [header, markers, data, folder],
            historySeed: RecordingHistoryModel().forkSeed(),
            liveSnapshot: PipelineSnapshot(),
            channels: ChannelModel()
        )
        PendingWindowForks.shared.push(payload)

        let claimed = try? #require(PendingWindowForks.shared.claim())
        #expect(claimed?.packageURL == header)
        #expect(claimed?.securityScopedURLs == [header, markers, data, folder])
        #expect(PendingWindowForks.shared.claim() == nil, "claimed exactly once")
    }

    /// And the recording hands them out, which is what `forkToNewWindow` reads.
    @Test("A recording exposes the scopes it was opened with")
    func recordingExposesItsScopes() {
        let header = URL(fileURLWithPath: "/tmp/subject.vhdr")
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let recording = MFFRecording(packageURL: header, securityScopedURLs: [header, folder])
        #expect(recording.securityScopedURLs == [header, folder])
    }

    /// An MFF opened without any extra scope must not start claiming one.
    @Test("An ordinary open carries no scopes it was not given")
    func ordinaryOpenCarriesNothingExtra() {
        let recording = MFFRecording(packageURL: URL(fileURLWithPath: "/tmp/subject.mff"))
        #expect(recording.securityScopedURLs.isEmpty)
    }
}
