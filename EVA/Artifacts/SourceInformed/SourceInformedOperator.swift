//
//  SourceInformedOperator.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

/// Numerical provenance for one source-informed sensor-space operator.
nonisolated struct SourceInformedOperatorDiagnostics: Codable, Equatable, Sendable {
    var electrodeCount: Int
    var brainColumnCount: Int
    var artifactInputCount: Int
    var artifactRetainedCount: Int
    var artifactDroppedCount: Int
    var requestedBrainRegularization: Double
    var projectedBrainMeanColumnPower: Double
    var effectiveRidge: Double
    var minimumCholeskyDiagonal: Double
    var maximumCholeskyDiagonal: Double
}

/// A square sensor-space operator and the numerical facts needed to audit it.
nonisolated struct SourceInformedOperator: Codable, Equatable, Sendable {
    /// electrodes × electrodes, in the same ordered identity as the input basis.
    var matrix: [[Double]]
    var diagnostics: SourceInformedOperatorDiagnostics
}

nonisolated enum SourceInformedOperatorError: Error, Equatable, LocalizedError, Sendable {
    case emptyBrainBasis
    case raggedBrainBasis
    case nonFiniteBrainBasis
    case zeroNormBrainColumn(index: Int)
    case artifactChannelMismatch(expected: Int, found: Int)
    case nonFiniteArtifactTopography(index: Int)
    case invalidRegularization(Double)
    case noProjectedBrainEnergy
    case regularizedSystemNotPositiveDefinite
    case regularizedSolveFailed
    case nonFiniteOperator
    case malformedOperator
    case emptySignal
    case signalChannelMismatch(expected: Int, found: Int)
    case raggedSignal
    case nonFiniteSignal
    case nonFiniteOutput

    var errorDescription: String? {
        switch self {
        case .emptyBrainBasis:
            "The source-informed brain basis is empty."
        case .raggedBrainBasis:
            "The source-informed brain basis has inconsistent row lengths."
        case .nonFiniteBrainBasis:
            "The source-informed brain basis contains a non-finite value."
        case let .zeroNormBrainColumn(index):
            "Brain-basis column \(index) has zero numerical norm."
        case let .artifactChannelMismatch(expected, found):
            "An artifact topography has \(found) channels; expected \(expected)."
        case let .nonFiniteArtifactTopography(index):
            "Artifact topography \(index) contains a non-finite value."
        case let .invalidRegularization(value):
            "Brain regularization must be finite and non-negative; found \(value)."
        case .noProjectedBrainEnergy:
            "The artifact subspace removes all numerical energy from the brain basis."
        case .regularizedSystemNotPositiveDefinite:
            "The regularized source-informed system is not positive definite."
        case .regularizedSolveFailed:
            "The regularized source-informed system could not be solved."
        case .nonFiniteOperator:
            "The source-informed operator contains a non-finite value."
        case .malformedOperator:
            "The source-informed operator is not a finite square matrix."
        case .emptySignal:
            "The signal supplied to the source-informed operator is empty."
        case let .signalChannelMismatch(expected, found):
            "The signal has \(found) channels; the operator requires \(expected)."
        case .raggedSignal:
            "The signal supplied to the source-informed operator is ragged or has no samples."
        case .nonFiniteSignal:
            "The signal supplied to the source-informed operator contains a non-finite value."
        case .nonFiniteOutput:
            "Applying the source-informed operator produced a non-finite value."
        }
    }
}

/// UI-free construction and application of the PCA-S/MSEC family operator.
/// Artifact discovery is intentionally outside this type.
nonisolated enum SourceInformedSeparation {
    static func makeOperator(
        brainBasis: [[Double]],
        artifactTopographies: [[Double]],
        brainRegularization: Double
    ) throws -> SourceInformedOperator {
        let electrodeCount = brainBasis.count
        guard electrodeCount > 0 else { throw SourceInformedOperatorError.emptyBrainBasis }
        let brainColumnCount = brainBasis.first?.count ?? 0
        guard brainColumnCount > 0 else { throw SourceInformedOperatorError.emptyBrainBasis }
        guard brainBasis.allSatisfy({ $0.count == brainColumnCount }) else {
            throw SourceInformedOperatorError.raggedBrainBasis
        }
        guard brainBasis.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw SourceInformedOperatorError.nonFiniteBrainBasis
        }
        guard brainRegularization.isFinite, brainRegularization >= 0 else {
            throw SourceInformedOperatorError.invalidRegularization(brainRegularization)
        }
        for (index, topography) in artifactTopographies.enumerated() {
            guard topography.count == electrodeCount else {
                throw SourceInformedOperatorError.artifactChannelMismatch(
                    expected: electrodeCount, found: topography.count
                )
            }
            guard topography.allSatisfy(\.isFinite) else {
                throw SourceInformedOperatorError.nonFiniteArtifactTopography(index: index)
            }
        }

        var normalizedBrain = [[Double]](
            repeating: [Double](repeating: 0, count: brainColumnCount),
            count: electrodeCount
        )
        for column in 0..<brainColumnCount {
            var squaredNorm = 0.0
            for electrode in 0..<electrodeCount {
                let value = brainBasis[electrode][column]
                squaredNorm += value * value
            }
            let norm = squaredNorm.squareRoot()
            guard norm > 1e-30 else {
                throw SourceInformedOperatorError.zeroNormBrainColumn(index: column)
            }
            for electrode in 0..<electrodeCount {
                normalizedBrain[electrode][column] = brainBasis[electrode][column] / norm
            }
        }

        // Modified Gram-Schmidt with a second pass prevents nearly collinear
        // caller-supplied topographies from leaving a meaningful residual.
        var artifactBasis: [[Double]] = []
        for topography in artifactTopographies {
            var vector = topography
            for _ in 0..<2 {
                for existing in artifactBasis {
                    let projection = LinearAlgebra.dot(vector, existing)
                    for index in vector.indices { vector[index] -= projection * existing[index] }
                }
            }
            let norm = LinearAlgebra.dot(vector, vector).squareRoot()
            guard norm > 1e-12 else { continue }
            artifactBasis.append(vector.map { $0 / norm })
        }

        func projectOutArtifacts(_ vector: [Double]) -> [Double] {
            var result = vector
            for component in artifactBasis {
                let projection = LinearAlgebra.dot(result, component)
                for index in result.indices { result[index] -= projection * component[index] }
            }
            return result
        }

        var projectedBrain = [[Double]](
            repeating: [Double](repeating: 0, count: brainColumnCount),
            count: electrodeCount
        )
        for column in 0..<brainColumnCount {
            let projected = projectOutArtifacts(
                (0..<electrodeCount).map { normalizedBrain[$0][column] }
            )
            for electrode in 0..<electrodeCount {
                projectedBrain[electrode][column] = projected[electrode]
            }
        }

        var system = [[Double]](
            repeating: [Double](repeating: 0, count: brainColumnCount),
            count: brainColumnCount
        )
        for row in 0..<brainColumnCount {
            for column in row..<brainColumnCount {
                var sum = 0.0
                for electrode in 0..<electrodeCount {
                    sum += projectedBrain[electrode][row] * projectedBrain[electrode][column]
                }
                system[row][column] = sum
                system[column][row] = sum
            }
        }
        let meanColumnPower = (0..<brainColumnCount).reduce(0.0) {
            $0 + system[$1][$1]
        } / Double(brainColumnCount)
        guard meanColumnPower.isFinite, meanColumnPower > 1e-30 else {
            throw SourceInformedOperatorError.noProjectedBrainEnergy
        }
        let effectiveRidge = max(
            brainRegularization * meanColumnPower,
            1e-12 * meanColumnPower
        )
        for column in 0..<brainColumnCount { system[column][column] += effectiveRidge }

        guard let factor = LinearAlgebra.factorSymmetricPositiveDefinite(system) else {
            throw SourceInformedOperatorError.regularizedSystemNotPositiveDefinite
        }
        let rightHandSides = LinearAlgebra.transpose(projectedBrain)
        guard let brainWeights = factor.solve(rightHandSides) else {
            throw SourceInformedOperatorError.regularizedSolveFailed
        }

        var matrix = [[Double]](
            repeating: [Double](repeating: 0, count: electrodeCount),
            count: electrodeCount
        )
        for row in 0..<electrodeCount {
            for column in 0..<electrodeCount {
                var sum = 0.0
                for basisColumn in 0..<brainColumnCount {
                    sum += normalizedBrain[row][basisColumn] * brainWeights[basisColumn][column]
                }
                matrix[row][column] = sum
            }
        }
        guard matrix.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw SourceInformedOperatorError.nonFiniteOperator
        }

        let factorMinimum = factor.factorDiagonal.min() ?? .nan
        let factorMaximum = factor.factorDiagonal.max() ?? .nan
        return SourceInformedOperator(
            matrix: matrix,
            diagnostics: SourceInformedOperatorDiagnostics(
                electrodeCount: electrodeCount,
                brainColumnCount: brainColumnCount,
                artifactInputCount: artifactTopographies.count,
                artifactRetainedCount: artifactBasis.count,
                artifactDroppedCount: artifactTopographies.count - artifactBasis.count,
                requestedBrainRegularization: brainRegularization,
                projectedBrainMeanColumnPower: meanColumnPower,
                effectiveRidge: effectiveRidge,
                minimumCholeskyDiagonal: factorMinimum,
                maximumCholeskyDiagonal: factorMaximum
            )
        )
    }

    static func apply(
        _ sourceInformedOperator: SourceInformedOperator,
        to signal: [[Double]]
    ) throws -> [[Double]] {
        try apply(matrix: sourceInformedOperator.matrix, to: signal)
    }

    /// Applies a persisted or boundary-adapted operator when its construction
    /// diagnostics travel separately. The same strict matrix/signal validation
    /// is used by the value-typed overload above.
    static func apply(
        matrix: [[Double]],
        to signal: [[Double]]
    ) throws -> [[Double]] {
        let electrodeCount = matrix.count
        guard electrodeCount > 0,
              matrix.allSatisfy({ $0.count == electrodeCount && $0.allSatisfy(\.isFinite) })
        else { throw SourceInformedOperatorError.malformedOperator }
        guard !signal.isEmpty else { throw SourceInformedOperatorError.emptySignal }
        guard signal.count == electrodeCount else {
            throw SourceInformedOperatorError.signalChannelMismatch(
                expected: electrodeCount, found: signal.count
            )
        }
        let sampleCount = signal.first?.count ?? 0
        guard sampleCount > 0, signal.allSatisfy({ $0.count == sampleCount }) else {
            throw SourceInformedOperatorError.raggedSignal
        }
        guard signal.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw SourceInformedOperatorError.nonFiniteSignal
        }

        var output = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount), count: electrodeCount
        )
        for row in 0..<electrodeCount {
            for column in 0..<electrodeCount {
                let weight = matrix[row][column]
                guard weight != 0 else { continue }
                for sample in 0..<sampleCount {
                    output[row][sample] += weight * signal[column][sample]
                }
            }
        }
        guard output.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw SourceInformedOperatorError.nonFiniteOutput
        }
        return output
    }
}
