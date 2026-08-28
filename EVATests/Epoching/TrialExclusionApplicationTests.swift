//
//  TrialExclusionApplicationTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP TW-5, the half that changes data: a committed exclusion has to reach
//  the average through `ProcessingCore` — the path a headless batch takes — and
//  not merely round-trip through `eva.xml`.
//
//  `anExcludedTrialActuallyChangesTheAverage` is here so none of the rest can
//  pass vacuously. Every other test asserts on counts and reasons, and counts
//  would go on agreeing perfectly if the exclusion never touched a sample.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct TrialExclusionApplicationTests {

    // MARK: - Harness

    private func makeCore() -> ProcessingCore {
        let store = RecordingStore()
        return ProcessingCore(
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
    }

    private let samplingRate: Double = 500
    private let spacing = 1000

    /// Six trials. Trial 3 is given a large DC offset so removing it moves the
    /// average by an amount no rounding can explain — the alternative is a test
    /// that "passes" against an average that never changed.
    private func signal(nEvents: Int = 6, offsetTrial: Int? = nil, offset: Float = 50) -> MFFSignalData {
        let sampleCount = spacing * (nEvents + 1)
        var channel = [Float](repeating: 0, count: sampleCount)
        var state: UInt64 = 99
        for i in channel.indices {
            state = state &* 6364136223846793005 &+ 1
            channel[i] = Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
        }
        if let offsetTrial {
            let center = offsetTrial * spacing
            for i in max(0, center - spacing / 2) ..< min(sampleCount, center + spacing / 2) {
                channel[i] += offset
            }
        }

        let events = (1 ... nEvents).map { index in
            MFFEvent(
                id: "stim\(index)",
                code: "stim",
                beginTimeSeconds: Double(index * spacing) / samplingRate,
                rawBeginTime: "\(index * spacing)",
                sourceFile: "test"
            )
        }

        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/trial-exclusion.bin"),
            signalType: "EEG",
            numberOfChannels: 1,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: events,
            data: [channel],
            channelNames: ["E1"]
        )
    }

    /// The source event time an exclusion key has to name, for trial `index`
    /// (1-based, matching the event ids above).
    private func eventTime(_ index: Int) -> Double {
        Double(index * spacing) / samplingRate
    }

    private func script(excluding exclusion: EVAProcessingStep? = nil) -> EVAProcessingScript {
        var script = EVAProcessingScript()
        if let exclusion { script.append(exclusion) }
        script.append(EVAProcessingStep(operation: .segment, parameters: [
            "eventCodes": "stim",
            "preStimulusMs": "40",
            "postStimulusMs": "120",
            "average": "true",
            "interpolateBadChannelsPerEpoch": "false",
        ]))
        return script
    }

    private func exclusionStep(
        trials: [(index: Int, event: Int)],
        origin: ExcludedTrial.Origin = .rule,
        category: String = "stim"
    ) -> EVAProcessingStep {
        var criteria = TrialSelectionAnalyzer.Criteria()
        criteria.minCorrelation = 0.3
        return EVAProcessingStep(
            operation: .trialExclusion,
            parameters: TrialExclusionResolver.parameters(for: criteria),
            excludedTrials: trials.map {
                ExcludedTrial(
                    category: category,
                    sourceCode: "stim",
                    sourceTimeSeconds: eventTime($0.event),
                    recordedIndex: $0.index,
                    reasons: ["r < 0.30"],
                    origin: origin
                )
            }
        )
    }

    private func averageSamples(_ core: ProcessingCore) throws -> [Float] {
        let signal = try #require(core.epoching.epochedSignal)
        return try #require(signal.data.first)
    }

    // MARK: - The exclusion reaches the samples

    /// Non-vacuity. Everything else in this file counts things; this is the one
    /// that proves there is something to count.
    @Test func anExcludedTrialActuallyChangesTheAverage() async throws {
        let input = signal(offsetTrial: 3)

        let keptAll = makeCore()
        _ = await keptAll.applyAutoSteps(script(), to: input)
        let withEverything = try averageSamples(keptAll)

        let excluded = makeCore()
        _ = await excluded.applyAutoSteps(
            script(excluding: exclusionStep(trials: [(index: 2, event: 3)])),
            to: input
        )
        let withoutTrialThree = try averageSamples(excluded)

        #expect(withEverything.count == withoutTrialThree.count)
        let biggestDifference = zip(withEverything, withoutTrialThree)
            .map { abs($0 - $1) }
            .max() ?? 0
        // The offset trial carries +50 µV over a sixth of the average, so
        // removing it must move it by several µV. A tolerance-sized difference
        // would mean the exclusion never reached the averager.
        #expect(biggestDifference > 1, "excluding a trial did not change the average")
    }

    /// A restoration is provenance, not an exclusion. It must leave the samples
    /// exactly as they were.
    @Test func aRestoredTrialLeavesTheAverageAlone() async throws {
        let input = signal(offsetTrial: 3)

        let untouched = makeCore()
        _ = await untouched.applyAutoSteps(script(), to: input)

        let restored = makeCore()
        _ = await restored.applyAutoSteps(
            script(excluding: exclusionStep(trials: [(index: 2, event: 3)], origin: .restored)),
            to: input
        )

        #expect(try averageSamples(untouched) == (try averageSamples(restored)))
    }

    // MARK: - Attribution

    @Test func theExcludedTrialIsDebitedToItsCategoryWithItsReason() async throws {
        let core = makeCore()
        _ = await core.applyAutoSteps(
            script(excluding: exclusionStep(trials: [(index: 2, event: 3)])),
            to: signal()
        )

        let tally = try #require(core.epoching.psaExclusionSummary.perCategory["stim"])
        #expect(tally.candidates == 6)
        #expect(tally.accepted == 5, "an excluded trial must not still count as included")
        #expect(tally.reasons[TrialExclusionResolver.reasonLabel] == 1)
    }

    /// The retention story an MFF cannot tell on its own — this is what reaches
    /// QuickLook's bars and `RecordingCombiner`.
    @Test func theExclusionReachesTheCategoryRejectionsEvaXMLWrites() async throws {
        let core = makeCore()
        _ = await core.applyAutoSteps(
            script(excluding: exclusionStep(trials: [(index: 1, event: 2), (index: 2, event: 3)])),
            to: signal()
        )

        let rejections = core.epoching.psaExclusionSummary.categoryRejections
        let stim = try #require(rejections.first { $0.category == "stim" })
        #expect(stim.total == 6)
        #expect(stim.included == 4)
        #expect(stim.reasons[TrialExclusionResolver.reasonLabel] == 2)
    }

    @Test func theResolutionIsPublishedForTheStatusLine() async throws {
        let core = makeCore()
        _ = await core.applyAutoSteps(
            script(excluding: exclusionStep(trials: [(index: 2, event: 3)])),
            to: signal()
        )

        let resolution = try #require(core.epoching.trialExclusionResolution)
        #expect(resolution.isComplete)
        #expect(resolution.excludedIndices.count == 1)
    }

    // MARK: - Safety

    /// The structural property the whole design rests on: a script from another
    /// subject names events this file does not have, so it removes nothing —
    /// and nothing in the walk has to know whose file it is looking at.
    @Test func aScriptFromAnotherSubjectExcludesNothingAndSaysSo() async throws {
        let input = signal(offsetTrial: 3)

        let untouched = makeCore()
        _ = await untouched.applyAutoSteps(script(), to: input)

        let foreign = makeCore()
        // Times no event in this recording sits at.
        var step = exclusionStep(trials: [(index: 0, event: 3)])
        step.excludedTrials = step.excludedTrials.map {
            var trial = $0
            trial.sourceTimeSeconds += 137
            return trial
        }
        _ = await foreign.applyAutoSteps(script(excluding: step), to: input)

        #expect(try averageSamples(untouched) == (try averageSamples(foreign)))
        let resolution = try #require(foreign.epoching.trialExclusionResolution)
        #expect(!resolution.isComplete)
        #expect(resolution.unresolved.count == 1)
        #expect(resolution.excludedIndices.isEmpty)
    }

    /// A trial the operator excluded that no longer exists cannot be silently
    /// forgiven: the average on screen is not the reviewed one, and the summary
    /// must not claim it is.
    @Test func aPartlyUnresolvableExclusionAppliesWhatMatchedAndReportsTheRest() async throws {
        let core = makeCore()
        var step = exclusionStep(trials: [(index: 2, event: 3)])
        step.excludedTrials.append(ExcludedTrial(
            category: "stim",
            sourceCode: "stim",
            sourceTimeSeconds: 999,
            recordedIndex: 9,
            reasons: ["r < 0.30"]
        ))
        _ = await core.applyAutoSteps(script(excluding: step), to: signal())

        let resolution = try #require(core.epoching.trialExclusionResolution)
        #expect(!resolution.isComplete)
        #expect(resolution.excludedIndices.count == 1)
        #expect(resolution.unresolved.count == 1)
    }

    // MARK: - Round trip through the file

    /// The end-to-end claim: what one run committed, another run reads back out
    /// of `eva.xml` and applies to the same samples.
    @Test func aCommittedExclusionSurvivesTheFileAndReproducesTheAverage() async throws {
        let input = signal(offsetTrial: 3)

        let first = makeCore()
        let committed = script(excluding: exclusionStep(trials: [(index: 2, event: 3)]))
        _ = await first.applyAutoSteps(committed, to: input)
        let original = try averageSamples(first)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trial-exclusion-\(UUID().uuidString).mff")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try EVAProcessingScriptXML.write(committed, toPackage: directory)
        let reloaded = try #require(EVAProcessingScriptXML.read(fromPackage: directory))

        let second = makeCore()
        _ = await second.applyAutoSteps(reloaded, to: input)

        #expect(try averageSamples(second) == original)
        #expect(second.epoching.trialExclusionResolution?.isComplete == true)
    }

    // MARK: - Re-averaging must not accumulate

    /// A post-processing toggle re-averages from a summary that already carries
    /// this reason's counts. An incrementing fold would grow them on every
    /// toggle until the file claimed more exclusions than the category had
    /// trials — and it would look plausible for the first few toggles.
    @Test func restatingAnExclusionDoesNotAccumulate() {
        var summary = PSAExclusionSummary()
        summary.perCategory["stim"] = PSAExclusionSummary.CategoryTally(candidates: 6, accepted: 6)

        for _ in 0 ..< 4 {
            summary.recordExclusions(["stim": 2], reason: TrialExclusionResolver.reasonLabel)
        }

        let tally = summary.perCategory["stim"]
        #expect(tally?.accepted == 4)
        #expect(tally?.reasons[TrialExclusionResolver.reasonLabel] == 2)
    }

    /// Clearing has to reach the summary as "nothing", or the removed decision
    /// goes on being reported by a summary nobody updated.
    @Test func clearingAnExclusionRestoresTheAcceptedCount() {
        var summary = PSAExclusionSummary()
        summary.perCategory["stim"] = PSAExclusionSummary.CategoryTally(candidates: 6, accepted: 6)

        summary.recordExclusions(["stim": 2], reason: TrialExclusionResolver.reasonLabel)
        summary.recordExclusions([:], reason: TrialExclusionResolver.reasonLabel)

        let tally = summary.perCategory["stim"]
        #expect(tally?.accepted == 6)
        #expect(tally?.reasons[TrialExclusionResolver.reasonLabel] == nil,
                "a reason that excluded nothing is noise in the retention story")
    }

    @Test func revisingAnExclusionDownwardRestoresTheDifference() {
        var summary = PSAExclusionSummary()
        summary.perCategory["stim"] = PSAExclusionSummary.CategoryTally(candidates: 6, accepted: 6)

        summary.recordExclusions(["stim": 3], reason: TrialExclusionResolver.reasonLabel)
        summary.recordExclusions(["stim": 1], reason: TrialExclusionResolver.reasonLabel)

        #expect(summary.perCategory["stim"]?.accepted == 5)
        #expect(summary.perCategory["stim"]?.reasons[TrialExclusionResolver.reasonLabel] == 1)
    }

    /// Other reasons are recorded by the build and must survive a restatement
    /// of this one.
    @Test func restatingOneReasonLeavesOthersAlone() {
        var summary = PSAExclusionSummary()
        var tally = PSAExclusionSummary.CategoryTally(candidates: 8, accepted: 6)
        tally.reasons["Out of bounds"] = 2
        summary.perCategory["stim"] = tally

        summary.recordExclusions(["stim": 2], reason: TrialExclusionResolver.reasonLabel)
        summary.recordExclusions(["stim": 2], reason: TrialExclusionResolver.reasonLabel)

        #expect(summary.perCategory["stim"]?.reasons["Out of bounds"] == 2)
        #expect(summary.perCategory["stim"]?.accepted == 4)
    }

    // MARK: - The decision is derived from the script, never left over

    /// A batch reuses one `ProcessingCore` across files. If the committed
    /// exclusion were merely *set* by a script that names one and never cleared
    /// by one that does not, the second file would inherit the first's decision
    /// — and because the keys would resolve to nothing, it would inherit it
    /// silently as "0 excluded, 2 unresolved" rather than as an error.
    ///
    /// This is the `ReplaySettingsRestore` rule in its third instance: an absent
    /// step cannot say it is absent, so the state is derived totally from the
    /// path rather than left alone.
    @Test func aSecondScriptWithoutAnExclusionDoesNotInheritTheFirsts() async throws {
        let input = signal(offsetTrial: 3)
        let core = makeCore()

        _ = await core.applyAutoSteps(
            script(excluding: exclusionStep(trials: [(index: 2, event: 3)])),
            to: input
        )
        #expect(core.epoching.committedTrialExclusion != nil)
        let withExclusion = try averageSamples(core)

        // The same core, now handed a script that names no exclusion.
        _ = await core.applyAutoSteps(script(), to: input)

        #expect(core.epoching.committedTrialExclusion == nil, "a leftover decision survived the next file")
        let withoutExclusion = try averageSamples(core)
        #expect(withExclusion != withoutExclusion, "the two runs must actually differ, or this proves nothing")

        // And the retention story is restored, not left claiming a trial the
        // average now contains.
        let tally = try #require(core.epoching.psaExclusionSummary.perCategory["stim"])
        #expect(tally.accepted == 6)
        #expect(tally.reasons[TrialExclusionResolver.reasonLabel] == nil)
    }

    /// The other direction: a script that names one must still apply it after a
    /// script that did not, or clearing would be sticky.
    @Test func anExclusionStillAppliesAfterAScriptWithoutOne() async throws {
        let input = signal(offsetTrial: 3)
        let core = makeCore()

        _ = await core.applyAutoSteps(script(), to: input)
        let plain = try averageSamples(core)

        _ = await core.applyAutoSteps(
            script(excluding: exclusionStep(trials: [(index: 2, event: 3)])),
            to: input
        )

        #expect(core.epoching.committedTrialExclusion != nil)
        #expect(try averageSamples(core) != plain)
    }
}
