//
//  IAAFTSurrogateGeneratorTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct IAAFTSurrogateGeneratorTests {
    @Test func preservesAmplitudeDistributionExactlyAndIsDeterministic() throws {
        let sorted = Self.distribution(count: 128)
        let target = try Self.targetMagnitudes(for: sorted, exponent: -1)
        let first = try IAAFTSurrogateGenerator.generate(
            targetFourierMagnitudes: target,
            sortedValues: sorted,
            seed: 42
        )
        let repeated = try IAAFTSurrogateGenerator.generate(
            targetFourierMagnitudes: target,
            sortedValues: sorted,
            seed: 42
        )
        let different = try IAAFTSurrogateGenerator.generate(
            targetFourierMagnitudes: target,
            sortedValues: sorted,
            seed: 43
        )
        #expect(first.values.sorted() == sorted.sorted())
        #expect(first == repeated)
        #expect(first.values != different.values)
        #expect(first.diagnostics.iterations > 0)
    }

    @Test(arguments: [-0.05, -0.5, -1.0])
    func followsWhitePinkAndSteepTargetSpectra(exponent: Double) throws {
        let sorted = Self.distribution(count: 256)
        let target = try Self.targetMagnitudes(for: sorted, exponent: exponent)
        let result = try IAAFTSurrogateGenerator.generate(
            targetFourierMagnitudes: target,
            sortedValues: sorted,
            seed: UInt64(1_000 + Int(abs(exponent) * 100)),
            configuration: IAAFTConfiguration(
                errorThreshold: 2e-4,
                speedThreshold: 1e-7,
                maximumIterations: 1_000
            )
        )
        let actual = try RhythmicityDFTPlan(count: result.values.count).forward(result.values)
        let half = 1..<(result.values.count / 2)
        let targetLog = half.map { log(max(target[$0], 1e-20)) }
        let actualLog = half.map { log(max(hypot(actual.real[$0], actual.imaginary[$0]), 1e-20)) }
        // A perfectly flat spectrum cannot generally coexist with an exactly
        // retained non-Gaussian rank distribution. IAAFT converges on the best
        // alternating projection; this bound still detects loss of the target.
        #expect(Self.correlation(targetLog, actualLog) > 0.93)
        #expect(result.values.sorted() == sorted.sorted())
        // A stable alternating-projection fixed point is a normal IAAFT exit
        // when the two exact constraints are incompatible. It must settle
        // before the hard iteration cap and retain both diagnostics.
        #expect(result.diagnostics.status != .iterationLimit)
    }

    @Test func reportsIterationLimitWithoutDiscardingFinalIterate() throws {
        let sorted = Self.distribution(count: 64)
        let target = try Self.targetMagnitudes(for: sorted, exponent: -1)
        let result = try IAAFTSurrogateGenerator.generate(
            targetFourierMagnitudes: target,
            sortedValues: sorted,
            seed: 9,
            configuration: IAAFTConfiguration(
                errorThreshold: 1e-20,
                speedThreshold: 0,
                maximumIterations: 1
            )
        )
        #expect(result.diagnostics.status == .iterationLimit)
        #expect(result.diagnostics.iterations == 1)
        #expect(result.values.sorted() == sorted.sorted())
    }

    @Test func cancellationDoesNotReturnAPartialSurrogate() throws {
        let cancellation = RhythmicityCancellation()
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try IAAFTSurrogateGenerator.generate(
                targetFourierMagnitudes: [0, 1, 1, 1],
                sortedValues: [-1, -0.5, 0.5, 1],
                seed: 1,
                cancellation: cancellation
            )
        }
    }

    private static func distribution(count: Int) -> [Double] {
        (0..<count).map { index in
            let x = (Double(index) + 0.5) / Double(count)
            return 2 * x - 1 + 0.15 * sin(7 * x)
        }.sorted()
    }

    private static func targetMagnitudes(for values: [Double], exponent: Double) throws -> [Double] {
        let count = values.count
        var weights = [Double](repeating: 0, count: count)
        for bin in 1..<count {
            let frequency = Double(min(bin, count - bin))
            weights[bin] = pow(frequency, exponent / 2)
        }
        let targetEnergy = Double(count) * values.reduce(0) { $0 + $1 * $1 }
        let weightEnergy = weights.reduce(0) { $0 + $1 * $1 }
        let scale = sqrt(targetEnergy / weightEnergy)
        return weights.map { $0 * scale }
    }

    private static func correlation(_ left: [Double], _ right: [Double]) -> Double {
        let meanLeft = left.reduce(0, +) / Double(left.count)
        let meanRight = right.reduce(0, +) / Double(right.count)
        var numerator = 0.0
        var leftEnergy = 0.0
        var rightEnergy = 0.0
        for index in left.indices {
            let x = left[index] - meanLeft
            let y = right[index] - meanRight
            numerator += x * y
            leftEnergy += x * x
            rightEnergy += y * y
        }
        return numerator / sqrt(leftEnergy * rightEnergy)
    }
}
