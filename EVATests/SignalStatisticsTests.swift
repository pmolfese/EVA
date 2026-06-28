//
//  SignalStatisticsTests.swift
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

struct SignalStatisticsTests {

    @Test func percentileDoubleEndpointsAndMiddle() {
        let sorted = [0.0, 1.0, 2.0, 3.0, 4.0]
        #expect(SignalStatistics.percentile(sorted, fraction: 0) == 0)
        #expect(SignalStatistics.percentile(sorted, fraction: 1) == 4)
        #expect(SignalStatistics.percentile(sorted, fraction: 0.5) == 2)
    }

    @Test func percentileFloatMatchesDouble() {
        let sorted: [Float] = [0, 10, 20, 30, 40]
        #expect(SignalStatistics.percentile(sorted, fraction: 0.5) == 20)
    }

    @Test func rootMeanSquareOfConstant() {
        #expect(abs(SignalStatistics.rootMeanSquare([3, 3, 3, 3]) - 3) < 1e-12)
    }

    @Test func rootMeanSquareKnownValue() {
        // sqrt((3^2 + 4^2)/2) = sqrt(12.5)
        #expect(abs(SignalStatistics.rootMeanSquare([3, 4]) - (12.5).squareRoot()) < 1e-12)
    }

    @Test func sampleVarianceExceedsPopulationVariance() {
        let values = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
        let pop = SignalStatistics.populationVariance(values)
        let sample = SignalStatistics.sampleVariance(values)
        let n = Double(values.count)
        // sampleVar = popVar * n / (n - 1)
        #expect(abs(sample - pop * n / (n - 1)) < 1e-9)
        #expect(abs(pop - 4) < 1e-9) // textbook population variance for this set
    }

    @Test func vectorEnergyIsSumOfSquares() {
        #expect(abs(SignalStatistics.vectorEnergy([1.0, 2.0, 3.0]) - 14) < 1e-12)
        #expect(abs(SignalStatistics.vectorEnergy([1, 2, 3] as [Float]) - 14) < 1e-6)
    }

    @Test func degenerateInputsAreSafe() {
        #expect(SignalStatistics.rootMeanSquare([]) == 0)
        #expect(SignalStatistics.populationVariance([]) == 0)
        #expect(SignalStatistics.sampleVariance([1]) == 0)
        #expect(SignalStatistics.vectorEnergy([] as [Double]) == 0)
    }
}
