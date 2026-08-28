//
//  ClusterRepeatedMeasuresTests.swift
//  EVATests
//
//  Within-subject designs, p-value cluster-forming thresholds, and TFCE end to
//  end through both analyzers.
//

import Foundation
import Testing
@testable import EVA

struct ClusterRepeatedMeasuresTests {
    // MARK: - Paired t

    @Test func pairedTMatchesAHandCalculatedOneSampleT() throws {
        // Differences 1, 2, 3, 4: mean 2.5, sd 1.290994449, se 0.6454972244,
        // t = 3.872983346.
        let input = ClusterPermutationAnalyzer.Input(
            conditionA: .init(name: "A", trials: [[2], [4], [6], [8]]),
            conditionB: .init(name: "B", trials: [[1], [2], [3], [4]]),
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 15, threshold: .statistic(1), seed: 3)
        ))
        #expect(abs(result.observedStatistics[0] - 3.872_983_346) < 1e-9)
        #expect(result.degreesOfFreedom == 3)
        #expect(result.pairCount == 4)
    }

    @Test func pairedDesignRecoversAnEffectTheIndependentDesignMisses() throws {
        // Every unit has a large idiosyncratic offset and a small consistent
        // condition effect. Pairing removes the offset; the independent test
        // drowns in it.
        let channelCount = 2
        let sampleCount = 20
        let featureCount = channelCount * sampleCount
        var rng = SeededGenerator(seed: 0x9A1_7ED)
        let unitCount = 20

        var conditionA: [[Double]] = []
        var conditionB: [[Double]] = []
        for _ in 0..<unitCount {
            let offset = Double.random(in: -20...20, using: &rng)
            var a = [Double](repeating: 0, count: featureCount)
            var b = [Double](repeating: 0, count: featureCount)
            for channel in 0..<channelCount {
                for sample in 0..<sampleCount {
                    let index = channel * sampleCount + sample
                    let effect = (6...13).contains(sample) ? 1.2 : 0
                    a[index] = offset + effect + Double.random(in: -0.4...0.4, using: &rng)
                    b[index] = offset + Double.random(in: -0.4...0.4, using: &rng)
                }
            }
            conditionA.append(a)
            conditionB.append(b)
        }

        func run(_ design: ClusterPermutationAnalyzer.Design) throws -> ClusterPermutationAnalyzer.Result {
            try #require(try ClusterPermutationAnalyzer.analyze(
                input: .init(
                    conditionA: .init(name: "A", trials: conditionA),
                    conditionB: .init(name: "B", trials: conditionB),
                    channelCount: channelCount,
                    sampleCount: sampleCount,
                    spatialAdjacency: [[1], [0]],
                    design: design
                ),
                configuration: .init(permutationCount: 499, threshold: .probability(0.05), seed: 11)
            ))
        }

        let paired = try run(.repeatedMeasures)
        let independent = try run(.independent)

        let pairedCluster = try #require(paired.clusters.first)
        #expect(pairedCluster.pValue < 0.05)
        #expect(pairedCluster.startSample <= 6)
        #expect(pairedCluster.endSample >= 13)
        // The between-unit offset swamps the independent test.
        #expect(independent.clusters.allSatisfy { $0.pValue > 0.05 })
    }

    @Test func pairedDesignRejectsUnequalConditionSizes() {
        let input = ClusterPermutationAnalyzer.Input(
            conditionA: .init(name: "A", trials: [[1], [2], [3]]),
            conditionB: .init(name: "B", trials: [[1], [2]]),
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        #expect(throws: ClusterPermutationAnalyzer.AnalysisError.unbalancedPairs) {
            try ClusterPermutationAnalyzer.analyze(input: input, configuration: .init())
        }
    }

    @Test func pairedDesignIsDeterministicForTheSameSeed() throws {
        let input = ClusterPermutationAnalyzer.Input(
            conditionA: .init(name: "A", trials: [[1, 2], [2, 3], [3, 4], [4, 5]]),
            conditionB: .init(name: "B", trials: [[0, 1], [1, 1], [2, 2], [3, 3]]),
            channelCount: 1,
            sampleCount: 2,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        let configuration = ClusterPermutationAnalyzer.Configuration(
            permutationCount: 99,
            threshold: .statistic(1.5),
            seed: 21
        )
        let first = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
        let second = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
        #expect(first == second)
    }

    // MARK: - Repeated-measures F

    @Test func repeatedMeasuresFMatchesAHandCalculatedANOVA() throws {
        // 3 units x 3 conditions:
        //   unit 1: 1, 2, 3   unit 2: 2, 4, 6   unit 3: 3, 5, 7
        // Correction 33^2/9 = 121. Condition sums 6, 11, 16 give SS_cond =
        // 413/3 - 121 = 50/3. Unit sums 6, 12, 15 give SS_unit = 135 - 121 = 14.
        // SS_total = 153 - 121 = 32, so SS_error = 32 - 50/3 - 14 = 4/3.
        // F = (50/3 / 2) / (4/3 / 4) = 25.
        let input = ClusterPermutationFAnalyzer.Input(
            conditions: [
                .init(name: "A", trials: [[1], [2], [3]]),
                .init(name: "B", trials: [[2], [4], [5]]),
                .init(name: "C", trials: [[3], [6], [7]]),
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 25, threshold: .statistic(1), seed: 5)
        ))
        #expect(result.numeratorDegreesOfFreedom == 2)
        #expect(result.denominatorDegreesOfFreedom == 4)
        #expect(result.unitCount == 3)
        #expect(abs(result.observedStatistics[0] - 25) < 1e-10)
    }

    @Test func repeatedMeasuresFRemovesTheUnitMainEffect() throws {
        // Identical condition means, wildly different unit means: the between-
        // unit variance must land in the unit term, not the error term, so F
        // stays at zero rather than being deflated by it.
        let input = ClusterPermutationFAnalyzer.Input(
            conditions: [
                .init(name: "A", trials: [[1], [101], [1_001]]),
                .init(name: "B", trials: [[1], [101], [1_001]]),
                .init(name: "C", trials: [[1], [101], [1_001]]),
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: input,
            configuration: .init(permutationCount: 9, threshold: .statistic(1), seed: 2)
        ))
        #expect(result.observedStatistics[0] == 0)
    }

    @Test func repeatedMeasuresFRejectsUnbalancedConditions() {
        let input = ClusterPermutationFAnalyzer.Input(
            conditions: [
                .init(name: "A", trials: [[1], [2], [3]]),
                .init(name: "B", trials: [[1], [2]]),
                .init(name: "C", trials: [[1], [2], [3]]),
            ],
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]],
            design: .repeatedMeasures
        )
        #expect(throws: ClusterPermutationFAnalyzer.AnalysisError.unbalancedUnits) {
            try ClusterPermutationFAnalyzer.analyze(input: input, configuration: .init())
        }
    }

    @Test func repeatedMeasuresFFindsAPlantedWithinUnitEffect() throws {
        let channelCount = 3
        let sampleCount = 18
        let featureCount = channelCount * sampleCount
        var rng = SeededGenerator(seed: 0x5EED_F00D)
        let unitCount = 14

        var conditions = [[[Double]]](repeating: [], count: 3)
        for _ in 0..<unitCount {
            let offset = Double.random(in: -15...15, using: &rng)
            for condition in 0..<3 {
                var values = [Double](repeating: 0, count: featureCount)
                for channel in 0..<channelCount {
                    for sample in 0..<sampleCount {
                        let planted = channel <= 1 && (5...11).contains(sample)
                            ? Double(condition) * 1.5
                            : 0
                        values[channel * sampleCount + sample] =
                            offset + planted + Double.random(in: -0.5...0.5, using: &rng)
                    }
                }
                conditions[condition].append(values)
            }
        }

        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: .init(
                conditions: [
                    .init(name: "A", trials: conditions[0]),
                    .init(name: "B", trials: conditions[1]),
                    .init(name: "C", trials: conditions[2]),
                ],
                channelCount: channelCount,
                sampleCount: sampleCount,
                spatialAdjacency: [[1], [0, 2], [1]],
                design: .repeatedMeasures
            ),
            configuration: .init(permutationCount: 499, threshold: .probability(0.05), seed: 77)
        ))
        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 5)
        #expect(cluster.endSample >= 11)
        #expect(Set(cluster.channelIndices).isSuperset(of: [0, 1]))
    }

    // MARK: - Probability thresholds

    @Test func probabilityThresholdResolvesToTheCriticalStatistic() throws {
        var rng = SeededGenerator(seed: 0x4B1D)
        let trials = { (count: Int) in
            (0..<count).map { _ in (0..<10).map { _ in Double.random(in: -1...1, using: &rng) } }
        }
        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: .init(
                conditionA: .init(name: "A", trials: trials(16)),
                conditionB: .init(name: "B", trials: trials(16)),
                channelCount: 1,
                sampleCount: 10,
                spatialAdjacency: [[]]
            ),
            configuration: .init(permutationCount: 49, threshold: .probability(0.05), seed: 9)
        ))
        // df = 30, so qt(.975, 30) = 2.042272.
        #expect(result.degreesOfFreedom == 30)
        let resolved = try #require(result.resolvedThreshold)
        #expect(abs(resolved - 2.042_272_456) < 1e-6)
    }

    @Test func theSameProbabilityGivesDifferentThresholdsAtDifferentDegreesOfFreedom() throws {
        func resolvedThreshold(trialsPerCondition: Int) throws -> Double {
            var rng = SeededGenerator(seed: 0x1234)
            let trials = (0..<trialsPerCondition).map { _ in
                (0..<4).map { _ in Double.random(in: -1...1, using: &rng) }
            }
            let result = try #require(try ClusterPermutationAnalyzer.analyze(
                input: .init(
                    conditionA: .init(name: "A", trials: trials),
                    conditionB: .init(name: "B", trials: trials),
                    channelCount: 1,
                    sampleCount: 4,
                    spatialAdjacency: [[]]
                ),
                configuration: .init(permutationCount: 9, threshold: .probability(0.05), seed: 1)
            ))
            return try #require(result.resolvedThreshold)
        }
        let few = try resolvedThreshold(trialsPerCondition: 3)
        let many = try resolvedThreshold(trialsPerCondition: 100)
        #expect(few > many)
        #expect(many < 2.0)
        #expect(few > 2.5)
    }

    @Test func fProbabilityThresholdResolvesAgainstBothDegreesOfFreedom() throws {
        var rng = SeededGenerator(seed: 0xABCD)
        let trials = { (0..<16).map { _ in (0..<5).map { _ in Double.random(in: -1...1, using: &rng) } } }
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: .init(
                conditions: [
                    .init(name: "A", trials: trials()),
                    .init(name: "B", trials: trials()),
                    .init(name: "C", trials: trials()),
                ],
                channelCount: 1,
                sampleCount: 5,
                spatialAdjacency: [[]]
            ),
            configuration: .init(permutationCount: 19, threshold: .probability(0.05), seed: 4)
        ))
        // df = (2, 45), so qf(.95, 2, 45) = 3.2043175.
        #expect(result.numeratorDegreesOfFreedom == 2)
        #expect(result.denominatorDegreesOfFreedom == 45)
        let resolved = try #require(result.resolvedThreshold)
        #expect(abs(resolved - 3.204_317_5) < 1e-5)
    }

    // MARK: - TFCE end to end

    @Test func tfceFindsAPlantedEffectAndReportsPointPValues() throws {
        let channelCount = 3
        let sampleCount = 16
        let featureCount = channelCount * sampleCount
        var rng = SeededGenerator(seed: 0x7C3E_0001)

        func trials(effect: Double) -> [[Double]] {
            (0..<20).map { _ in
                var values = [Double](repeating: 0, count: featureCount)
                for channel in 0..<channelCount {
                    for sample in 0..<sampleCount {
                        let planted = channel <= 1 && (5...10).contains(sample) ? effect : 0
                        values[channel * sampleCount + sample] =
                            planted + Double.random(in: -0.8...0.8, using: &rng)
                    }
                }
                return values
            }
        }

        let result = try #require(try ClusterPermutationAnalyzer.analyze(
            input: .init(
                conditionA: .init(name: "A", trials: trials(effect: 1.5)),
                conditionB: .init(name: "B", trials: trials(effect: 0)),
                channelCount: channelCount,
                sampleCount: sampleCount,
                spatialAdjacency: [[1], [0, 2], [1]]
            ),
            configuration: .init(
                permutationCount: 299,
                inference: .tfce,
                tfce: .init(extentExponent: 0.5, heightExponent: 2, stepCount: 30),
                seed: 31
            )
        ))

        // TFCE ignores the cluster-forming threshold entirely.
        #expect(result.resolvedThreshold == nil)
        let scores = try #require(result.observedTFCEScores)
        let pointPValues = try #require(result.pointPValues)
        #expect(scores.count == featureCount)
        #expect(pointPValues.count == featureCount)

        // The planted region is significant; the untouched third channel is not.
        #expect(pointPValues[0 * sampleCount + 8] < 0.05)
        #expect(pointPValues[2 * sampleCount + 8] > 0.05)

        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 6)
        #expect(cluster.endSample >= 9)
    }

    @Test func tfceIsDeterministicForTheSameSeed() throws {
        var rng = SeededGenerator(seed: 0x2222)
        let trials = { (0..<8).map { _ in (0..<12).map { _ in Double.random(in: -1...1, using: &rng) } } }
        let input = ClusterPermutationAnalyzer.Input(
            conditionA: .init(name: "A", trials: trials()),
            conditionB: .init(name: "B", trials: trials()),
            channelCount: 2,
            sampleCount: 6,
            spatialAdjacency: [[1], [0]]
        )
        let configuration = ClusterPermutationAnalyzer.Configuration(
            permutationCount: 99,
            inference: .tfce,
            seed: 8
        )
        let first = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
        let second = try ClusterPermutationAnalyzer.analyze(input: input, configuration: configuration)
        #expect(first == second)
    }

    @Test func tfceRejectsDegenerateParameters() {
        let input = ClusterPermutationAnalyzer.Input(
            conditionA: .init(name: "A", trials: [[1], [2]]),
            conditionB: .init(name: "B", trials: [[3], [4]]),
            channelCount: 1,
            sampleCount: 1,
            spatialAdjacency: [[]]
        )
        #expect(throws: ClusterPermutationAnalyzer.AnalysisError.invalidConfiguration) {
            try ClusterPermutationAnalyzer.analyze(
                input: input,
                configuration: .init(inference: .tfce, tfce: .init(stepCount: 1))
            )
        }
    }

    @Test func tfceWorksForTheOmnibusF() throws {
        var rng = SeededGenerator(seed: 0x7C3E_0002)
        let sampleCount = 12
        func trials(effect: Double) -> [[Double]] {
            (0..<12).map { _ in
                (0..<sampleCount).map { sample in
                    ((4...8).contains(sample) ? effect : 0) + Double.random(in: -0.6...0.6, using: &rng)
                }
            }
        }
        let result = try #require(try ClusterPermutationFAnalyzer.analyze(
            input: .init(
                conditions: [
                    .init(name: "A", trials: trials(effect: 0)),
                    .init(name: "B", trials: trials(effect: 2.0)),
                    .init(name: "C", trials: trials(effect: -2.0)),
                ],
                channelCount: 1,
                sampleCount: sampleCount,
                spatialAdjacency: [[]]
            ),
            configuration: .init(permutationCount: 299, inference: .tfce, seed: 61)
        ))
        let scores = try #require(result.observedTFCEScores)
        // F is non-negative, so no enhanced score may be negative.
        #expect(scores.allSatisfy { $0 >= 0 })
        let cluster = try #require(result.clusters.first)
        #expect(cluster.pValue < 0.05)
        #expect(cluster.startSample <= 5)
        #expect(cluster.endSample >= 7)
    }
}
