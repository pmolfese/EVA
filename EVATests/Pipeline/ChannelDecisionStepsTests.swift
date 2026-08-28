//
//  ChannelDecisionStepsTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Bad-channel marks and interpolation as `eva.xml` provenance — `REWIND.md` work
//  item 4. Before this, `markBad` and `interpolateChannels` were declared
//  operations that nothing emitted, so those decisions existed on disk only as
//  prose in `log_eva_*.txt`.
//
//  The two things most worth pinning here are the ones that would fail silently:
//  the 1-based channel numbering (0-based internally, and an off-by-one in a
//  provenance record is invisible until someone acts on it), and that the steps
//  stay **non-replayable** — making them replayable would interpolate channels on
//  a different subject's electrodes.
//

import Testing
import Foundation
@testable import EVA

struct ChannelDecisionStepsTests {

    private func script(_ operations: [EVAProcessingStep.Operation]) -> EVAProcessingScript {
        var script = EVAProcessingScript()
        for operation in operations {
            script.append(EVAProcessingStep(operation: operation))
        }
        return script
    }

    // MARK: - Encoding

    /// `ChannelModel` stores 0-based indices; `log_eva_*.txt` and every UI label
    /// are 1-based. The steps follow the human numbering.
    @Test func channelsAreWrittenOneBasedAndSorted() {
        let steps = ChannelDecisionSteps.steps(
            badChannels: [16, 0, 4],
            interpolatedChannels: [7]
        )
        let bad = steps.first { $0.operation == .markBad }
        #expect(bad?.parameters["channels"] == "1,5,17")

        let interpolated = steps.first { $0.operation == .interpolateChannels }
        #expect(interpolated?.parameters["channels"] == "8")
        #expect(interpolated?.parameters["method"] == ChannelDecisionSteps.methodParameterValue)
    }

    @Test func channelListRoundTrips() {
        let indices: Set<Int> = [0, 7, 63, 127]
        let list = ChannelDecisionSteps.channelList(indices)
        #expect(list == "1,8,64,128")
        #expect(ChannelDecisionSteps.channelIndices(from: list) == indices)
    }

    /// One malformed entry must not discard the rest — a hand-edited `eva.xml`
    /// losing every channel but keeping the step would be worse than noisy.
    @Test func channelListIgnoresGarbageEntriesIndividually() {
        #expect(ChannelDecisionSteps.channelIndices(from: "1, 8 ,oops,64") == [0, 7, 63])
        #expect(ChannelDecisionSteps.channelIndices(from: "0,-3,5") == [4],
                "0 and negatives are not valid 1-based channels")
        #expect(ChannelDecisionSteps.channelIndices(from: "").isEmpty)
    }

    /// No bad channels means no step, not a step with an empty list — a
    /// recording with clean electrodes should read as having no such stage.
    @Test func emptySetsProduceNoSteps() {
        #expect(ChannelDecisionSteps.steps(badChannels: [], interpolatedChannels: []).isEmpty)

        let onlyBad = ChannelDecisionSteps.steps(badChannels: [3], interpolatedChannels: [])
        #expect(onlyBad.map(\.operation) == [.markBad])

        let onlyInterpolated = ChannelDecisionSteps.steps(badChannels: [], interpolatedChannels: [3])
        #expect(onlyInterpolated.map(\.operation) == [.interpolateChannels])
    }

    /// Provenance, not instructions. Replaying "interpolate channel 8" onto
    /// another subject would repair a channel that may be perfectly good there.
    @Test func stepsAreNotReplayable() {
        let steps = ChannelDecisionSteps.steps(badChannels: [1], interpolatedChannels: [2])
        #expect(steps.allSatisfy { !$0.replayable })
        #expect(steps.allSatisfy { $0.note?.isEmpty == false })
        // And therefore invisible to the headless apply core.
        var script = EVAProcessingScript()
        for step in steps { script.append(step) }
        #expect(script.replayableSteps.isEmpty)
    }

    // MARK: - Placement

    @Test func stepsGoImmediatelyBeforeSegment() {
        let result = ChannelDecisionSteps.inserted(
            into: script([.mriGradientCorrection, .filter, .segment]),
            badChannels: [0],
            interpolatedChannels: [1]
        )
        #expect(result.steps.map(\.operation)
                == [.mriGradientCorrection, .filter, .markBad, .interpolateChannels, .segment])
    }

    @Test func stepsAreAppendedWhenThereIsNoSegment() {
        let result = ChannelDecisionSteps.inserted(
            into: script([.mriGradientCorrection, .filter]),
            badChannels: [0],
            interpolatedChannels: []
        )
        #expect(result.steps.map(\.operation) == [.mriGradientCorrection, .filter, .markBad])
    }

    /// The interactive and headless paths both run a script through this, and
    /// the headless one starts from a script that may already carry these steps
    /// (it was read from a package EVA wrote). Passing through twice must not
    /// duplicate them, and must reflect the *current* decisions, not the old.
    @Test func insertingIsIdempotentAndReflectsCurrentState() {
        let once = ChannelDecisionSteps.inserted(
            into: script([.filter, .segment]),
            badChannels: [0, 1],
            interpolatedChannels: []
        )
        let twice = ChannelDecisionSteps.inserted(
            into: once,
            badChannels: [0, 1],
            interpolatedChannels: []
        )
        #expect(once.steps.map(\.operation) == twice.steps.map(\.operation))
        #expect(twice.steps.filter { $0.operation == .markBad }.count == 1)

        // A later run that escalated another channel replaces the old list.
        let updated = ChannelDecisionSteps.inserted(
            into: once,
            badChannels: [0, 1, 9],
            interpolatedChannels: []
        )
        #expect(updated.steps.first { $0.operation == .markBad }?.parameters["channels"] == "1,2,10")
    }

    @Test func noDecisionsStripsStaleSteps() {
        // Someone unmarked every bad channel: the step must disappear rather
        // than linger describing a state that no longer exists.
        let withSteps = ChannelDecisionSteps.inserted(
            into: script([.filter]),
            badChannels: [0],
            interpolatedChannels: []
        )
        let cleared = ChannelDecisionSteps.inserted(
            into: withSteps,
            badChannels: [],
            interpolatedChannels: []
        )
        #expect(cleared.steps.map(\.operation) == [.filter])
    }

    // MARK: - Through eva.xml and onto the rail

    @Test func stepsSurviveTheXMLRoundTrip() throws {
        let outgoing = ChannelDecisionSteps.inserted(
            into: script([.filter]),
            badChannels: [16, 0],
            interpolatedChannels: [7]
        )

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-decisions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try EVAProcessingScriptXML.write(outgoing, toPackage: package)
        let read = try #require(EVAProcessingScriptXML.read(fromPackage: package))

        let bad = try #require(read.steps.first { $0.operation == .markBad })
        #expect(bad.parameters["channels"] == "1,17")
        #expect(!bad.replayable)

        let interpolated = try #require(read.steps.first { $0.operation == .interpolateChannels })
        #expect(interpolated.parameters["channels"] == "8")
    }

    /// The rail shows a count, not a list — a 40-channel rejection would push
    /// everything else off a 260 pt row. This is the node `REWIND.md`'s figure
    /// has always shown and the app could not previously produce.
    @Test func railRendersTheseAsCounts() {
        let steps = ChannelDecisionSteps.steps(
            badChannels: [0, 4, 16, 63],
            interpolatedChannels: [7, 20]
        )
        let bad = try? #require(steps.first { $0.operation == .markBad })
        #expect(HistoryStepSummary.title(for: .markBad) == "mark bad")
        #expect(bad.map(HistoryStepSummary.subtitle(for:)) == "4 ch")

        let interpolated = try? #require(steps.first { $0.operation == .interpolateChannels })
        #expect(HistoryStepSummary.title(for: .interpolateChannels) == "interpolate")
        #expect(interpolated.map(HistoryStepSummary.subtitle(for:)) == "2 ch · spherical spline")
    }

    /// The data loss a paired run exposed: `markBad` was carried in the script,
    /// never applied, and then **stripped** from the output — because the
    /// outgoing script is rebuilt from the run's own (empty) bad set. The batch
    /// output claimed no channels were bad when its own script said one was.
    @MainActor
    @Test func headlessCoreAppliesMarkBadAndPreservesItOnTheWayOut() async throws {
        let signal = SyntheticSignal.make(
            (0..<4).map { _ in [Float](repeating: 1, count: 200) },
            samplingRate: 100
        )
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

        let incoming = ChannelDecisionSteps.inserted(
            into: script([.filter]),
            badChannels: [0, 2],
            interpolatedChannels: []
        )
        _ = await core.applyAutoSteps(incoming, to: signal)

        #expect(store.channels.bad == [0, 2], "the mark must be applied, not just carried")

        // And therefore survives the rebuild of the outgoing script.
        let outgoing = ChannelDecisionSteps.inserted(
            into: incoming,
            badChannels: store.channels.bad,
            interpolatedChannels: Set(store.channels.interpolated.keys)
        )
        let markBad = try #require(outgoing.steps.first { $0.operation == .markBad })
        #expect(markBad.parameters["channels"] == "1,3")
    }

    /// Absolute, not additive — the step replaces the set rather than unioning,
    /// which is what makes "unmark a channel" an ordinary step.
    @MainActor
    @Test func applyingMarkBadReplacesRatherThanUnions() async throws {
        let signal = SyntheticSignal.make([[0, 1, 2, 3]], samplingRate: 100)
        let store = RecordingStore()
        store.channels.bad = [5, 9]
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

        var incoming = EVAProcessingScript()
        incoming.append(EVAProcessingStep(
            operation: .markBad,
            parameters: ["channels": "1"],
            replayable: false
        ))
        _ = await core.applyAutoSteps(incoming, to: signal)

        #expect(store.channels.bad == [0], "replaced, not unioned with 5 and 9")
    }

    @Test func historyGivesTheseStepsTheirOwnNodes() {
        let script = ChannelDecisionSteps.inserted(
            into: self.script([.filter, .segment]),
            badChannels: [0, 4],
            interpolatedChannels: [7]
        )
        let history = EVAHistory(recordingKey: "sub-014.mff", script: script)
        #expect(history.currentPath.compactMap { $0.step?.operation }
                == [.filter, .markBad, .interpolateChannels, .segment])

        // And a different set of bad channels is a different node, so the two
        // runs do not share a cached signal.
        let other = EVAHistory(recordingKey: "sub-014.mff", script: ChannelDecisionSteps.inserted(
            into: self.script([.filter, .segment]),
            badChannels: [0, 4, 9],
            interpolatedChannels: [7]
        ))
        #expect(history.currentID != other.currentID)
    }
}
