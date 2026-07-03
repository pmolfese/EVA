//
//  GradientReplayTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
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
        let a = GradientViewModel()
        a.method = .fastr
        a.trMarkerCode = "TR"
        a.windowBefore = 3
        a.windowAfter = 4
        a.fastrSlices = 5
        a.fastrOBSAuto = false
        a.fastrANC = true
        a.excludeHighMotion = true
        a.motionFDThreshold = 0.35

        let b = GradientViewModel()
        b.apply(parameters: a.parameters)

        #expect(b.parameters == a.parameters)
        #expect(b.method == .fastr)
        #expect(b.trMarkerCode == "TR")
        #expect(b.windowBefore == 3)
        #expect(b.windowAfter == 4)
        #expect(b.fastrSlices == 5)
        #expect(b.fastrOBSAuto == false)
        #expect(b.fastrANC == true)
        #expect(b.excludeHighMotion == true)
    }

    @MainActor
    @Test func aasGradientOmitsFastrKeysButRoundTrips() {
        let a = GradientViewModel()
        a.method = .aas
        a.windowBefore = 2
        a.windowAfter = 2

        #expect(a.parameters["slices"] == nil) // FASTR-only keys absent for AAS

        let b = GradientViewModel()
        b.apply(parameters: a.parameters)
        #expect(b.method == .aas)
        #expect(b.parameters == a.parameters)
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
