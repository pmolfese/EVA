//
//  RecordingHistoryOnDiskPrefixTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Reported: opening an already-processed package (filter, threshold detection,
//  interpolation baked into `signal1.bin` by a prior EVA run) showed the history
//  rail at bare "raw" — the file's own `eva.xml` lineage was discarded, because
//  `recordProcessingHistory()` only ever reflects *this session's* pipeline view
//  models, which start empty on every load regardless of what produced the
//  loaded bytes.
//
//  `seedOnDiskPrefix` is the fix: `eva.xml`'s steps become a fixed prefix that
//  every `record()` call folds in ahead of whatever this session does. These
//  tests use the reported file's actual eva.xml shape — filter →
//  thresholdArtifactDetection → interpolateChannels, the last one
//  non-replayable.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct RecordingHistoryOnDiskPrefixTests {

    private func filterStep() -> EVAProcessingStep {
        EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "0.1", "lowPassHz": "30"])
    }

    private func detectionStep() -> EVAProcessingStep {
        EVAProcessingStep(
            operation: .thresholdArtifactDetection,
            parameters: ["eyeBlink": "true", "eyeMovement": "true"]
        )
    }

    private func interpolateStep() -> EVAProcessingStep {
        EVAProcessingStep(
            operation: .interpolateChannels,
            parameters: ["channels": "10,69", "method": "sphericalSpline"],
            replayable: false
        )
    }

    @Test("A processed file's on-disk lineage replaces the bare root")
    func onDiskPrefixReplacesRawRoot() {
        let model = RecordingHistoryModel()
        let onDisk = [filterStep(), detectionStep(), interpolateStep()]

        model.seedOnDiskPrefix(recordingKey: "josh_pilot.mff", steps: onDisk)

        // Not sitting at the root — the loaded file is the *result* of these
        // steps, not the recording before them.
        #expect(model.history.currentID != model.history.rootID)
        // Every step is a real node on the path to current, in order.
        let operations = model.history.currentPath.compactMap { $0.step?.operation }
        #expect(operations == [.filter, .thresholdArtifactDetection, .interpolateChannels])
    }

    @Test("The tip is instant; the steps before it are not")
    func onlyTheTipHasASnapshot() {
        let model = RecordingHistoryModel()
        model.seedOnDiskPrefix(
            recordingKey: "josh_pilot.mff", steps: [filterStep(), detectionStep(), interpolateStep()]
        )
        model.storeSnapshot(PipelineSnapshot())

        let rows = model.railNodes(rawSubtitle: "raw")
        #expect(rows.count == 4) // root + 3 steps
        let tipID = model.history.currentID.hex
        for row in rows {
            #expect(row.isInstant == (row.id == tipID), "\(row.title) should only be instant if it is the tip")
        }
        // Concretely: the interpolation node (the tip) is instant, the filter
        // and detection nodes are not — that is what makes them show as
        // "history, but not clickable" in the rail rather than vanishing.
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })
        #expect(byTitle[HistoryStepSummary.title(for: .interpolateChannels)]?.isInstant == true)
        #expect(byTitle[HistoryStepSummary.title(for: .filter)]?.isInstant == false)
        #expect(byTitle[HistoryStepSummary.title(for: .thresholdArtifactDetection)]?.isInstant == false)
    }

    @Test("A live edit afterward forks from the on-disk tip, not from root")
    func liveEditsBuildOnTheOnDiskTip() {
        let model = RecordingHistoryModel()
        model.seedOnDiskPrefix(recordingKey: "josh_pilot.mff", steps: [filterStep(), detectionStep()])
        let onDiskTip = model.history.currentID

        // The session now applies wavelet reduction on top of the loaded file.
        // Realistically the *live* script contains only this — filter and
        // detection are baked into the loaded samples, not reproduced by this
        // session's (still-empty) filter/detection view models, so
        // `currentProcessingScript()` would never re-list them here.
        model.record(
            recordingKey: "josh_pilot.mff",
            script: EVAProcessingScript(steps: [
                EVAProcessingStep(operation: .waveletReduce, parameters: ["strength": "2"])
            ])
        )

        #expect(model.history.current.parent == onDiskTip)
        #expect(model.history.node(onDiskTip)?.children.contains(model.history.currentID) == true)
    }

    @Test("Re-seeding the same steps is a no-op, so repeated onChange firings do not thrash the tree")
    func reSeedingIdenticalStepsIsANoOp() {
        let model = RecordingHistoryModel()
        let steps = [filterStep(), detectionStep()]
        model.seedOnDiskPrefix(recordingKey: "josh_pilot.mff", steps: steps)
        let firstTip = model.history.currentID

        model.seedOnDiskPrefix(recordingKey: "josh_pilot.mff", steps: steps)
        #expect(model.history.currentID == firstTip)
    }

    @Test("record() with an empty live script does not walk the pointer back to root")
    func emptyLiveScriptDoesNotDiscardTheOnDiskTip() {
        let model = RecordingHistoryModel()
        model.seedOnDiskPrefix(recordingKey: "josh_pilot.mff", steps: [filterStep(), detectionStep()])
        let seededTip = model.history.currentID

        // This is the exact shape of the bug: `recordProcessingHistory()` fires
        // from an `.onChange` whose script reflects empty view models, whatever
        // order it runs in relative to seeding.
        model.record(recordingKey: "josh_pilot.mff", script: EVAProcessingScript(steps: []))

        #expect(model.history.currentID == seededTip)
        #expect(model.history.currentID != model.history.rootID)
    }

    @Test("Opening a different recording clears the previous file's on-disk prefix")
    func newRecordingClearsThePreviousPrefix() {
        let model = RecordingHistoryModel()
        model.seedOnDiskPrefix(recordingKey: "josh_pilot.mff", steps: [filterStep(), detectionStep()])

        model.record(recordingKey: "other_subject.mff", script: EVAProcessingScript(steps: []))

        #expect(model.history.currentID == model.history.rootID)
        #expect(model.onDiskPrefix.isEmpty)
    }

    @Test("A file with no eva.xml lineage behaves exactly as before")
    func noOnDiskStepsIsUnchangedBehaviour() {
        let model = RecordingHistoryModel()
        model.record(recordingKey: "raw_recording.mff", script: EVAProcessingScript(steps: []))
        #expect(model.history.currentID == model.history.rootID)

        model.record(
            recordingKey: "raw_recording.mff",
            script: EVAProcessingScript(steps: [filterStep()])
        )
        #expect(model.history.current.step?.operation == .filter)
        #expect(model.history.current.parent == model.history.rootID)
    }
}
