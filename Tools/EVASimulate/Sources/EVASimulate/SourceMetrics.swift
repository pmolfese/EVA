//
//  SourceMetrics.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Ground-truth scoring for source locations and recovered component signals.
//  Both use minimum-cost bipartite assignment, so an inverse method or ICA is
//  not penalized merely for returning its sources in a different order.
//

import Foundation

nonisolated struct EstimatedSource: Codable, Sendable {
    var id: String? = nil
    var positionMeters: Vector3D
    var orientation: Vector3D? = nil
}

nonisolated struct EstimatedSourceSet: Codable, Sendable {
    var sources: [EstimatedSource]
}

nonisolated struct SourceLocationMatch: Codable, Sendable {
    var trueSourceID: String
    var estimatedSourceID: String
    var distanceMillimeters: Double
    /// Axial error: p and -p are equivalent because a recovered waveform may
    /// absorb the sign flip. Nil when the estimate did not provide orientation.
    var orientationErrorDegrees: Double?
}

nonisolated struct SourceLocationScore: Codable, Sendable {
    var matchedCount: Int
    var missedTrueSources: Int
    var extraEstimatedSources: Int
    var meanDistanceMillimeters: Double
    var medianDistanceMillimeters: Double
    var maximumDistanceMillimeters: Double
    var meanOrientationErrorDegrees: Double?
    var matches: [SourceLocationMatch]
}

nonisolated struct SourceRecoveryMatch: Codable, Sendable {
    var trueSourceID: String
    var recoveredComponent: String
    var correlation: Double
    var absoluteCorrelation: Double
}

nonisolated struct SourceRecoveryScore: Codable, Sendable {
    var matchedCount: Int
    var missedTrueSources: Int
    var extraRecoveredComponents: Int
    var meanAbsoluteCorrelation: Double
    var medianAbsoluteCorrelation: Double
    var minimumAbsoluteCorrelation: Double
    var matches: [SourceRecoveryMatch]
}

nonisolated struct SourceScoreReport: Codable, Sendable {
    var location: SourceLocationScore?
    var recovery: SourceRecoveryScore?
}

nonisolated enum SourceMetrics {
    static func locationScore(
        truth: [SimulatedSource],
        estimated: [EstimatedSource]
    ) -> SourceLocationScore {
        let costs = truth.map { trueSource in
            estimated.map { estimate in
                (trueSource.positionMeters - estimate.positionMeters).norm
            }
        }
        let pairs = minimumCostPairs(costs).sorted { $0.row < $1.row }
        let matches = pairs.map { pair -> SourceLocationMatch in
            let trueSource = truth[pair.row]
            let estimate = estimated[pair.column]
            let orientationError: Double?
            if let orientation = estimate.orientation, orientation.norm > 1e-15 {
                let cosine = max(-1, min(1, abs(
                    trueSource.orientation.dot(orientation.normalized())
                )))
                orientationError = acos(cosine) * 180 / Double.pi
            } else {
                orientationError = nil
            }
            return SourceLocationMatch(
                trueSourceID: trueSource.id,
                estimatedSourceID: estimate.id ?? "estimated-\(pair.column + 1)",
                distanceMillimeters: costs[pair.row][pair.column] * 1000,
                orientationErrorDegrees: orientationError
            )
        }
        let distances = matches.map(\.distanceMillimeters)
        let orientationErrors = matches.compactMap(\.orientationErrorDegrees)
        return SourceLocationScore(
            matchedCount: matches.count,
            missedTrueSources: max(0, truth.count - matches.count),
            extraEstimatedSources: max(0, estimated.count - matches.count),
            meanDistanceMillimeters: mean(distances),
            medianDistanceMillimeters: median(distances),
            maximumDistanceMillimeters: distances.max() ?? 0,
            meanOrientationErrorDegrees: orientationErrors.isEmpty ? nil : mean(orientationErrors),
            matches: matches
        )
    }

    static func recoveryScore(
        trueIDs: [String],
        trueSignals: [[Double]],
        recoveredNames: [String],
        recoveredSignals: [[Double]]
    ) -> SourceRecoveryScore {
        let signed = trueSignals.map { truth in
            recoveredSignals.map { DipoleEEGGenerator.pearson(truth, $0) }
        }
        let costs = signed.map { $0.map { 1 - abs($0) } }
        let pairs = minimumCostPairs(costs).sorted { $0.row < $1.row }
        let matches = pairs.map { pair -> SourceRecoveryMatch in
            let correlation = signed[pair.row][pair.column]
            return SourceRecoveryMatch(
                trueSourceID: pair.row < trueIDs.count ? trueIDs[pair.row] : "S\(pair.row + 1)",
                recoveredComponent: pair.column < recoveredNames.count
                    ? recoveredNames[pair.column]
                    : "component-\(pair.column + 1)",
                correlation: correlation,
                absoluteCorrelation: abs(correlation)
            )
        }
        let correlations = matches.map(\.absoluteCorrelation)
        return SourceRecoveryScore(
            matchedCount: matches.count,
            missedTrueSources: max(0, trueSignals.count - matches.count),
            extraRecoveredComponents: max(0, recoveredSignals.count - matches.count),
            meanAbsoluteCorrelation: mean(correlations),
            medianAbsoluteCorrelation: median(correlations),
            minimumAbsoluteCorrelation: correlations.min() ?? 0,
            matches: matches
        )
    }

    /// Rectangular Hungarian assignment. Returns min(rows, columns) pairs.
    static func minimumCostPairs(_ costs: [[Double]]) -> [(row: Int, column: Int)] {
        let rowCount = costs.count
        let columnCount = costs.first?.count ?? 0
        guard rowCount > 0, columnCount > 0,
              costs.allSatisfy({ $0.count == columnCount }) else { return [] }
        if rowCount <= columnCount {
            return hungarianRows(costs)
        }
        let transposed = (0..<columnCount).map { column in
            (0..<rowCount).map { row in costs[row][column] }
        }
        return hungarianRows(transposed).map { (row: $0.column, column: $0.row) }
    }

    /// Requires rows <= columns.
    private static func hungarianRows(_ costs: [[Double]]) -> [(row: Int, column: Int)] {
        let rows = costs.count
        let columns = costs[0].count
        var rowPotential = [Double](repeating: 0, count: rows + 1)
        var columnPotential = [Double](repeating: 0, count: columns + 1)
        var matchedRow = [Int](repeating: 0, count: columns + 1)
        var previousColumn = [Int](repeating: 0, count: columns + 1)

        for row in 1...rows {
            matchedRow[0] = row
            var currentColumn = 0
            var minimum = [Double](repeating: .infinity, count: columns + 1)
            var used = [Bool](repeating: false, count: columns + 1)
            repeat {
                used[currentColumn] = true
                let currentRow = matchedRow[currentColumn]
                var delta = Double.infinity
                var nextColumn = 0
                for column in 1...columns where !used[column] {
                    let reduced = costs[currentRow - 1][column - 1]
                        - rowPotential[currentRow] - columnPotential[column]
                    if reduced < minimum[column] {
                        minimum[column] = reduced
                        previousColumn[column] = currentColumn
                    }
                    if minimum[column] < delta {
                        delta = minimum[column]
                        nextColumn = column
                    }
                }
                for column in 0...columns {
                    if used[column] {
                        rowPotential[matchedRow[column]] += delta
                        columnPotential[column] -= delta
                    } else {
                        minimum[column] -= delta
                    }
                }
                currentColumn = nextColumn
            } while matchedRow[currentColumn] != 0

            repeat {
                let previous = previousColumn[currentColumn]
                matchedRow[currentColumn] = matchedRow[previous]
                currentColumn = previous
            } while currentColumn != 0
        }

        var result: [(row: Int, column: Int)] = []
        for column in 1...columns where matchedRow[column] > 0 {
            result.append((matchedRow[column] - 1, column - 1))
        }
        return result
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

