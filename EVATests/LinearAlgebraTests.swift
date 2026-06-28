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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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
}
