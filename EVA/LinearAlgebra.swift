//
//  LinearAlgebra.swift
//  EVA
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

import Accelerate
import Foundation

nonisolated enum LinearAlgebra {
    static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count else { return 0 }
        var total = 0.0
        for index in lhs.indices {
            total += lhs[index] * rhs[index]
        }
        return total
    }

    static func identity(_ size: Int) -> [[Double]] {
        (0..<size).map { row in
            (0..<size).map { row == $0 ? 1.0 : 0.0 }
        }
    }

    static func transpose(_ matrix: [[Double]]) -> [[Double]] {
        guard let columns = matrix.first?.count else { return [] }
        return (0..<columns).map { column in
            matrix.map { $0[column] }
        }
    }

    static func solveLinearSystem(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = matrix.count
        guard n > 0, rhs.count == n, matrix.allSatisfy({ $0.count == n }) else { return nil }

        var a = matrix
        var b = rhs
        for pivot in 0..<n {
            var bestRow = pivot
            var bestValue = abs(a[pivot][pivot])
            for row in (pivot + 1)..<n {
                let value = abs(a[row][pivot])
                if value > bestValue {
                    bestValue = value
                    bestRow = row
                }
            }
            guard bestValue > 1e-12 else { return nil }

            if bestRow != pivot {
                a.swapAt(bestRow, pivot)
                b.swapAt(bestRow, pivot)
            }

            let divisor = a[pivot][pivot]
            for column in pivot..<n {
                a[pivot][column] /= divisor
            }
            b[pivot] /= divisor

            for row in 0..<n where row != pivot {
                let factor = a[row][pivot]
                guard abs(factor) > 0 else { continue }
                for column in pivot..<n {
                    a[row][column] -= factor * a[pivot][column]
                }
                b[row] -= factor * b[pivot]
            }
        }
        return b
    }

    static func solveLinearSystem(a: inout [Double], b: inout [Double], size: Int) -> [Double]? {
        for col in 0..<size {
            var pivotRow = col
            var pivotMag = abs(a[col * size + col])
            for r in (col + 1)..<size {
                let mag = abs(a[r * size + col])
                if mag > pivotMag {
                    pivotMag = mag
                    pivotRow = r
                }
            }
            guard pivotMag > 1e-12 else { return nil }

            if pivotRow != col {
                for c in 0..<size {
                    a.swapAt(pivotRow * size + c, col * size + c)
                }
                b.swapAt(pivotRow, col)
            }

            let pivot = a[col * size + col]
            for r in 0..<size where r != col {
                let factor = a[r * size + col] / pivot
                if factor == 0 { continue }
                for c in col..<size {
                    a[r * size + c] -= factor * a[col * size + c]
                }
                b[r] -= factor * b[col]
            }
        }

        var x = [Double](repeating: 0, count: size)
        for index in 0..<size {
            x[index] = b[index] / a[index * size + index]
        }
        return x
    }

    static func symmetricEigenDecomposition(_ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else {
            return ([], [])
        }

        var columnMajor = Array(repeating: 0.0, count: n * n)
        for row in 0..<n {
            for column in 0..<n {
                columnMajor[column * n + row] = matrix[row][column]
            }
        }

        var eigenvalues = Array(repeating: 0.0, count: n)
        var jobz = Int8(UnicodeScalar("V").value)
        var uplo = Int8(UnicodeScalar("U").value)
        var dimension = __CLPK_integer(n)
        var leadingDimension = __CLPK_integer(n)
        var queryWork = 0.0
        var querySize = __CLPK_integer(-1)
        var info = __CLPK_integer(0)

        dsyev_(
            &jobz,
            &uplo,
            &dimension,
            &columnMajor,
            &leadingDimension,
            &eigenvalues,
            &queryWork,
            &querySize,
            &info
        )

        guard info == 0 else {
            return jacobiEigenDecomposition(matrix)
        }

        var workSize = __CLPK_integer(max(Int(queryWork.rounded(.up)), 3 * n - 1))
        var work = Array(repeating: 0.0, count: Int(workSize))
        info = 0

        dsyev_(
            &jobz,
            &uplo,
            &dimension,
            &columnMajor,
            &leadingDimension,
            &eigenvalues,
            &work,
            &workSize,
            &info
        )

        guard info == 0 else {
            return jacobiEigenDecomposition(matrix)
        }

        let eigenvectors = (0..<n).map { row in
            (0..<n).map { column in
                columnMajor[column * n + row]
            }
        }
        return (eigenvalues, eigenvectors)
    }

    private static func jacobiEigenDecomposition(_ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let n = matrix.count
        guard n > 0 else { return ([], []) }
        guard n > 1 else { return ([matrix[0][0]], [[1]]) }
        var a = matrix
        var v = identity(n)
        let maxIterations = max(100, n * n * 8)

        for _ in 0..<maxIterations {
            var p = 0
            var q = min(1, n - 1)
            var maxValue = 0.0
            for row in 0..<n {
                for column in (row + 1)..<n {
                    let value = abs(a[row][column])
                    if value > maxValue {
                        maxValue = value
                        p = row
                        q = column
                    }
                }
            }
            if maxValue < 1e-10 { break }

            let app = a[p][p]
            let aqq = a[q][q]
            let apq = a[p][q]
            let tau = (aqq - app) / (2 * apq)
            let t = (tau >= 0 ? 1.0 : -1.0) / (abs(tau) + sqrt(1 + tau * tau))
            let c = 1.0 / sqrt(1 + t * t)
            let s = t * c

            for k in 0..<n where k != p && k != q {
                let akp = a[k][p]
                let akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[p][k] = a[k][p]
                a[k][q] = s * akp + c * akq
                a[q][k] = a[k][q]
            }

            a[p][p] = c * c * app - 2 * s * c * apq + s * s * aqq
            a[q][q] = s * s * app + 2 * s * c * apq + c * c * aqq
            a[p][q] = 0
            a[q][p] = 0

            for k in 0..<n {
                let vkp = v[k][p]
                let vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }

        return ((0..<n).map { a[$0][$0] }, v)
    }
}
