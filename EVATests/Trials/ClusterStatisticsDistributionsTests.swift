//
//  ClusterStatisticsDistributionsTests.swift
//  EVATests
//
//  Reference values are R's `qt`/`qf`/`pt`/`pf` and `lgamma`, quoted to more
//  digits than the assertions need.
//

import Foundation
import Testing
@testable import EVA

struct ClusterStatisticsDistributionsTests {
    @Test func logGammaMatchesKnownValues() {
        // Gamma(n) = (n-1)! for integer n.
        #expect(abs(ClusterStatisticsDistributions.logGamma(1)) < 1e-12)
        #expect(abs(ClusterStatisticsDistributions.logGamma(5) - log(24.0)) < 1e-11)
        #expect(abs(ClusterStatisticsDistributions.logGamma(0.5) - log(Double.pi.squareRoot())) < 1e-12)
        // lgamma(100) = 359.1342053695754
        #expect(abs(ClusterStatisticsDistributions.logGamma(100) - 359.134_205_369_575_4) < 1e-9)
    }

    @Test func incompleteBetaMatchesClosedFormCases() {
        // I_x(1, 1) = x
        #expect(abs(ClusterStatisticsDistributions.regularizedIncompleteBeta(a: 1, b: 1, x: 0.37) - 0.37) < 1e-12)
        // I_x(1, 2) = 1 - (1 - x)^2
        let x = 0.25
        #expect(abs(
            ClusterStatisticsDistributions.regularizedIncompleteBeta(a: 1, b: 2, x: x)
                - (1 - (1 - x) * (1 - x))
        ) < 1e-12)
        // Symmetric case is exactly one half at the midpoint.
        #expect(abs(ClusterStatisticsDistributions.regularizedIncompleteBeta(a: 3, b: 3, x: 0.5) - 0.5) < 1e-12)
    }

    @Test func twoTailedTProbabilityMatchesR() {
        // 2 * pt(2.0, df, lower = FALSE)
        #expect(abs(ClusterStatisticsDistributions.twoTailedTProbability(2.0, degreesOfFreedom: 10) - 0.073_388_034_77) < 1e-9)
        #expect(abs(ClusterStatisticsDistributions.twoTailedTProbability(2.0, degreesOfFreedom: 60) - 0.050_033_043_65) < 1e-9)
        #expect(abs(ClusterStatisticsDistributions.twoTailedTProbability(2.0, degreesOfFreedom: 2) - 0.183_503_419_07) < 1e-9)
        #expect(ClusterStatisticsDistributions.twoTailedTProbability(0, degreesOfFreedom: 10) == 1)
    }

    @Test func criticalTMatchesR() throws {
        // qt(1 - alpha/2, df)
        let cases: [(alpha: Double, df: Double, expected: Double)] = [
            (0.05, 10, 2.228_138_852),
            (0.05, 60, 2.000_297_822),
            (0.01, 30, 2.749_995_65),
            (0.10, 5, 2.015_048_373),
            (0.05, 1_000, 1.962_339_08),
        ]
        for testCase in cases {
            let critical = try #require(ClusterStatisticsDistributions.criticalT(
                twoTailedAlpha: testCase.alpha,
                degreesOfFreedom: testCase.df
            ))
            #expect(abs(critical - testCase.expected) < 1e-6)
        }
    }

    @Test func criticalFMatchesR() throws {
        // qf(1 - alpha, d1, d2)
        let cases: [(alpha: Double, d1: Double, d2: Double, expected: Double)] = [
            (0.05, 2, 45, 3.204_317_5),
            (0.05, 1, 10, 4.964_602_74),
            (0.01, 3, 20, 4.938_193_66),
            (0.05, 4, 100, 2.462_607_2),
        ]
        for testCase in cases {
            let critical = try #require(ClusterStatisticsDistributions.criticalF(
                alpha: testCase.alpha,
                numeratorDegreesOfFreedom: testCase.d1,
                denominatorDegreesOfFreedom: testCase.d2
            ))
            #expect(abs(critical - testCase.expected) < 1e-5)
        }
    }

    @Test func criticalValuesRoundTripThroughTheirTails() throws {
        for df in [3.0, 12.0, 47.0, 250.0] {
            for alpha in [0.001, 0.01, 0.05, 0.10] {
                let critical = try #require(ClusterStatisticsDistributions.criticalT(
                    twoTailedAlpha: alpha,
                    degreesOfFreedom: df
                ))
                let recovered = ClusterStatisticsDistributions.twoTailedTProbability(
                    critical,
                    degreesOfFreedom: df
                )
                #expect(abs(recovered - alpha) < 1e-9)
            }
        }
    }

    @Test func aFixedStatisticThresholdMeansDifferentThingsAtDifferentTrialCounts() {
        // The reason the probability threshold exists at all.
        let small = ClusterStatisticsDistributions.twoTailedTProbability(2.0, degreesOfFreedom: 4)
        let large = ClusterStatisticsDistributions.twoTailedTProbability(2.0, degreesOfFreedom: 400)
        #expect(small > 0.11)
        #expect(large < 0.05)
    }

    @Test func rejectsDegenerateArguments() {
        #expect(ClusterStatisticsDistributions.criticalT(twoTailedAlpha: 0, degreesOfFreedom: 10) == nil)
        #expect(ClusterStatisticsDistributions.criticalT(twoTailedAlpha: 1, degreesOfFreedom: 10) == nil)
        #expect(ClusterStatisticsDistributions.criticalT(twoTailedAlpha: 0.05, degreesOfFreedom: 0) == nil)
        #expect(ClusterStatisticsDistributions.criticalF(
            alpha: 0.05,
            numeratorDegreesOfFreedom: 0,
            denominatorDegreesOfFreedom: 10
        ) == nil)
    }
}
