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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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
