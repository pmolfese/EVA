//
//  ComplexCoefficientProviderTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct ComplexCoefficientProviderTests {
    private struct InputFixture: Decodable {
        struct Impulse: Decodable {
            var samplingRateHz: Double
            var sampleCount: Int
            var impulseIndexZeroBased: Int
            var frequencyHz: Double
            var waveletWidthCycles: Double
            var selectedIndicesZeroBased: [Int]
        }
        var impulseKernel: Impulse
    }

    private struct OutputFixture: Decodable {
        struct Impulse: Decodable {
            var selectedIndicesZeroBased: [Int]
            var real: [Double]
            var imaginary: [Double]
        }
        var impulseKernel: Impulse
    }

    private static let input: InputFixture = decode("Rhythmicity/reference-input.json")
    private static let output: OutputFixture = decode("Rhythmicity/python-reference.json")

    @Test func fieldTripConventionMatchesPinnedImpulseCoefficients() throws {
        let fixture = Self.input.impulseKernel
        var impulse = [Double](repeating: 0, count: fixture.sampleCount)
        impulse[fixture.impulseIndexZeroBased] = 1
        let tile = try DirectComplexCoefficientProvider().coefficients(
            signal: impulse,
            samplingRate: fixture.samplingRateHz,
            frequencyHz: fixture.frequencyHz,
            widthCycles: fixture.waveletWidthCycles,
            edgePolicy: .validOnly,
            cancellation: RhythmicityCancellation()
        )

        #expect(Self.output.impulseKernel.selectedIndicesZeroBased == fixture.selectedIndicesZeroBased)
        var maximumError = 0.0
        for (fixtureIndex, sampleIndex) in fixture.selectedIndicesZeroBased.enumerated() {
            maximumError = max(
                maximumError,
                max(
                    abs(tile.real[sampleIndex] - Self.output.impulseKernel.real[fixtureIndex]),
                    abs(tile.imaginary[sampleIndex] - Self.output.impulseKernel.imaginary[fixtureIndex])
                )
            )
        }
        #expect(maximumError < 1e-12, "LAVI impulse coefficient error: \(maximumError)")
        #expect(tile.validSampleRange == 47..<976)
    }

    @Test func evenTapCountRetainsTheHalfSampleCenter() {
        let kernel = LAVI2026Morlet.kernel(
            frequencyHz: 10,
            widthCycles: 5,
            samplingRate: 200
        )
        #expect(kernel.count == 96)
        #expect(kernel.imaginary[47] < 0)
        #expect(kernel.imaginary[48] > 0)
        #expect(abs(kernel.imaginary[47] + kernel.imaginary[48]) < 5e-5)
    }

    @Test func coefficientProviderHonorsCancellationBeforeAllocation() {
        let cancellation = RhythmicityCancellation()
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try DirectComplexCoefficientProvider().coefficients(
                signal: [1, 2, 3],
                samplingRate: 100,
                frequencyHz: 10,
                widthCycles: 5,
                edgePolicy: .validOnly,
                cancellation: cancellation
            )
        }
    }

    private static func decode<T: Decodable>(_ name: String) -> T {
        let data = try! Data(contentsOf: Fixtures.url(name))
        return try! JSONDecoder().decode(T.self, from: data)
    }
}
