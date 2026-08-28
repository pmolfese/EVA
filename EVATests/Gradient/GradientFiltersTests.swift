//
//  GradientFiltersTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The OBS and ANC sections of the functional spec both require the input to be
//  high-passed before anything is estimated from it. These cover the two
//  high-pass forms used to do that.
//

import Testing
import Foundation
@testable import EVA

struct GradientFiltersTests {

    private let samplingRate = 1000.0

    private func sine(hz: Double, count: Int, amplitude: Double = 10, phase: Double = 0) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / 1000 + phase)) }
    }

    private func rootMeanSquare(_ values: [Float], over range: Range<Int>) -> Double {
        var total = 0.0
        for index in range { total += Double(values[index]) * Double(values[index]) }
        return (total / Double(range.count)).squareRoot()
    }

    // MARK: - Butterworth high-pass

    @Test func highPassRemovesAConstantOffset() {
        let flat = [Float](repeating: 25, count: 2000)
        let filtered = GradientFilters.highPassZeroPhase(flat, cutoffHz: 2, samplingRate: samplingRate)
        #expect(rootMeanSquare(filtered, over: 200..<1800) < 0.01)
    }

    @Test func highPassRemovesSlowDriftButKeepsThePassband() {
        let count = 4000
        let drift = (0..<count).map { Float(40 * Double($0) / Double(count)) }
        let signal = sine(hz: 20, count: count)
        let combined = zip(signal, drift).map(+)

        let filtered = GradientFilters.highPassZeroPhase(combined, cutoffHz: 2, samplingRate: samplingRate)
        let interior = 500..<3500
        let recovered = rootMeanSquare(filtered, over: interior)
        let expected = rootMeanSquare(signal, over: interior)
        #expect(abs(recovered - expected) < expected * 0.05,
                "recovered \(recovered) vs \(expected)")
    }

    @Test func highPassIntroducesNoPhaseShift() {
        let count = 4000
        let signal = sine(hz: 20, count: count)
        let filtered = GradientFilters.highPassZeroPhase(signal, cutoffHz: 2, samplingRate: samplingRate)
        let r = GradientDonorSelection.pearsonCorrelation(
            Array(signal[500..<3500]),
            Array(filtered[500..<3500])
        )
        #expect(r > 0.999, "zero-phase filtering should not shift the waveform; r = \(r)")
    }

    @Test func highPassAttenuatesBelowTheCutoff() {
        let count = 8000
        let slow = sine(hz: 0.3, count: count)
        let filtered = GradientFilters.highPassZeroPhase(slow, cutoffHz: 2, samplingRate: samplingRate)
        let interior = 1000..<7000
        #expect(rootMeanSquare(filtered, over: interior) < rootMeanSquare(slow, over: interior) * 0.1)
    }

    @Test func highPassLeavesUnusableRequestsAlone() {
        let signal = sine(hz: 20, count: 500)
        #expect(GradientFilters.highPassZeroPhase(signal, cutoffHz: 0, samplingRate: samplingRate) == signal)
        #expect(GradientFilters.highPassZeroPhase(signal, cutoffHz: 800, samplingRate: samplingRate) == signal)
        let tiny: [Float] = [1, 2, 3]
        #expect(GradientFilters.highPassZeroPhase(tiny, cutoffHz: 2, samplingRate: samplingRate) == tiny)
    }

    @Test func highPassProducesFiniteOutput() {
        let signal = sine(hz: 40, count: 3000, amplitude: 1e5)
        let filtered = GradientFilters.highPassZeroPhase(signal, cutoffHz: 2, samplingRate: samplingRate)
        let finite = filtered.allSatisfy { $0.isFinite }
        #expect(finite)
    }

    // MARK: - Detrending

    @Test func detrendingRemovesOffsetAndSlope() {
        let ramp = (0..<200).map { Float(5 + 0.25 * Double($0)) }
        let detrended = GradientFilters.removeLinearTrend(ramp)
        for value in detrended { #expect(abs(value) < 1e-3) }
    }

    @Test func detrendingKeepsOscillationRidingOnATrend() {
        let count = 400
        let oscillation = sine(hz: 25, count: count)
        let trend = (0..<count).map { Float(12 - 0.08 * Double($0)) }
        let combined = zip(oscillation, trend).map(+)

        let detrended = GradientFilters.removeLinearTrend(combined)
        var worst = 0.0
        for index in 0..<count {
            worst = max(worst, abs(Double(detrended[index] - oscillation[index])))
        }
        // A sinusoid observed over a finite window has a small non-zero
        // least-squares slope of its own, so detrending necessarily takes a
        // little of it — here about 1 unit out of an amplitude of 10. That is
        // acceptable for the one place this is used: shaping residuals before
        // OBS estimates a basis from them.
        #expect(worst < 1.2, "worst deviation from the pure oscillation was \(worst)")
    }

    @Test func detrendingHandlesShortAndEmptyInput() {
        #expect(GradientFilters.removeLinearTrend([]).isEmpty)
        #expect(GradientFilters.removeLinearTrend([4]) == [0])
        let pair = GradientFilters.removeLinearTrend([2, 6])
        #expect(abs(pair[0] + 2) < 1e-5 && abs(pair[1] - 2) < 1e-5)
    }
}
