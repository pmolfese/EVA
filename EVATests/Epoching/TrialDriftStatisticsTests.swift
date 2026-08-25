//
//  TrialDriftStatisticsTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The p-values here end up printed next to a claim about drift, so the tail
//  areas are checked against published t-table values rather than assumed.
//

import Testing
import Foundation
@testable import EVA

struct TrialDriftStatisticsTests {

    // MARK: - Student's t, against the table

    @Test func tailAreasMatchTheTTable() {
        // Classic two-tailed 0.05 critical values.
        #expect(abs(TrialDriftStatistics.studentTTwoTailed(t: 2.228, df: 10) - 0.05) < 0.001)
        #expect(abs(TrialDriftStatistics.studentTTwoTailed(t: 2.086, df: 20) - 0.05) < 0.001)
        #expect(abs(TrialDriftStatistics.studentTTwoTailed(t: 1.960, df: 100_000) - 0.05) < 0.001)
        // And a 0.01 one.
        #expect(abs(TrialDriftStatistics.studentTTwoTailed(t: 3.169, df: 10) - 0.01) < 0.001)
        // t = 0 is the whole distribution.
        #expect(abs(TrialDriftStatistics.studentTTwoTailed(t: 0, df: 10) - 1.0) < 1e-9)
    }

    @Test func incompleteBetaMatchesKnownValues() {
        // I_0.5(1,1) = 0.5, and the symmetric case I_0.5(2,2) = 0.5.
        #expect(abs(TrialDriftStatistics.regularizedIncompleteBeta(a: 1, b: 1, x: 0.5) - 0.5) < 1e-9)
        #expect(abs(TrialDriftStatistics.regularizedIncompleteBeta(a: 2, b: 2, x: 0.5) - 0.5) < 1e-9)
        // I_x(1,1) = x.
        #expect(abs(TrialDriftStatistics.regularizedIncompleteBeta(a: 1, b: 1, x: 0.25) - 0.25) < 1e-9)
        #expect(TrialDriftStatistics.regularizedIncompleteBeta(a: 3, b: 5, x: 0) == 0)
        #expect(TrialDriftStatistics.regularizedIncompleteBeta(a: 3, b: 5, x: 1) == 1)
    }

    // MARK: - Ranks and Spearman

    @Test func tiedValuesShareAnAverageRank() {
        // 10, 20, 20, 30 -> ranks 1, 2.5, 2.5, 4.
        #expect(TrialDriftStatistics.ranks([10, 20, 20, 30]) == [1, 2.5, 2.5, 4])
        #expect(TrialDriftStatistics.ranks([5, 5, 5]) == [2, 2, 2])
    }

    @Test func aPerfectlyMonotonicDriftScoresOne() throws {
        let order = (0 ..< 20).map(Double.init)
        // Monotonic but distinctly non-linear: Pearson would be below 1 here,
        // Spearman should not be.
        let values = order.map { $0 * $0 }
        let result = try #require(TrialDriftStatistics.rankCorrelation(of: values, against: order))
        #expect(abs(result.rho - 1) < 1e-9)
        #expect(result.p < 0.001)
        #expect(result.isSignificant)
    }

    @Test func noDriftIsNotCalledSignificant() throws {
        let order = (0 ..< 30).map(Double.init)
        // Deterministic alternation: no monotonic trend at all.
        let values = order.map { $0.truncatingRemainder(dividingBy: 2) }
        let result = try #require(TrialDriftStatistics.rankCorrelation(of: values, against: order))
        #expect(abs(result.rho) < 0.2)
        #expect(result.isSignificant == false)
    }

    @Test func aDecliningMeasureGivesANegativeRho() throws {
        let order = (0 ..< 15).map(Double.init)
        let values = order.map { 100 - $0 * 3 }
        let result = try #require(TrialDriftStatistics.rankCorrelation(of: values, against: order))
        #expect(abs(result.rho + 1) < 1e-9)

        let trend = try #require(TrialDriftStatistics.linearTrend(of: values, against: order))
        #expect(abs(trend.slopePerTrial + 3) < 1e-9)
        #expect(abs(trend.value(at: 0) - 100) < 1e-9)
    }

    @Test func tooFewTrialsYieldNoCorrelation() {
        #expect(TrialDriftStatistics.rankCorrelation(of: [1, 2], against: [1, 2]) == nil)
    }

    // MARK: - Running median

    @Test func theRunningMedianIgnoresASpikeAMovingMeanWouldFollow() {
        var values = [Double](repeating: 1, count: 21)
        values[10] = 100

        let smoothed = TrialDriftStatistics.runningMedian(values, window: 5)
        // The spike does not survive the median at all.
        #expect(smoothed[10] == 1)
        #expect(smoothed.allSatisfy { $0 == 1 })

        // A mean over the same window would have been dragged well off 1.
        let windowMean = values[8 ... 12].reduce(0, +) / 5
        #expect(windowMean > 20)
    }

    // MARK: - Groups

    @Test func splitHalvesAndThirdsAreLabelledAsSuch() {
        let values = (1 ... 12).map(Double.init)

        let halves = TrialDriftStatistics.groupSummaries(values, groupCount: 2)
        #expect(halves.map(\.label) == ["First half", "Last half"])
        #expect(halves[0].count == 6)
        #expect(abs(halves[0].mean - 3.5) < 1e-9)
        #expect(abs(halves[1].mean - 9.5) < 1e-9)

        let thirds = TrialDriftStatistics.groupSummaries(values, groupCount: 3)
        #expect(thirds.map(\.label) == ["Early", "Middle", "Late"])
        #expect(thirds.allSatisfy { $0.count == 4 })

        let quarters = TrialDriftStatistics.groupSummaries(values, groupCount: 4)
        #expect(quarters.map(\.label) == ["Group 1", "Group 2", "Group 3", "Group 4"])
    }

    @Test func standardErrorShrinksWithMoreTrials() {
        let small = (0 ..< 4).map { Double($0) }
        let large = (0 ..< 64).map { Double($0 % 4) }
        #expect(TrialDriftStatistics.standardError(large) < TrialDriftStatistics.standardError(small))
        #expect(TrialDriftStatistics.standardError([7]) == 0)
    }

    // MARK: - Convergence

    @Test func convergenceRisesTowardOneAndEndsThere() throws {
        let base = (0 ..< 50).map { sin(Double($0) / 5) }
        var trials: [[Double]] = []
        for index in 0 ..< 20 {
            let scale = 1.0 + Double(index % 3) * 0.05
            trials.append(base.map { $0 * scale })
        }

        let points = TrialDriftStatistics.convergence(trials: trials)
        #expect(points.count == 19) // no point for a single-trial "average"
        let last = try #require(points.last)
        #expect(abs(last.correlationWithFinal - 1) < 1e-9)
        #expect(last.trialCount == 20)
    }

    @Test func anEarlyOutlierHoldsTheAverageAwayFromWhereItEndsUp() throws {
        // What the convergence panel is actually for: an early wild trial keeps
        // the running average unlike its destination for longer than a clean
        // run does. (A LATE outlier cannot show as a dip — the final average
        // already contains it, so adding it moves the running average toward
        // the final, not away.)
        let base = (0 ..< 50).map { sin(Double($0) / 5) }
        let contaminant = (0 ..< 50).map { cos(Double($0) / 5) * 8 }

        var contaminated = [[Double]](repeating: base, count: 30)
        contaminated[1] = contaminant

        let clean = [[Double]](repeating: base, count: 30)

        let earlyContaminated = try #require(
            TrialDriftStatistics.convergence(trials: contaminated).first { $0.trialCount == 4 }
        )
        let earlyClean = try #require(
            TrialDriftStatistics.convergence(trials: clean).first { $0.trialCount == 4 }
        )
        #expect(earlyContaminated.correlationWithFinal < earlyClean.correlationWithFinal)

        // And it does recover: by the end the early contamination is diluted.
        let late = try #require(
            TrialDriftStatistics.convergence(trials: contaminated).first { $0.trialCount == 29 }
        )
        #expect(late.correlationWithFinal > earlyContaminated.correlationWithFinal)
    }

    @Test func oneDominantTrialCanInvertTheAverageAndConvergenceSaysSo() {
        // Nineteen ordinary trials and one enormous inverted one: the "final"
        // average is upside down, so every running average before that trial
        // correlates -1 with the destination. Worth pinning — it looks alarming
        // on the plot, and it should, because the category average really is
        // being decided by a single trial.
        let base = (0 ..< 50).map { sin(Double($0) / 5) }
        var trials = [[Double]](repeating: base, count: 20)
        trials[18] = base.map { -$0 * 30 }

        let points = TrialDriftStatistics.convergence(trials: trials)
        let before = points.first { $0.trialCount == 18 }
        #expect((before?.correlationWithFinal ?? 0) < -0.99)
        #expect((points.last?.correlationWithFinal ?? 0) > 0.99)
    }

    // MARK: - Residuals

    @Test func residualsAreTrialMinusReferencePerSample() {
        let residuals = TrialDriftStatistics.residuals(
            trials: [[1, 2, 3], [4, 5, 6]],
            reference: [1, 1, 1]
        )
        #expect(residuals == [[0, 1, 2], [3, 4, 5]])
    }

    @Test func residualsTruncateToTheShorterSeries() {
        let residuals = TrialDriftStatistics.residuals(trials: [[1, 2, 3, 4]], reference: [1, 1])
        #expect(residuals == [[0, 1]])
    }
}
