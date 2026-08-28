//
//  TrialExclusionResolverTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP TW-5. Three things have to hold before a reviewed exclusion can be
//  trusted to survive a file:
//
//  1. Everything committed comes back out of `eva.xml` — including the
//     restorations, which are the half a threshold cannot express.
//  2. A recorded key finds the same *trial* after an upstream change moved every
//     sample index, and says so when it finds nothing rather than applying the
//     part that still matched.
//  3. The history node identity covers the trial set, since it is an input, and
//     does NOT cover things that change no samples.
//

import Testing
import Foundation
@testable import EVA

struct TrialExclusionResolverTests {

    // MARK: - Fixtures

    /// Six trials, three per category, one event every two seconds.
    private func segments(
        startingAtSample start: Int = 0,
        epochLength: Int = 200,
        categories: [String] = ["LC++", "RC++"]
    ) -> [EpochSegment] {
        var out: [EpochSegment] = []
        var sample = start
        for index in 0 ..< 3 {
            for category in categories {
                out.append(EpochSegment(
                    startSample: sample,
                    endSample: sample + epochLength,
                    stimulusOffsetSamples: 50,
                    category: category,
                    sourceCode: "DIN1",
                    sourceTimeSeconds: Double(index) * 2 + (category == "LC++" ? 0 : 1),
                    colorIndex: 0,
                    contributingEpochCount: 1
                ))
                sample += epochLength
            }
        }
        return out
    }

    private func reviewed(
        _ category: String,
        index: Int,
        time: Double,
        reasons: [String] = ["r < 0.30"],
        origin: ExcludedTrial.Origin = .rule
    ) -> TrialExclusionResolver.ReviewedExclusion {
        TrialExclusionResolver.ReviewedExclusion(
            category: category,
            trialIndex: index,
            sourceTimeSeconds: time,
            reasons: reasons,
            origin: origin
        )
    }

    private var context: TrialExclusionResolver.ScoringContext {
        TrialExclusionResolver.ScoringContext(
            channelScope: "singleChannel",
            channels: ["Cz"],
            windowStartMs: 80,
            windowEndMs: 320
        )
    }

    private var criteria: TrialSelectionAnalyzer.Criteria {
        var criteria = TrialSelectionAnalyzer.Criteria()
        criteria.minCorrelation = 0.3
        criteria.minSlope = 0.4
        criteria.excludedClassifications = [.inverted]
        criteria.excludesMislabels = true
        return criteria
    }

    private func parse(_ script: EVAProcessingScript) throws -> EVAProcessingScript {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-trial-exclusion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try EVAProcessingScriptXML.write(script, toPackage: url)
        guard let read = EVAProcessingScriptXML.read(fromPackage: url) else {
            Issue.record("eva.xml did not parse")
            return EVAProcessingScript()
        }
        return read
    }

    // MARK: - Building the step

    @Test func buildingJoinsEachReviewedTrialToItsSourceCode() {
        let all = segments()
        let result = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 1, time: 2)],
            criteria: criteria,
            context: context,
            segments: all
        )

        #expect(result.isComplete)
        #expect(result.step.operation == .trialExclusion)
        #expect(result.step.excludedTrials.count == 1)
        let trial = result.step.excludedTrials[0]
        #expect(trial.category == "LC++")
        #expect(trial.sourceCode == "DIN1")
        #expect(trial.recordedIndex == 1)
        #expect(trial.origin == .rule)
    }

    /// A decision naming an event this file does not have must be reported, not
    /// written with an empty key that will silently fail to resolve later.
    @Test func buildingReportsAReviewedTrialWithNoMatchingSegment() {
        let result = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 999)],
            criteria: criteria,
            context: context,
            segments: segments()
        )

        #expect(!result.isComplete)
        #expect(result.unmatched.count == 1)
        #expect(result.step.excludedTrials.isEmpty)
    }

    @Test func theNoteCountsExclusionsAndRestorationsSeparately() {
        let result = TrialExclusionResolver.makeStep(
            reviewed: [
                reviewed("LC++", index: 0, time: 0),
                reviewed("LC++", index: 1, time: 2),
                reviewed("RC++", index: 0, time: 1, origin: .restored),
            ],
            criteria: criteria,
            context: context,
            segments: segments()
        )

        #expect(result.step.note == "Excluded 2 trials · 1 restored by operator")
    }

    // MARK: - eva.xml round trip

    @Test func everyRecordedFieldSurvivesTheFile() throws {
        var script = EVAProcessingScript()
        script.append(TrialExclusionResolver.makeStep(
            reviewed: [
                reviewed("LC++", index: 1, time: 2, reasons: ["r < 0.30", "β < 0.40"]),
                reviewed("RC++", index: 2, time: 5, reasons: [], origin: .manual),
                reviewed("RC++", index: 0, time: 1, reasons: ["inverted"], origin: .restored),
            ],
            criteria: criteria,
            context: context,
            segments: segments()
        ).step)

        let read = try parse(script)
        #expect(read.steps.count == 1)
        let step = read.steps[0]
        #expect(step.operation == .trialExclusion)
        #expect(step.excludedTrials.count == 3)

        let ruled = step.excludedTrials.first { $0.origin == .rule }
        #expect(ruled?.category == "LC++")
        #expect(ruled?.sourceCode == "DIN1")
        #expect(ruled?.recordedIndex == 1)
        #expect(ruled?.reasons == ["r < 0.30", "β < 0.40"])
        #expect(abs((ruled?.sourceTimeSeconds ?? 0) - 2) < 1e-9)

        // A trial with no reasons must not lose its identity to the
        // self-closing element the writer uses for it.
        let manual = step.excludedTrials.first { $0.origin == .manual }
        #expect(manual?.recordedIndex == 2)
        #expect(manual?.reasons.isEmpty == true)

        // The restoration is the whole "reviewed" claim. Losing it would leave a
        // file that reads as though the rule was never overruled.
        let restored = step.excludedTrials.first { $0.origin == .restored }
        #expect(restored?.isExcluded == false)
        #expect(restored?.reasons == ["inverted"])
    }

    @Test func theCriteriaSurviveTheFileAndReadBackAsCriteria() throws {
        var script = EVAProcessingScript()
        script.append(TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 0)],
            criteria: criteria,
            context: context,
            segments: segments()
        ).step)

        let step = try parse(script).steps[0]
        let restored = TrialExclusionResolver.criteria(from: step.parameters, category: "LC++")
        #expect(restored.minCorrelation == 0.3)
        #expect(restored.minSlope == 0.4)
        #expect(restored.maxResidualRMS == nil)
        #expect(restored.maxRobustDistance == nil)
        #expect(restored.excludedClassifications == [.inverted])
        #expect(restored.excludesMislabels)
    }

    /// "No bound on this measure" is a different state from "a bound at the end
    /// of its range", and an absent key is how the file says it.
    @Test func inactiveBoundsAreAbsentRatherThanWrittenAtTheirDefault() {
        let parameters = TrialExclusionResolver.parameters(for: .none)
        #expect(parameters["minCorrelation"] == nil)
        #expect(parameters["minSlope"] == nil)
        #expect(parameters["maxResidualRMS"] == nil)
        #expect(parameters["maxRobustDistance"] == nil)
        #expect(parameters["excludesMislabels"] == nil)
    }

    @Test func theScoringContextIsRecordedBecauseTheScoresAreMeaninglessWithoutIt() throws {
        var script = EVAProcessingScript()
        script.append(TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 0)],
            criteria: criteria,
            context: context,
            segments: segments()
        ).step)

        let parameters = try parse(script).steps[0].parameters
        #expect(parameters["LC++.channelScope"] == "singleChannel")
        #expect(parameters["LC++.channels"] == "Cz")
        #expect(parameters["LC++.leaveOneOut"] == "true")
        #expect(parameters["LC++.windowStartMs"] == "80.000")
        #expect(parameters["LC++.windowEndMs"] == "320.000")
    }

    // MARK: - Resolution

    @Test func resolutionFindsThePositionsTheAveragerDrops() {
        let all = segments()
        let step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 1, time: 2)],
            criteria: criteria,
            context: context,
            segments: all
        ).step

        let resolution = TrialExclusionResolver.resolve(step: step, segments: all)
        #expect(resolution.isComplete)
        #expect(resolution.excludedIndices.count == 1)
        let position = try! #require(resolution.excludedIndices.first)
        #expect(all[position].category == "LC++")
        #expect(abs(all[position].sourceTimeSeconds - 2) < 1e-9)
    }

    /// The reason the key is not an index. Re-segmenting with different bounds
    /// moves every `startSample` and can change how many trials precede a given
    /// one — and the recorded exclusion must still name the trial the operator
    /// actually looked at.
    @Test func aRecordedKeySurvivesAReSegmentThatMovesEverySampleIndex() {
        let original = segments()
        let step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 1, time: 2)],
            criteria: criteria,
            context: context,
            segments: original
        ).step

        // A different epoch window: every sample bound differs, the source
        // events do not.
        let reSegmented = segments(startingAtSample: 5_000, epochLength: 512)
        #expect(reSegmented[0].startSample != original[0].startSample)

        let resolution = TrialExclusionResolver.resolve(step: step, segments: reSegmented)
        #expect(resolution.isComplete)
        let position = try! #require(resolution.excludedIndices.first)
        #expect(reSegmented[position].category == "LC++")
        #expect(abs(reSegmented[position].sourceTimeSeconds - 2) < 1e-9)
    }

    /// A trial index that no longer means what it meant at commit time is
    /// harmless — the key is what is matched on — but the operator's numbering
    /// is stale, so it is reported rather than passed over in silence.
    @Test func aMovedTrialResolvesAndIsReported() {
        let original = segments()
        let step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 2, time: 4)],
            criteria: criteria,
            context: context,
            segments: original
        ).step

        // The first LC++ trial is gone, so the reviewed trial is now #1, not #2.
        let dropped = original.filter { !($0.category == "LC++" && $0.sourceTimeSeconds == 0) }
        let resolution = TrialExclusionResolver.resolve(step: step, segments: dropped)

        #expect(resolution.isComplete)
        #expect(resolution.excludedIndices.count == 1)
        #expect(resolution.movedIndices.count == 1)
        #expect(resolution.movedIndices.first?.recordedIndex == 2)
    }

    /// Applying the half that still matched would produce an average nobody
    /// reviewed, so a partial resolution is a failure, not a partial success.
    @Test func aPartiallyResolvedStepIsNotComplete() {
        let all = segments()
        var step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 0)],
            criteria: criteria,
            context: context,
            segments: all
        ).step
        step.excludedTrials.append(ExcludedTrial(
            category: "LC++",
            sourceCode: "DIN1",
            sourceTimeSeconds: 999,
            recordedIndex: 7
        ))

        let resolution = TrialExclusionResolver.resolve(step: step, segments: all)
        #expect(!resolution.isComplete)
        #expect(resolution.unresolved.count == 1)
        #expect(resolution.excludedIndices.count == 1, "the matched half is still reported, for the caller to show")
    }

    /// A restoration excludes nothing, so its disappearance leaves nothing about
    /// the average in doubt and must not block the step.
    @Test func aMissingRestorationDoesNotMakeTheStepUnresolvable() {
        let all = segments()
        var step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 0)],
            criteria: criteria,
            context: context,
            segments: all
        ).step
        step.excludedTrials.append(ExcludedTrial(
            category: "LC++",
            sourceCode: "DIN1",
            sourceTimeSeconds: 999,
            recordedIndex: 7,
            origin: .restored
        ))

        let resolution = TrialExclusionResolver.resolve(step: step, segments: all)
        #expect(resolution.isComplete)
        #expect(resolution.unresolved.isEmpty)
    }

    /// A script from another subject names that subject's events. Resolving
    /// nothing is the correct answer, and it is what keeps one subject's
    /// reviewed trial list off another subject's data.
    @Test func anotherSubjectsKeysResolveToNothing() {
        let step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 0)],
            criteria: criteria,
            context: context,
            segments: segments()
        ).step

        let otherSubject = segments(categories: ["GoTrial", "NoGo"])
        let resolution = TrialExclusionResolver.resolve(step: step, segments: otherSubject)
        #expect(!resolution.isComplete)
        #expect(resolution.excludedIndices.isEmpty)
    }

    /// A pooled category is built from its members' trials, but it is a
    /// different average and was reviewed separately. Excluding a trial from
    /// `LC++` must not silently reach into `correct`.
    @Test func exclusionAppliesToTheReviewedCategoryOnly() {
        var all = segments()
        // The same event, contributing to the pooled category as well.
        all.append(EpochSegment(
            startSample: 9_000,
            endSample: 9_200,
            stimulusOffsetSamples: 50,
            category: "correct",
            sourceCode: "DIN1",
            sourceTimeSeconds: 2,
            colorIndex: 1,
            contributingEpochCount: 1
        ))

        let step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 1, time: 2)],
            criteria: criteria,
            context: context,
            segments: all
        ).step

        let resolution = TrialExclusionResolver.resolve(step: step, segments: all)
        #expect(resolution.excludedIndices.count == 1)
        let excludedCategories = resolution.excludedIndices.map { all[$0].category }
        #expect(excludedCategories == ["LC++"])
    }

    @Test func perCategoryCountsFeedTheExclusionSummary() {
        let all = segments()
        let step = TrialExclusionResolver.makeStep(
            reviewed: [
                reviewed("LC++", index: 0, time: 0),
                reviewed("LC++", index: 1, time: 2),
                reviewed("RC++", index: 0, time: 1),
            ],
            criteria: criteria,
            context: context,
            segments: all
        ).step

        let resolution = TrialExclusionResolver.resolve(step: step, segments: all)
        let counts = TrialExclusionResolver.excludedCountsByCategory(
            step: step, segments: all, resolution: resolution
        )
        #expect(counts["LC++"] == 2)
        #expect(counts["RC++"] == 1)
    }

    // MARK: - Replay classification

    @Test func aResolvableStepReplaysFromTheFilesOwnRecordWithoutAsking() {
        let all = segments()
        let step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 0)],
            criteria: criteria,
            context: context,
            segments: all
        ).step
        var script = EVAProcessingScript()
        script.append(step)

        var availability = ReplayPayloadAvailability.none
        availability.resolvedTrialExclusionStepIDs =
            TrialExclusionResolver.resolvableStepIDs(in: script, segments: all)

        #expect(availability.resolvedTrialExclusionStepIDs.contains(script.steps[0].id))
        #expect(script.steps[0].replayInteraction(given: availability) == .resolvedFromPayload)
    }

    /// Knowing nothing about the file — and on another subject's data — the
    /// recorded trial list must never be applied. The criteria are re-proposed
    /// for review instead.
    @Test func anUnresolvableStepBecomesADecision() {
        let step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 0)],
            criteria: criteria,
            context: context,
            segments: segments()
        ).step
        var script = EVAProcessingScript()
        script.append(step)

        #expect(script.steps[0].replayInteraction == .decision)

        var availability = ReplayPayloadAvailability.none
        availability.resolvedTrialExclusionStepIDs = TrialExclusionResolver.resolvableStepIDs(
            in: script, segments: segments(categories: ["GoTrial", "NoGo"])
        )
        #expect(availability.resolvedTrialExclusionStepIDs.isEmpty)
        #expect(script.steps[0].replayInteraction(given: availability) == .decision)
    }

    /// The step stays replayable: the thresholds are portable even though the
    /// trial list is not, so Copy Processing must carry it rather than drop it.
    @Test func theStepIsCarriedByCopyProcessing() {
        let step = TrialExclusionResolver.makeStep(
            reviewed: [reviewed("LC++", index: 0, time: 0)],
            criteria: criteria,
            context: context,
            segments: segments()
        ).step
        #expect(step.replayable)
    }

    // MARK: - History identity

    private func historyStep(_ reviewedSet: [TrialExclusionResolver.ReviewedExclusion]) -> EVAProcessingStep {
        TrialExclusionResolver.makeStep(
            reviewed: reviewedSet, criteria: criteria, context: context, segments: segments()
        ).step
    }

    /// The trial set is an *input* to the average, unlike `rejections`, so it
    /// has to reach the node ID as a payload digest. Two different reviewed sets
    /// hashing alike would serve one average out of the cache for the other.
    @Test func adifferentTrialSetIsADifferentNode() {
        var history = EVAHistory(recordingKey: "r")
        let a = historyStep([reviewed("LC++", index: 0, time: 0)])
        let b = historyStep([reviewed("LC++", index: 1, time: 2)])

        let first = history.apply(a, payloadDigest: EVAHistory.digest([a.trialExclusionIdentityBytes.base64EncodedString()]))
        history.stepBack()
        let second = history.apply(b, payloadDigest: EVAHistory.digest([b.trialExclusionIdentityBytes.base64EncodedString()]))

        #expect(first != second)
    }

    @Test func recommittingTheSameSetDeduplicates() {
        var history = EVAHistory(recordingKey: "r")
        let a = historyStep([reviewed("LC++", index: 0, time: 0)])
        let b = historyStep([reviewed("LC++", index: 0, time: 0)])
        // Distinct step values — `id` and `appliedAt` differ — but the same
        // decision, which is what the content-addressed ID is supposed to see.
        #expect(a.id != b.id)

        let first = history.apply(a, payloadDigest: EVAHistory.digest([a.trialExclusionIdentityBytes.base64EncodedString()]))
        history.stepBack()
        let second = history.apply(b, payloadDigest: EVAHistory.digest([b.trialExclusionIdentityBytes.base64EncodedString()]))

        #expect(first == second)
        #expect(history.count == 2, "re-committing the same reviewed set must not fork the tree")
    }

    /// Same rule as the ICA payload: two records that produce identical samples
    /// must produce identical digests. A restoration removes nothing, so a node
    /// that excludes the same trials is the same node whether or not the
    /// operator also put a third trial back.
    @Test func aRestorationAloneDoesNotChangeTheNode() {
        let excludingOnly = historyStep([reviewed("LC++", index: 0, time: 0)])
        let alsoRestoring = historyStep([
            reviewed("LC++", index: 0, time: 0),
            reviewed("RC++", index: 0, time: 1, origin: .restored),
        ])

        #expect(excludingOnly.trialExclusionIdentityBytes == alsoRestoring.trialExclusionIdentityBytes)
        // …and the restoration is still on the step, for the file to record.
        #expect(alsoRestoring.excludedTrials.count == 2)
    }

    @Test func reviewOrderDoesNotChangeTheNode() {
        let forward = historyStep([
            reviewed("LC++", index: 0, time: 0),
            reviewed("RC++", index: 1, time: 3),
        ])
        let reversed = historyStep([
            reviewed("RC++", index: 1, time: 3),
            reviewed("LC++", index: 0, time: 0),
        ])
        #expect(forward.trialExclusionIdentityBytes == reversed.trialExclusionIdentityBytes)
    }

    /// Re-tuning a threshold to the same surviving trials still forks, because
    /// the criteria live in `parameters` and `EVAHistory` hashes those. One
    /// recomputed average buys a history rail that shows the thresholds actually
    /// used — see `trialExclusionIdentityBytes`.
    @Test func differentThresholdsForkEvenWhenTheTrialSetMatches() {
        var history = EVAHistory(recordingKey: "r")
        let reviewedSet = [reviewed("LC++", index: 0, time: 0)]

        var looser = TrialSelectionAnalyzer.Criteria()
        looser.minCorrelation = 0.2

        let a = TrialExclusionResolver.makeStep(
            reviewed: reviewedSet, criteria: criteria, context: context, segments: segments()
        ).step
        let b = TrialExclusionResolver.makeStep(
            reviewed: reviewedSet, criteria: looser, context: context, segments: segments()
        ).step
        #expect(a.trialExclusionIdentityBytes == b.trialExclusionIdentityBytes)

        let first = history.apply(a, payloadDigest: EVAHistory.digest([a.trialExclusionIdentityBytes.base64EncodedString()]))
        history.stepBack()
        let second = history.apply(b, payloadDigest: EVAHistory.digest([b.trialExclusionIdentityBytes.base64EncodedString()]))
        #expect(first != second)
    }

    // MARK: - Rail rendering

    @Test func theRailSaysWhatWasExcludedAndThatTheRuleWasOverruled() {
        let step = historyStep([
            reviewed("LC++", index: 0, time: 0),
            reviewed("LC++", index: 1, time: 2),
            reviewed("RC++", index: 0, time: 1, origin: .restored),
        ])
        let subtitle = HistoryStepSummary.subtitle(for: step)

        #expect(subtitle.contains("2 trials"))
        #expect(subtitle.contains("r<0.3"))
        #expect(subtitle.contains("β<0.4"))
        #expect(subtitle.contains("1 restored"))
        #expect(HistoryStepSummary.title(for: .trialExclusion) == "exclude trials")
    }

    // MARK: - Per-category merge

    private func context(channel: String) -> TrialExclusionResolver.ScoringContext {
        TrialExclusionResolver.ScoringContext(
            channelScope: "singleChannel", channels: [channel],
            windowStartMs: 80, windowEndMs: 320
        )
    }

    private func commit(
        _ reviewedSet: [TrialExclusionResolver.ReviewedExclusion],
        for category: String,
        criteria: TrialSelectionAnalyzer.Criteria? = nil,
        channel: String = "Cz",
        into existing: EVAProcessingStep?
    ) -> EVAProcessingStep {
        TrialExclusionResolver.merged(
            reviewed: reviewedSet,
            for: category,
            criteria: criteria ?? self.criteria,
            context: context(channel: channel),
            into: existing,
            segments: segments()
        ).step
    }

    /// The failure this merge exists to prevent, and the reason it is hard to
    /// notice by hand: the category in front of you would look correct.
    @Test func committingASecondCategoryKeepsTheFirst() {
        let first = commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        let second = commit([reviewed("RC++", index: 1, time: 3)], for: "RC++", into: first)

        #expect(second.excludedTrials.count == 2)
        #expect(second.excludedTrials.filter { $0.category == "LC++" }.count == 1)
        #expect(second.excludedTrials.filter { $0.category == "RC++" }.count == 1)
    }

    @Test func recommittingACategoryReplacesOnlyItsOwnTrials() {
        let first = commit(
            [reviewed("LC++", index: 0, time: 0), reviewed("LC++", index: 1, time: 2)],
            for: "LC++", into: nil
        )
        let withOther = commit([reviewed("RC++", index: 1, time: 3)], for: "RC++", into: first)
        // A second look at LC++ keeps only one trial this time.
        let reviewedAgain = commit([reviewed("LC++", index: 1, time: 2)], for: "LC++", into: withOther)

        #expect(reviewedAgain.excludedTrials.filter { $0.category == "LC++" }.count == 1)
        #expect(reviewedAgain.excludedTrials.filter { $0.category == "RC++" }.count == 1)
    }

    /// Each category carries its own thresholds, so re-tuning for one must not
    /// rewrite the rule recorded against the other.
    @Test func eachCategoryKeepsItsOwnCriteria() {
        var looser = TrialSelectionAnalyzer.Criteria()
        looser.minCorrelation = 0.1

        let first = commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        let second = commit(
            [reviewed("RC++", index: 1, time: 3)], for: "RC++", criteria: looser, into: first
        )

        #expect(TrialExclusionResolver.criteria(from: second.parameters, category: "LC++").minCorrelation == 0.3)
        #expect(TrialExclusionResolver.criteria(from: second.parameters, category: "RC++").minCorrelation == 0.1)
    }

    /// …and its own scoring context, since one category can be reviewed on a
    /// different channel from the next.
    @Test func eachCategoryKeepsItsOwnScoringContext() {
        let first = commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", channel: "Cz", into: nil)
        let second = commit([reviewed("RC++", index: 1, time: 3)], for: "RC++", channel: "Pz", into: first)

        #expect(second.parameters["LC++.channels"] == "Cz")
        #expect(second.parameters["RC++.channels"] == "Pz")
    }

    /// A bound switched off during a re-review must not survive as a stale key,
    /// or the file would claim a rule that did not produce this decision.
    @Test func aBoundSwitchedOffIsRemovedOnRecommit() {
        let first = commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        #expect(first.parameters["LC++.minSlope"] != nil)

        var onlyCorrelation = TrialSelectionAnalyzer.Criteria()
        onlyCorrelation.minCorrelation = 0.3
        let second = commit(
            [reviewed("LC++", index: 0, time: 0)], for: "LC++", criteria: onlyCorrelation, into: first
        )

        #expect(second.parameters["LC++.minSlope"] == nil)
        #expect(second.parameters["LC++.minCorrelation"] != nil)
    }

    /// Committing another category edits the same decision. A new step id would
    /// invalidate `resolvedTrialExclusionStepIDs` and turn a resolvable
    /// exclusion back into a prompt.
    @Test func mergingKeepsTheStepIdentity() {
        let first = commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        let second = commit([reviewed("RC++", index: 1, time: 3)], for: "RC++", into: first)
        #expect(first.id == second.id)
    }

    @Test func reviewedDecisionsForOtherCategoriesAreIgnored() {
        let step = commit(
            [reviewed("LC++", index: 0, time: 0), reviewed("RC++", index: 1, time: 3)],
            for: "LC++", into: nil
        )
        #expect(step.excludedTrials.count == 1)
        #expect(step.excludedTrials.allSatisfy { $0.category == "LC++" })
    }

    @Test func committingAnEmptySetForACategoryClearsIt() {
        let both = commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into:
            commit([reviewed("RC++", index: 1, time: 3)], for: "RC++", into: nil))
        let cleared = commit([], for: "LC++", into: both)

        #expect(cleared.excludedTrials.filter { $0.category == "LC++" }.isEmpty)
        #expect(cleared.excludedTrials.filter { $0.category == "RC++" }.count == 1)
    }

    @Test func removingTheLastCategoryRemovesTheStepEntirely() {
        let only = commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        #expect(TrialExclusionResolver.removing(category: "LC++", from: only) == nil)

        let both = commit([reviewed("RC++", index: 1, time: 3)], for: "RC++", into: only)
        let remaining = TrialExclusionResolver.removing(category: "LC++", from: both)
        #expect(remaining?.excludedTrials.count == 1)
        #expect(remaining?.parameters["LC++.minCorrelation"] == nil)
    }

    @Test func categoriesReportsEveryCategoryTheStepCarries() {
        let step = commit([reviewed("RC++", index: 1, time: 3)], for: "RC++", into:
            commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil))
        #expect(TrialExclusionResolver.categories(in: step) == ["LC++", "RC++"])
    }

    /// A category whose own name contains a dot still resolves, because the key
    /// is parsed on the last one.
    @Test func aCategoryNameContainingADotStillKeysCorrectly() {
        let parameters = TrialExclusionResolver.parameters(for: criteria, category: "stim.1")
        #expect(parameters["stim.1.minCorrelation"] != nil)
        #expect(TrialExclusionResolver.criteria(from: parameters, category: "stim.1").minCorrelation == 0.3)
    }

    /// A step written before the split carries unkeyed parameters meaning "this
    /// rule applied to everything", and must keep reading that way.
    @Test func unkeyedLegacyParametersStillReadAsARule() {
        let legacy = TrialExclusionResolver.parameters(for: criteria)
        #expect(TrialExclusionResolver.criteria(from: legacy, category: "LC++").minCorrelation == 0.3)
        #expect(TrialExclusionResolver.criteria(from: legacy).minCorrelation == 0.3)
    }

    /// The rail must not attribute one category's thresholds to a decision made
    /// under another's.
    @Test func theRailSaysHowManyRulesWhenCategoriesDisagree() {
        var looser = TrialSelectionAnalyzer.Criteria()
        looser.minCorrelation = 0.1
        let step = commit(
            [reviewed("RC++", index: 1, time: 3)], for: "RC++", criteria: looser, into:
                commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        )
        #expect(HistoryStepSummary.subtitle(for: step).contains("2 rules"))
    }

    // MARK: - Per-category clearing

    @Test func clearingOneCategoryLeavesTheOthersCriteriaIntact() {
        var looser = TrialSelectionAnalyzer.Criteria()
        looser.minCorrelation = 0.1

        let both = commit(
            [reviewed("RC++", index: 1, time: 3)], for: "RC++", criteria: looser, channel: "Pz", into:
                commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        )
        let remaining = TrialExclusionResolver.removing(category: "LC++", from: both)

        #expect(remaining?.excludedTrials.map(\.category) == ["RC++"])
        #expect(remaining?.parameters["RC++.minCorrelation"] == "0.1000")
        #expect(remaining?.parameters["RC++.channels"] == "Pz")
        #expect(remaining?.parameters["LC++.channels"] == nil)
        #expect(remaining?.id == both.id, "clearing a category edits the decision, it does not start a new one")
    }

    /// The rule is "does anything still get excluded", not "are there any
    /// trials left". A step carrying only restorations records that the rule
    /// was overruled everywhere and removes nothing — a record committing could
    /// never have produced, so clearing must not produce it either.
    @Test func clearingDownToRestorationsOnlyRemovesTheStep() {
        let both = commit(
            [reviewed("RC++", index: 0, time: 1, origin: .restored)], for: "RC++", into:
                commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        )
        #expect(both.excludedTrials.count == 2)
        #expect(TrialExclusionResolver.removing(category: "LC++", from: both) == nil)
    }

    @Test func clearingACategoryThatWasNeverCommittedChangesNothing() {
        let only = commit([reviewed("LC++", index: 0, time: 0)], for: "LC++", into: nil)
        let after = TrialExclusionResolver.removing(category: "RC++", from: only)
        #expect(after?.excludedTrials.count == 1)
        #expect(after?.parameters["LC++.minCorrelation"] != nil)
    }
}
