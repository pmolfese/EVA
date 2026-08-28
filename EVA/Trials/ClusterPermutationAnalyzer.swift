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
//
//  Two exchangeability schemes are supported, and they answer different
//  questions. Under `.independent` the observations are unrelated and condition
//  labels are shuffled freely, preserving group sizes. Under `.repeatedMeasures`
//  the observations are paired — the same subject or the same trial slot
//  measured in both conditions — and only the sign of each pair's difference is
//  exchangeable. Applying the independent scheme to paired data discards the
//  pairing that makes the design sensitive and is anticonservative when the
//  units differ systematically from one another.
//

import Accelerate
import Foundation

nonisolated enum ClusterPermutationAnalyzer {
    typealias Cluster = SpatiotemporalCluster

    // MARK: - Inputs

    nonisolated enum Design: String, CaseIterable, Identifiable, Sendable, Equatable {
        case independent = "Independent"
        case repeatedMeasures = "Paired"

        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .independent:
                return "Trials in the two conditions are unrelated observations. Condition labels are shuffled across all trials, preserving the two group sizes."
            case .repeatedMeasures:
                return "Each observation in one condition is matched to one in the other — the same subject, or the same trial position. The test runs on the paired differences and permutes by flipping each pair's sign."
            }
        }
    }

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
        let design: Design

        init(
            conditionA: Condition,
            conditionB: Condition,
            channelCount: Int,
            sampleCount: Int,
            spatialAdjacency: [[Int]],
            design: Design = .independent
        ) {
            self.conditionA = conditionA
            self.conditionB = conditionB
            self.channelCount = channelCount
            self.sampleCount = sampleCount
            self.spatialAdjacency = spatialAdjacency
            self.design = design
        }
    }

    struct Configuration: Sendable, Equatable {
        var permutationCount = 1_000
        /// How the cluster-forming threshold was specified. Ignored under TFCE.
        var threshold = ClusterFormingThreshold.statistic(2.0)
        var inference = ClusterInferenceMode.clusterMass
        var tfce = TFCEParameters.default
        var seed: UInt64 = 0xE7A_C1A5_7E57

        init(
            permutationCount: Int = 1_000,
            threshold: ClusterFormingThreshold = .statistic(2.0),
            inference: ClusterInferenceMode = .clusterMass,
            tfce: TFCEParameters = .default,
            seed: UInt64 = 0xE7A_C1A5_7E57
        ) {
            self.permutationCount = permutationCount
            self.threshold = threshold
            self.inference = inference
            self.tfce = tfce
            self.seed = seed
        }
    }

    struct Result: Sendable, Equatable {
        let conditionA: String
        let conditionB: String
        let conditionACount: Int
        let conditionBCount: Int
        let design: Design
        /// Matched pairs under `.repeatedMeasures`; nil otherwise.
        let pairCount: Int?
        let degreesOfFreedom: Double
        let channelCount: Int
        let sampleCount: Int
        let observedStatistics: [Double]
        /// Populated under TFCE only.
        let observedTFCEScores: [Double]?
        /// Point-wise corrected p-values; populated under TFCE only.
        let pointPValues: [Double]?
        /// The `|t|` actually used to form clusters, after resolving a
        /// probability threshold against the design's df. Nil under TFCE.
        let resolvedThreshold: Double?
        let clusters: [Cluster]
        let nullMaximumClusterMasses: [Double]
        let configuration: Configuration
    }

    enum AnalysisError: Error, Sendable, Equatable {
        case invalidDimensions
        case insufficientTrials
        case invalidConfiguration
        case unbalancedPairs
    }

    // MARK: - Entry point

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
        guard configuration.permutationCount > 0 else { throw AnalysisError.invalidConfiguration }
        if configuration.inference == .tfce {
            guard configuration.tfce.isValid else { throw AnalysisError.invalidConfiguration }
        }
        if input.design == .repeatedMeasures, nA != nB {
            throw AnalysisError.unbalancedPairs
        }

        let degreesOfFreedom = input.design == .repeatedMeasures
            ? Double(nA - 1)
            : Double(nA + nB - 2)
        guard degreesOfFreedom > 0 else { throw AnalysisError.insufficientTrials }

        let resolvedThreshold: Double?
        if configuration.inference == .clusterMass {
            guard let value = resolveThreshold(configuration.threshold, degreesOfFreedom: degreesOfFreedom) else {
                throw AnalysisError.invalidConfiguration
            }
            resolvedThreshold = value
        } else {
            resolvedThreshold = nil
        }

        let grid = ClusterGrid(
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            spatialAdjacency: input.spatialAdjacency
        )

        switch input.design {
        case .independent:
            return try analyzeIndependent(
                input: input,
                configuration: configuration,
                grid: grid,
                degreesOfFreedom: degreesOfFreedom,
                resolvedThreshold: resolvedThreshold,
                progress: progress
            )
        case .repeatedMeasures:
            return try analyzePaired(
                input: input,
                configuration: configuration,
                grid: grid,
                degreesOfFreedom: degreesOfFreedom,
                resolvedThreshold: resolvedThreshold,
                progress: progress
            )
        }
    }

    static func resolveThreshold(
        _ threshold: ClusterFormingThreshold,
        degreesOfFreedom: Double
    ) -> Double? {
        switch threshold {
        case .statistic(let value):
            guard value.isFinite, value > 0 else { return nil }
            return value
        case .probability(let alpha):
            guard alpha > 0, alpha < 1 else { return nil }
            return ClusterStatisticsDistributions.criticalT(
                twoTailedAlpha: alpha,
                degreesOfFreedom: degreesOfFreedom
            )
        }
    }

    // MARK: - Independent samples

    private static func analyzeIndependent(
        input: Input,
        configuration: Configuration,
        grid: ClusterGrid,
        degreesOfFreedom: Double,
        resolvedThreshold: Double?,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> Result? {
        let featureCount = grid.featureCount
        let nA = input.conditionA.trials.count
        let nB = input.conditionB.trials.count

        let trials = input.conditionA.trials + input.conditionB.trials
        let totalCount = trials.count
        var totalSums = [Double](repeating: 0, count: featureCount)
        var totalSumSquares = [Double](repeating: 0, count: featureCount)
        for trial in trials {
            add(trial, to: &totalSums)
            addSquares(trial, to: &totalSumSquares)
        }
        // Freeze the accumulated arrays before they cross the concurrent
        // permutation boundary. Their contents are read-only from here on.
        let fixedTotalSums = totalSums
        let fixedTotalSumSquares = totalSumSquares

        var observedGroupSums = [Double](repeating: 0, count: featureCount)
        for trial in input.conditionA.trials {
            add(trial, to: &observedGroupSums)
        }
        let observed = independentTStatistics(
            groupASums: observedGroupSums,
            totalSums: fixedTotalSums,
            totalSumSquares: fixedTotalSumSquares,
            nA: nA,
            nB: nB
        )

        let outcome = try runPermutations(
            grid: grid,
            configuration: configuration,
            resolvedThreshold: resolvedThreshold,
            observed: observed,
            progress: progress
        ) { permutationIndex, rng, workspace in
            var indices = Array(0..<totalCount)
            shufflePrefix(&indices, prefixCount: nA, using: &rng)
            var groupSums = [Double](repeating: 0, count: featureCount)
            for offset in 0..<nA {
                add(trials[indices[offset]], to: &groupSums)
            }
            return independentTStatistics(
                groupASums: groupSums,
                totalSums: fixedTotalSums,
                totalSumSquares: fixedTotalSumSquares,
                nA: nA,
                nB: nB
            )
        }
        guard let outcome else { return nil }

        return Result(
            conditionA: input.conditionA.name,
            conditionB: input.conditionB.name,
            conditionACount: nA,
            conditionBCount: nB,
            design: .independent,
            pairCount: nil,
            degreesOfFreedom: degreesOfFreedom,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            observedStatistics: observed,
            observedTFCEScores: outcome.tfceScores,
            pointPValues: outcome.pointPValues,
            resolvedThreshold: resolvedThreshold,
            clusters: outcome.clusters,
            nullMaximumClusterMasses: outcome.nullMaxima,
            configuration: configuration
        )
    }

    /// Equal-variance independent-samples t. Under the label-exchangeability
    /// null, this studentized statistic works with unequal group sizes without
    /// throwing away trials merely to equalize counts.
    private static func independentTStatistics(
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

    // MARK: - Repeated measures (paired)

    private static func analyzePaired(
        input: Input,
        configuration: Configuration,
        grid: ClusterGrid,
        degreesOfFreedom: Double,
        resolvedThreshold: Double?,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> Result? {
        let featureCount = grid.featureCount
        let pairCount = input.conditionA.trials.count

        // The paired design collapses to a one-sample test on differences.
        var differences: [[Double]] = []
        differences.reserveCapacity(pairCount)
        for index in 0..<pairCount {
            let a = input.conditionA.trials[index]
            let b = input.conditionB.trials[index]
            var difference = [Double](repeating: 0, count: featureCount)
            for feature in 0..<featureCount {
                difference[feature] = a[feature] - b[feature]
            }
            differences.append(difference)
        }
        let fixedDifferences = differences

        // Sign flipping leaves every squared difference untouched, so the
        // sum-of-squares term is computed once and reused by every permutation.
        var sumSquares = [Double](repeating: 0, count: featureCount)
        for difference in fixedDifferences {
            addSquares(difference, to: &sumSquares)
        }
        let fixedSumSquares = sumSquares

        var observedSums = [Double](repeating: 0, count: featureCount)
        for difference in fixedDifferences {
            add(difference, to: &observedSums)
        }
        let observed = pairedTStatistics(
            sums: observedSums,
            sumSquares: fixedSumSquares,
            pairCount: pairCount
        )

        let outcome = try runPermutations(
            grid: grid,
            configuration: configuration,
            resolvedThreshold: resolvedThreshold,
            observed: observed,
            progress: progress
        ) { permutationIndex, rng, workspace in
            var sums = [Double](repeating: 0, count: featureCount)
            for difference in fixedDifferences {
                // One fair coin per pair: the exchangeable unit under the
                // repeated-measures null is the sign of the difference.
                if Bool.random(using: &rng) {
                    add(difference, to: &sums)
                } else {
                    subtract(difference, from: &sums)
                }
            }
            return pairedTStatistics(
                sums: sums,
                sumSquares: fixedSumSquares,
                pairCount: pairCount
            )
        }
        guard let outcome else { return nil }

        return Result(
            conditionA: input.conditionA.name,
            conditionB: input.conditionB.name,
            conditionACount: pairCount,
            conditionBCount: pairCount,
            design: .repeatedMeasures,
            pairCount: pairCount,
            degreesOfFreedom: degreesOfFreedom,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            observedStatistics: observed,
            observedTFCEScores: outcome.tfceScores,
            pointPValues: outcome.pointPValues,
            resolvedThreshold: resolvedThreshold,
            clusters: outcome.clusters,
            nullMaximumClusterMasses: outcome.nullMaxima,
            configuration: configuration
        )
    }

    /// One-sample t on the paired differences.
    private static func pairedTStatistics(
        sums: [Double],
        sumSquares: [Double],
        pairCount: Int
    ) -> [Double] {
        let n = Double(pairCount)
        var result = [Double](repeating: 0, count: sums.count)
        guard pairCount > 1 else { return result }
        let degreesOfFreedom = n - 1

        for feature in result.indices {
            let sum = sums[feature]
            let mean = sum / n
            let deviationSS = max(sumSquares[feature] - (sum * sum / n), 0)
            let standardError = sqrt((deviationSS / degreesOfFreedom) / n)
            if standardError > 1e-15, standardError.isFinite {
                let value = mean / standardError
                result[feature] = value.isFinite ? value : 0
            }
        }
        return result
    }

    // MARK: - Shared permutation driver

    struct PermutationOutcome {
        let clusters: [Cluster]
        let nullMaxima: [Double]
        let tfceScores: [Double]?
        let pointPValues: [Double]?
    }

    /// Drives the permutation loop for either design and either inference mode.
    /// `statisticsForPermutation` returns the full statistic map for one
    /// relabeling; everything downstream — cluster growth, TFCE, correction —
    /// is identical between designs.
    ///
    /// Returns `nil` when the surrounding task is cancelled.
    static func runPermutations(
        grid: ClusterGrid,
        configuration: Configuration,
        resolvedThreshold: Double?,
        observed: [Double],
        signed: Bool = true,
        progress: (@Sendable (Double) -> Void)?,
        statisticsForPermutation: @escaping @Sendable (Int, inout SeededGenerator, ClusterGrid.Workspace) -> [Double]
    ) throws -> PermutationOutcome? {
        // Give each permutation an index-stable seed before parallel work
        // begins. Results therefore do not depend on thread scheduling.
        var seedSource = SeededGenerator(seed: configuration.seed)
        let permutationSeeds = (0..<configuration.permutationCount).map { _ in seedSource.next() }
        let nullStorage = PermutationValueStorage(count: configuration.permutationCount)
        defer { nullStorage.deallocate() }

        let observedTFCE: [Double]? = configuration.inference == .tfce
            ? grid.tfceScores(statistics: observed, signed: signed, parameters: configuration.tfce)
            : nil

        // Process several waves rather than one monolithic concurrentPerform.
        // Besides keeping all CPU cores occupied, this returns to the parent
        // Swift task regularly so cancellation remains responsive.
        let workerCount = min(evaMaxWorkers, configuration.permutationCount)
        let batchSize = max(workerCount * 4, 1)
        var completed = 0
        let inference = configuration.inference
        let tfceParameters = configuration.tfce
        let threshold = resolvedThreshold ?? 0

        while completed < configuration.permutationCount {
            if Task.isCancelled { return nil }
            let batchStart = completed
            let batchCount = min(batchSize, configuration.permutationCount - batchStart)
            evaConcurrentPerform(iterations: batchCount) { batchOffset in
                let permutation = batchStart + batchOffset
                var rng = SeededGenerator(seed: permutationSeeds[permutation])
                let workspace = grid.makeWorkspace()
                let statistics = statisticsForPermutation(permutation, &rng, workspace)
                switch inference {
                case .clusterMass:
                    nullStorage[permutation] = grid.maximumClusterMass(
                        statistics: statistics,
                        threshold: threshold,
                        signed: signed,
                        workspace: workspace
                    )
                case .tfce:
                    let scores = grid.tfceScores(
                        statistics: statistics,
                        signed: signed,
                        parameters: tfceParameters
                    )
                    nullStorage[permutation] = scores.reduce(0) { max($0, abs($1)) }
                }
            }
            completed += batchCount
            progress?(Double(completed) / Double(configuration.permutationCount))
        }
        let nullMaxima = nullStorage.values

        let workspace = grid.makeWorkspace()
        switch inference {
        case .clusterMass:
            let candidates = grid.formClusters(
                statistics: observed,
                threshold: threshold,
                signed: signed,
                workspace: workspace
            )
            let clusters = candidates.map { candidate in
                Cluster(
                    id: 0,
                    sign: candidate.sign,
                    pointIndices: candidate.points,
                    mass: candidate.mass,
                    pValue: ClusterCorrection.pValue(observed: candidate.mass, nullMaxima: nullMaxima),
                    startSample: candidate.startSample,
                    endSample: candidate.endSample,
                    channelIndices: candidate.channels
                )
            }
            return PermutationOutcome(
                clusters: ClusterCorrection.sortedForDisplay(clusters),
                nullMaxima: nullMaxima,
                tfceScores: nil,
                pointPValues: nil
            )
        case .tfce:
            let scores = observedTFCE ?? []
            let pointPValues = ClusterCorrection.pointPValues(scores: scores, nullMaxima: nullMaxima)
            // Group the surviving points at the most permissive alpha the UI
            // offers, so the alpha control can still filter afterwards.
            let candidates = grid.componentsOfSignificantPoints(
                scores: scores,
                pValues: pointPValues,
                alpha: 0.10,
                signed: signed,
                workspace: workspace
            )
            let clusters = candidates.map { candidate -> Cluster in
                let best = candidate.points.map { pointPValues[$0] }.min() ?? 1
                return Cluster(
                    id: 0,
                    sign: candidate.sign,
                    pointIndices: candidate.points,
                    mass: candidate.mass,
                    pValue: best,
                    startSample: candidate.startSample,
                    endSample: candidate.endSample,
                    channelIndices: candidate.channels
                )
            }
            return PermutationOutcome(
                clusters: ClusterCorrection.sortedForDisplay(clusters),
                nullMaxima: nullMaxima,
                tfceScores: scores,
                pointPValues: pointPValues
            )
        }
    }

    // MARK: - Vector helpers

    static func add(_ source: [Double], to destination: inout [Double]) {
        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let sourceBase = sourceBuffer.baseAddress,
                      let destinationBase = destinationBuffer.baseAddress else { return }
                vDSP_vaddD(sourceBase, 1, destinationBase, 1, destinationBase, 1, vDSP_Length(source.count))
            }
        }
    }

    static func subtract(_ source: [Double], from destination: inout [Double]) {
        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let sourceBase = sourceBuffer.baseAddress,
                      let destinationBase = destinationBuffer.baseAddress else { return }
                vDSP_vsubD(sourceBase, 1, destinationBase, 1, destinationBase, 1, vDSP_Length(source.count))
            }
        }
    }

    static func addSquares(_ source: [Double], to destination: inout [Double]) {
        for index in source.indices {
            destination[index] += source[index] * source[index]
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
}
