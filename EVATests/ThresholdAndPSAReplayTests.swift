//
//  ThresholdAndPSAReplayTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Round-trip coverage for the flat (human-readable) eva.xml params: ocular
//  threshold config and PSA epoching. Flat params replace the old JSON blob so
//  naive readers can print each setting.
//

import Testing
import Foundation
@testable import EVA

struct ThresholdAndPSAReplayTests {

    @Test func thresholdConfigFlatParamsRoundTrip() {
        var c = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        c.amplitudeMinMicrovolts = 175
        c.amplitudeMaxMicrovolts = 500
        c.riseWindowSeconds = 0.1
        c.velocityEnabled = true
        c.velocityThresholdMicrovoltsPerMillisecond = 6
        c.polarity = .positive
        c.channelOverride = [7, 24]

        let flat = c.flatParameters(prefix: "blink")
        let back = EyeArtifactThresholdConfiguration.fromFlatParameters(
            flat, prefix: "blink", base: .defaults(for: .blink))
        #expect(back == c)
    }

    @Test func thresholdFlatParamsAreReadableNotJSON() {
        let flat = EyeArtifactThresholdConfiguration.defaults(for: .blink).flatParameters(prefix: "blink")
        #expect(flat["blink.amplitudeMinMicrovolts"] == "150")
        #expect(flat["blink.polarity"] == "Bipolar")
        #expect(flat["blink.mergeGapSeconds"] == "0.25")
        // No value should be a JSON blob.
        #expect(flat.values.allSatisfy { !$0.contains("{") && !$0.contains("\"") })
    }

    @MainActor
    @Test func epochingParametersRoundTrip() {
        let a = EpochingViewModel(store: RecordingStore())
        a.preStimulus = 0.15
        a.postStimulus = 0.6
        a.offset = 0.02
        a.baselineCorrected = true
        a.averageReference = true
        a.averageOnApply = true
        a.skipEyeBlinks = false
        a.selectedEventCodes = ["TAR", "STD"]
        a.categoryNames = ["TAR": "Target", "STD": "Standard"]

        let p = a.parameters
        #expect(p["preStimulusMs"] == "150")
        #expect(p["postStimulusMs"] == "600")
        #expect(p["average"] == "true")
        #expect(p["eventCodes"] == "STD,TAR") // sorted
        #expect(p["category.TAR"] == "Target")

        let b = EpochingViewModel(store: RecordingStore())
        b.apply(parameters: p)
        #expect(b.preStimulus == 0.15)
        #expect(b.postStimulus == 0.6)
        #expect(b.baselineCorrected == true)
        #expect(b.averageOnApply == true)
        #expect(b.skipEyeBlinks == false)
        #expect(b.selectedEventCodes == ["TAR", "STD"])
        #expect(b.categoryNames["STD"] == "Standard")
    }
}
