//
//  ClusterPermutationAnalyzerTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct ClusterPermutationAnalyzerTests {
    @Test func derivesTheCommonStimulusRelativeEpochWindow() throws {
        let segments = [
            EpochSegment(
                startSample: 0,
                endSample: 600,
                stimulusOffsetSamples: 100,
                category: "A",
                sourceCode: "A",
                sourceTimeSeconds: 1,
                colorIndex: 0,
                contributingEpochCount: 1
            ),
            EpochSegment(
                startSample: 601,
                endSample: 1_101,
                stimulusOffsetSamples: 120,
                category: "B",
                sourceCode: "B",
                sourceTimeSeconds: 2,
                colorIndex: 1,
                contributingEpochCount: 1
            )
        ]

        let window = try #require(ClusterStatisticsRunner.commonWindowMilliseconds(
            segments: segments,
            samplingRate: 1_000
        ))
        #expect(window.lowerBound == -100)
        #expect(window.upperBound == 380)
    }

    @Test func summarizesClusterSensorMeansAndStandardErrorsAcrossTrials() {
        let summary = ClusterStatisticsRunner.waveformSummary(
            trials: [
                [1, 2, 3, 4],
                [3, 4, 5, 6]
            ],
            channelIndices: [0, 1],
            sampleCount: 2
        )

        #expect(summary.mean == [3, 4])
        #expect(abs(summary.standardError[0] - 1) < 1e-12)
        #expect(abs(summary.standardError[1] - 1) < 1e-12)
    }

    @Test func findsAPlantedPositiveSpatiotemporalCluster() throws {
        let channelCount = 3
        let sampleCount = 20
        let featureCount = channelCount * sampleCount
        var rng = SeededGenerator(seed: 0xC1A5_7E57)

        func trial(conditionEffect: Double) -> [Double] {
            var values = [Double](repeating: 0, count: featureCount)
            for channel in 0..<channelCount {
                for sample in 0..<sampleCount {
                    let noise = Double.random(in: -0.5...0.5, using: &rng)
                    let planted = (channel <= 1 && (7...12).contains(sample)) ? conditionEffect : 0
                    values[channel * sampleCount + sample] = noise + planted
                }
            }
            return values
        }

        let conditionA = (0..<18).map { _ in trial(conditionEffect: 2.5) }
        let conditionB = (0..<18).map { _ in trial(conditionEffect: 0) }
        let input = ClusterPermutationAnalyzer.Input(
            conditionA: .init(name: "A", trials: conditionA),
            conditionB: .init(name: "B", trials: conditionB),
            channelCount: channelCount,
            sampleCount: sampleCount,
            spatialAdjacency: [[1], [0, 2], [1]]
        )
        let configuration = ClusterPermutationAnalyzer.Configuration(
            permutationCount: 499,
            clusterThreshold: 2,
            seed: 42
        )

        let maybeResult = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
        let result = try #require(maybeResult)
        let cluster = try #require(result.clusters.first)
        #expect(cluster.sign == 1)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 7)
        #expect(cluster.endSample >= 12)
        #expect(Set(cluster.channelIndices).isSuperset(of: [0, 1]))
        #expect(cluster.pointIndices.contains(0 * sampleCount + 9))
        #expect(cluster.pointIndices.contains(1 * sampleCount + 9))
    }

    @Test func isDeterministicForTheSameSeed() throws {
        let a = [
            [3.0, 3.1, 0, 0], [2.8, 3.2, 0.1, -0.1],
            [3.2, 2.9, -0.1, 0.1], [3.1, 3.0, 0.2, -0.2]
        ]
        let b = [
            [0.0, 0.1, 0, 0], [0.2, -0.1, -0.1, 0.1],
            [-0.2, 0.0, 0.1, -0.1], [0.1, -0.2, -0.2, 0.2]
        ]
        let input = ClusterPermutationAnalyzer.Input(
            conditionA: .init(name: "A", trials: a),
            conditionB: .init(name: "B", trials: b),
            channelCount: 2,
            sampleCount: 2,
            spatialAdjacency: [[1], [0]]
        )
        let configuration = ClusterPermutationAnalyzer.Configuration(
            permutationCount: 99,
            clusterThreshold: 1.5,
            seed: 7
        )

        let maybeFirst = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
        let maybeSecond = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
        let first = try #require(maybeFirst)
        let second = try #require(maybeSecond)
        #expect(first == second)
    }

    @Test func keepsOppositeSignsInSeparateClusters() throws {
        let a = [[4.0, -4.0], [5.0, -5.0], [4.5, -4.5], [5.5, -5.5]]
        let b = [[0.0, 0.0], [0.2, -0.2], [-0.2, 0.2], [0.1, -0.1]]
        let input = ClusterPermutationAnalyzer.Input(
            conditionA: .init(name: "A", trials: a),
            conditionB: .init(name: "B", trials: b),
            channelCount: 1,
            sampleCount: 2,
            spatialAdjacency: [[]]
        )
        let maybeResult = try ClusterPermutationAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 49, clusterThreshold: 2, seed: 1)
        )
        let result = try #require(maybeResult)
        #expect(result.clusters.count == 2)
        #expect(Set(result.clusters.map(\.sign)) == [-1, 1])
    }
}
