//
//  ClusterPermutationFAnalyzerTests.swift
//  EVATests
//


import Testing
@testable import EVA

struct ClusterPermutationFAnalyzerTests {
    @Test func matchesAHandCalculatedOneWayANOVA() throws {
        let input = ClusterPermutationFAnalyzer.Input(
            conditions: [
                .init(name: "A", trials: [[1], [2]]),
                .init(name: "B", trials: [[3], [4]]),
                .init(name: "C", trials: [[5], [6]])
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]]
        )
        let maybeResult = try ClusterPermutationFAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 9, clusterThreshold: 1, seed: 1)
        )
        let result = try #require(maybeResult)
        #expect(abs(result.observedStatistics[0] - 16) < 1e-12)
    }

    @Test func findsAPlantedOmnibusSpatiotemporalEffect() throws {
        let channelCount = 3
        let sampleCount = 20
        let featureCount = channelCount * sampleCount
        var rng = SeededGenerator(seed: 0xF7E5_7001)

        func trials(effect: Double) -> [[Double]] {
            (0..<16).map { _ in
                var values = [Double](repeating: 0, count: featureCount)
                for channel in 0..<channelCount {
                    for sample in 0..<sampleCount {
                        let noise = Double.random(in: -0.6...0.6, using: &rng)
                        let planted = channel <= 1 && (7...12).contains(sample) ? effect : 0
                        values[channel * sampleCount + sample] = noise + planted
                    }
                }
                return values
            }
        }

        let input = ClusterPermutationFAnalyzer.Input(
            conditions: [
                .init(name: "A", trials: trials(effect: 0)),
                .init(name: "B", trials: trials(effect: 2.5)),
                .init(name: "C", trials: trials(effect: -2.5))
            ],
            channelCount: channelCount,
            sampleCount: sampleCount,
            spatialAdjacency: [[1], [0, 2], [1]]
        )
        let configuration = ClusterPermutationFAnalyzer.Configuration(
            permutationCount: 499,
            clusterThreshold: 5,
            seed: 42
        )

        let maybeResult = try ClusterPermutationFAnalyzer.analyze(
            input: input,
            configuration: configuration
        )
        let result = try #require(maybeResult)
        let cluster = try #require(result.clusters.first)
        #expect(result.conditionCounts == [16, 16, 16])
        #expect(result.numeratorDegreesOfFreedom == 2)
        #expect(result.denominatorDegreesOfFreedom == 45)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 7)
        #expect(cluster.endSample >= 12)
        #expect(Set(cluster.channelIndices).isSuperset(of: [0, 1]))
    }

    @Test func isDeterministicForTheSameSeed() throws {
        let input = ClusterPermutationFAnalyzer.Input(
            conditions: [
                .init(name: "A", trials: [[0, 0], [0.1, -0.1], [-0.1, 0.1]]),
                .init(name: "B", trials: [[2, 2], [2.1, 1.9], [1.9, 2.1]]),
                .init(name: "C", trials: [[-2, -2], [-1.9, -2.1], [-2.1, -1.9]])
            ],
            channelCount: 1,
            sampleCount: 2,
            spatialAdjacency: [[]]
        )
        let configuration = ClusterPermutationFAnalyzer.Configuration(
            permutationCount: 99,
            clusterThreshold: 3,
            seed: 7
        )

        let first = try ClusterPermutationFAnalyzer.analyze(input: input, configuration: configuration)
        let second = try ClusterPermutationFAnalyzer.analyze(input: input, configuration: configuration)
        #expect(first == second)
    }

    @Test func requiresAtLeastThreeConditions() {
        let input = ClusterPermutationFAnalyzer.Input(
            conditions: [
                .init(name: "A", trials: [[0], [1]]),
                .init(name: "B", trials: [[2], [3]])
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]]
        )

        #expect(throws: ClusterPermutationFAnalyzer.AnalysisError.insufficientConditions) {
            try ClusterPermutationFAnalyzer.analyze(input: input, configuration: .init())
        }
    }
}
