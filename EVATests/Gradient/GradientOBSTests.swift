//
//  GradientOBSTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Covers the "OBS Residual Removal" section of the FASTR-family functional spec.
//

import Testing
import Foundation
@testable import EVA

struct GradientOBSTests {

    // MARK: - Fixtures

    /// A set of orthonormal shapes over `length` samples, built from distinct
    /// harmonics so they are mutually orthogonal by construction.
    private func orthonormalShapes(count: Int, length: Int) -> [[Float]] {
        (1...count).map { harmonic in
            var shape = (0..<length).map {
                Float(sin(2 * .pi * Double(harmonic) * Double($0) / Double(length)))
            }
            var norm = 0.0
            for value in shape { norm += Double(value) * Double(value) }
            norm = norm.squareRoot()
            for index in shape.indices { shape[index] /= Float(norm) }
            return shape
        }
    }

    /// Deterministic, roughly uncorrelated coefficients.
    private func coefficient(_ epoch: Int, seed: Double) -> Double {
        cos(seed * Double(epoch) + seed)
    }

    private func combine(_ shapes: [[Float]], weights: [Double]) -> [Float] {
        let length = shapes[0].count
        var result = [Float](repeating: 0, count: length)
        for (shape, weight) in zip(shapes, weights) {
            for index in 0..<length { result[index] += Float(weight) * shape[index] }
        }
        return result
    }

    // MARK: - Chunking

    @Test func chunkRangesCoverEveryEpochExactlyOnce() {
        let ranges = GradientOBS.chunkRanges(
            epochCount: 250, epochPeriodSamples: 100, samplingRate: 1000, chunkSeconds: 6
        )
        #expect(!ranges.isEmpty)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == 250)
        for index in 1..<ranges.count {
            #expect(ranges[index].lowerBound == ranges[index - 1].upperBound)
        }
    }

    @Test func chunkSizeFollowsTheRequestedDuration() {
        // 100-sample epochs at 1000 Hz arrive 10 per second, so 6 seconds is 60.
        let ranges = GradientOBS.chunkRanges(
            epochCount: 240, epochPeriodSamples: 100, samplingRate: 1000, chunkSeconds: 6
        )
        #expect(ranges.count == 4)
        #expect(ranges.allSatisfy { $0.count == 60 })
    }

    @Test func anUndersizedTailIsMergedIntoThePreviousChunk() {
        // 125 epochs at 60 per chunk would leave a tail of 5, below the minimum.
        let ranges = GradientOBS.chunkRanges(
            epochCount: 125, epochPeriodSamples: 100, samplingRate: 1000, chunkSeconds: 6
        )
        #expect(ranges.count == 2)
        #expect(ranges.last?.count == 65)
        #expect(ranges.allSatisfy { $0.count >= GradientOBS.minimumEpochsForBasis })
    }

    @Test func aShortRecordingIsASingleChunk() {
        let ranges = GradientOBS.chunkRanges(
            epochCount: 20, epochPeriodSamples: 100, samplingRate: 1000, chunkSeconds: 60
        )
        #expect(ranges == [0..<20])
    }

    // MARK: - Subsampling

    @Test func subsamplingIsEvenlySpacedDeterministicAndCapped() {
        let candidates = Array(0..<100)
        let picked = GradientOBS.subsample(candidates, limit: 10)
        #expect(picked.count <= 10)
        #expect(picked.first == 0)
        #expect(picked.last == 99)
        #expect(picked == picked.sorted())
        #expect(GradientOBS.subsample(candidates, limit: 10) == picked)
    }

    @Test func subsamplingLeavesSmallSetsIntact() {
        let candidates = [3, 7, 11]
        #expect(GradientOBS.subsample(candidates, limit: 10) == candidates)
        #expect(GradientOBS.subsample(candidates, limit: 0).isEmpty)
    }

    // MARK: - Basis estimation

    @Test func noBasisIsBuiltWhenOBSIsOff() {
        let shapes = orthonormalShapes(count: 2, length: 64)
        let residuals = (0..<20).map { epoch in
            combine(shapes, weights: [coefficient(epoch, seed: 0.7), coefficient(epoch, seed: 1.3)])
        }
        let basis = GradientOBS.basis(
            residuals: residuals, mode: .off, varianceThreshold: 0.9, maximumComponents: 5
        )
        #expect(basis.isEmpty)
    }

    @Test func fixedModeReturnsTheRequestedNumberOfComponents() {
        let shapes = orthonormalShapes(count: 3, length: 64)
        let residuals = (0..<30).map { epoch in
            combine(shapes, weights: [
                coefficient(epoch, seed: 0.7),
                coefficient(epoch, seed: 1.3),
                coefficient(epoch, seed: 2.1)
            ])
        }
        let basis = GradientOBS.basis(
            residuals: residuals, mode: .fixed(componentCount: 2),
            varianceThreshold: 0.9, maximumComponents: 5
        )
        #expect(basis.count == 2)
    }

    @Test func automaticModeStopsOnceTheVarianceThresholdIsMet() {
        // Three shapes with amplitudes 10, 1, and 0.1 — variance shares of
        // roughly 0.99, 0.0099, and 0.0001.
        let shapes = orthonormalShapes(count: 3, length: 64)
        let residuals = (0..<40).map { epoch in
            combine(shapes, weights: [
                10 * coefficient(epoch, seed: 0.7),
                1 * coefficient(epoch, seed: 1.3),
                0.1 * coefficient(epoch, seed: 2.1)
            ])
        }

        let lenient = GradientOBS.basis(
            residuals: residuals, mode: .automatic,
            varianceThreshold: 0.9, maximumComponents: 5
        )
        #expect(lenient.count == 1)

        let strict = GradientOBS.basis(
            residuals: residuals, mode: .automatic,
            varianceThreshold: 0.999, maximumComponents: 5
        )
        #expect(strict.count == 2)
    }

    @Test func automaticModeRespectsTheComponentCeiling() {
        let shapes = orthonormalShapes(count: 6, length: 64)
        let residuals = (0..<40).map { epoch in
            combine(shapes, weights: (0..<6).map { coefficient(epoch, seed: 0.6 + Double($0) * 0.4) })
        }
        let basis = GradientOBS.basis(
            residuals: residuals, mode: .automatic,
            varianceThreshold: 0.99999, maximumComponents: 3
        )
        #expect(basis.count <= 3)
    }

    @Test func theBasisRecoversAKnownLowRankSubspace() {
        let shapes = orthonormalShapes(count: 2, length: 64)
        let residuals = (0..<30).map { epoch in
            combine(shapes, weights: [coefficient(epoch, seed: 0.7), coefficient(epoch, seed: 1.3)])
        }
        let basis = GradientOBS.basis(
            residuals: residuals, mode: .fixed(componentCount: 2),
            varianceThreshold: 0.9, maximumComponents: 5
        )
        #expect(basis.count == 2)

        // Anything inside the span should be reproduced almost exactly.
        let inside = combine(shapes, weights: [0.4, -0.9])
        let recovered = GradientOBS.projection(of: inside, onto: basis)
        var worst = 0.0
        for index in inside.indices {
            worst = max(worst, abs(Double(recovered[index] - inside[index])))
        }
        #expect(worst < 1e-4, "worst reconstruction error \(worst)")
    }

    @Test func somethingOrthogonalToTheSpanIsLeftAlone() {
        let shapes = orthonormalShapes(count: 3, length: 64)
        let residuals = (0..<30).map { epoch in
            combine(Array(shapes.prefix(2)), weights: [
                coefficient(epoch, seed: 0.7),
                coefficient(epoch, seed: 1.3)
            ])
        }
        let basis = GradientOBS.basis(
            residuals: residuals, mode: .fixed(componentCount: 2),
            varianceThreshold: 0.9, maximumComponents: 5
        )
        // The third harmonic never appears in the residuals, so OBS must not
        // touch it — this is what keeps the stage from eating real signal.
        let outside = shapes[2]
        let removed = GradientOBS.projection(of: outside, onto: basis)
        for value in removed { #expect(abs(value) < 1e-4) }
    }

    @Test func basisEstimationHandlesDegenerateInput() {
        let empty = GradientOBS.basis(
            residuals: [], mode: .automatic, varianceThreshold: 0.9, maximumComponents: 5
        )
        #expect(empty.isEmpty)

        let single = GradientOBS.basis(
            residuals: [[1, 2, 3, 4]], mode: .automatic,
            varianceThreshold: 0.9, maximumComponents: 5
        )
        #expect(single.isEmpty)

        let flat = GradientOBS.basis(
            residuals: Array(repeating: [Float](repeating: 0, count: 32), count: 12),
            mode: .automatic, varianceThreshold: 0.9, maximumComponents: 5
        )
        #expect(flat.isEmpty)
    }

    @Test func projectionOntoAnEmptyBasisRemovesNothing() {
        let epoch: [Float] = [3, -1, 4, 1, 5]
        let removed = GradientOBS.projection(of: epoch, onto: [])
        #expect(removed == [0, 0, 0, 0, 0])
    }

    @Test func basisEstimationIsDeterministic() {
        let shapes = orthonormalShapes(count: 3, length: 48)
        let residuals = (0..<25).map { epoch in
            combine(shapes, weights: [
                coefficient(epoch, seed: 0.7),
                coefficient(epoch, seed: 1.3),
                coefficient(epoch, seed: 2.1)
            ])
        }
        let sample: [Float] = combine(shapes, weights: [1, -0.5, 0.25])
        let first = GradientOBS.basis(
            residuals: residuals, mode: .automatic, varianceThreshold: 0.95, maximumComponents: 4
        )
        let second = GradientOBS.basis(
            residuals: residuals, mode: .automatic, varianceThreshold: 0.95, maximumComponents: 4
        )
        #expect(first.count == second.count)
        // Eigenvector signs are arbitrary, but the projection they define is not.
        #expect(GradientOBS.projection(of: sample, onto: first)
                == GradientOBS.projection(of: sample, onto: second))
    }
}
