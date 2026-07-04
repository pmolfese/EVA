//
//  TRSpacingTests.swift
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
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct TRSpacingTests {

    @Test func evenlySpacedTriggers() {
        let info = TRSpacingInfo.from(triggerSamples: [0, 100, 200, 300, 400], samplingRate: 100)
        #expect(info.isEvenlySpaced)
        #expect(info.triggerCount == 5)
        #expect(info.distinctIntervalCount == 1)
        #expect(abs(info.modeSeconds - 1.0) < 1e-9)      // 100 samples / 100 Hz
        #expect(abs(info.medianSeconds - 1.0) < 1e-9)
        #expect(abs(info.meanSeconds - 1.0) < 1e-9)
    }

    @Test func withinToleranceStaysEven() {
        // Gaps 100, 101, 100, 99 — all within 1 sample of the median (100).
        let info = TRSpacingInfo.from(triggerSamples: [0, 100, 201, 301, 400], samplingRate: 100)
        #expect(info.isEvenlySpaced)
    }

    @Test func beyondToleranceIsUneven() {
        // A 150-sample gap deviates 50 from the median => uneven.
        let info = TRSpacingInfo.from(triggerSamples: [0, 100, 250, 350], samplingRate: 100)
        #expect(!info.isEvenlySpaced)
        #expect(info.distinctIntervalCount == 2)
    }

    @Test func modePicksMostCommonInterval() {
        // Gaps: 100,100,100,140 => mode 100 (1.0 s), mean (110) and median differ.
        let info = TRSpacingInfo.from(triggerSamples: [0, 100, 200, 300, 440], samplingRate: 100)
        #expect(abs(info.modeSeconds - 1.0) < 1e-9)
        #expect(info.meanSeconds > info.modeSeconds)   // mean dragged up by the 140 gap
    }

    @Test func tooFewTriggers() {
        let none = TRSpacingInfo.from(triggerSamples: [], samplingRate: 100)
        #expect(!none.hasEnoughTriggers)
        #expect(!none.isEvenlySpaced)

        let one = TRSpacingInfo.from(triggerSamples: [42], samplingRate: 100)
        #expect(!one.hasEnoughTriggers)
        #expect(!one.isEvenlySpaced)
    }

    @Test func unsortedInputIsHandled() {
        let info = TRSpacingInfo.from(triggerSamples: [300, 0, 200, 100], samplingRate: 100)
        #expect(info.isEvenlySpaced)
        #expect(abs(info.modeSeconds - 1.0) < 1e-9)
    }

    @Test func zeroSamplingRateGivesZeroSeconds() {
        let info = TRSpacingInfo.from(triggerSamples: [0, 100, 200], samplingRate: 0)
        #expect(info.isEvenlySpaced)         // spacing logic still works in samples
        #expect(info.modeSeconds == 0)       // but seconds are undefined -> 0
    }
}
