//
//  ClusterFormationTests.swift
//  EVATests
//
//  Covers the shared lattice: connected-component growth, and the union-find
//  TFCE integration against a deliberately naive reference implementation of
//  the same integral.
//

import Foundation
import Testing
@testable import EVA

struct ClusterFormationTests {
    // MARK: - Connected components

    @Test func growsTemporalClustersWithinAChannel() {
        let grid = ClusterGrid(channelCount: 2, sampleCount: 5, spatialAdjacency: [[], []])
        // Channel 0 samples 1-3 are supra-threshold; channel 1 is flat.
        let statistics: [Double] = [0, 3, 4, 3, 0, 0, 0, 0, 0, 0]
        let clusters = grid.formClusters(
            statistics: statistics,
            threshold: 2,
            signed: true,
            workspace: grid.makeWorkspace()
        )
        #expect(clusters.count == 1)
        #expect(clusters[0].points == [1, 2, 3])
        #expect(clusters[0].mass == 10)
        #expect(clusters[0].startSample == 1)
        #expect(clusters[0].endSample == 3)
        #expect(clusters[0].channels == [0])
    }

    @Test func doesNotBridgeChannelsWithoutSpatialAdjacency() {
        let statistics: [Double] = [0, 3, 0, 0, 3, 0]
        let disconnected = ClusterGrid(channelCount: 2, sampleCount: 3, spatialAdjacency: [[], []])
        #expect(disconnected.formClusters(
            statistics: statistics,
            threshold: 2,
            signed: true,
            workspace: disconnected.makeWorkspace()
        ).count == 2)

        let connected = ClusterGrid(channelCount: 2, sampleCount: 3, spatialAdjacency: [[1], [0]])
        let merged = connected.formClusters(
            statistics: statistics,
            threshold: 2,
            signed: true,
            workspace: connected.makeWorkspace()
        )
        #expect(merged.count == 1)
        #expect(merged[0].channels == [0, 1])
    }

    @Test func keepsOppositeSignedRegionsApart() {
        let grid = ClusterGrid(channelCount: 1, sampleCount: 4, spatialAdjacency: [[]])
        let statistics: [Double] = [3, 4, -4, -3]
        let signed = grid.formClusters(
            statistics: statistics,
            threshold: 2,
            signed: true,
            workspace: grid.makeWorkspace()
        )
        #expect(signed.count == 2)
        #expect(signed.map(\.sign).sorted() == [-1, 1])
        // Mass is the absolute sum, so both clusters weigh 7.
        #expect(signed.allSatisfy { $0.mass == 7 })

        // Unsigned (F-like) growth has no sign to respect.
        let unsigned = grid.formClusters(
            statistics: [3, 4, 4, 3],
            threshold: 2,
            signed: false,
            workspace: grid.makeWorkspace()
        )
        #expect(unsigned.count == 1)
        #expect(unsigned[0].mass == 14)
    }

    @Test func maximumClusterMassAgreesWithFullFormation() {
        var rng = SeededGenerator(seed: 0xC0FF_EE01)
        let grid = ClusterGrid(channelCount: 4, sampleCount: 25, spatialAdjacency: [[1], [0, 2], [1, 3], [2]])
        for _ in 0..<25 {
            let statistics = (0..<100).map { _ in Double.random(in: -4...4, using: &rng) }
            let expected = grid.formClusters(
                statistics: statistics,
                threshold: 1.5,
                signed: true,
                workspace: grid.makeWorkspace()
            ).map(\.mass).max() ?? 0
            let actual = grid.maximumClusterMass(
                statistics: statistics,
                threshold: 1.5,
                signed: true,
                workspace: grid.makeWorkspace()
            )
            #expect(abs(actual - expected) < 1e-12)
        }
    }

    @Test func workspaceReuseDoesNotLeakStateBetweenPasses() {
        let grid = ClusterGrid(channelCount: 2, sampleCount: 4, spatialAdjacency: [[1], [0]])
        let workspace = grid.makeWorkspace()
        let statistics: [Double] = [3, 3, 0, 0, 3, 3, 0, 0]
        let first = grid.formClusters(statistics: statistics, threshold: 2, signed: true, workspace: workspace)
        let second = grid.formClusters(statistics: statistics, threshold: 2, signed: true, workspace: workspace)
        #expect(first.count == second.count)
        #expect(first.map(\.mass) == second.map(\.mass))
    }

    // MARK: - TFCE

    /// The textbook TFCE integral, written the slow obvious way: re-run
    /// connected components at every threshold and add each point's share.
    /// The shipped implementation must agree with this to floating-point noise.
    private func referenceTFCE(
        grid: ClusterGrid,
        statistics: [Double],
        signed: Bool,
        parameters: TFCEParameters
    ) -> [Double] {
        var scores = [Double](repeating: 0, count: statistics.count)
        let magnitudes = statistics.map { signed ? abs($0) : max($0, 0) }
        guard let peak = magnitudes.max(), peak > 0 else { return scores }
        let stepHeight = peak / Double(parameters.stepCount)

        for step in 1...parameters.stepCount {
            let height = stepHeight * Double(step)
            let clusters = grid.formClusters(
                statistics: statistics,
                threshold: height,
                signed: signed,
                workspace: grid.makeWorkspace()
            )
            for cluster in clusters {
                let increment = pow(Double(cluster.points.count), parameters.extentExponent)
                    * pow(height, parameters.heightExponent)
                    * stepHeight
                for point in cluster.points { scores[point] += increment }
            }
        }
        if signed {
            for index in scores.indices where statistics[index] < 0 {
                scores[index] = -scores[index]
            }
        }
        return scores
    }

    @Test func tfceMatchesTheNaiveIntegralOnSignedData() {
        var rng = SeededGenerator(seed: 0x7FCE_0001)
        let grid = ClusterGrid(
            channelCount: 5,
            sampleCount: 20,
            spatialAdjacency: [[1], [0, 2], [1, 3], [2, 4], [3]]
        )
        let parameters = TFCEParameters(extentExponent: 0.5, heightExponent: 2.0, stepCount: 40)

        for _ in 0..<10 {
            let statistics = (0..<100).map { _ in Double.random(in: -5...5, using: &rng) }
            let expected = referenceTFCE(
                grid: grid,
                statistics: statistics,
                signed: true,
                parameters: parameters
            )
            let actual = grid.tfceScores(statistics: statistics, signed: true, parameters: parameters)
            for index in expected.indices {
                #expect(abs(actual[index] - expected[index]) < 1e-9)
            }
        }
    }

    @Test func tfceMatchesTheNaiveIntegralOnNonNegativeData() {
        var rng = SeededGenerator(seed: 0x7FCE_0002)
        let grid = ClusterGrid(channelCount: 4, sampleCount: 15, spatialAdjacency: [[1], [0, 2], [1, 3], [2]])
        let parameters = TFCEParameters(extentExponent: 0.6, heightExponent: 1.5, stepCount: 30)

        for _ in 0..<10 {
            let statistics = (0..<60).map { _ in Double.random(in: 0...9, using: &rng) }
            let expected = referenceTFCE(
                grid: grid,
                statistics: statistics,
                signed: false,
                parameters: parameters
            )
            let actual = grid.tfceScores(statistics: statistics, signed: false, parameters: parameters)
            for index in expected.indices {
                #expect(abs(actual[index] - expected[index]) < 1e-9)
            }
        }
    }

    @Test func tfceRewardsBroadEffectsOverIsolatedSpikes() {
        let grid = ClusterGrid(channelCount: 1, sampleCount: 20, spatialAdjacency: [[]])
        var statistics = [Double](repeating: 0, count: 20)
        // One tall isolated point against a broad plateau of the same height.
        statistics[2] = 4
        for sample in 8...16 { statistics[sample] = 4 }

        let scores = grid.tfceScores(statistics: statistics, signed: true, parameters: .default)
        #expect(scores[12] > scores[2])
    }

    @Test func tfceIsZeroForAFlatField() {
        let grid = ClusterGrid(channelCount: 2, sampleCount: 6, spatialAdjacency: [[1], [0]])
        let scores = grid.tfceScores(
            statistics: [Double](repeating: 0, count: 12),
            signed: true,
            parameters: .default
        )
        #expect(scores.allSatisfy { $0 == 0 })
    }

    @Test func tfcePreservesEffectDirection() {
        let grid = ClusterGrid(channelCount: 1, sampleCount: 10, spatialAdjacency: [[]])
        var statistics = [Double](repeating: 0, count: 10)
        for sample in 1...3 { statistics[sample] = 3 }
        for sample in 6...8 { statistics[sample] = -3 }

        let scores = grid.tfceScores(statistics: statistics, signed: true, parameters: .default)
        #expect(scores[2] > 0)
        #expect(scores[7] < 0)
        #expect(abs(scores[2] + scores[7]) < 1e-9)
    }

    // MARK: - Correction

    @Test func pValueIncludesTheObservedStatisticInItsOwnNull() {
        // With 99 permutations the floor is 1/100, never zero.
        let null = [Double](repeating: 0, count: 99)
        #expect(abs(ClusterCorrection.pValue(observed: 100, nullMaxima: null) - 0.01) < 1e-12)
        // An observed value beaten by every permutation cannot reach p = 1
        // by more than the same single count.
        let dominating = [Double](repeating: 500, count: 99)
        #expect(abs(ClusterCorrection.pValue(observed: 1, nullMaxima: dominating) - 1.0) < 1e-12)
    }

    @Test func pointPValuesMatchADirectCount() {
        var rng = SeededGenerator(seed: 0x9911)
        let null = (0..<200).map { _ in Double.random(in: 0...10, using: &rng) }
        let scores = (0..<50).map { _ in Double.random(in: -10...10, using: &rng) }
        let computed = ClusterCorrection.pointPValues(scores: scores, nullMaxima: null)
        for (index, score) in scores.enumerated() {
            let exceedances = null.filter { $0 >= abs(score) }.count
            let expected = Double(exceedances + 1) / Double(null.count + 1)
            #expect(abs(computed[index] - expected) < 1e-12)
        }
    }

    @Test func displaySortPutsTheMostSignificantClusterFirstAndRenumbers() {
        let clusters = [
            SpatiotemporalCluster(id: 7, sign: 1, pointIndices: [0], mass: 5, pValue: 0.4, startSample: 0, endSample: 0, channelIndices: [0]),
            SpatiotemporalCluster(id: 3, sign: -1, pointIndices: [1], mass: 9, pValue: 0.01, startSample: 1, endSample: 1, channelIndices: [0]),
            SpatiotemporalCluster(id: 5, sign: 1, pointIndices: [2], mass: 20, pValue: 0.4, startSample: 2, endSample: 2, channelIndices: [0]),
        ]
        let sorted = ClusterCorrection.sortedForDisplay(clusters)
        #expect(sorted.map(\.id) == [0, 1, 2])
        #expect(sorted.map(\.pValue) == [0.01, 0.4, 0.4])
        // Ties on p break by mass, largest first.
        #expect(sorted[1].mass == 20)
    }
}
