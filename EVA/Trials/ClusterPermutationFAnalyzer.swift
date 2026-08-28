//
//  ClusterPermutationFAnalyzer.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Omnibus spatiotemporal cluster permutation F-test, in both a one-way
//  independent-samples and a one-way repeated-measures form.
//
//  The exchangeability schemes differ in an important way. Independent samples
//  permutes trial labels across the whole pool. Repeated measures permutes
//  condition labels *within* each unit, which leaves the unit main effect
//  intact under the null — the same restriction that makes the repeated-measures
//  F sensitive in the first place. Permuting across units instead would test a
//  null nobody asked about and would inflate the error term with between-unit
//  variance.
//

import Foundation

nonisolated enum ClusterPermutationFAnalyzer {
    nonisolated enum Design: String, CaseIterable, Identifiable, Sendable, Equatable {
        case independent = "Independent"
        case repeatedMeasures = "Repeated measures"

        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .independent:
                return "Every trial is an unrelated observation. One-way ANOVA across all trials; labels are shuffled over the whole pool."
            case .repeatedMeasures:
                return "Each unit — a subject, or a matched trial position — contributes one observation to every condition. The unit main effect is partialled out and labels are shuffled only within units."
            }
        }
    }

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
        let design: Design

        init(
            conditions: [Condition],
            channelCount: Int,
            sampleCount: Int,
            spatialAdjacency: [[Int]],
            design: Design = .independent
        ) {
            self.conditions = conditions
            self.channelCount = channelCount
            self.sampleCount = sampleCount
            self.spatialAdjacency = spatialAdjacency
            self.design = design
        }
    }

    struct Configuration: Sendable, Equatable {
        var permutationCount = 1_000
        var threshold = ClusterFormingThreshold.statistic(4.0)
        var inference = ClusterInferenceMode.clusterMass
        var tfce = TFCEParameters.default
        var seed: UInt64 = 0xE7A_F1A5_7E57

        init(
            permutationCount: Int = 1_000,
            threshold: ClusterFormingThreshold = .statistic(4.0),
            inference: ClusterInferenceMode = .clusterMass,
            tfce: TFCEParameters = .default,
            seed: UInt64 = 0xE7A_F1A5_7E57
        ) {
            self.permutationCount = permutationCount
            self.threshold = threshold
            self.inference = inference
            self.tfce = tfce
            self.seed = seed
        }
    }

    struct Result: Sendable, Equatable {
        let conditionNames: [String]
        let conditionCounts: [Int]
        let design: Design
        /// Units contributing to every condition under repeated measures.
        let unitCount: Int?
        let channelCount: Int
        let sampleCount: Int
        let numeratorDegreesOfFreedom: Int
        let denominatorDegreesOfFreedom: Int
        let observedStatistics: [Double]
        let observedTFCEScores: [Double]?
        let pointPValues: [Double]?
        let resolvedThreshold: Double?
        let clusters: [SpatiotemporalCluster]
        let nullMaximumClusterMasses: [Double]
        let configuration: Configuration
    }

    enum AnalysisError: Error, Sendable, Equatable {
        case invalidDimensions
        case insufficientConditions
        case insufficientTrials
        case invalidConfiguration
        case unbalancedUnits
    }

    // MARK: - Entry point

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
        guard configuration.permutationCount > 0 else { throw AnalysisError.invalidConfiguration }
        if configuration.inference == .tfce {
            guard configuration.tfce.isValid else { throw AnalysisError.invalidConfiguration }
        }

        let conditionCounts = input.conditions.map { $0.trials.count }
        let conditionCount = input.conditions.count
        let numeratorDF = conditionCount - 1

        let denominatorDF: Int
        let unitCount: Int?
        switch input.design {
        case .independent:
            denominatorDF = conditionCounts.reduce(0, +) - conditionCount
            unitCount = nil
        case .repeatedMeasures:
            guard Set(conditionCounts).count == 1 else { throw AnalysisError.unbalancedUnits }
            let units = conditionCounts[0]
            denominatorDF = (conditionCount - 1) * (units - 1)
            unitCount = units
        }
        guard denominatorDF > 0 else { throw AnalysisError.insufficientTrials }

        let resolvedThreshold: Double?
        if configuration.inference == .clusterMass {
            guard let value = resolveThreshold(
                configuration.threshold,
                numeratorDegreesOfFreedom: Double(numeratorDF),
                denominatorDegreesOfFreedom: Double(denominatorDF)
            ) else { throw AnalysisError.invalidConfiguration }
            resolvedThreshold = value
        } else {
            resolvedThreshold = nil
        }

        let grid = ClusterGrid(
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            spatialAdjacency: input.spatialAdjacency
        )

        let observed: [Double]
        let permute: @Sendable (Int, inout SeededGenerator, ClusterGrid.Workspace) -> [Double]

        switch input.design {
        case .independent:
            let trials = input.conditions.flatMap(\.trials)
            let totalTrialCount = trials.count
            var totalSums = [Double](repeating: 0, count: featureCount)
            var totalSumSquares = [Double](repeating: 0, count: featureCount)
            for trial in trials {
                ClusterPermutationAnalyzer.add(trial, to: &totalSums)
                ClusterPermutationAnalyzer.addSquares(trial, to: &totalSumSquares)
            }
            let fixedTotalSums = totalSums
            let fixedTotalSumSquares = totalSumSquares

            let observedGroupSums = input.conditions.map { condition -> [Double] in
                var sums = [Double](repeating: 0, count: featureCount)
                for trial in condition.trials { ClusterPermutationAnalyzer.add(trial, to: &sums) }
                return sums
            }
            observed = independentFStatistics(
                groupSums: observedGroupSums,
                groupCounts: conditionCounts,
                totalSums: fixedTotalSums,
                totalSumSquares: fixedTotalSumSquares
            )
            permute = { _, rng, _ in
                var indices = Array(0..<totalTrialCount)
                shuffle(&indices, using: &rng)
                var groupSums: [[Double]] = []
                groupSums.reserveCapacity(conditionCounts.count)
                var cursor = 0
                for count in conditionCounts {
                    var sums = [Double](repeating: 0, count: featureCount)
                    for index in indices[cursor..<(cursor + count)] {
                        ClusterPermutationAnalyzer.add(trials[index], to: &sums)
                    }
                    groupSums.append(sums)
                    cursor += count
                }
                return independentFStatistics(
                    groupSums: groupSums,
                    groupCounts: conditionCounts,
                    totalSums: fixedTotalSums,
                    totalSumSquares: fixedTotalSumSquares
                )
            }

        case .repeatedMeasures:
            let units = unitCount ?? 0
            // units[i][j] is unit i observed in condition j.
            let unitObservations: [[[Double]]] = (0..<units).map { unit in
                input.conditions.map { $0.trials[unit] }
            }

            // Everything except the condition sums is invariant under
            // within-unit relabeling, so it is computed once here.
            var grandSums = [Double](repeating: 0, count: featureCount)
            var totalSumSquares = [Double](repeating: 0, count: featureCount)
            var unitSumOfSquaredSums = [Double](repeating: 0, count: featureCount)
            for observations in unitObservations {
                var unitSums = [Double](repeating: 0, count: featureCount)
                for observation in observations {
                    ClusterPermutationAnalyzer.add(observation, to: &unitSums)
                    ClusterPermutationAnalyzer.addSquares(observation, to: &totalSumSquares)
                }
                ClusterPermutationAnalyzer.add(unitSums, to: &grandSums)
                ClusterPermutationAnalyzer.addSquares(unitSums, to: &unitSumOfSquaredSums)
            }
            let fixedGrandSums = grandSums
            let fixedTotalSumSquares = totalSumSquares
            let fixedUnitSumOfSquaredSums = unitSumOfSquaredSums

            let observedConditionSums = input.conditions.map { condition -> [Double] in
                var sums = [Double](repeating: 0, count: featureCount)
                for trial in condition.trials { ClusterPermutationAnalyzer.add(trial, to: &sums) }
                return sums
            }
            observed = repeatedMeasuresFStatistics(
                conditionSums: observedConditionSums,
                grandSums: fixedGrandSums,
                totalSumSquares: fixedTotalSumSquares,
                unitSumOfSquaredSums: fixedUnitSumOfSquaredSums,
                unitCount: units,
                conditionCount: conditionCount
            )
            permute = { _, rng, _ in
                var conditionSums = [[Double]](
                    repeating: [Double](repeating: 0, count: featureCount),
                    count: conditionCount
                )
                var assignment = Array(0..<conditionCount)
                for observations in unitObservations {
                    // A fresh within-unit relabeling for every unit; the unit
                    // itself is never exchanged with any other.
                    shuffle(&assignment, using: &rng)
                    for slot in 0..<conditionCount {
                        ClusterPermutationAnalyzer.add(
                            observations[slot],
                            to: &conditionSums[assignment[slot]]
                        )
                    }
                }
                return repeatedMeasuresFStatistics(
                    conditionSums: conditionSums,
                    grandSums: fixedGrandSums,
                    totalSumSquares: fixedTotalSumSquares,
                    unitSumOfSquaredSums: fixedUnitSumOfSquaredSums,
                    unitCount: units,
                    conditionCount: conditionCount
                )
            }
        }

        // F is non-negative, so clusters are grown without a sign constraint.
        let outcome = try ClusterPermutationAnalyzer.runPermutations(
            grid: grid,
            configuration: .init(
                permutationCount: configuration.permutationCount,
                threshold: configuration.threshold,
                inference: configuration.inference,
                tfce: configuration.tfce,
                seed: configuration.seed
            ),
            resolvedThreshold: resolvedThreshold,
            observed: observed,
            signed: false,
            progress: progress,
            statisticsForPermutation: permute
        )
        guard let outcome else { return nil }

        return Result(
            conditionNames: input.conditions.map(\.name),
            conditionCounts: conditionCounts,
            design: input.design,
            unitCount: unitCount,
            channelCount: input.channelCount,
            sampleCount: input.sampleCount,
            numeratorDegreesOfFreedom: numeratorDF,
            denominatorDegreesOfFreedom: denominatorDF,
            observedStatistics: observed,
            observedTFCEScores: outcome.tfceScores,
            pointPValues: outcome.pointPValues,
            resolvedThreshold: resolvedThreshold,
            clusters: outcome.clusters,
            nullMaximumClusterMasses: outcome.nullMaxima,
            configuration: configuration
        )
    }

    static func resolveThreshold(
        _ threshold: ClusterFormingThreshold,
        numeratorDegreesOfFreedom d1: Double,
        denominatorDegreesOfFreedom d2: Double
    ) -> Double? {
        switch threshold {
        case .statistic(let value):
            guard value.isFinite, value > 0 else { return nil }
            return value
        case .probability(let alpha):
            return ClusterStatisticsDistributions.criticalF(
                alpha: alpha,
                numeratorDegreesOfFreedom: d1,
                denominatorDegreesOfFreedom: d2
            )
        }
    }

    // MARK: - Statistics

    /// Conventional one-way ANOVA F at every channel/time feature.
    private static func independentFStatistics(
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

    /// One-way repeated-measures F. The error term is the condition x unit
    /// interaction, obtained by removing both main effects from the total.
    ///
    /// Sphericity is assumed, as it is by every uncorrected repeated-measures F.
    /// The permutation step corrects the *family-wise* error across the lattice;
    /// it does not repair a violated sphericity assumption within a feature. In
    /// practice this matters little here because the reference distribution is
    /// the permutation distribution of the same statistic rather than the
    /// tabulated F, so the test remains valid under exchangeability even where
    /// the tabulated F would not be.
    private static func repeatedMeasuresFStatistics(
        conditionSums: [[Double]],
        grandSums: [Double],
        totalSumSquares: [Double],
        unitSumOfSquaredSums: [Double],
        unitCount: Int,
        conditionCount: Int
    ) -> [Double] {
        let n = Double(unitCount)
        let k = Double(conditionCount)
        let conditionDF = k - 1
        let errorDF = (k - 1) * (n - 1)
        var result = [Double](repeating: 0, count: grandSums.count)
        guard unitCount > 1, conditionCount > 1, errorDF > 0 else { return result }
        let observationCount = n * k

        for feature in result.indices {
            let grand = grandSums[feature]
            let correction = grand * grand / observationCount

            var conditionCorrection = 0.0
            for condition in conditionSums.indices {
                let sum = conditionSums[condition][feature]
                conditionCorrection += sum * sum
            }
            conditionCorrection /= n

            let unitCorrection = unitSumOfSquaredSums[feature] / k

            let conditionSS = max(conditionCorrection - correction, 0)
            let totalSS = max(totalSumSquares[feature] - correction, 0)
            let unitSS = max(unitCorrection - correction, 0)
            let errorSS = max(totalSS - conditionSS - unitSS, 0)

            let denominator = errorSS / errorDF
            if denominator > 1e-15, denominator.isFinite {
                let value = (conditionSS / conditionDF) / denominator
                result[feature] = value.isFinite ? value : 0
            }
        }
        return result
    }

    private static func shuffle<R: RandomNumberGenerator>(_ values: inout [Int], using rng: inout R) {
        guard values.count > 1 else { return }
        for index in 0..<(values.count - 1) {
            let other = Int.random(in: index..<values.count, using: &rng)
            if index != other { values.swapAt(index, other) }
        }
    }
}
