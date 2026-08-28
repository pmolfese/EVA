//
//  ThresholdConfigCommitTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP RW-1 item 5 — a threshold edit must commit exactly one history state.
//
//  Two failure modes bracket the right answer, and the shipped code sat on the
//  first of them. `ProcessingChainSignature` carries no parameter values (by
//  design — it is evaluated on every body pass), and threshold detection
//  produces no signal of its own, so retuning the detector changed nothing the
//  history observer could see: **zero** states, and the tuned values never
//  entered the file's lineage. The opposite mistake is just as bad: the sheet's
//  controls are bound live, so folding the values themselves into the signature
//  would mint a node per slider tick.
//
//  `ArtifactViewModel.thresholdConfigCommits` is the middle answer — one bump
//  when the sheet commits.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct ThresholdConfigCommitTests {

    private func detectionStep(blinkMinimum: Int) -> EVAProcessingStep {
        EVAProcessingStep(
            operation: .thresholdArtifactDetection,
            parameters: [
                "eyeBlink": "true",
                "eyeMovement": "false",
                "blink.amplitudeMinMicrovolts": "\(blinkMinimum)"
            ]
        )
    }

    private func signature(commits: Int) -> WaveformView.ProcessingChainSignature {
        WaveformView.ProcessingChainSignature(
            raw: nil, gradient: nil, bcg: nil, ica: nil, filter: nil, wavelet: nil, epoched: nil,
            cleaningActive: false, cleaningEnabled: true,
            thresholdDetection: true, detectsBlinks: true, detectsMovements: false,
            thresholdConfigCommits: commits
        )
    }

    // MARK: - The signature notices a commit, and only a commit

    @Test("A commit changes the chain signature, so the history observer runs")
    func commitMovesTheSignature() {
        #expect(signature(commits: 0) != signature(commits: 1))
    }

    @Test("Editing values without committing leaves the signature alone")
    func liveEditingDoesNotMoveTheSignature() {
        // Dragging a slider mutates `blinkThresholdConfig` continuously. None of
        // that reaches the signature — which is what keeps a drag from minting
        // a node per tick.
        let store = RecordingStore()
        let artifactVM = ArtifactViewModel(store: store)
        let before = artifactVM.thresholdConfigCommits

        artifactVM.blinkThresholdConfig.amplitudeMinMicrovolts = 61
        artifactVM.blinkThresholdConfig.amplitudeMinMicrovolts = 62
        artifactVM.blinkThresholdConfig.amplitudeMinMicrovolts = 63

        #expect(artifactVM.thresholdConfigCommits == before)
        #expect(signature(commits: before) == signature(commits: artifactVM.thresholdConfigCommits))
    }

    @Test("Committing bumps once per commit")
    func commitBumpsOnce() {
        let store = RecordingStore()
        let artifactVM = ArtifactViewModel(store: store)

        artifactVM.commitThresholdConfiguration()
        #expect(artifactVM.thresholdConfigCommits == 1)
        artifactVM.commitThresholdConfiguration()
        #expect(artifactVM.thresholdConfigCommits == 2)
    }

    // MARK: - What the commit produces in the tree

    @Test("A committed threshold change records exactly one new state")
    func oneNodePerCommittedChange() {
        let model = RecordingHistoryModel()
        model.record(
            recordingKey: "sub-014.mff",
            script: EVAProcessingScript(steps: [detectionStep(blinkMinimum: 60)])
        )
        let before = model.history.count
        let firstTip = model.history.currentID

        model.record(
            recordingKey: "sub-014.mff",
            script: EVAProcessingScript(steps: [detectionStep(blinkMinimum: 90)])
        )

        // One state, not zero and not several. The retune diverges at the same
        // parent, so the superseded tuning is an abandoned future and is
        // replaced rather than accumulated — standard Mac undo semantics, the
        // same as re-applying a filter with different settings. What matters
        // for item 5 is that the rail gains exactly one detection node showing
        // the committed values.
        #expect(model.history.currentID != firstTip)
        #expect(model.history.count == before, "the superseded tuning is replaced, not kept alongside")
        #expect(model.history.children(of: model.history.rootID).count == 1)
        #expect(model.history.node(firstTip) == nil, "the old tuning's node is gone")
        #expect(model.history.current.step?.operation == .thresholdArtifactDetection)
        #expect(
            model.history.current.step?.parameters["blink.amplitudeMinMicrovolts"] == "90"
        )
    }

    @Test("Committing without changing anything adds no state")
    func anUnchangedCommitIsFree() {
        // Done on an untouched sheet, or the second of the two commits Done
        // itself produces (the button, then `onDisappear`). Content addressing
        // makes the identical script resolve to the node already current.
        let model = RecordingHistoryModel()
        model.record(
            recordingKey: "sub-014.mff",
            script: EVAProcessingScript(steps: [detectionStep(blinkMinimum: 60)])
        )
        let tip = model.history.currentID
        let count = model.history.count

        model.record(
            recordingKey: "sub-014.mff",
            script: EVAProcessingScript(steps: [detectionStep(blinkMinimum: 60)])
        )

        #expect(model.history.currentID == tip)
        #expect(model.history.count == count)
    }

    @Test("Threshold values are part of node identity, so two tunings are two nodes")
    func thresholdValuesAreInTheNodeHash() {
        let history = EVAHistory(recordingKey: "sub-014.mff")
        let parent = history.rootID
        #expect(
            history.idFor(step: detectionStep(blinkMinimum: 60), parent: parent)
            != history.idFor(step: detectionStep(blinkMinimum: 90), parent: parent)
        )
    }
}
