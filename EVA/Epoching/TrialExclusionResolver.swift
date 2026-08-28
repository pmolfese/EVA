//
//  TrialExclusionResolver.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Trial-wise Phase 3, committed: turning a reviewed exclusion set into a
//  `trialExclusion` step, and turning that step back into the segment indices
//  the averager drops.
//
//  This is deliberately the ONLY place source event keys become positions.
//  Before it, a manual exclusion was interactive session state with no headless
//  equivalent — see the comment at `EpochingViewModel.applyBuildJob` — so
//  interactive and batch runs of the same recording could not produce the same
//  average. One resolver, called from both, is what closes that.
//

import Foundation

nonisolated enum TrialExclusionResolver {

    // MARK: - Scoring context

    /// What the `r`/`β`/residual numbers in the recorded reasons were computed
    /// on. Provenance, not configuration: the scores are uninterpretable
    /// without it, and none of it is recoverable from the trial list.
    struct ScoringContext: Sendable, Equatable {
        /// `SingleTrialChannelScope`'s label — one channel, or an ROI average.
        var channelScope: String
        /// The channels behind that scope, as displayed.
        var channels: [String]
        var windowStartMs: Double?
        var windowEndMs: Double?
        /// Every similarity score is leave-one-out. Recorded rather than
        /// assumed, so a future change to that premise is visible in old files.
        var leaveOneOut: Bool = true

        /// Keyed by category for the same reason the criteria are: one category
        /// can be reviewed on `Cz` over 80–320 ms and the next on a parietal ROI
        /// over a different window, and a single global record would attribute
        /// both sets of scores to whichever was reviewed last.
        func parameters(category: String? = nil) -> [String: String] {
            var out: [String: String] = [:]
            func put(_ name: String, _ value: String) {
                out[TrialExclusionResolver.parameterKey(name, category: category)] = value
            }
            put("channelScope", channelScope)
            put("leaveOneOut", String(leaveOneOut))
            if !channels.isEmpty { put("channels", channels.joined(separator: ",")) }
            if let windowStartMs { put("windowStartMs", String(format: "%.3f", windowStartMs)) }
            if let windowEndMs { put("windowEndMs", String(format: "%.3f", windowEndMs)) }
            return out
        }
    }

    // MARK: - Building the step

    /// One reviewed decision, before it is joined to a segment. Neutral of the
    /// analyzer types so the commit path and tests can build one directly.
    struct ReviewedExclusion: Sendable, Equatable {
        var category: String
        var trialIndex: Int
        var sourceTimeSeconds: Double
        var reasons: [String] = []
        var origin: ExcludedTrial.Origin = .rule
    }

    /// What building a step could not do, so the caller can refuse rather than
    /// commit a record that will not resolve on reload.
    struct BuildResult: Sendable {
        var step: EVAProcessingStep
        /// Reviewed decisions whose `category` + `sourceTimeSeconds` matched no
        /// segment, and which therefore carry no source code. Committing with
        /// these present writes a record that cannot be resolved later.
        var unmatched: [ReviewedExclusion] = []

        var isComplete: Bool { unmatched.isEmpty }
    }

    /// Commits one category's reviewed set into an existing step, or into a new
    /// one when there is nothing committed yet.
    ///
    /// **Replaces `category` and leaves every other category standing.** This is
    /// the whole reason the merge exists: Phase 3 reviews one category at a
    /// time, so a commit that rebuilt the step from only what is on screen would
    /// silently discard the review of every category looked at earlier — and it
    /// would look like it worked, because the category in front of you would be
    /// correct.
    ///
    /// Reviewed decisions naming another category are ignored rather than
    /// quietly written, since they cannot have come from this review.
    static func merged(
        reviewed: [ReviewedExclusion],
        for category: String,
        criteria: TrialSelectionAnalyzer.Criteria,
        context: ScoringContext,
        into existing: EVAProcessingStep?,
        segments: [EpochSegment]
    ) -> BuildResult {
        let mine = reviewed.filter { $0.category == category }
        let joined = join(mine, to: segments)

        var trials = (existing?.excludedTrials ?? []).filter { $0.category != category }
        trials.append(contentsOf: joined.trials)

        // Drop this category's old parameters before writing the new ones, so a
        // bound switched off in review does not survive as a stale key. Other
        // categories' keys, and any unkeyed legacy ones, are left alone.
        var parameters = (existing?.parameters ?? [:]).filter {
            parameterName($0.key).category != category
        }
        for (key, value) in context.parameters(category: category) { parameters[key] = value }
        for (key, value) in Self.parameters(for: criteria, category: category) { parameters[key] = value }

        return BuildResult(
            step: step(trials: trials, parameters: parameters, id: existing?.id),
            unmatched: joined.unmatched
        )
    }

    /// Removes one category from a committed step, leaving every other
    /// category's decision standing — the counterpart to committing one
    /// category at a time.
    ///
    /// Returns nil when what remains excludes nothing. Note the test is for a
    /// remaining *exclusion*, not for remaining trials: a step left carrying
    /// only restorations records that the rule was overruled everywhere and
    /// removes no trial at all, which is not a decision worth persisting. The
    /// commit path applies the same rule, and the two must agree or clearing
    /// down to nothing would leave a record committing could never have made.
    static func removing(category: String, from existing: EVAProcessingStep) -> EVAProcessingStep? {
        let trials = existing.excludedTrials.filter { $0.category != category }
        guard trials.contains(where: \.isExcluded) else { return nil }
        return step(
            trials: trials,
            parameters: existing.parameters.filter { parameterName($0.key).category != category },
            id: existing.id
        )
    }

    /// Builds a step from a reviewed set spanning any number of categories, with
    /// one rule applied to all of them. The all-at-once entry point; interactive
    /// review goes through `merged(reviewed:for:...)` instead.
    static func makeStep(
        reviewed: [ReviewedExclusion],
        criteria: TrialSelectionAnalyzer.Criteria,
        context: ScoringContext,
        segments: [EpochSegment]
    ) -> BuildResult {
        var result = BuildResult(step: step(trials: [], parameters: [:], id: nil))
        for category in Set(reviewed.map(\.category)).sorted() {
            let merged = merged(
                reviewed: reviewed,
                for: category,
                criteria: criteria,
                context: context,
                into: result.step,
                segments: segments
            )
            result.step = merged.step
            result.unmatched.append(contentsOf: merged.unmatched)
        }
        return result
    }

    // MARK: - Assembly

    /// Joins reviewed decisions to real segments, picking up the source code
    /// each key needs. A decision matching no segment is reported rather than
    /// written with an empty code that could never resolve.
    private static func join(
        _ reviewed: [ReviewedExclusion],
        to segments: [EpochSegment]
    ) -> (trials: [ExcludedTrial], unmatched: [ReviewedExclusion]) {
        var trials: [ExcludedTrial] = []
        var unmatched: [ReviewedExclusion] = []

        for decision in reviewed {
            guard let segment = segments.first(where: {
                $0.category == decision.category
                    && abs($0.sourceTimeSeconds - decision.sourceTimeSeconds) <= ExcludedTrial.timeToleranceSeconds
            }) else {
                unmatched.append(decision)
                continue
            }
            trials.append(ExcludedTrial(
                category: decision.category,
                sourceCode: segment.sourceCode,
                sourceTimeSeconds: segment.sourceTimeSeconds,
                recordedIndex: decision.trialIndex,
                reasons: decision.reasons,
                origin: decision.origin
            ))
        }
        return (trials, unmatched)
    }

    private static func step(
        trials: [ExcludedTrial],
        parameters: [String: String],
        id: UUID?
    ) -> EVAProcessingStep {
        let excludedCount = trials.filter(\.isExcluded).count
        let restoredCount = trials.count - excludedCount
        var note = "Excluded \(excludedCount) trial\(excludedCount == 1 ? "" : "s")"
        if restoredCount > 0 {
            note += " · \(restoredCount) restored by operator"
        }

        var step = EVAProcessingStep(
            operation: .trialExclusion,
            parameters: parameters,
            // The criteria are portable even though the trial list is not, so
            // Copy Processing carries the step and re-proposes the thresholds
            // for review. `replayInteraction(given:)` is what keeps one
            // subject's trial list off another subject's data.
            replayable: true,
            note: note,
            excludedTrials: trials.sorted {
                ($0.category, $0.sourceTimeSeconds) < ($1.category, $1.sourceTimeSeconds)
            }
        )
        // Committing another category edits the same decision rather than
        // starting a new one, so the step keeps its identity — which is what
        // `ReplayPayloadAvailability.resolvedTrialExclusionStepIDs` is keyed on.
        if let id { step.id = id }
        return step
    }

    // MARK: - Per-category parameter keying

    /// Phase 3 reviews **one category at a time**: `selectedCategory` drives the
    /// criteria sliders, and re-tuning them for `RC++` says nothing about the
    /// thresholds that produced the `LC++` decision already committed. So the
    /// step's flat parameter bag is keyed by category — `LC++.minCorrelation` —
    /// rather than carrying one global rule that the last category reviewed
    /// would silently overwrite.
    ///
    /// Keyed into the existing bag rather than into new XML structure: the
    /// `<param>` element already round-trips anything, and a second nested shape
    /// would have to be taught to every reader that currently walks parameters.
    ///
    /// Parsed on the **last** dot, so a category whose own name contains one
    /// (`stim.1`) still resolves. That holds precisely because no parameter
    /// *name* here contains a dot, which is a constraint on this list, not a
    /// general property — keep it true when adding one.
    static func parameterKey(_ name: String, category: String?) -> String {
        guard let category else { return name }
        return "\(category).\(name)"
    }

    private static func parameterName(_ key: String) -> (category: String?, name: String) {
        guard let dot = key.lastIndex(of: ".") else { return (nil, key) }
        return (String(key[key.startIndex ..< dot]), String(key[key.index(after: dot)...]))
    }

    /// Every category this step carries parameters or trials for.
    static func categories(in step: EVAProcessingStep) -> [String] {
        var names = Set(step.excludedTrials.map(\.category))
        for key in step.parameters.keys {
            if let category = parameterName(key).category { names.insert(category) }
        }
        return names.sorted()
    }

    /// The criteria as portable step parameters. Only active bounds are
    /// written — "no bound on this measure" is a different state from "a bound
    /// at the end of its range", and an absent key is how that is said.
    static func parameters(
        for criteria: TrialSelectionAnalyzer.Criteria,
        category: String? = nil
    ) -> [String: String] {
        var out: [String: String] = [:]
        func put(_ name: String, _ value: String) {
            out[parameterKey(name, category: category)] = value
        }
        if let value = criteria.minCorrelation { put("minCorrelation", String(format: "%.4f", value)) }
        if let value = criteria.minSlope { put("minSlope", String(format: "%.4f", value)) }
        if let value = criteria.maxResidualRMS { put("maxResidualRMS", String(format: "%.4f", value)) }
        if let value = criteria.maxRobustDistance { put("maxRobustDistance", String(format: "%.4f", value)) }
        if !criteria.excludedClassifications.isEmpty {
            put("excludedClassifications", criteria.excludedClassifications
                .map(\.rawValue).sorted().joined(separator: ","))
        }
        if criteria.excludesMislabels { put("excludesMislabels", "true") }
        return out
    }

    /// The inverse — the portable half of a recorded step, for re-proposing it
    /// in the Phase 3 UI when the trial keys belong to another subject.
    ///
    /// Falls back to the unkeyed name when no keyed one is present, which is
    /// what makes a step written before the per-category split still read as a
    /// rule that applied to everything. Absence of both is a genuinely inactive
    /// bound, not a missing value to substitute a default for.
    static func criteria(
        from parameters: [String: String],
        category: String? = nil
    ) -> TrialSelectionAnalyzer.Criteria {
        func value(_ name: String) -> String? {
            if let category, let keyed = parameters[parameterKey(name, category: category)] {
                return keyed
            }
            return parameters[name]
        }

        var criteria = TrialSelectionAnalyzer.Criteria()
        criteria.minCorrelation = value("minCorrelation").flatMap(Double.init)
        criteria.minSlope = value("minSlope").flatMap(Double.init)
        criteria.maxResidualRMS = value("maxResidualRMS").flatMap(Double.init)
        criteria.maxRobustDistance = value("maxRobustDistance").flatMap(Double.init)
        criteria.excludedClassifications = Set(
            (value("excludedClassifications") ?? "")
                .split(separator: ",")
                .compactMap { TrialSimilarityAnalyzer.Classification(rawValue: String($0)) }
        )
        criteria.excludesMislabels = value("excludesMislabels") == "true"
        return criteria
    }

    // MARK: - Resolving the step against a file

    /// The outcome of matching a recorded step's keys against real segments.
    ///
    /// `unresolved` is the point of this type. A recorded key that matches no
    /// segment means the trial the operator reviewed is not in this data — a
    /// re-segment moved the epoch bounds, or the script came from another
    /// subject — and applying the half that still matched would produce an
    /// average nobody reviewed. Callers must treat a non-empty `unresolved` as
    /// a decision, never as a partial success.
    struct Resolution: Sendable, Equatable {
        /// Positions in the `segments` array to drop from the average.
        var excludedIndices: Set<Int> = []
        /// Recorded exclusions that matched no segment.
        var unresolved: [ExcludedTrial] = []
        /// Recorded exclusions whose position moved since the commit. Harmless
        /// — the key is what is matched on — but worth reporting, because it
        /// means the trial numbering the operator saw no longer applies.
        var movedIndices: [ExcludedTrial] = []

        var isComplete: Bool { unresolved.isEmpty }
    }

    /// Matches a `trialExclusion` step's recorded trials against `segments`.
    ///
    /// A pooled category is resolved on its own name, not through its members:
    /// the key carries the category the operator was reviewing, and excluding a
    /// trial from `LC++` deliberately does not exclude the same event's
    /// contribution to the pooled `correct` average. Those are two different
    /// averages and the review was of one of them.
    static func resolve(step: EVAProcessingStep, segments: [EpochSegment]) -> Resolution {
        guard step.operation == .trialExclusion else { return Resolution() }

        // Position within its own category, matching what the analyzer and the
        // UI number trials by, so `recordedIndex` is compared like with like.
        var indexWithinCategory: [Int: Int] = [:]
        var seenPerCategory: [String: Int] = [:]
        for (position, segment) in segments.enumerated() {
            let next = seenPerCategory[segment.category, default: 0]
            indexWithinCategory[position] = next
            seenPerCategory[segment.category] = next + 1
        }

        var resolution = Resolution()
        for trial in step.excludedTrials {
            guard let position = segments.firstIndex(where: {
                trial.matches(
                    category: $0.category,
                    sourceCode: $0.sourceCode,
                    sourceTimeSeconds: $0.sourceTimeSeconds
                )
            }) else {
                // A `.restored` trial that no longer exists is not a failure:
                // it excluded nothing, so nothing about the average is in
                // doubt. Only a missing exclusion makes the result unreviewed.
                if trial.isExcluded { resolution.unresolved.append(trial) }
                continue
            }
            if trial.recordedIndex >= 0, indexWithinCategory[position] != trial.recordedIndex {
                resolution.movedIndices.append(trial)
            }
            if trial.isExcluded { resolution.excludedIndices.insert(position) }
        }
        return resolution
    }

    /// Every `trialExclusion` step in `script` that resolves completely against
    /// `segments`, in the form `ReplayPayloadAvailability` wants.
    static func resolvableStepIDs(
        in script: EVAProcessingScript,
        segments: [EpochSegment]
    ) -> Set<UUID> {
        var out = Set<UUID>()
        for step in script.steps where step.operation == .trialExclusion {
            if resolve(step: step, segments: segments).isComplete {
                out.insert(step.id)
            }
        }
        return out
    }

    // MARK: - Reporting

    /// The reason label these exclusions contribute to
    /// `PSAExclusionSummary.CategoryTally.reasons`, and from there to the
    /// `average` step's `CategoryRejection`, QuickLook retention bars, and
    /// `RecordingCombiner`.
    static let reasonLabel = "Low similarity"

    /// Per-category counts of what a resolved step removed, for the exclusion
    /// summary to fold in.
    static func excludedCountsByCategory(
        step: EVAProcessingStep,
        segments: [EpochSegment],
        resolution: Resolution
    ) -> [String: Int] {
        var out: [String: Int] = [:]
        for position in resolution.excludedIndices where segments.indices.contains(position) {
            out[segments[position].category, default: 0] += 1
        }
        return out
    }
}
