//
//  ClusterPermutationFAnalyzer.swift
//  EVA
//
//  One-way independent-samples spatiotemporal cluster permutation F-test.
//  Trial labels are exchangeable under the omnibus null and each permutation
//  preserves the observed number of trials in every condition.
//


import Foundation

nonisolated enum ClusterPermutationFAnalyzer {
    struct Condition: Sendable {
        let name: String
        /// One flattened channel-major matrix per trial.
        let trials: [[Double]]
    }

    struct Input: Sendable {
        let conditions: [Condition]
        let channelCount: Int
        let sampleCount: Int
        let spatialAdjacency: [[Int]]
    }

    struct Configuration: Sendable, Equatable {
        var permutationCount = 1_000
        /// Samples enter a cluster when `F >= clusterThreshold`.
        var clusterThreshold = 4.0
        var seed: UInt64 = 0xE7A_F1A5_7E57
    }

    struct Result: Sendable, Equatable {
        let conditionNames: [String]
        let conditionCounts: [Int]
        let channelCount: Int
        let sampleCount: Int
        let numeratorDegreesOfFreedom: Int
        let denominatorDegreesOfFreedom: Int
        let observedStatistics: [Double]
        let clusters: [ClusterPermutationAnalyzer.Cluster]
        let nullMaximumClusterMasses: [Double]
        let configuration: Configuration
    }

    enum AnalysisError: Error, Sendable, Equatable {
        case invalidDimensions
        case insufficientConditions
        case insufficientTrials
        case invalidConfiguration
    }

    static func analyze(
        input: Input,
        configuration: Configuration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Result? {
        let featureCount = input.channelCount * input.sampleCount
        guard input.channelCount > 0,
              input.sampleCount > 0,
              input.spatialAdjacency.count == input.channelCount,
              input.conditions.allSatisfy({ condition in
                  condition.trials.allSatisfy { $0.count == featureCount }
              }) else { throw AnalysisError.invalidDimensions }
        guard input.conditions.count >= 3 else { throw AnalysisError.insufficientConditions }
        guard input.conditions.allSatisfy({ $0.trials.count >= 2 }) else {
            throw AnalysisError.insufficientTrials
        }
        guard configuration.permutationCount > 0,
              configuration.clusterThreshold.isFinite,
              configuration.clusterThreshold > 0 else {
            throw AnalysisError.invalidConfiguration
        }

        let conditionCounts = input.conditions.map { $0.trials.count }
        let trials = input.conditions.flatMap(\.trials)
        let totalTrialCount = trials.count
        let numeratorDF = input.conditions.count - 1
        let denominatorDF = totalTrialCount - input.conditions.count
        guard denominatorDF > 0 else { throw AnalysisError.insufficientTrials }

        var totalSums = [Double](repeating: 0, count: featureCount)
        var totalSumSquares = [Double](repeating: 0, count: featureCount)
        for trial in trials {
            add(trial, to: &totalSums)
            for feature in 0..<featureCount {
                totalSumSquares[feature] += trial[feature] * trial[feature]
            }
        }
        let fixedTotalSums = totalSums
        let fixedTotalSumSquares = totalSumSquares

        let observedGroupSums = input.conditions.map { condition -> [Double] in
            var sums = [Double](repeating: 0, count: featureCount)
            for trial in condition.trials { add(trial, to: &sums) }
            return sums
        }
        let observed = fStatistics(
            groupSums: observedGroupSums,
            groupCounts: conditionCounts,
            totalSums: fixedTotalSums,
            totalSumSquares: fixedTotalSumSquares
        )
        let observedCandidates = clusters(
            statistics: observed,
            threshold: configuration.clusterThreshold,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            spatialAdjacency: input.spatialAdjacency
        )

        var seedSource = SeededGenerator(seed: configuration.seed)
        let permutationSeeds = (0..<configuration.permutationCount).map { _ in seedSource.next() }
        let massStorage = UnsafeMassStorage(count: configuration.permutationCount)
        defer { massStorage.deallocate() }

        let workerCount = min(evaMaxWorkers, configuration.permutationCount)
        let batchSize = max(workerCount * 4, 1)
        var completed = 0
        while completed < configuration.permutationCount {
            if Task.isCancelled { return nil }
            let batchStart = completed
            let batchCount = min(batchSize, configuration.permutationCount - batchStart)
            evaConcurrentPerform(iterations: batchCount) { batchOffset in
                let permutation = batchStart + batchOffset
                var rng = SeededGenerator(seed: permutationSeeds[permutation])
                var indices = Array(0..<totalTrialCount)
                shuffle(&indices, using: &rng)

                var groupSums: [[Double]] = []
                groupSums.reserveCapacity(conditionCounts.count)
                var cursor = 0
                for count in conditionCounts {
                    var sums = [Double](repeating: 0, count: featureCount)
                    for index in indices[cursor..<(cursor + count)] {
                        add(trials[index], to: &sums)
                    }
                    groupSums.append(sums)
                    cursor += count
                }
                let statistics = fStatistics(
                    groupSums: groupSums,
                    groupCounts: conditionCounts,
                    totalSums: fixedTotalSums,
                    totalSumSquares: fixedTotalSumSquares
                )
                massStorage[permutation] = maximumClusterMass(
                    statistics: statistics,
                    threshold: configuration.clusterThreshold,
                    channelCount: input.channelCount,
                    sampleCount: input.sampleCount,
                    spatialAdjacency: input.spatialAdjacency
                )
            }
            completed += batchCount
            progress?(Double(completed) / Double(configuration.permutationCount))
        }
        let nullMaximumMasses = massStorage.values

        let denominator = Double(configuration.permutationCount + 1)
        let corrected = observedCandidates.map { candidate -> ClusterPermutationAnalyzer.Cluster in
            let exceedances = nullMaximumMasses.reduce(into: 0) { count, nullMass in
                if nullMass >= candidate.mass { count += 1 }
            }
            return ClusterPermutationAnalyzer.Cluster(
                id: 0,
                sign: 1,
                pointIndices: candidate.points,
                mass: candidate.mass,
                pValue: Double(exceedances + 1) / denominator,
                startSample: candidate.startSample,
                endSample: candidate.endSample,
                channelIndices: candidate.channels
            )
        }
        .sorted {
            if $0.pValue != $1.pValue { return $0.pValue < $1.pValue }
            return $0.mass > $1.mass
        }
        let sortedClusters = corrected.enumerated().map { index, cluster in
            ClusterPermutationAnalyzer.Cluster(
                id: index,
                sign: 1,
                pointIndices: cluster.pointIndices,
                mass: cluster.mass,
                pValue: cluster.pValue,
                startSample: cluster.startSample,
                endSample: cluster.endSample,
                channelIndices: cluster.channelIndices
            )
        }

        return Result(
            conditionNames: input.conditions.map(\.name),
            conditionCounts: conditionCounts,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            numeratorDegreesOfFreedom: numeratorDF,
            denominatorDegreesOfFreedom: denominatorDF,
            observedStatistics: observed,
            clusters: sortedClusters,
            nullMaximumClusterMasses: nullMaximumMasses,
            configuration: configuration
        )
    }

    /// Conventional one-way ANOVA F at every channel/time feature.
    private static func fStatistics(
        groupSums: [[Double]],
        groupCounts: [Int],
        totalSums: [Double],
        totalSumSquares: [Double]
    ) -> [Double] {
        let groupCount = groupCounts.count
        let totalCount = groupCounts.reduce(0, +)
        let betweenDF = Double(groupCount - 1)
        let withinDF = Double(totalCount - groupCount)
        var result = [Double](repeating: 0, count: totalSums.count)
        guard groupCount >= 2, totalCount > groupCount else { return result }

        for feature in result.indices {
            var groupCorrection = 0.0
            for group in groupSums.indices {
                let count = Double(groupCounts[group])
                let sum = groupSums[group][feature]
                groupCorrection += sum * sum / count
            }
            let grandCorrection = totalSums[feature] * totalSums[feature] / Double(totalCount)
            let betweenSS = max(groupCorrection - grandCorrection, 0)
            let withinSS = max(totalSumSquares[feature] - groupCorrection, 0)
            let denominator = withinSS / withinDF
            if denominator > 1e-15, denominator.isFinite {
                let value = (betweenSS / betweenDF) / denominator
                result[feature] = value.isFinite ? value : 0
            }
        }
        return result
    }

    private static func add(_ source: [Double], to destination: inout [Double]) {
        for index in source.indices { destination[index] += source[index] }
    }

    private static func shuffle<R: RandomNumberGenerator>(_ values: inout [Int], using rng: inout R) {
        guard values.count > 1 else { return }
        for index in 0..<(values.count - 1) {
            let other = Int.random(in: index..<values.count, using: &rng)
            if index != other { values.swapAt(index, other) }
        }
    }

    private struct CandidateCluster {
        let points: [Int]
        let mass: Double
        let startSample: Int
        let endSample: Int
        let channels: [Int]
    }

    private static func clusters(
        statistics: [Double],
        threshold: Double,
        channelCount: Int,
        sampleCount: Int,
        spatialAdjacency: [[Int]]
    ) -> [CandidateCluster] {
        var visited = [Bool](repeating: false, count: statistics.count)
        var output: [CandidateCluster] = []
        for seed in statistics.indices where !visited[seed] && statistics[seed] >= threshold {
            var queue = [seed]
            visited[seed] = true
            var cursor = 0
            var mass = 0.0
            var points: [Int] = []
            var channels = Set<Int>()
            var startSample = sampleCount
            var endSample = 0

            while cursor < queue.count {
                let point = queue[cursor]
                cursor += 1
                points.append(point)
                mass += statistics[point]
                let channel = point / sampleCount
                let sample = point % sampleCount
                channels.insert(channel)
                startSample = min(startSample, sample)
                endSample = max(endSample, sample)

                if sample > 0 {
                    enqueue(point - 1, statistics: statistics, threshold: threshold, visited: &visited, queue: &queue)
                }
                if sample + 1 < sampleCount {
                    enqueue(point + 1, statistics: statistics, threshold: threshold, visited: &visited, queue: &queue)
                }
                for neighbor in spatialAdjacency[channel] where neighbor >= 0 && neighbor < channelCount {
                    enqueue(
                        neighbor * sampleCount + sample,
                        statistics: statistics,
                        threshold: threshold,
                        visited: &visited,
                        queue: &queue
                    )
                }
            }
            output.append(CandidateCluster(
                points: points.sorted(),
                mass: mass,
                startSample: startSample,
                endSample: endSample,
                channels: channels.sorted()
            ))
        }
        return output
    }

    private static func maximumClusterMass(
        statistics: [Double],
        threshold: Double,
        channelCount: Int,
        sampleCount: Int,
        spatialAdjacency: [[Int]]
    ) -> Double {
        clusters(
            statistics: statistics,
            threshold: threshold,
            channelCount: channelCount,
            sampleCount: sampleCount,
            spatialAdjacency: spatialAdjacency
        ).map(\.mass).max() ?? 0
    }

    private static func enqueue(
        _ point: Int,
        statistics: [Double],
        threshold: Double,
        visited: inout [Bool],
        queue: inout [Int]
    ) {
        guard statistics.indices.contains(point), !visited[point], statistics[point] >= threshold else { return }
        visited[point] = true
        queue.append(point)
    }

    private final class UnsafeMassStorage: @unchecked Sendable {
        private let pointer: UnsafeMutablePointer<Double>
        private let count: Int

        init(count: Int) {
            self.count = count
            pointer = .allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
        }

        subscript(index: Int) -> Double {
            get { pointer[index] }
            set { pointer[index] = newValue }
        }

        var values: [Double] { Array(UnsafeBufferPointer(start: pointer, count: count)) }

        func deallocate() {
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }
    }
}
