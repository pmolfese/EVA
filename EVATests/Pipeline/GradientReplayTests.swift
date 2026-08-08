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
        a.windowBefore = 3
        a.windowAfter = 4
        a.fastrSlices = 5
        a.fastrOBSAuto = true
        a.fastrANC = true
        a.fastrSubSample = false
        a.fastrUseFacetWindow = true
        a.fastrOBSRandomSampling = true
        a.fastrANCSliceHighPass = true
        a.fastrUseMetal = true
        a.fastrDonorSelection = .bergenRSquare
        a.moosmannMotionMetric = .allParameters
        a.excludeHighMotion = true
        a.motionFDThreshold = 0.35

        let b = GradientViewModel(store: RecordingStore())
        b.apply(parameters: a.parameters)

        #expect(b.parameters == a.parameters)
        #expect(b.method == .fastr)
        #expect(b.trMarkerCode == "TR")
        #expect(b.windowBefore == 3)
        #expect(b.windowAfter == 4)
        #expect(b.fastrSlices == 5)
        #expect(b.fastrOBSAuto)
        #expect(b.fastrANC == true)
        #expect(!b.fastrSubSample)
        #expect(b.fastrUseFacetWindow)
        #expect(b.fastrOBSRandomSampling)
        #expect(b.fastrANCSliceHighPass)
        #expect(b.fastrUseMetal)
        #expect(b.fastrDonorSelection == .bergenRSquare)
        #expect(b.moosmannMotionMetric == .allParameters)
        #expect(b.excludeHighMotion == true)
    }

    @MainActor
    @Test func aasGradientOmitsFastrKeysButRoundTrips() {
        let a = GradientViewModel(store: RecordingStore())
        a.method = .aas
        a.windowBefore = 2
        a.windowAfter = 2

        #expect(a.parameters["slices"] == nil) // FASTR-only keys absent for AAS

        let b = GradientViewModel(store: RecordingStore())
        b.apply(parameters: a.parameters)
        #expect(b.method == .aas)
        #expect(b.parameters == a.parameters)
    }

    @MainActor
    @Test func masMetalSelectionRoundTrips() {
        let source = GradientViewModel(store: RecordingStore())
        source.method = .mas
        source.fastrUseMetal = true

        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: source.parameters)

        #expect(restored.method == .mas)
        #expect(restored.fastrUseMetal)
        #expect(restored.parameters == source.parameters)
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
