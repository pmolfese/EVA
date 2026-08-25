//
//  TrialAlignmentMetricsTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Built on a two-peak waveform on purpose: the whole point of these metrics is
//  that a single whole-epoch correlation cannot tell "my P3 is missing" from
//  "my P3 is late".
//

import Testing
import Foundation
@testable import EVA

struct TrialAlignmentMetricsTests {

    private let rate = 500.0
    private let count = 300
    private let offset = 50

    /// P1-like bump near 100 ms and a P3-like bump near 400 ms, independently
    /// scalable so a trial can have one and not the other.
    private func twoPeak(early: Double = 1, late: Double = 1) -> [Double] {
        (0 ..< count).map { index in
            let t = Double(index - offset) / rate
            let first = bump(t, center: 0.10, width: 0.06) * early
            let second = bump(t, center: 0.40, width: 0.12) * late
            return first + second
        }
    }

    private func bump(_ t: Double, center: Double, width: Double) -> Double {
        let z = (t - center) / width
        return exp(-z * z) * 1.0
    }

    private func shifted(_ series: [Double], by samples: Int) -> [Double] {
        (0 ..< series.count).map { index in
            let source = index - samples
            return series.indices.contains(source) ? series[source] : 0
        }
    }

    private func noisy(_ series: [Double], scale: Double, seed: UInt64) -> [Double] {
        var generator = SeededGenerator(seed: seed)
        return series.map { value in
            let unit = Double(generator.next() >> 11) / Double(UInt64(1) << 53)
            return value + (unit - 0.5) * 2 * scale
        }
    }

    // MARK: - Per-window

    @Test func aMissingLatePeakShowsInItsOwnWindowNotTheEarlyOne() throws {
        let reference = twoPeak()
        let trial = twoPeak(early: 1, late: 0.05)   // P1 intact, P3 gone

        let windows = [
            TrialAlignmentMetrics.AnalysisWindow(name: "P1", startMs: 40, endMs: 180),
            TrialAlignmentMetrics.AnalysisWindow(name: "P3", startMs: 250, endMs: 550)
        ]
        let scores = TrialAlignmentMetrics.windowScores(
            trial: trial, reference: reference, windows: windows,
            stimulusOffsetSamples: offset, samplingRate: rate
        )
        #expect(scores.count == 2)

        let p1 = try #require(scores.first { $0.windowName == "P1" })
        let p3 = try #require(scores.first { $0.windowName == "P3" })

        // Shape survives in both — it is the SIZE that vanished, which is
        // exactly the distinction β exists to make.
        #expect(p1.correlation > 0.95)
        #expect(abs(p1.slope - 1) < 0.15)
        #expect(p3.slope < 0.3, "P3 slope \(p3.slope)")

        // And a single whole-epoch score would have blurred the two together.
        let whole = TrialSimilarityAnalyzer.regression(of: trial, on: reference)
        #expect(whole.slope > p3.slope)
    }

    // MARK: - Time-resolved

    @Test func timeResolvedCorrelationLocatesWhereATrialGoesWrong() throws {
        let reference = twoPeak()
        var trial = twoPeak()
        // Corrupt only the late half.
        for index in 200 ..< count { trial[index] = -trial[index] * 3 }

        let points = TrialAlignmentMetrics.timeResolvedCorrelation(
            trial: trial, reference: reference,
            windowSamples: 40, stepSamples: 5,
            stimulusOffsetSamples: offset, samplingRate: rate
        )
        #expect(points.count > 5)

        let early = points.filter { $0.centerSample < 150 }.map(\.correlation)
        let late = points.filter { $0.centerSample > 230 }.map(\.correlation)
        #expect(!early.isEmpty && !late.isEmpty)
        #expect((early.reduce(0, +) / Double(early.count)) > 0.9)
        #expect((late.reduce(0, +) / Double(late.count)) < 0)
    }

    @Test func timeResolvedCorrelationNeedsAUsableWindow() {
        let reference = twoPeak()
        #expect(
            TrialAlignmentMetrics.timeResolvedCorrelation(
                trial: reference, reference: reference,
                windowSamples: 1000, stimulusOffsetSamples: offset, samplingRate: rate
            ).isEmpty
        )
    }

    // MARK: - Affine

    @Test func aMerelyLateTrialFitsCleanlyOnceShifted() throws {
        let reference = twoPeak()
        let trial = shifted(reference, by: 20)   // 40 ms late, otherwise identical

        let fit = try #require(
            TrialAlignmentMetrics.affineFit(
                trial: trial, reference: reference,
                maxLagSamples: 60, samplingRate: rate
            )
        )

        #expect(fit.lagSamples == 20)
        #expect(abs(fit.lagMs - 40) < 1e-6)
        #expect(abs(fit.gain - 1) < 0.05)
        // The whole point: after alignment there is almost nothing left, so the
        // trial is late rather than bad.
        #expect(fit.residualAfter < 0.1, "residualAfter \(fit.residualAfter)")
        #expect(fit.residualBefore > fit.residualAfter)
        #expect(fit.explainedByAlignment > 0.8)
    }

    @Test func aMerelySmallTrialIsExplainedByGainNotByShape() throws {
        let reference = twoPeak()
        let trial = reference.map { $0 * 0.35 }

        let fit = try #require(
            TrialAlignmentMetrics.affineFit(
                trial: trial, reference: reference,
                maxLagSamples: 40, samplingRate: rate
            )
        )
        #expect(fit.lagSamples == 0)
        #expect(abs(fit.gain - 0.35) < 0.05)
        #expect(fit.residualAfter < 0.1)
    }

    @Test func aGenuinelyDifferentShapeIsNotRescuedByAlignment() throws {
        let reference = twoPeak()
        // Same components, opposite relative weighting: no shift or scale can
        // turn one into the other.
        let trial = twoPeak(early: 0.1, late: 2.0)

        let fit = try #require(
            TrialAlignmentMetrics.affineFit(
                trial: trial, reference: reference,
                maxLagSamples: 60, samplingRate: rate
            )
        )
        #expect(fit.residualAfter > 0.2, "residualAfter \(fit.residualAfter)")
    }

    @Test func deformationRisesWithTheBendingRequired() throws {
        let reference = twoPeak()
        let straight = try #require(
            TrialAlignmentMetrics.affineFit(trial: reference, reference: reference, maxLagSamples: 60, samplingRate: rate)
        )
        let bent = try #require(
            TrialAlignmentMetrics.affineFit(
                trial: shifted(reference, by: 45).map { $0 * 0.3 },
                reference: reference, maxLagSamples: 60, samplingRate: rate
            )
        )
        #expect(straight.deformation < 0.05)
        #expect(bent.deformation > straight.deformation)
        // Fits well AFTER heavy bending — which the deformation number is there
        // to stop anyone missing.
        #expect(bent.residualAfter < 0.2)
    }

    @Test func theLagSearchIsBoundedSoAnyLagCannotBeFound() throws {
        let reference = twoPeak()
        let trial = shifted(reference, by: 40)
        let fit = try #require(
            TrialAlignmentMetrics.affineFit(
                trial: trial, reference: reference,
                maxLagSamples: 5, samplingRate: rate
            )
        )
        #expect(abs(fit.lagSamples) <= 5)
        #expect(fit.residualAfter > 0.2, "a clipped search must not claim a clean fit")
    }

    @Test func affineToleratesNoiseWithoutInventingALag() throws {
        let reference = twoPeak()
        let trial = noisy(reference, scale: 0.05, seed: 31)
        let fit = try #require(
            TrialAlignmentMetrics.affineFit(trial: trial, reference: reference, maxLagSamples: 50, samplingRate: rate)
        )
        #expect(abs(fit.lagSamples) <= 3, "lag \(fit.lagSamples)")
        #expect(abs(fit.gain - 1) < 0.2)
    }

    // MARK: - Component regression

    @Test func jointRegressionSplitsVarianceTwoWindowsWouldBothClaim() throws {
        // Two heavily overlapping regressors. The trial is 1.0 of the first and
        // 0.0 of the second; a per-window fit on the second window would still
        // report a large slope, because the first component bleeds into it.
        let first = twoPeak(early: 1, late: 0)
        let second = twoPeak(early: 0.8, late: 1)
        let trial = first

        let fit = try #require(
            TrialAlignmentMetrics.componentRegression(trial: trial, regressors: [first, second])
        )
        #expect(fit.weights.count == 2)
        #expect(abs(fit.weights[0] - 1) < 0.15, "weights \(fit.weights)")
        #expect(abs(fit.weights[1]) < 0.15, "weights \(fit.weights)")
        #expect(fit.normalizedResidualRMS < 0.05)
    }

    @Test func jointRegressionRecoversAKnownMixture() throws {
        let first = twoPeak(early: 1, late: 0)
        let second = twoPeak(early: 0, late: 1)
        let trial = zip(first, second).map { 0.4 * $0 + 1.7 * $1 }

        let fit = try #require(
            TrialAlignmentMetrics.componentRegression(trial: trial, regressors: [first, second])
        )
        #expect(abs(fit.weights[0] - 0.4) < 0.05)
        #expect(abs(fit.weights[1] - 1.7) < 0.05)
    }

    @Test func jointRegressionRefusesAnUnderdeterminedSystem() {
        let short = [1.0, 2.0, 3.0]
        #expect(
            TrialAlignmentMetrics.componentRegression(
                trial: short, regressors: [short, short, short, short]
            ) == nil
        )
        #expect(TrialAlignmentMetrics.componentRegression(trial: short, regressors: []) == nil)
    }
}
