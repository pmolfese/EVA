//
//  BatchPrefixPlannerTests.swift
//  EVATests
//


import Foundation
import Testing
@testable import EVA

struct BatchPrefixPlannerTests {
    private func script(_ steps: [EVAProcessingStep]) -> EVAProcessingScript {
        var script = EVAProcessingScript()
        script.steps = steps
        return script
    }

    @Test func prefixIsContiguousAndStopsBeforeAnOtherwiseAutomaticOperation() {
        let gradient = EVAProcessingStep(operation: .mriGradientCorrection)
        let filter = EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1"])
        let ica = EVAProcessingStep(operation: .icaClean)

        let plan = BatchPrefixPlanner.plan(
            script: script([gradient, filter, ica]),
            availability: ReplayPayloadAvailability(hasICAPayload: true),
            skipUnsupportedDecisions: false,
            mode: .fullAuto
        )

        #expect(plan.prefix.steps.map(\.operation) == [.mriGradientCorrection])
        #expect(plan.remainder.steps.map(\.operation) == [.filter, .icaClean])
        #expect(plan.stopReason == .outsideSafePrefix(.filter))
    }

    @Test func phaseBMayDropAnUnsupportedDecisionBeforeThePrefixContinues() {
        let pcas = EVAProcessingStep(
            operation: .bcgCorrection,
            parameters: ["beatEventCode": "R128"]
        )
        let gradient = EVAProcessingStep(operation: .mriGradientCorrection)
        let ica = EVAProcessingStep(operation: .icaClean)
        let filter = EVAProcessingStep(operation: .filter)

        let plan = BatchPrefixPlanner.plan(
            script: script([pcas, gradient, ica, filter]),
            availability: ReplayPayloadAvailability(hasICAPayload: true),
            skipUnsupportedDecisions: true,
            mode: .fullAuto
        )

        #expect(plan.effectiveScript.steps.map(\.operation) == [.mriGradientCorrection, .icaClean, .filter])
        #expect(plan.prefix.steps.map(\.operation) == [.mriGradientCorrection, .icaClean])
        #expect(plan.prefixDrops.map(\.operation) == [.bcgCorrection])
        #expect(plan.remainderDrops.isEmpty)
        #expect(plan.stopReason == .outsideSafePrefix(.filter))
    }

    @Test func aReviewedGradientMakesThePrefixEmpty() {
        let gradient = EVAProcessingStep(operation: .mriGradientCorrection)
        let plan = BatchPrefixPlanner.plan(
            script: script([gradient, EVAProcessingStep(operation: .icaClean)]),
            availability: ReplayPayloadAvailability(hasICAPayload: true),
            skipUnsupportedDecisions: false,
            mode: .fullAuto,
            reviewStepIDs: [gradient.id]
        )

        #expect(!plan.hasUsefulPrefix)
        #expect(plan.remainder.steps.count == 2)
        #expect(plan.stopReason == .reviewRequired(.mriGradientCorrection))
    }

    @Test func reviewEachAlwaysStartsWithTheOriginalFile() {
        let gradient = EVAProcessingStep(operation: .mriGradientCorrection)
        let plan = BatchPrefixPlanner.plan(
            script: script([gradient]),
            availability: .none,
            skipUnsupportedDecisions: false,
            mode: .reviewEach
        )

        #expect(plan.prefix.steps.isEmpty)
        #expect(plan.stopReason == .reviewEach(.mriGradientCorrection))
    }

    @Test func supportedPCASIsEligibleButMissingEvidenceStopsOrDropsIt() {
        let pcas = EVAProcessingStep(
            operation: .bcgCorrection,
            parameters: ["beatEventCode": "R128"]
        )
        let supported = BatchPrefixPlanner.plan(
            script: script([pcas]),
            availability: ReplayPayloadAvailability(
                hasElectrodeGeometry: true,
                beatEventCodes: ["R128"]
            ),
            skipUnsupportedDecisions: false,
            mode: .fullAuto
        )
        #expect(supported.prefix.steps.map(\.operation) == [.bcgCorrection])
        #expect(supported.stopReason == .endOfScript)

        let stopped = BatchPrefixPlanner.plan(
            script: script([pcas]),
            availability: .none,
            skipUnsupportedDecisions: false,
            mode: .fullAuto
        )
        #expect(stopped.prefix.steps.isEmpty)
        #expect(stopped.stopReason == .decisionRequired(.bcgCorrection))

        let dropped = BatchPrefixPlanner.plan(
            script: script([pcas]),
            availability: .none,
            skipUnsupportedDecisions: true,
            mode: .fullAuto
        )
        #expect(dropped.prefix.steps.isEmpty)
        #expect(dropped.remainder.steps.isEmpty)
        #expect(dropped.prefixDrops.map(\.operation) == [.bcgCorrection])
        #expect(dropped.stopReason == .endOfScript)
    }

    @Test func ICARequiresThisFilesOwnPayloadEvenForAProvenanceOnlyStep() {
        var ica = EVAProcessingStep(operation: .icaClean)
        ica.replayable = false
        let plan = BatchPrefixPlanner.plan(
            script: script([ica]),
            availability: .none,
            skipUnsupportedDecisions: true,
            mode: .fullAuto
        )

        #expect(plan.prefix.steps.isEmpty)
        #expect(plan.stopReason == .unresolvedPayload(.icaClean))
    }

    @Test func failedExternalPreflightStopsBeforeTheStep() {
        let gradient = EVAProcessingStep(operation: .mriGradientCorrection)
        let plan = BatchPrefixPlanner.plan(
            script: script([gradient]),
            availability: .none,
            skipUnsupportedDecisions: false,
            mode: .fullAuto,
            unavailableExternalInputStepIDs: [gradient.id]
        )

        #expect(plan.prefix.steps.isEmpty)
        #expect(plan.stopReason == .missingExternalInput(.mriGradientCorrection))
    }

    @Test func prefixDigestTracksComputationButNotCaptureMetadata() {
        var first = EVAProcessingStep(
            operation: .mriGradientCorrection,
            parameters: ["window": "31", "motion": "off"]
        )
        var equivalent = first
        equivalent.id = UUID()
        equivalent.appliedAt = Date(timeIntervalSince1970: 123)
        equivalent.note = "captured somewhere else"
        equivalent.replayable = false

        let firstDigest = BatchCheckpointDigest.script(script([first]))
        let equivalentDigest = BatchCheckpointDigest.script(script([equivalent]))
        #expect(firstDigest == equivalentDigest)

        first.parameters["window"] = "41"
        #expect(BatchCheckpointDigest.script(script([first])) != firstDigest)
    }
}
