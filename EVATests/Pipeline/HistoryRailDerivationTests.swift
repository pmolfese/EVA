//
//  HistoryRailDerivationTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The read-only History rail's two pure pieces: building a linear `EVAHistory`
//  from a processing script, and rendering a node's title and parameter
//  subtitle. Everything the rail shows comes through here, so these cover it
//  without a view.
//

import Testing
import Foundation
@testable import EVA

struct HistoryRailDerivationTests {

    private func step(
        _ operation: EVAProcessingStep.Operation,
        _ parameters: [String: String] = [:]
    ) -> EVAProcessingStep {
        EVAProcessingStep(operation: operation, parameters: parameters)
    }

    private func script(_ steps: [EVAProcessingStep]) -> EVAProcessingScript {
        var script = EVAProcessingScript()
        for step in steps { script.append(step) }
        return script
    }

    // MARK: - Building the tree from a script

    @Test func scriptBecomesALinearChainEndingAtTheTip() {
        let history = EVAHistory(
            recordingKey: "sub-014.mff",
            script: script([
                step(.mriGradientCorrection, ["method": "FASTR"]),
                step(.filter, ["highPassHz": "0.1", "lowPassHz": "40"]),
                step(.segment, ["eventCodes": "LC++,RC++"])
            ])
        )

        #expect(history.count == 4, "root plus three steps")
        #expect(history.currentPath.count == 4)
        #expect(history.current.step?.operation == .segment, "current is the tip")
        #expect(history.currentPath.first?.isRoot == true)
        // A derived history is linear by construction — the script describes the
        // state you are in, not the ones you passed through.
        for node in history.currentPath.dropLast() {
            #expect(history.children(of: node.id).count == 1)
        }
    }

    @Test func anEmptyScriptIsJustTheRoot() {
        let history = EVAHistory(recordingKey: "r", script: EVAProcessingScript())
        #expect(history.count == 1)
        #expect(history.current.isRoot)
        #expect(history.current.displayLabel == "raw")
    }

    /// Rebuilding after a stage re-runs with the *same* settings must produce the
    /// same nodes, or the rail would grow every time someone re-applies a filter
    /// at the same cutoffs. Content addressing gives this for free — this pins
    /// that the derivation does not accidentally defeat it.
    ///
    /// Compared by node identity rather than `==`: two separately built trees
    /// carry different `createdAt` stamps, which is why `RecordingHistoryModel`
    /// runs `adoptAnnotations` before its equality guard.
    @Test func rebuildingAnUnchangedScriptYieldsTheSameNodes() {
        let steps = [
            step(.filter, ["highPassHz": "0.1", "lowPassHz": "40"]),
            step(.segment, ["eventCodes": "LC++"])
        ]
        let a = EVAHistory(recordingKey: "r", script: script(steps))
        let b = EVAHistory(recordingKey: "r", script: script(steps))
        #expect(a.currentPath.map(\.id) == b.currentPath.map(\.id))
        #expect(a.currentID == b.currentID)
    }

    /// Re-adopting an unchanged prefix must resolve to the nodes that already
    /// exist, not build parallel ones — that is what makes accumulation cheap.
    @MainActor
    @Test func readoptingAPrefixReusesItsNodes() {
        let model = RecordingHistoryModel()
        model.record(recordingKey: "r", script: script([step(.filter, ["highPassHz": "0.1"])]))
        let filterNode = model.history.currentID

        model.record(recordingKey: "r", script: script([
            step(.filter, ["highPassHz": "0.1"]),
            step(.segment, ["eventCodes": "LC++"])
        ]))

        #expect(model.history.current.parent == filterNode)
        #expect(model.history.count == 3, "root, filter, segment — no duplicate filter")
    }

    @Test func changingAParameterChangesOnlyTheTail() {
        let wide = EVAHistory(recordingKey: "r", script: script([
            step(.mriGradientCorrection, ["method": "FASTR"]),
            step(.filter, ["highPassHz": "0.1", "lowPassHz": "40"])
        ]))
        let narrow = EVAHistory(recordingKey: "r", script: script([
            step(.mriGradientCorrection, ["method": "FASTR"]),
            step(.filter, ["highPassHz": "1", "lowPassHz": "30"])
        ]))

        #expect(wide.currentPath[1].id == narrow.currentPath[1].id, "shared gradient node")
        #expect(wide.currentID != narrow.currentID, "different filter node")
    }

    @Test func differentRecordingsGetDifferentNodes() {
        let steps = [step(.filter, ["highPassHz": "0.1", "lowPassHz": "40"])]
        let a = EVAHistory(recordingKey: "sub-014.mff", script: script(steps))
        let b = EVAHistory(recordingKey: "sub-015.mff", script: script(steps))
        #expect(a.currentID != b.currentID)
    }

    // MARK: - Rail rows

    @MainActor
    @Test func railRowsRunRootFirstWithTheTipCurrent() {
        let model = RecordingHistoryModel()
        model.record(recordingKey: "r", script: script([
            step(.filter, ["highPassHz": "0.1", "lowPassHz": "40"]),
            step(.segment, ["eventCodes": "LC++,RC++", "preStimulusMs": "-100", "postStimulusMs": "600"])
        ]))

        let rows = model.railNodes(rawSubtitle: "128 ch · 1000 Hz · 21:04")
        #expect(rows.count == 3)
        #expect(rows[0].title == "raw")
        #expect(rows[0].subtitle == "128 ch · 1000 Hz · 21:04")
        #expect(rows[1].title == "filter")
        #expect(rows[2].title == "segment")
        #expect(rows.filter(\.isCurrent).map(\.title) == ["segment"], "exactly one current node")
    }

    /// The model assigns only when the tree actually differs, so a redundant
    /// record does not invalidate the rail. Cheap to get wrong and invisible
    /// when it is.
    @MainActor
    @Test func redundantRecordDoesNotChangeTheHistory() {
        let model = RecordingHistoryModel()
        let steps = script([step(.filter, ["highPassHz": "0.1"])])
        model.record(recordingKey: "r", script: steps)
        let first = model.history
        model.record(recordingKey: "r", script: steps)
        #expect(model.history == first)
    }

    // MARK: - Linear replacement policy

    @MainActor
    @Test func changingAStageReplacesTheOldFuture() throws {
        let model = RecordingHistoryModel()
        model.record(recordingKey: "r", script: script([
            step(.mriGradientCorrection, ["method": "FASTR"]),
            step(.filter, ["highPassHz": "0.1", "lowPassHz": "40"])
        ]))
        let wide = model.history.currentID
        let branchPoint = try #require(model.history.current.parent)

        model.record(recordingKey: "r", script: script([
            step(.mriGradientCorrection, ["method": "FASTR"]),
            step(.filter, ["highPassHz": "1", "lowPassHz": "30"])
        ]))
        let narrow = model.history.currentID

        #expect(wide != narrow)
        #expect(model.history.node(wide) == nil, "the replaced filter must leave no abandoned sibling")
        #expect(model.history.currentID == narrow, "and the pointer follows the new chain")
        #expect(model.history.children(of: branchPoint).count == 1)
    }

    /// Annotations ride along, because nothing is discarded any more.
    @MainActor
    @Test func aPinSurvivesLaterChainChanges() {
        let model = RecordingHistoryModel()
        model.record(recordingKey: "r", script: script([step(.filter, ["highPassHz": "0.1"])]))
        let pinned = model.history.currentID
        model.setPinned(true, for: pinned)

        model.record(recordingKey: "r", script: script([
            step(.filter, ["highPassHz": "0.1"]),
            step(.segment, ["eventCodes": "LC++"])
        ]))

        #expect(model.history.node(pinned)?.isPinned == true)
    }

    /// Removing a stage walks back up the existing trunk rather than building a
    /// parallel one — undo should not double the tree.
    @MainActor
    @Test func removingAStageReturnsToTheExistingNode() {
        let model = RecordingHistoryModel()
        model.record(recordingKey: "r", script: script([step(.filter, ["highPassHz": "0.1"])]))
        let filterNode = model.history.currentID
        model.record(recordingKey: "r", script: script([
            step(.filter, ["highPassHz": "0.1"]),
            step(.segment, ["eventCodes": "LC++"])
        ]))
        let countWithSegment = model.history.count

        model.record(recordingKey: "r", script: script([step(.filter, ["highPassHz": "0.1"])]))

        #expect(model.history.currentID == filterNode)
        #expect(model.history.count == countWithSegment, "the segment node is kept, not recreated")
        #expect(model.canStepForward, "removal remains redoable until another action replaces it")
    }

    @MainActor
    @Test func applyingANewFilterAfterRemovalDiscardsTheUndoneFilter() {
        let model = RecordingHistoryModel()
        model.record(recordingKey: "r", script: script([
            step(.filter, ["highPassHz": "0.1", "lowPassHz": "40"]),
            step(.reference, ["scheme": "average"])
        ]))
        let oldFilter = try! #require(model.history.currentPath.first { $0.step?.operation == .filter }?.id)
        let oldReference = model.history.currentID

        model.record(recordingKey: "r", script: script([]))
        #expect(model.history.node(oldFilter) != nil)
        #expect(model.history.node(oldReference) != nil)
        #expect(model.canStepForward)

        model.record(recordingKey: "r", script: script([
            step(.filter, ["highPassHz": "1", "lowPassHz": "30"])
        ]))

        #expect(model.history.node(oldFilter) == nil)
        #expect(model.history.node(oldReference) == nil)
        #expect(model.history.count == 2, "raw plus only the replacement filter")
        #expect(!model.canStepForward)
    }

    @MainActor
    @Test func reapplyingTheExactUndoneFilterUsesRedoInsteadOfDeletingIt() {
        let model = RecordingHistoryModel()
        let filtered = script([step(.filter, ["highPassHz": "0.1", "lowPassHz": "40"])])
        model.record(recordingKey: "r", script: filtered)
        let original = model.history.currentID
        model.record(recordingKey: "r", script: script([]))

        model.record(recordingKey: "r", script: filtered)

        #expect(model.history.currentID == original)
        #expect(model.history.count == 2)
    }

    /// Opening a different recording must not inherit the previous one's tree.
    @MainActor
    @Test func aDifferentRecordingStartsAFreshTree() {
        let model = RecordingHistoryModel()
        model.record(recordingKey: "sub-014.mff", script: script([step(.filter, ["highPassHz": "0.1"])]))
        let first = model.history.currentID

        model.record(recordingKey: "sub-015.mff", script: script([step(.filter, ["highPassHz": "0.1"])]))

        #expect(model.history.node(first) == nil)
        #expect(model.history.count == 2, "root plus the one step")
    }

    /// ICA's portable parameters are identical for two removals that excluded
    /// different components. Without the payload digest they would collapse to
    /// one node, and navigating to it would serve the wrong cached signal.
    @MainActor
    @Test func payloadDigestsSeparateOtherwiseIdenticalSteps() {
        let model = RecordingHistoryModel()
        let icaScript = script([step(.icaClean, ["method": "picard", "components": "20"])])

        model.record(recordingKey: "r", script: icaScript, payloadDigests: [.icaClean: "aaaa"])
        let first = model.history.currentID
        model.record(recordingKey: "r", script: icaScript, payloadDigests: [.icaClean: "bbbb"])
        let second = model.history.currentID

        #expect(first != second)
        #expect(model.history.node(first) == nil)
        #expect(model.history.children(of: model.history.rootID).count == 1)
    }

    // MARK: - Subtitles

    @Test func filterSubtitleReadsAsABand() {
        #expect(HistoryStepSummary.subtitle(for: step(.filter, [
            "highPassHz": "0.1", "lowPassHz": "40"
        ])) == "0.1–40 Hz")

        #expect(HistoryStepSummary.subtitle(for: step(.filter, [
            "highPassHz": "0.1"
        ])) == "0.1 Hz high-pass")

        #expect(HistoryStepSummary.subtitle(for: step(.filter, [
            "lowPassHz": "40"
        ])) == "40 Hz low-pass")
    }

    @Test func filterSubtitleNamesTheLineNoiseTreatment() {
        #expect(HistoryStepSummary.subtitle(for: step(.filter, [
            "highPassHz": "0.1", "lowPassHz": "40",
            "lineNoiseMode": "notch", "lineNoiseHz": "60"
        ])) == "0.1–40 Hz · 60 Hz notch")

        #expect(HistoryStepSummary.subtitle(for: step(.filter, [
            "highPassHz": "0.1", "lowPassHz": "40",
            "lineNoiseMode": "adaptiveCleanLine", "lineNoiseHz": "50"
        ])) == "0.1–40 Hz · CleanLine 50 Hz")

        // A line-noise-only filter has no band, and must not render a stray
        // separator or an empty leading segment.
        #expect(HistoryStepSummary.subtitle(for: step(.filter, [
            "lineNoiseMode": "notch", "lineNoiseHz": "60"
        ])) == "60 Hz notch")
    }

    @Test func segmentSubtitleCountsConditions() {
        let subtitle = HistoryStepSummary.subtitle(for: step(.segment, [
            "eventCodes": "LC++,RC++,LI++,RI++",
            "preStimulusMs": "-100",
            "postStimulusMs": "600",
            "average": "true"
        ]))
        #expect(subtitle == "4 conditions · −100–600 ms · averaged")

        let single = HistoryStepSummary.subtitle(for: step(.segment, ["eventCodes": "LC++"]))
        #expect(single == "1 condition", "singular, not '1 conditions'")
    }

    /// `segmentField` only appears when it is not the default — the rail should
    /// not spend a line saying "on code" for every segmentation.
    @Test func segmentSubtitleMentionsANonDefaultField() {
        #expect(HistoryStepSummary.subtitle(for: step(.segment, [
            "eventCodes": "LC++", "segmentField": PSASegmentField.code.rawValue
        ])) == "1 condition")

        #expect(HistoryStepSummary.subtitle(for: step(.segment, [
            "eventCodes": "LC++", "segmentField": PSASegmentField.artifact.rawValue
        ])) == "1 condition · on artifacts")
    }

    @Test func gradientAndICASubtitlesNameTheirMethod() {
        #expect(HistoryStepSummary.subtitle(for: step(.mriGradientCorrection, [
            "method": "FASTR", "donorVolumes": "30", "anc": "true"
        ])) == "FASTR · 30 donors · ANC")

        #expect(HistoryStepSummary.subtitle(for: step(.icaClean, [
            "method": "picard", "components": "20", "averageReference": "true"
        ])) == "picard · 20 components · avg ref")
    }

    /// A step whose parameters this file does not recognize still says
    /// something, rather than rendering as a bare title that explains nothing.
    @Test func unrecognizedParametersStillProduceASubtitle() {
        let subtitle = HistoryStepSummary.subtitle(for: step(.combine, ["files": "3", "mode": "append"]))
        #expect(subtitle == "2 settings")

        #expect(HistoryStepSummary.subtitle(for: step(.markBad)) == "",
                "no parameters at all means no subtitle, not '0 settings'")
    }

    @Test func titlesAreShortEnoughForTheRail() {
        // The rail is ~260 pt wide and pairs the title with its parameters on the
        // same visual line, which is why these are shorter than
        // `ReplayStepDisplay.label(for:)`.
        #expect(HistoryStepSummary.title(for: .filter) == "filter")
        #expect(HistoryStepSummary.title(for: .icaClean) == "ICA")
        #expect(HistoryStepSummary.title(for: .mriGradientCorrection) == "gradient correction")
        for operation in EVAProcessingStep.Operation.allCases {
            let title = HistoryStepSummary.title(for: operation)
            #expect(!title.isEmpty)
            #expect(title.count <= 20, "\(operation.rawValue) title too long for the rail: \(title)")
            #expect(title.count <= ReplayStepDisplay.label(for: operation).count,
                    "\(operation.rawValue) should not be longer than the checklist label")
        }
    }

    @Test func clockDurationFormatsMinutesAndHours() {
        #expect(WaveformView.clockDuration(1264) == "21:04")
        #expect(WaveformView.clockDuration(4864) == "1:21:04")
        #expect(WaveformView.clockDuration(9) == "0:09")
    }
}
