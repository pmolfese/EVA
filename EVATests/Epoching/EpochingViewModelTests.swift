//
//  EpochingViewModelTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Additional coverage for the L4 epoching store beyond the parameter-bridge
//  smoke test in ProcessingStoreTests.swift: default rejection/display state
//  and the averageReference bridge.

import Testing
import Foundation
@testable import EVA

struct EpochingViewModelTests {

    @MainActor
    @Test func defaultsMatchExpectedInitialState() {
        let vm = EpochingViewModel(store: RecordingStore())
        #expect(!vm.showsSheet)
        #expect(vm.selectedEventCodes.isEmpty)
        #expect(vm.skipEyeBlinks)
        #expect(vm.skipEyeMovements)
        #expect(vm.skipIfContainsArtifact)
        #expect(vm.escalatesBadChannelsToGlobal)
        #expect(vm.epochedSignal == nil)
        #expect(vm.epochSegments.isEmpty)
        #expect(!vm.isAveraged)
        #expect(vm.showsNoiseBand)
        #expect(!vm.showsButterflyPlot)
    }

    @MainActor
    @Test func parametersReflectAverageReferenceToggle() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.averageReference = true
        #expect(vm.parameters["averageReference"] == "true")
        vm.averageReference = false
        #expect(vm.parameters["averageReference"] == "false")
    }

    @MainActor
    @Test func parametersRoundTripPerEpochBadChannelSettings() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.interpolatesBadChannelsPerEpoch = true
        vm.epochBadChannelThresholds = EpochBadChannelThresholds(
            minMicrovolts: -125,
            maxMicrovolts: 175,
            maxSlopeMicrovoltsPerSample: 21,
            maxAccelerationMicrovoltsPerSample: 11,
            maxBadChannelFraction: 0.2,
            maxBadChannelCount: 9,
            usesAbsoluteBadChannelCount: true
        )
        vm.escalatesBadChannelsToGlobal = true
        vm.escalationThresholdPercent = 65

        let params = vm.parameters
        #expect(params["interpolateBadChannelsPerEpoch"] == "true")
        #expect(params["badChannel.minMicrovolts"] == "-125")
        #expect(params["badChannel.maxMicrovolts"] == "175")
        #expect(params["badChannel.maxSlopeMicrovoltsPerSample"] == "21")
        #expect(params["badChannel.maxAccelerationMicrovoltsPerSample"] == "11")
        #expect(params["badChannel.maxBadChannelFraction"] == "0.2")
        #expect(params["badChannel.maxBadChannelCount"] == "9")
        #expect(params["badChannel.usesAbsoluteBadChannelCount"] == "true")
        #expect(params["badChannel.escalateToGlobal"] == "true")
        #expect(params["badChannel.globalEscalationThresholdPercent"] == "65")

        let restored = EpochingViewModel(store: RecordingStore())
        restored.apply(parameters: params)

        #expect(restored.interpolatesBadChannelsPerEpoch)
        #expect(restored.epochBadChannelThresholds == vm.epochBadChannelThresholds)
        #expect(restored.escalatesBadChannelsToGlobal)
        #expect(restored.escalationThresholdPercent == 65)
    }

    // MARK: - Artifact rejection window

    @MainActor
    @Test func rejectionWindowIsWholeEpochUntilLimited() {
        let vm = EpochingViewModel(store: RecordingStore())
        #expect(!vm.limitsArtifactRejectionWindow)
        #expect(vm.effectiveArtifactRejectionWindow == nil)
        #expect(vm.parameters["artifactWindowLimited"] == nil)
    }

    @MainActor
    @Test func rejectionWindowClampsToTheEpoch() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.preStimulus = 0.1
        vm.postStimulus = 0.8
        vm.limitsArtifactRejectionWindow = true
        // Deliberately wider than the epoch on both sides.
        vm.artifactRejectionWindowStart = -0.5
        vm.artifactRejectionWindowEnd = 2.0

        let window = vm.effectiveArtifactRejectionWindow
        #expect(window?.lowerBound == -0.1)
        #expect(window?.upperBound == 0.8)
    }

    /// An inverted window must reject *nothing*, never fall back to the whole
    /// epoch — a mistyped bound should not silently reject every trial.
    @MainActor
    @Test func invertedRejectionWindowCollapsesRatherThanWidening() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.preStimulus = 0.1
        vm.postStimulus = 0.8
        vm.limitsArtifactRejectionWindow = true
        vm.artifactRejectionWindowStart = 0.6
        vm.artifactRejectionWindowEnd = 0.2

        #expect(vm.artifactRejectionWindowIsInverted)
        let window = vm.effectiveArtifactRejectionWindow
        #expect(window?.lowerBound == 0.6)
        #expect(window?.upperBound == 0.6)
    }

    @MainActor
    @Test func seedingTheWindowUsesTheCurrentEpochBounds() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.preStimulus = 0.15
        vm.postStimulus = 1.2
        vm.seedArtifactRejectionWindowFromEpoch()
        #expect(vm.artifactRejectionWindowStart == -0.15)
        #expect(vm.artifactRejectionWindowEnd == 1.2)
    }

    @MainActor
    @Test func rejectionWindowRoundTripsThroughParameters() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.limitsArtifactRejectionWindow = true
        vm.artifactRejectionWindowStart = -0.1
        vm.artifactRejectionWindowEnd = 0.5
        let parameters = vm.parameters
        #expect(parameters["artifactWindowLimited"] == "true")
        #expect(parameters["artifactWindowStartMs"] == "-100")
        #expect(parameters["artifactWindowEndMs"] == "500")

        let restored = EpochingViewModel(store: RecordingStore())
        restored.apply(parameters: parameters)
        #expect(restored.limitsArtifactRejectionWindow)
        #expect(abs(restored.artifactRejectionWindowStart - -0.1) < 1e-9)
        #expect(abs(restored.artifactRejectionWindowEnd - 0.5) < 1e-9)
    }

    /// The window is only carried when rejection itself is on, and its absence
    /// has to restore as "not limited" rather than leaving a stale value.
    @MainActor
    @Test func rejectionWindowIsNotCarriedWhenRejectionIsOff() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.skipIfContainsArtifact = false
        vm.limitsArtifactRejectionWindow = true
        #expect(vm.parameters["artifactWindowLimited"] == nil)

        let restored = EpochingViewModel(store: RecordingStore())
        restored.limitsArtifactRejectionWindow = true
        restored.apply(parameters: vm.parameters)
        #expect(!restored.limitsArtifactRejectionWindow)
    }

    @MainActor
    @Test func skippedArtifactSelectionIsIndependentOfKnownArtifacts() {
        let vm = EpochingViewModel(store: RecordingStore())
        let id1 = DefinedArtifact.ID()
        let id2 = DefinedArtifact.ID()
        vm.knownArtifactIDsForRejection = [id1, id2]
        vm.skippedDefinedArtifactIDs = [id1]

        #expect(vm.knownArtifactIDsForRejection.count == 2)
        #expect(vm.skippedDefinedArtifactIDs == [id1])
        #expect(!vm.skippedDefinedArtifactIDs.contains(id2))
    }

    @MainActor
    @Test func categoryNamesAndTimingMarkersAreIndependentDictionaries() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.categoryNames["1"] = "Target"
        vm.timingMarkerValuesBySegmentValue["1"] = "TREV"
        vm.timingMarkerEnabledValues.insert("1")

        #expect(vm.categoryNames["1"] == "Target")
        #expect(vm.timingMarkerValuesBySegmentValue["1"] == "TREV")
        #expect(vm.timingMarkerEnabledValues.contains("1"))
    }
}
