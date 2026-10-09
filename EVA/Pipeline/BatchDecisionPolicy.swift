//
//  BatchDecisionPolicy.swift
//  EVA
//
//  Per-file policy for PB-1 Phase B. This is deliberately pure: setup
//  prediction, windowed replay, and headless execution all ask the same rule
//  which recorded decisions this particular input cannot support.
//

import Foundation

nonisolated struct BatchDecisionDrop: Identifiable, Sendable, Equatable {
    let stepIndex: Int
    let operation: EVAProcessingStep.Operation
    let reason: String

    var id: Int { stepIndex }
    var auditLogLine: String {
        "dropped \(operation.rawValue): \(reason) (skip-decisions policy)"
    }
}

nonisolated struct BatchDecisionPolicyResult: Sendable {
    let script: EVAProcessingScript
    let drops: [BatchDecisionDrop]
}

nonisolated enum BatchDecisionPolicy {
    /// Removes only decisions that this file cannot resolve. Supported steps
    /// remain in order and run normally; disabling the policy is an identity
    /// operation. Step indices always refer to the input script.
    static func apply(
        to script: EVAProcessingScript,
        availability: ReplayPayloadAvailability,
        enabled: Bool
    ) -> BatchDecisionPolicyResult {
        guard enabled else { return BatchDecisionPolicyResult(script: script, drops: []) }

        var kept: [EVAProcessingStep] = []
        var drops: [BatchDecisionDrop] = []
        kept.reserveCapacity(script.steps.count)

        for (index, step) in script.steps.enumerated() {
            guard step.replayInteraction(given: availability) == .decision,
                  !isExempt(step.operation) else {
                kept.append(step)
                continue
            }
            drops.append(BatchDecisionDrop(
                stepIndex: index,
                operation: step.operation,
                reason: reason(for: step, availability: availability)
            ))
        }

        var effective = script
        effective.steps = kept
        return BatchDecisionPolicyResult(script: effective, drops: drops)
    }

    static func isExempt(_ operation: EVAProcessingStep.Operation) -> Bool {
        switch operation {
        case .markBad, .interpolateChannels, .trialExclusion:
            return true
        default:
            return false
        }
    }

    private static func reason(
        for step: EVAProcessingStep,
        availability: ReplayPayloadAvailability
    ) -> String {
        switch step.operation {
        case .icaClean:
            return "this recording has no ICA replay payload"
        case .artifactClean:
            return "this recording has no artifact replay payload"
        case .bcgCorrection:
            let code = step.parameters["beatEventCode"] ?? EVAProcessingStep.defaultBeatEventCode
            var missing: [String] = []
            if !availability.hasElectrodeGeometry { missing.append("electrode coordinates") }
            if !availability.beatEventCodes.contains(code) {
                missing.append("beat events named \(code)")
            }
            return "this recording is missing \(missing.joined(separator: " and "))"
        default:
            return "this recording cannot resolve the recorded decision"
        }
    }
}
