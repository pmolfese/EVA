//
//  LinearAlgebraTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Testing
import Foundation
@testable import EVA

struct LinearAlgebraTests {

    @Test func dotProduct() {
        #expect(LinearAlgebra.dot([1, 2, 3], [4, 5, 6]) == 32)
        #expect(LinearAlgebra.dot([], []) == 0)
    }

    @Test func identityIsDiagonalOnes() {
        let identity = LinearAlgebra.identity(3)
        for i in 0..<3 {
            for j in 0..<3 {
                #expect(identity[i][j] == (i == j ? 1 : 0))
            }
        }
    }

    @Test func transposeSwapsRowsAndColumns() {
        let matrix = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
        let transposed = LinearAlgebra.transpose(matrix)
        #expect(transposed == [[1, 4], [2, 5], [3, 6]])
    }

    @Test func solveLinearSystemRecoversKnownSolution() {
        // 2x + y = 5 ; x + 3y = 10  ->  x = 1, y = 3
        let a = [[2.0, 1.0], [1.0, 3.0]]
        let b = [5.0, 10.0]
        let solution = LinearAlgebra.solveLinearSystem(a, b)
        let x = try! #require(solution)
        #expect(abs(x[0] - 1) < 1e-9)
        #expect(abs(x[1] - 3) < 1e-9)
    }

    @Test func solveLinearSystemReturnsNilForSingular() {
        // Rows are linearly dependent -> no unique solution.
        let a = [[1.0, 2.0], [2.0, 4.0]]
        let b = [3.0, 6.0]
        #expect(LinearAlgebra.solveLinearSystem(a, b) == nil)
    }

    @Test func choleskyFactorSolvesSeveralRightHandSides() throws {
        let matrix = [[4.0, 1.0], [1.0, 3.0]]
        let factor = try #require(LinearAlgebra.factorSymmetricPositiveDefinite(matrix))
        let solution = try #require(factor.solve([[1.0, 2.0], [2.0, 1.0]]))

        for rightHandSide in 0..<2 {
            for row in 0..<2 {
                let recovered = (0..<2).reduce(0.0) {
                    $0 + matrix[row][$1] * solution[$1][rightHandSide]
                }
                let expected = [[1.0, 2.0], [2.0, 1.0]][row][rightHandSide]
                #expect(abs(recovered - expected) < 1e-12)
            }
        }
        #expect(factor.factorDiagonal.allSatisfy { $0 > 0 && $0.isFinite })
    }

    @Test func choleskyFactorRejectsNonPositiveDefiniteAndAsymmetricInput() {
        #expect(LinearAlgebra.factorSymmetricPositiveDefinite([[1.0, 2.0], [2.0, 1.0]]) == nil)
        #expect(LinearAlgebra.factorSymmetricPositiveDefinite([[2.0, 1.0], [0.0, 2.0]]) == nil)
    }

    @Test func symmetricEigenDecompositionMatchesDiagonal() {
        // Eigenvalues of a diagonal matrix are its diagonal entries.
        let matrix = [[2.0, 0.0, 0.0], [0.0, 5.0, 0.0], [0.0, 0.0, 9.0]]
        let result = LinearAlgebra.symmetricEigenDecomposition(matrix)
        #expect(result.values.sorted() == [2, 5, 9])
    }

    @Test func symmetricEigenDecompositionReconstructsMatrix() {
        // A symmetric matrix must satisfy A ≈ V · diag(λ) · Vᵀ.
        let a = [[4.0, 1.0, 0.0], [1.0, 3.0, 1.0], [0.0, 1.0, 2.0]]
        let (values, vectors) = LinearAlgebra.symmetricEigenDecomposition(a)
        let n = a.count

        // Eigenvectors are stored as columns: vectors[i][k] is component i of the
        // k-th eigenvector. Reconstruct A = Σ_k λ_k · v_k · v_kᵀ.
        var reconstructed = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for k in 0..<n {
            for i in 0..<n {
                for j in 0..<n {
                    reconstructed[i][j] += values[k] * vectors[i][k] * vectors[j][k]
                }
            }
        }

        var maxError = 0.0
        for i in 0..<n {
            for j in 0..<n {
                maxError = max(maxError, abs(reconstructed[i][j] - a[i][j]))
            }
        }
        #expect(maxError < 1e-6, "reconstruction error \(maxError)")
    }

    @Test func eigenvectorsAreOrthonormal() {
        let a = [[4.0, 1.0, 0.0], [1.0, 3.0, 1.0], [0.0, 1.0, 2.0]]
        let (_, vectors) = LinearAlgebra.symmetricEigenDecomposition(a)
        let n = a.count
        // Pull eigenvectors out as columns before checking orthonormality.
        let columns = (0..<n).map { k in (0..<n).map { i in vectors[i][k] } }
        for i in 0..<n {
            #expect(abs(LinearAlgebra.dot(columns[i], columns[i]) - 1) < 1e-6)
            for j in (i + 1)..<n {
                #expect(abs(LinearAlgebra.dot(columns[i], columns[j])) < 1e-6)
            }
        }
    }

    // MARK: - Truncated eigen-decomposition

    /// A matrix with a known spectrum, built as `sum lambda_k v_k v_k^T` from an
    /// orthonormal basis, so the eigenvalues are exactly what was put in.
    private func matrix(withEigenvalues values: [Double]) -> [[Double]] {
        let n = values.count
        // Orthonormal DCT-II basis: cheap to write down and exactly orthogonal.
        let basis = (0..<n).map { k in
            (0..<n).map { i -> Double in
                let scale = (k == 0 ? 1.0 : 2.0) / Double(n)
                return scale.squareRoot() * cos(.pi * Double(k) * (Double(i) + 0.5) / Double(n))
            }
        }
        var result = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for k in 0..<n {
            for i in 0..<n {
                for j in 0..<n {
                    result[i][j] += values[k] * basis[k][i] * basis[k][j]
                }
            }
        }
        return result
    }

    @Test func leadingEigenpairsMatchTheKnownSpectrum() throws {
        let spectrum = [50.0, 20.0, 9.0, 4.0, 1.0, 0.25, 0.1, 0.01]
        let a = matrix(withEigenvalues: spectrum)
        let (values, vectors) = LinearAlgebra.leadingSymmetricEigenpairs(a, count: 3)

        #expect(values.count == 3)
        #expect(vectors.count == 3)
        // Descending, and the three largest of what was put in.
        for (found, expected) in zip(values, [50.0, 20.0, 9.0]) {
            #expect(abs(found - expected) < 1e-8, "eigenvalue \(found) vs \(expected)")
        }
        for vector in vectors {
            #expect(abs(LinearAlgebra.dot(vector, vector) - 1) < 1e-9)
        }
        #expect(abs(LinearAlgebra.dot(vectors[0], vectors[1])) < 1e-9)
        #expect(abs(LinearAlgebra.dot(vectors[0], vectors[2])) < 1e-9)
    }

    /// The point of the truncated path: it must agree with the full
    /// decomposition, not merely be plausible. Signs are arbitrary, so the
    /// comparison is on the eigenvalues and on `A v = lambda v`.
    @Test func leadingEigenpairsAgreeWithTheFullDecomposition() {
        let a = matrix(withEigenvalues: (0..<12).map { 100.0 / Double($0 + 1) })
        let full = LinearAlgebra.symmetricEigenDecomposition(a)
        let leading = LinearAlgebra.leadingSymmetricEigenpairs(a, count: 4)

        // The full solver returns ascending values; the leading ones are last.
        let expected = full.values.suffix(4).reversed()
        for (found, want) in zip(leading.values, expected) {
            #expect(abs(found - want) < 1e-8, "\(found) vs \(want)")
        }
        for (index, vector) in leading.vectors.enumerated() {
            let product = (0..<a.count).map { row in
                LinearAlgebra.dot(a[row], vector)
            }
            for row in 0..<a.count {
                #expect(abs(product[row] - leading.values[index] * vector[row]) < 1e-7,
                        "A v != lambda v at component \(index) row \(row)")
            }
        }
    }

    @Test func leadingEigenpairsHandleDegenerateRequests() {
        let a = [[4.0, 1.0, 0.0], [1.0, 3.0, 1.0], [0.0, 1.0, 2.0]]
        #expect(LinearAlgebra.leadingSymmetricEigenpairs(a, count: 0).values.isEmpty)
        #expect(LinearAlgebra.leadingSymmetricEigenpairs(a, count: -1).values.isEmpty)
        #expect(LinearAlgebra.leadingSymmetricEigenpairs([], count: 2).values.isEmpty)
        // Asking for more than the matrix has returns everything, not a failure.
        #expect(LinearAlgebra.leadingSymmetricEigenpairs(a, count: 9).values.count == 3)
        // A ragged matrix is rejected rather than read out of bounds.
        #expect(LinearAlgebra.leadingSymmetricEigenpairs([[1.0, 2.0], [3.0]], count: 1).values.isEmpty)
    }

    @Test func leadingEigenpairsOfARankDeficientMatrix() {
        // Rank 2 in a 5x5: the trailing eigenvalues are zero and must not be
        // mistaken for the leading ones.
        let a = matrix(withEigenvalues: [7.0, 3.0, 0, 0, 0])
        let (values, _) = LinearAlgebra.leadingSymmetricEigenpairs(a, count: 3)
        #expect(values.count == 3)
        #expect(abs(values[0] - 7) < 1e-9)
        #expect(abs(values[1] - 3) < 1e-9)
        #expect(abs(values[2]) < 1e-9)
    }
}
