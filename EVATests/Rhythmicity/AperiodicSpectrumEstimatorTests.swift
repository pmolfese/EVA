//
//  AperiodicSpectrumEstimatorTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct AperiodicSpectrumEstimatorTests {
    @Test func complexDFTRoundTripIsNormalized() throws {
        let values = (0..<127).map { index in
            sin(Double(index) * 0.17) + 0.2 * cos(Double(index) * 0.43)
        }
        let plan = try RhythmicityDFTPlan(count: values.count)
        let spectrum = plan.forward(values)
        let recovered = plan.inverse(real: spectrum.real, imaginary: spectrum.imaginary)
        let maximumError = zip(values, recovered).map { abs($0 - $1) }.max() ?? .infinity
        #expect(maximumError < 1e-12)
    }

    @Test func welchWindowsNeverBridgeSegments() throws {
        let samplingRate = 64.0
        let first = (0..<128).map { sin(2 * Double.pi * 8 * Double($0) / samplingRate) }
        let second = (0..<128).map { sin(2 * Double.pi * 13 * Double($0) / samplingRate + 1.3) }
        let pooled = try AperiodicSpectrumEstimator.welch(
            samples: first + second,
            samplingRate: samplingRate,
            segments: [0..<128, 128..<256],
            windowSamples: 64
        )
        let firstOnly = try AperiodicSpectrumEstimator.welch(
            samples: first,
            samplingRate: samplingRate,
            segments: [0..<128],
            windowSamples: 64
        )
        let secondOnly = try AperiodicSpectrumEstimator.welch(
            samples: second,
            samplingRate: samplingRate,
            segments: [0..<128],
            windowSamples: 64
        )
        let expected = zip(firstOnly.power, secondOnly.power).map { ($0 + $1) / 2 }
        let maximumError = zip(pooled.power, expected).map { abs($0 - $1) }.max() ?? .infinity
        #expect(pooled.windowCount == firstOnly.windowCount + secondOnly.windowCount)
        #expect(maximumError < 1e-14)
    }

    @Test func linearPowerFitRecoversKnownPowerLaw() throws {
        let frequencies = (0...80).map(Double.init)
        let expectedExponent = -1.7
        let expectedIntercept = log10(2.5)
        let power = frequencies.map { frequency in
            frequency == 0 ? 0 : 2.5 * pow(frequency, expectedExponent)
        }
        let fit = try AperiodicSpectrumEstimator.fitPowerLaw(
            spectrum: WelchSpectrum(
                frequenciesHz: frequencies,
                power: power,
                windowSamples: 160,
                overlapSamples: 80,
                windowCount: 4
            ),
            fitRangeHz: 3...40
        )
        #expect(abs(fit.exponent - expectedExponent) < 1e-10)
        #expect(abs(fit.intercept - expectedIntercept) < 1e-10)
        #expect(abs(fit.rSquared - 1) < 1e-12)
    }

    @Test func excludedLineRangeDoesNotBiasFit() throws {
        let frequencies = (0...80).map(Double.init)
        var power = frequencies.map { frequency in
            frequency == 0 ? 0 : 4 * pow(frequency, -1.2)
        }
        power[60] *= 1_000_000
        let fit = try AperiodicSpectrumEstimator.fitPowerLaw(
            spectrum: WelchSpectrum(
                frequenciesHz: frequencies,
                power: power,
                windowSamples: 160,
                overlapSamples: 80,
                windowCount: 3
            ),
            fitRangeHz: 3...75,
            excludedRangesHz: [58...62]
        )
        #expect(abs(fit.exponent + 1.2) < 1e-9)
        #expect(fit.excludedRangesHz == [58...62])
    }
}
