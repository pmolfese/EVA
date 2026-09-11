//
//  RhythmicityMilestone0Tests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation
import Testing
@testable import EVA

struct RhythmicityMilestone0Tests {
    private struct ReferenceInput: Decodable {
        struct Signal: Decodable {
            var samplingRateHz: Double
            var channels: [[Double]]
            var frequenciesHz: [Double]
            var waveletWidthCycles: Double
            var lagCycles: Double
        }
        struct ImpulseKernel: Decodable {
            var samplingRateHz: Double
            var sampleCount: Int
            var impulseIndexZeroBased: Int
            var frequencyHz: Double
            var waveletWidthCycles: Double
            var selectedIndicesZeroBased: [Int]
        }
        var schemaVersion: Int
        var signal: Signal
        var impulseKernel: ImpulseKernel
    }

    private struct PythonReference: Decodable {
        struct ImpulseKernel: Decodable {
            var selectedIndicesZeroBased: [Int]
            var real: [Double]
            var imaginary: [Double]
        }
        var schemaVersion: Int
        var upstreamCommit: String
        var lavi: [[Double]]
        var impulseKernel: ImpulseKernel
    }

    private struct ComplexValue {
        var re: Double
        var im: Double

        var magnitudeSquared: Double { re * re + im * im }
        var isFinite: Bool { re.isFinite && im.isFinite }
    }

    private static let input: ReferenceInput = decode("Rhythmicity/reference-input.json")
    private static let reference: PythonReference = decode("Rhythmicity/python-reference.json")

    private static func decode<T: Decodable>(_ name: String) -> T {
        let data = try! Data(contentsOf: Fixtures.url(name))
        return try! JSONDecoder().decode(T.self, from: data)
    }

    @Test func fixturesPinTheSelectedPythonRevision() {
        #expect(Self.input.schemaVersion == 1)
        #expect(Self.reference.schemaVersion == 1)
        #expect(Self.reference.upstreamCommit == "78386879eeb8cf9be06a1edfa6917c91b2d0d2ba")
        #expect(Self.reference.lavi.count == Self.input.signal.channels.count)
        #expect(Self.reference.lavi.allSatisfy { $0.count == Self.input.signal.frequenciesHz.count })
    }

    @Test func existingMorletHasEquivalentShapeButADifferentCenterConvention() {
        let input = Self.input.impulseKernel
        var impulse = [Double](repeating: 0, count: input.sampleCount)
        impulse[input.impulseIndexZeroBased] = 1
        let kernel = ComplexMorlet.kernel(
            frequencyHz: input.frequencyHz,
            nCycles: input.waveletWidthCycles,
            samplingRate: input.samplingRateHz,
            zeroMean: false
        )
        let coefficient = ComplexMorlet.convolveSame(signal: impulse, kernel: kernel)
        let actual = input.selectedIndicesZeroBased.map {
            ComplexValue(re: coefficient.re[$0], im: coefficient.im[$0])
        }
        let expected = zip(Self.reference.impulseKernel.real, Self.reference.impulseKernel.imaginary)
            .map { ComplexValue(re: $0.0, im: $0.1) }

        // Normalization is irrelevant to LAVI, so compare unit complex values.
        // The FieldTrip-style reference has an even sampled kernel at this
        // frequency and a half-sample center phase; EVA/MNE has an odd kernel
        // with an exact t=0 sample. Their envelope/phase shapes otherwise agree.
        var maximumUnitError = 0.0
        for (lhs, rhs) in zip(actual, expected) {
            let lhsMagnitude = sqrt(lhs.magnitudeSquared)
            let rhsMagnitude = sqrt(rhs.magnitudeSquared)
            guard lhsMagnitude > 1e-12, rhsMagnitude > 1e-12 else { continue }
            maximumUnitError = max(
                maximumUnitError,
                hypot(lhs.re / lhsMagnitude - rhs.re / rhsMagnitude,
                      lhs.im / lhsMagnitude - rhs.im / rhsMagnitude)
            )
        }
        #expect(maximumUnitError > 0.10 && maximumUnitError < 0.20,
                "Expected the pinned half-sample phase offset; got \(maximumUnitError)")
    }

    @Test func existingMorletCannotServeAsThePaperPreset() {
        let input = Self.input.signal
        var maximumError = 0.0
        for channel in input.channels.indices {
            for frequencyIndex in input.frequenciesHz.indices {
                let frequency = input.frequenciesHz[frequencyIndex]
                let actual = Self.lavi(
                    signal: input.channels[channel],
                    samplingRate: input.samplingRateHz,
                    frequencyHz: frequency,
                    widthCycles: input.waveletWidthCycles,
                    lagCycles: input.lagCycles
                )
                maximumError = max(maximumError, abs(actual - Self.reference.lavi[channel][frequencyIndex]))
            }
        }
        // The largest difference is about 0.545 at the lowest default
        // frequency. Milestone 1 therefore needs a separate FieldTrip/LAVI
        // convention; changing the existing MNE-compatible kernel would break
        // ERSP/ITPC parity.
        #expect(maximumError > 0.50 && maximumError < 0.56,
                "Pinned kernel-spike difference changed to \(maximumError)")
    }

    /// Milestone-0 spike only. Production segment-aware accumulation lands in
    /// milestone 1 and will be tested directly against the same fixture.
    private static func lavi(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        lagCycles: Double
    ) -> Double {
        let wavelet = ComplexMorlet.kernel(
            frequencyHz: frequencyHz,
            nCycles: widthCycles,
            samplingRate: samplingRate,
            zeroMean: false
        )
        let convolved = ComplexMorlet.convolveSame(signal: signal, kernel: wavelet)
        var coefficients = zip(convolved.re, convolved.im).map { ComplexValue(re: $0.0, im: $0.1) }

        // Match the maintained Python reference's FieldTrip valid-edge mask.
        let sigmaT = widthCycles / (2 * Double.pi * frequencyHz)
        let tapCount = Int(floor((6 * sigmaT) * samplingRate + 1e-12)) + 1
        for index in coefficients.indices {
            let oneBasedTime = Double(index + 1)
            if oneBasedTime < Double(tapCount) / 2
                || oneBasedTime >= Double(coefficients.count) - Double(tapCount) / 2 {
                coefficients[index] = ComplexValue(re: .nan, im: .nan)
            }
        }

        let lag = lagCycles / frequencyHz * samplingRate
        let integerLag = Int(floor(lag))
        let fraction = lag - Double(integerLag)
        let pairCount = coefficients.count - integerLag - 1
        var numerator = ComplexValue(re: 0, im: 0)
        var firstEnergy = 0.0
        var secondEnergy = 0.0
        for index in 0..<max(pairCount, 0) {
            let first = coefficients[index]
            let lower = coefficients[index + integerLag]
            let upper = coefficients[index + integerLag + 1]
            let second = ComplexValue(
                re: (1 - fraction) * lower.re + fraction * upper.re,
                im: (1 - fraction) * lower.im + fraction * upper.im
            )
            guard first.isFinite, second.isFinite else { continue }
            numerator.re += first.re * second.re + first.im * second.im
            numerator.im += first.im * second.re - first.re * second.im
            firstEnergy += first.magnitudeSquared
            secondEnergy += second.magnitudeSquared
        }
        return hypot(numerator.re, numerator.im) / sqrt(firstEnergy * secondEnergy)
    }
}
