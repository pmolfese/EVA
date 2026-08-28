//
//  GradientReplayTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Round-trip coverage for the reproducible eva.xml pipeline: gradient-correction
//  parameters and the portable eye-artifact threshold-detection config must both
//  survive serialize → deserialize so Copy Processing replays them exactly.
//

import Testing
import Foundation
@testable import EVA

struct GradientReplayTests {

    @MainActor
    @Test func gradientApplyParametersRoundTrip() {
        let a = GradientViewModel(store: RecordingStore())
        a.method = .fastr
        a.trMarkerCode = "TR"
        a.donorVolumes = 7
        a.slicesPerVolume = 5
        a.upsampleFactor = 2
        a.alignmentEnabled = true
        a.subSampleAlignment = false
        a.templateScaling = .leastSquares
        a.templateScaleSmoothingEpochs = 21
        a.templateScaleMinimum = 0.25
        a.templateScaleMaximum = 4
        a.donorRanking = .squaredCorrelation
        a.correlationThreshold = 0.85
        a.minimumCorrelatedDonors = 6
        a.correlationSearchWindow = 120
        a.obsSelection = .fixed
        a.obsFixedComponents = 4
        a.obsChunkSeconds = 45
        a.obsMaximumEpochsPerChunk = 128
        a.obsResidualEnergyFloor = 0.02
        a.ancEnabled = true
        a.ancSliceHighPass = true
        a.ancFilterLength = 48
        a.ancStepSize = 0.02
        a.computeBackend = .metal
        a.motionMetric = .allParameters
        a.excludeHighMotion = true
        a.motionFDThreshold = 0.35

        let b = GradientViewModel(store: RecordingStore())
        b.apply(parameters: a.parameters)

        #expect(b.parameters == a.parameters)
        #expect(b.method == .fastr)
        #expect(b.trMarkerCode == "TR")
        #expect(b.donorVolumes == 7)
        #expect(b.slicesPerVolume == 5)
        #expect(b.upsampleFactor == 2)
        #expect(!b.subSampleAlignment)
        #expect(b.templateScaling == .leastSquares)
        #expect(b.templateScaleSmoothingEpochs == 21)
        #expect(b.donorRanking == .squaredCorrelation)
        #expect(b.minimumCorrelatedDonors == 6)
        #expect(b.obsSelection == .fixed)
        #expect(b.obsFixedComponents == 4)
        #expect(b.obsMaximumEpochsPerChunk == 128)
        #expect(b.ancEnabled)
        #expect(b.ancSliceHighPass)
        #expect(b.ancFilterLength == 48)
        #expect(b.computeBackend == .metal)
        #expect(b.motionMetric == .allParameters)
        #expect(b.excludeHighMotion)
    }

    @MainActor
    @Test func aasGradientOmitsFastrKeysButRoundTrips() {
        let a = GradientViewModel(store: RecordingStore())
        a.method = .aas
        a.donorVolumes = 4

        // FASTR-only and slice-only keys are absent for a volume-level AAS run.
        #expect(a.parameters["slices"] == nil)
        #expect(a.parameters["obs"] == nil)
        #expect(a.parameters["templateScaling"] == nil)

        let b = GradientViewModel(store: RecordingStore())
        b.apply(parameters: a.parameters)
        #expect(b.method == .aas)
        #expect(b.parameters == a.parameters)
    }

    @MainActor
    @Test func allenIARParametersRoundTrip() {
        let a = GradientViewModel(store: RecordingStore())
        a.method = .allenIAR
        a.slicesPerVolume = 30
        a.allenSectionEpochs = 40   // 0 would mean "let the preset choose"
        a.allenCorrelationGate = 0.95
        a.allenInitialEpochs = 3
        a.ancEnabled = true

        let b = GradientViewModel(store: RecordingStore())
        b.apply(parameters: a.parameters)

        #expect(b.method == .allenIAR)
        #expect(b.slicesPerVolume == 30)
        #expect(b.allenSectionEpochs == 40)
        #expect(b.allenInitialEpochs == 3)
        #expect(b.ancEnabled)
        #expect(b.parameters == a.parameters)
    }

    @MainActor
    @Test func localTemplateParametersRoundTrip() {
        let a = GradientViewModel(store: RecordingStore())
        a.method = .mar
        a.localMinimumDonorDistance = 250
        a.localMinimumDonorCount = 3
        a.localSkipsTargetsWithoutEnoughDonors = true

        let b = GradientViewModel(store: RecordingStore())
        b.apply(parameters: a.parameters)

        #expect(b.method == .mar)
        #expect(b.localMinimumDonorDistance == 250)
        #expect(b.localMinimumDonorCount == 3)
        #expect(b.localSkipsTargetsWithoutEnoughDonors)
        #expect(b.parameters == a.parameters)
    }

    /// A parameter block written by EVA's previous gradient correctors is
    /// ignored in full rather than half-applied. Those engines had different
    /// defaults and options that do not map onto the current ones one-to-one, so
    /// taking the keys that happen to share a name would produce a run the file
    /// does not describe.
    @MainActor
    @Test func parametersFromTheOldEnginesAreRejectedAndReported() {
        let legacy = [
            "method": "FASTR",
            "trMarkerCode": "TR",
            "windowBefore": "9",
            "windowAfter": "9",
            "slices": "30",
            "obs": "true",
            "anc": "true",
            "facetWindow": "true",
            "obsRandomSampling": "true",
            "bergenRSquareDonors": "true"
        ]

        let vm = GradientViewModel(store: RecordingStore())
        let untouched = vm.method
        vm.apply(parameters: legacy)

        // Nothing was taken, not even the keys whose names still exist.
        #expect(vm.method == untouched)
        #expect(vm.trMarkerCode == "TREV")
        #expect(vm.donorVolumes == GradientViewModel.defaultDonorVolumes)
        #expect(vm.slicesPerVolume == 1)
        #expect(vm.obsSelection == .off)
        #expect(!vm.ancEnabled)
        // And the user is told, rather than silently getting a different run.
        #expect(vm.statusMessage != nil)
        #expect(vm.statusIsError == false)
    }

    @MainActor
    @Test func currentParametersCarryTheEngineToken() {
        let vm = GradientViewModel(store: RecordingStore())
        #expect(vm.parameters["engine"] != nil)
    }

    /// A sparse block is not a legacy block. A hand-written processing script
    /// that names only the method and the marker code has to keep working —
    /// rejecting anything without the engine token would break every script
    /// written by hand rather than by Copy Processing.
    @MainActor
    @Test func aSparseHandWrittenBlockStillApplies() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.apply(parameters: ["method": "AAS", "trMarkerCode": "TR"])

        #expect(vm.method == .aas)
        #expect(vm.trMarkerCode == "TR")
        #expect(vm.statusMessage == nil)
    }

    /// The three-way OBS selection replaced a bool, so a bool is itself evidence
    /// of the old writer even when no other legacy key survived.
    @MainActor
    @Test func aBooleanOBSValueMarksTheBlockLegacy() {
        let vm = GradientViewModel(store: RecordingStore())
        let untouched = vm.method
        vm.apply(parameters: ["method": "FASTR", "obs": "true"])

        #expect(vm.method == untouched)
        #expect(vm.statusMessage != nil)
    }

    /// The threshold-detection replay carries each ocular config as JSON in a
    /// param; verify that serialization is lossless.
    @Test func eyeThresholdConfigJSONRoundTrips() throws {
        var c = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        c.amplitudeMinMicrovolts = 123
        c.maxDurationSeconds = 0.4
        c.riseWindowSeconds = 0.1
        c.velocityEnabled = true
        c.polarity = .positive
        c.channelOverride = [5, 9]

        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(EyeArtifactThresholdConfiguration.self, from: data)

        #expect(back == c)
    }
}
