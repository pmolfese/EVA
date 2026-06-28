//
//  HealthScoringTests.swift
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

import Testing
import Foundation
@testable import EVA

struct HealthScoringTests {

    @Test func clippingFractionGuards() {
        // Too few samples -> 0.
        #expect(HealthScoring.clippingFraction(absValues: [100, 100, 100], maxAbs: 100) == 0)
        // maxAbs at or below 20 -> 0 (signal too small to be "clipping").
        #expect(HealthScoring.clippingFraction(absValues: [20, 20, 20, 20], maxAbs: 20) == 0)
    }

    @Test func clippingFractionCountsValuesNearMax() {
        // 4 of 8 samples sit at the rail (100); tolerance is max(0.1, 0.01).
        let abs = [100.0, 100.0, 100.0, 100.0, 10, 20, 30, 40]
        #expect(HealthScoring.clippingFraction(absValues: abs, maxAbs: 100) == 0.5)
    }

    @Test func scoreUpperRatioIsOneBelowGreenZeroAboveRed() {
        #expect(HealthScoring.scoreUpperRatio(1.0, green: 2, red: 6) == 1)
        #expect(HealthScoring.scoreUpperRatio(2.0, green: 2, red: 6) == 1)
        #expect(HealthScoring.scoreUpperRatio(6.0, green: 2, red: 6) == 0)
        #expect(HealthScoring.scoreUpperRatio(10.0, green: 2, red: 6) == 0)
        // Midpoint is linear: ratio 4 between 2 and 6 -> 0.5.
        #expect(abs(HealthScoring.scoreUpperRatio(4.0, green: 2, red: 6) - 0.5) < 1e-9)
    }

    @Test func scoreUpperRatioRejectsNonFinite() {
        #expect(HealthScoring.scoreUpperRatio(.nan, green: 2, red: 6) == 0)
    }

    @Test func scoreTwoSidedRatioIsSymmetricAroundOne() {
        // A ratio and its reciprocal score identically.
        let high = HealthScoring.scoreTwoSidedRatio(4.0, green: 2, red: 6)
        let low = HealthScoring.scoreTwoSidedRatio(0.25, green: 2, red: 6)
        #expect(abs(high - low) < 1e-9)
    }

    @Test func scoreLowerBoundRewardsLargerValues() {
        #expect(HealthScoring.scoreLowerBound(10, green: 8, red: 2) == 1)
        #expect(HealthScoring.scoreLowerBound(2, green: 8, red: 2) == 0)
        #expect(abs(HealthScoring.scoreLowerBound(5, green: 8, red: 2) - 0.5) < 1e-9)
    }

    @Test func gradeThresholds() {
        #expect(HealthScoring.grade(for: 0.90) == .good)
        #expect(HealthScoring.grade(for: 0.78) == .good)
        #expect(HealthScoring.grade(for: 0.60) == .watch)
        #expect(HealthScoring.grade(for: 0.50) == .watch)
        #expect(HealthScoring.grade(for: 0.10) == .poor)
    }

    @Test func formattingHelpers() {
        #expect(HealthScoring.formatPercent(0.5) == "50.0%")
        #expect(HealthScoring.formatPercent(2.0) == "100.0%") // clamped
        #expect(HealthScoring.formatRatio(3.0) == "3.0x")
        #expect(HealthScoring.formatRatio(.nan) == "nanx")
        #expect(HealthScoring.formatMicrovolts(250) == "250 uV")
        #expect(HealthScoring.formatMicrovolts(12.5) == "12.5 uV")
        #expect(HealthScoring.formatMicrovolts(1.25) == "1.25 uV")
    }
}
