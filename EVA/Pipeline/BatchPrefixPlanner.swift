//
//  BatchPrefixPlanner.swift
//  EVA
//
//  PB-1 Phase C1: the pure per-file contract for partial-then-resume.
//  This file deliberately performs no signal work and no I/O. Setup prediction,
//  execution, and resume all consume the same plan instead of independently
//  deciding which operations are safe to move ahead of a windowed replay.
//


import Foundation

nonisolated enum BatchPrefixRunMode: Sendable, Equatable {
    case fullAuto
    case reviewEach
}

nonisolated enum BatchPrefixStopReason: Sendable, Equatable {
    /// Every effective step belongs to the restricted prefix.
    case endOfScript
    /// Review Each intentionally opens the file before doing any work.
    case reviewEach(EVAProcessingStep.Operation)
    /// This particular step is configured to pause before it runs.
    case reviewRequired(EVAProcessingStep.Operation)
    /// The file still needs a subject-specific decision at this step.
    case decisionRequired(EVAProcessingStep.Operation)
    /// A required file-local input failed preflight (for example gradient
    /// correction without usable TR markers or motion information).
    case missingExternalInput(EVAProcessingStep.Operation)
    /// The step is not replayable from the information in this file.
    case unresolvedPayload(EVAProcessingStep.Operation)
    /// The operation may be headless-capable elsewhere, but is deliberately
    /// outside the narrow prefix allowlist needed for window parity.
    case outsideSafePrefix(EVAProcessingStep.Operation)
}

nonisolated struct BatchPrefixPlan: Sendable {
    /// Script after PB-1 Phase B's per-file decision policy.
    let effectiveScript: EVAProcessingScript
    /// The contiguous, safe, unattended beginning of `effectiveScript`.
    let prefix: EVAProcessingScript
    /// Everything beginning with the first gate or non-prefix operation.
    let remainder: EVAProcessingScript
    /// Phase B omissions encountered before the remainder begins. These belong
    /// in the partial checkpoint's audit trail.
    let prefixDrops: [BatchDecisionDrop]
    /// Phase B omissions at or after the remainder boundary. They are retained
    /// for the final run's provenance, but did not help produce the checkpoint.
    let remainderDrops: [BatchDecisionDrop]
    let stopReason: BatchPrefixStopReason

    var hasUsefulPrefix: Bool { !prefix.steps.isEmpty }
}

nonisolated enum BatchPrefixPlanner {
    /// The only operations Phase C may run before opening a normal EVA window.
    /// This is intentionally not "all auto steps": later panels can depend on
    /// transient state that is not reconstructed by reopening an MFF.
    static let allowedOperations: Set<EVAProcessingStep.Operation> = [
        .mriGradientCorrection,
        .bcgCorrection,
        .icaClean,
    ]

    /// Builds one file's Phase C plan.
    ///
    /// - Parameters:
    ///   - script: Already filtered to the operations the operator included.
    ///   - availability: Payload/geometry/event inventory for this input file.
    ///   - skipUnsupportedDecisions: PB-1 Phase B's per-file omission policy.
    ///   - mode: Review Each always produces an empty prefix.
    ///   - reviewStepIDs: Included steps whose Review toggle is enabled.
    ///   - unavailableExternalInputStepIDs: Steps that preflight knows cannot
    ///     execute from this file's external evidence.
    static func plan(
        script: EVAProcessingScript,
        availability: ReplayPayloadAvailability,
        skipUnsupportedDecisions: Bool,
        mode: BatchPrefixRunMode,
        reviewStepIDs: Set<UUID> = [],
        unavailableExternalInputStepIDs: Set<UUID> = []
    ) -> BatchPrefixPlan {
        let policy = BatchDecisionPolicy.apply(
            to: script,
            availability: availability,
            enabled: skipUnsupportedDecisions
        )
        let effective = policy.script

        var prefixCount = 0
        var stopReason: BatchPrefixStopReason = .endOfScript

        if mode == .reviewEach, let first = effective.steps.first {
            stopReason = .reviewEach(first.operation)
        } else {
            for step in effective.steps {
                if reviewStepIDs.contains(step.id) {
                    stopReason = .reviewRequired(step.operation)
                    break
                }
                if unavailableExternalInputStepIDs.contains(step.id) {
                    stopReason = .missingExternalInput(step.operation)
                    break
                }

                let interaction = step.replayInteraction(given: availability)
                if interaction == .decision {
                    stopReason = .decisionRequired(step.operation)
                    break
                }

                guard allowedOperations.contains(step.operation) else {
                    stopReason = .outsideSafePrefix(step.operation)
                    break
                }

                switch step.operation {
                case .mriGradientCorrection:
                    // Review is the operation's normal classification; only the
                    // explicit Review toggle above turns it into a gate.
                    guard step.replayable, interaction == .review || interaction == .auto else {
                        stopReason = .unresolvedPayload(step.operation)
                        return makePlan(
                            original: script, effective: effective, prefixCount: prefixCount,
                            drops: policy.drops, stopReason: stopReason
                        )
                    }
                case .bcgCorrection:
                    // PCA-S is portable only when this file supplies both its
                    // geometry and the requested beat events.
                    guard interaction == .auto else {
                        stopReason = .unresolvedPayload(step.operation)
                        return makePlan(
                            original: script, effective: effective, prefixCount: prefixCount,
                            drops: policy.drops, stopReason: stopReason
                        )
                    }
                case .icaClean:
                    // The operator must come from this exact file. A provenance-
                    // only ICA record without eva_ica.json cannot be prefixed.
                    guard interaction == .resolvedFromPayload, availability.hasICAPayload else {
                        stopReason = .unresolvedPayload(step.operation)
                        return makePlan(
                            original: script, effective: effective, prefixCount: prefixCount,
                            drops: policy.drops, stopReason: stopReason
                        )
                    }
                default:
                    // Kept exhaustive even though the allowlist guard makes the
                    // default unreachable; adding a future allowed operation
                    // should require an explicit safety decision here.
                    stopReason = .outsideSafePrefix(step.operation)
                    return makePlan(
                        original: script, effective: effective, prefixCount: prefixCount,
                        drops: policy.drops, stopReason: stopReason
                    )
                }

                prefixCount += 1
            }
        }

        return makePlan(
            original: script,
            effective: effective,
            prefixCount: prefixCount,
            drops: policy.drops,
            stopReason: stopReason
        )
    }

    private static func makePlan(
        original: EVAProcessingScript,
        effective: EVAProcessingScript,
        prefixCount: Int,
        drops: [BatchDecisionDrop],
        stopReason: BatchPrefixStopReason
    ) -> BatchPrefixPlan {
        var prefix = effective
        prefix.steps = Array(effective.steps.prefix(prefixCount))
        var remainder = effective
        remainder.steps = Array(effective.steps.dropFirst(prefixCount))

        // Drops refer to the original script. The first remainder step's
        // original index is therefore the precise audit boundary even when
        // Phase B removed one or more earlier decisions.
        let originalIndexByID = Dictionary(
            uniqueKeysWithValues: original.steps.enumerated().map { ($0.element.id, $0.offset) }
        )
        let boundary = remainder.steps.first
            .flatMap { originalIndexByID[$0.id] }
            ?? original.steps.count
        let prefixDrops = drops.filter { $0.stepIndex < boundary }
        let remainderDrops = drops.filter { $0.stepIndex >= boundary }

        return BatchPrefixPlan(
            effectiveScript: effective,
            prefix: prefix,
            remainder: remainder,
            prefixDrops: prefixDrops,
            remainderDrops: remainderDrops,
            stopReason: stopReason
        )
    }
}
