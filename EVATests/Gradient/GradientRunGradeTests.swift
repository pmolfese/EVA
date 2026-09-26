//
//  GradientRunGradeTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The gradient run grade: that the TR-locked residual metric reads near zero
//  on a clean correction and high on a poor one, and that the band edges
//  settled by GradientRunGradeMeasurementTests stay where they were put.
//

import Foundation
import Testing
@testable import EVA

struct GradientRunGradeTests {

    /// Brain-like noise plus a large, broadband periodic artifact, with the
    /// clean signal kept so a "correction" can be built at any quality.
    private struct Fixture {
        var clean: [[Float]]
        var noisy: [[Float]]
        var artifact: [[Float]]
        var triggers: [Int]
    }

    private func fixture(channels: Int = 6, period: Int = 400, volumes: Int = 30) -> Fixture {
        let n = period * volumes + 100
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func gaussian() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u1 = max(1e-12, Double(state >> 11) / Double(1 << 53))
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u2 = Double(state >> 11) / Double(1 << 53)
            return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
        // One period of a spiky dB/dt-like waveform.
        let shape: [Float] = (0..<period).map { k in
            let phase = Double(k % 40)
            return Float((phase < 3 ? 1.0 : (phase < 6 ? -1.0 : 0.05 * sin(Double(k) * 0.9))))
        }
        var clean: [[Float]] = [], noisy: [[Float]] = [], artifact: [[Float]] = []
        for c in 0..<channels {
            // Smooth "brain": a low-passed random walk, ~10 µV.
            var x = [Float](repeating: 0, count: n)
            var level: Float = 0
            for t in 0..<n { level = 0.97 * level + gaussian(); x[t] = level * 2.5 }
            let amplitude = Float(500 + 300 * c)
            let a: [Float] = (0..<n).map { t in t >= 50 && t < 50 + period * volumes ? amplitude * shape[(t - 50) % period] : 0 }
            clean.append(x)
            artifact.append(a)
            noisy.append(zip(x, a).map { $0 + $1 })
        }
        return Fixture(clean: clean, noisy: noisy, artifact: artifact,
                       triggers: (0..<volumes).map { 50 + $0 * period })
    }

    /// A correction that leaves `leftover` of the artifact behind.
    private func corrected(_ f: Fixture, leftover: Float) -> [[Float]] {
        zip(f.clean, f.artifact).map { x, a in zip(x, a).map { $0 + leftover * $1 } }
    }

    @Test func aPerfectCorrectionReadsNearZeroResidual() throws {
        let f = fixture()
        let m = try #require(GradientRunMetricsCalculator.measure(
            input: f.noisy, output: f.clean, triggers: f.triggers, samplingRate: 1000, correctedEpochs: 30, totalEpochs: 30))
        #expect(m.residualFractionP90 < GradientRunGrade.residualGoodCeiling / 2)
        #expect(m.removedVarianceFraction > 0.99)
        #expect(m.removedVarianceFraction <= 1.0001)
        #expect(GradientRunGrade.grade(from: m).grade == .good)
    }

    @Test func leftoverArtifactRaisesTheResidualAndTheGrade() throws {
        let f = fixture()
        let small = try #require(GradientRunMetricsCalculator.measure(
            input: f.noisy, output: corrected(f, leftover: 0.002), triggers: f.triggers, samplingRate: 1000,
            correctedEpochs: 30, totalEpochs: 30))
        let large = try #require(GradientRunMetricsCalculator.measure(
            input: f.noisy, output: corrected(f, leftover: 0.05), triggers: f.triggers, samplingRate: 1000,
            correctedEpochs: 30, totalEpochs: 30))
        #expect(large.residualFractionP90 > small.residualFractionP90)
        #expect(large.residualFractionP90 >= GradientRunGrade.residualPoorFloor)
        #expect(GradientRunGrade.grade(from: large).grade == .poor)
    }

    @Test func aTimingResidualIsSeen() throws {
        // Subtracting a one-sample-shifted artifact leaves a residue that is not
        // a scaled copy of the artifact, but is still locked to the TR.
        let f = fixture()
        let output = zip(f.noisy, f.artifact).map { x, a in
            x.indices.map { t in x[t] - (t > 0 ? a[t - 1] : 0) }
        }
        let m = try #require(GradientRunMetricsCalculator.measure(
            input: f.noisy, output: output, triggers: f.triggers, samplingRate: 1000, correctedEpochs: 30, totalEpochs: 30))
        #expect(m.residualFractionP90 >= GradientRunGrade.residualPoorFloor)
    }

    @Test func fewerThanTwoTriggersCannotBeMeasured() {
        let f = fixture()
        #expect(GradientRunMetricsCalculator.measure(
            input: f.noisy, output: f.clean, triggers: [50], samplingRate: 1000, correctedEpochs: 1, totalEpochs: 1) == nil)
    }

    // MARK: Band edges

    private func metrics(p90: Double, corrected: Int = 100, total: Int = 100) -> GradientRunMetrics {
        GradientRunMetrics(
            residualFractionP90: p90, residualFractionMedian: p90 / 2,
            residualFractionMax: p90, worstChannel: 3,
            inBandResidualFractionP90: p90, inBandResidualFractionMedian: p90 / 2,
            removedVarianceFraction: 0.999,
            correctedEpochs: corrected, totalEpochs: total, gradedChannelCount: 32)
    }

    @Test func residualBandEdges() {
        func grade(_ v: Double) -> RunGrade? {
            GradientRunGrade.grade(from: metrics(p90: v)).metrics.first { $0.name == "Residual artifact" }?.grade
        }
        #expect(grade(GradientRunGrade.residualGoodCeiling - 1e-6) == .good)
        #expect(grade(GradientRunGrade.residualGoodCeiling) == .watch)
        #expect(grade(GradientRunGrade.residualPoorFloor - 1e-6) == .watch)
        #expect(grade(GradientRunGrade.residualPoorFloor) == .poor)
    }

    @Test func coverageBandEdges() {
        func grade(_ corrected: Int) -> RunGrade? {
            GradientRunGrade.grade(from: metrics(p90: 0.001, corrected: corrected, total: 100))
                .metrics.first { $0.name == "Epoch coverage" }?.grade
        }
        #expect(grade(100) == .good)
        #expect(grade(98) == .good)
        #expect(grade(97) == .watch)
        #expect(grade(90) == .watch)
        #expect(grade(89) == .poor)
    }

    @Test func removedVarianceBandEdges() {
        func grade(_ v: Double) -> RunGrade {
            var m = metrics(p90: 0.001)
            m.removedVarianceFraction = v
            return GradientRunGrade.grade(from: m).grade
        }
        #expect(grade(GradientRunGrade.removedVariancePoorCeiling - 1e-6) == .poor)
        #expect(grade(GradientRunGrade.removedVariancePoorCeiling) == .good)
        #expect(grade(0.999) == .good)
        #expect(grade(GradientRunGrade.removedVariancePoorFloor - 1e-6) == .good)
        #expect(grade(GradientRunGrade.removedVariancePoorFloor) == .poor)
    }

    // MARK: History dispatch

    @MainActor @Test func aNodeIsGradedByItsOwnStepNotByUpstreamReports() {
        var snapshot = PipelineSnapshot()
        snapshot.gradientRunMetrics = metrics(p90: 0.5)
        let gradientStep = EVAProcessingStep(operation: .mriGradientCorrection)
        let filterStep = EVAProcessingStep(operation: .filter)
        #expect(RecordingHistoryModel.quality(for: gradientStep, in: snapshot)?.grade == .poor)
        // A filter applied after the gradient step carries the gradient metrics
        // in its snapshot but must not inherit the gradient's grade.
        #expect(RecordingHistoryModel.quality(for: filterStep, in: snapshot) == nil)
        #expect(RecordingHistoryModel.quality(for: nil, in: snapshot) == nil)
    }
}
