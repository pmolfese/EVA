//
//  ClusterPermutationAnalyzer.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Deterministic two-condition spatiotemporal cluster permutation statistics.
//  The inference unit is a single epoch. Condition labels are shuffled while
//  preserving group sizes; each permutation contributes its largest absolute
//  cluster mass to the family-wise null distribution.
//

import Accelerate
import Foundation

nonisolated enum ClusterPermutationAnalyzer {
    struct Condition: Sendable {
        let name: String
        /// One flattened channel-major matrix per trial:
        /// channel 0 samples, then channel 1 samples, and so on.
        let trials: [[Double]]
    }

    struct Input: Sendable {
        let conditionA: Condition
        let conditionB: Condition
        let channelCount: Int
        let sampleCount: Int
        /// Local channel index -> local neighboring channel indices.
        let spatialAdjacency: [[Int]]
    }

    struct Configuration: Sendable, Equatable {
        var permutationCount = 1_000
        /// Samples enter a cluster when `abs(t) >= clusterThreshold`.
        var clusterThreshold = 2.0
        var seed: UInt64 = 0xE7A_C1A5_7E57
    }

    struct Cluster: Identifiable, Sendable, Equatable {
        let id: Int
        /// Positive means condition A > B; negative means A < B.
        let sign: Int
        let pointIndices: [Int]
        let mass: Double
        let pValue: Double
        let startSample: Int
        let endSample: Int
        let channelIndices: [Int]
    }

    struct Result: Sendable, Equatable {
        let conditionA: String
        let conditionB: String
        let conditionACount: Int
        let conditionBCount: Int
        let channelCount: Int
        let sampleCount: Int
        let observedStatistics: [Double]
        let clusters: [Cluster]
        let nullMaximumClusterMasses: [Double]
        let configuration: Configuration
    }

    enum AnalysisError: Error, Sendable, Equatable {
        case invalidDimensions
        case insufficientTrials
        case invalidConfiguration
    }

    /// Returns `nil` when the surrounding task is cancelled.
    static func analyze(
        input: Input,
        configuration: Configuration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Result? {
        let featureCount = input.channelCount * input.sampleCount
        guard input.channelCount > 0,
              input.sampleCount > 0,
              input.spatialAdjacency.count == input.channelCount,
              input.conditionA.trials.allSatisfy({ $0.count == featureCount }),
              input.conditionB.trials.allSatisfy({ $0.count == featureCount }) else {
            throw AnalysisError.invalidDimensions
        }
        let nA = input.conditionA.trials.count
        let nB = input.conditionB.trials.count
        guard nA >= 2, nB >= 2 else { throw AnalysisError.insufficientTrials }
        guard configuration.permutationCount > 0,
              configuration.clusterThreshold.isFinite,
              configuration.clusterThreshold > 0 else {
            throw AnalysisError.invalidConfiguration
        }

        let trials = input.conditionA.trials + input.conditionB.trials
        let totalCount = trials.count
        var totalSums = [Double](repeating: 0, count: featureCount)
        var totalSumSquares = [Double](repeating: 0, count: featureCount)
        for trial in trials {
            add(trial, to: &totalSums)
            for feature in 0..<featureCount {
                totalSumSquares[feature] += trial[feature] * trial[feature]
            }
        }
        // Freeze the accumulated arrays before they cross the concurrent
        // permutation boundary. Their contents are read-only from here on.
        let fixedTotalSums = totalSums
        let fixedTotalSumSquares = totalSumSquares

        var observedGroupSums = [Double](repeating: 0, count: featureCount)
        for trial in input.conditionA.trials {
            add(trial, to: &observedGroupSums)
        }
        let observed = tStatistics(
            groupASums: observedGroupSums,
            totalSums: fixedTotalSums,
            totalSumSquares: fixedTotalSumSquares,
            nA: nA,
            nB: nB
        )
        let observedCandidates = clusters(
            statistics: observed,
            threshold: configuration.clusterThreshold,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            spatialAdjacency: input.spatialAdjacency
        )

        // Give each permutation an index-stable seed before parallel work
        // begins. Results therefore do not depend on thread scheduling.
        var seedSource = SeededGenerator(seed: configuration.seed)
        let permutationSeeds = (0..<configuration.permutationCount).map { _ in seedSource.next() }
        let massStorage = UnsafeMassStorage(count: configuration.permutationCount)
        defer { massStorage.deallocate() }

        // Process several waves rather than one monolithic concurrentPerform.
        // Besides keeping all CPU cores occupied, this returns to the parent
        // Swift task regularly so cancellation remains responsive.
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
                var indices = Array(0..<totalCount)
                shufflePrefix(&indices, prefixCount: nA, using: &rng)

                var groupSums = [Double](repeating: 0, count: featureCount)
                for offset in 0..<nA {
                    add(trials[indices[offset]], to: &groupSums)
                }
                let statistics = tStatistics(
                    groupASums: groupSums,
                    totalSums: fixedTotalSums,
                    totalSumSquares: fixedTotalSumSquares,
                    nA: nA,
                    nB: nB
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
        let correctedClusters = observedCandidates.enumerated().map { index, candidate in
            let exceedances = nullMaximumMasses.reduce(into: 0) { count, nullMass in
                if nullMass >= candidate.mass { count += 1 }
            }
            return Cluster(
                id: index,
                sign: candidate.sign,
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
        // Restore stable display ids after sorting.
        let sortedClusters = correctedClusters.enumerated().map { displayIndex, cluster in
            Cluster(
                id: displayIndex,
                sign: cluster.sign,
                pointIndices: cluster.pointIndices,
                mass: cluster.mass,
                pValue: cluster.pValue,
                startSample: cluster.startSample,
                endSample: cluster.endSample,
                channelIndices: cluster.channelIndices
            )
        }

        return Result(
            conditionA: input.conditionA.name,
            conditionB: input.conditionB.name,
            conditionACount: nA,
            conditionBCount: nB,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            observedStatistics: observed,
            clusters: sortedClusters,
            nullMaximumClusterMasses: nullMaximumMasses,
            configuration: configuration
        )
    }

    // MARK: - Test statistic

    /// Equal-variance independent-samples t. Under the label-exchangeability
    /// null, this studentized statistic works with unequal group sizes without
    /// throwing away trials merely to equalize counts.
    private static func tStatistics(
        groupASums: [Double],
        totalSums: [Double],
        totalSumSquares: [Double],
        nA: Int,
        nB: Int
    ) -> [Double] {
        let a = Double(nA)
        let b = Double(nB)
        let degreesOfFreedom = Double(nA + nB - 2)
        let scale = (1 / a) + (1 / b)
        var result = [Double](repeating: 0, count: groupASums.count)
        guard degreesOfFreedom > 0 else { return result }

        for feature in result.indices {
            let sumA = groupASums[feature]
            let sumB = totalSums[feature] - sumA
            let meanDifference = (sumA / a) - (sumB / b)
            // Within-group SS derived from invariant total sum-of-squares.
            let withinSS = max(totalSumSquares[feature] - (sumA * sumA / a) - (sumB * sumB / b), 0)
            let denominator = sqrt((withinSS / degreesOfFreedom) * scale)
            if denominator > 1e-15, denominator.isFinite {
                let value = meanDifference / denominator
                result[feature] = value.isFinite ? value : 0
            }
        }
        return result
    }

    private static func add(_ source: [Double], to destination: inout [Double]) {
        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let sourceBase = sourceBuffer.baseAddress,
                      let destinationBase = destinationBuffer.baseAddress else { return }
                vDSP_vaddD(sourceBase, 1, destinationBase, 1, destinationBase, 1, vDSP_Length(source.count))
            }
        }
    }

    /// Partial Fisher-Yates: only the first `prefixCount` positions need to be
    /// a uniformly sampled group.
    private static func shufflePrefix<R: RandomNumberGenerator>(
        _ values: inout [Int],
        prefixCount: Int,
        using rng: inout R
    ) {
        guard prefixCount > 0, prefixCount <= values.count else { return }
        for index in 0..<prefixCount {
            let other = Int.random(in: index..<values.count, using: &rng)
            if index != other { values.swapAt(index, other) }
        }
    }

    // MARK: - Clustering

    private struct CandidateCluster {
        let sign: Int
        let points: [Int]
        let mass: Double
        let startSample: Int
        let endSample: Int
        let channels: [Int]
    }

    /// Disjoint-index result buffer for the concurrent permutation map.
    /// The pointer is initialized before workers start, every worker writes a
    /// unique index, and deallocation happens only after all synchronous GCD
    /// waves have returned.
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

        var values: [Double] {
            Array(UnsafeBufferPointer(start: pointer, count: count))
        }

        func deallocate() {
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }
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

        for seed in statistics.indices where !visited[seed] && abs(statistics[seed]) >= threshold {
            let sign = statistics[seed] >= 0 ? 1 : -1
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
                mass += abs(statistics[point])
                let channel = point / sampleCount
                let sample = point % sampleCount
                channels.insert(channel)
                startSample = min(startSample, sample)
                endSample = max(endSample, sample)

                if sample > 0 {
                    enqueue(point - 1, sign: sign, statistics: statistics, threshold: threshold, visited: &visited, queue: &queue)
                }
                if sample + 1 < sampleCount {
                    enqueue(point + 1, sign: sign, statistics: statistics, threshold: threshold, visited: &visited, queue: &queue)
                }
                for neighborChannel in spatialAdjacency[channel]
                    where neighborChannel >= 0 && neighborChannel < channelCount {
                    enqueue(
                        neighborChannel * sampleCount + sample,
                        sign: sign,
                        statistics: statistics,
                        threshold: threshold,
                        visited: &visited,
                        queue: &queue
                    )
                }
            }

            output.append(CandidateCluster(
                sign: sign,
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
        sign: Int,
        statistics: [Double],
        threshold: Double,
        visited: inout [Bool],
        queue: inout [Int]
    ) {
        guard statistics.indices.contains(point), !visited[point] else { return }
        let statistic = statistics[point]
        guard abs(statistic) >= threshold, (statistic >= 0 ? 1 : -1) == sign else { return }
        visited[point] = true
        queue.append(point)
    }
}
