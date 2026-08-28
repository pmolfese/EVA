//
//  GradientSincResamplerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The functional spec requires that whichever resampling method is chosen for
//  alignment be documented and tested on synthetic shifted sinusoids. These are
//  those tests.
//

import Testing
import Foundation
@testable import EVA

struct GradientSincResamplerTests {

    private func sine(frequency: Double, count: Int, phase: Double = 0, amplitude: Double = 50) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) + phase)) }
    }

    // MARK: - Kernel

    @Test func kernelIsOneAtZeroAndZeroAtOtherIntegers() {
        #expect(abs(GradientSincResampler.kernel(0, lobes: 4) - 1) < 1e-12)
        for integer in [-3, -2, -1, 1, 2, 3] {
            let value = GradientSincResampler.kernel(Double(integer), lobes: 4)
            #expect(abs(value) < 1e-9, "kernel(\(integer)) should vanish, got \(value)")
        }
    }

    @Test func kernelVanishesOutsideItsSupport() {
        #expect(GradientSincResampler.kernel(4.5, lobes: 4) == 0)
        #expect(GradientSincResampler.kernel(-4.5, lobes: 4) == 0)
    }

    // MARK: - Upsampling

    @Test func upsampleThenDecimateReturnsTheOriginalSamples() {
        let original = sine(frequency: 0.013, count: 400)
        for factor in [2, 3, 5, 10] {
            let roundTrip = GradientSincResampler.decimate(
                GradientSincResampler.upsample(original, factor: factor),
                factor: factor
            )
            #expect(roundTrip.count == original.count)
            for index in original.indices {
                #expect(roundTrip[index] == original[index],
                        "factor \(factor) index \(index) changed on round trip")
            }
        }
    }

    @Test func upsampleApproximatesTheUnderlyingContinuousSignal() {
        let frequency = 0.01
        let count = 300
        let original = sine(frequency: frequency, count: count)
        let factor = 4
        let upsampled = GradientSincResampler.upsample(original, factor: factor)

        #expect(upsampled.count == count * factor)
        // Skip the clamped edges, where edge extension necessarily deviates.
        var worst = 0.0
        for m in (10 * factor)..<((count - 10) * factor) {
            let time = Double(m) / Double(factor)
            let expected = 50 * sin(2 * .pi * frequency * time)
            worst = max(worst, abs(Double(upsampled[m]) - expected))
        }
        #expect(worst < 0.05, "worst interpolation error \(worst)")
    }

    @Test func upsampleOfAConstantIsConstant() {
        let flat = [Float](repeating: 7, count: 50)
        let upsampled = GradientSincResampler.upsample(flat, factor: 4)
        for value in upsampled { #expect(abs(value - 7) < 1e-4) }
    }

    @Test func upsampleIsIdentityAtFactorOne() {
        let original = sine(frequency: 0.03, count: 64)
        #expect(GradientSincResampler.upsample(original, factor: 1) == original)
        #expect(GradientSincResampler.decimate(original, factor: 1) == original)
    }

    // MARK: - Fractional delay

    @Test func integerDelayShiftsByWholeSamples() {
        let original = sine(frequency: 0.02, count: 200)
        let delayed = GradientSincResampler.fractionalDelay(original, by: 3)
        for index in 3..<original.count {
            #expect(delayed[index] == original[index - 3])
        }
    }

    @Test func fractionalDelayMatchesAnAnalyticallyShiftedSinusoid() {
        let frequency = 0.01
        let count = 400
        let original = sine(frequency: frequency, count: count)

        for delay in [0.25, 0.5, -0.5, 1.75, -2.4] {
            let delayed = GradientSincResampler.fractionalDelay(original, by: delay)
            #expect(delayed.count == count)
            var worst = 0.0
            for index in 20..<(count - 20) {
                let expected = 50 * sin(2 * .pi * frequency * (Double(index) - delay))
                worst = max(worst, abs(Double(delayed[index]) - expected))
            }
            #expect(worst < 0.05, "delay \(delay) worst error \(worst)")
        }
    }

    @Test func fractionalDelayRoundTripsBackToTheOriginal() {
        let original = sine(frequency: 0.008, count: 300)
        let there = GradientSincResampler.fractionalDelay(original, by: 0.4)
        let back = GradientSincResampler.fractionalDelay(there, by: -0.4)
        var worst = 0.0
        for index in 30..<(original.count - 30) {
            worst = max(worst, abs(Double(back[index] - original[index])))
        }
        #expect(worst < 0.1, "worst round-trip error \(worst)")
    }

    @Test func zeroDelayIsExactlyIdentity() {
        let original = sine(frequency: 0.05, count: 100)
        #expect(GradientSincResampler.fractionalDelay(original, by: 0) == original)
    }

    @Test func resamplingProducesFiniteOutputForFiniteInput() {
        let original = sine(frequency: 0.4, count: 128, amplitude: 1e5)
        #expect(GradientSincResampler.upsample(original, factor: 8).allSatisfy { $0.isFinite })
        #expect(GradientSincResampler.fractionalDelay(original, by: 0.5).allSatisfy { $0.isFinite })
    }

    @Test func handlesDegenerateInputs() {
        #expect(GradientSincResampler.upsample([], factor: 4).isEmpty)
        #expect(GradientSincResampler.fractionalDelay([], by: 0.5).isEmpty)
        #expect(GradientSincResampler.upsample([3], factor: 3) == [3, 3, 3])
    }
}
