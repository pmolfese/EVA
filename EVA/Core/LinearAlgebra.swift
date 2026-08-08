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

    /// Solves A·x = b for a `size × size` row-major flat matrix `a`
    /// (`a[row*size+col]`) via LAPACK's `dgesv_` (general LU with partial
    /// pivoting) — falls back to a pure-Swift Gauss-Jordan elimination if
    /// LAPACK reports the system singular/ill-conditioned (`info != 0`) or
    /// isn't available. `dgesv_` alone is roughly a 10-50x speedup over the
    /// naive Swift loop at the ~100-250 dimension `SphericalSpline` calls this
    /// with (unvectorized O(n³) Swift vs. BLAS-backed LAPACK), which is the
    /// dominant per-epoch cost for per-epoch bad-channel interpolation.
    static func solveLinearSystem(a: inout [Double], b: inout [Double], size: Int) -> [Double]? {
        guard size > 0 else { return nil }
        if let solved = solveLinearSystemLAPACK(a: a, b: b, size: size) {
            return solved
        }
        return solveLinearSystemGaussJordan(a: &a, b: &b, size: size)
    }

    /// A reusable LU factorization of a `size × size` matrix (via LAPACK
    /// `dgetrf_`), so multiple right-hand sides against the SAME matrix can
    /// each be solved in O(n²) (`dgetrs_`) instead of O(n³) apiece. This is
    /// the shared-factorization counterpart to `solveLinearSystem(a:b:size:)`
    /// — worth it whenever several right-hand-side vectors share one matrix,
    /// which is exactly `SphericalSpline`'s case when several channels are
    /// bad in the same epoch: the system matrix depends only on the "good"
    /// electrode set (shared across all of them), only the right-hand side
    /// (which depends on the target electrode) differs.
    final class LUFactorization: @unchecked Sendable {
        private let columnMajorLU: [Double]
        private let ipiv: [LAPACKInt]
        private let size: Int

        fileprivate init(columnMajorLU: [Double], ipiv: [LAPACKInt], size: Int) {
            self.columnMajorLU = columnMajorLU
            self.ipiv = ipiv
            self.size = size
        }

        /// Solves A·x = b using the cached factorization. O(n²).
        func solve(_ b: [Double]) -> [Double]? {
            guard b.count == size else { return nil }
            return solve(b, rightHandSideCount: 1)
        }

        /// Solves A·X = B for several right-hand sides using the cached
        /// factorization. `b` is column-major with `size` rows and
        /// `rightHandSideCount` columns, matching LAPACK's `dgetrs_`.
        func solve(_ b: [Double], rightHandSideCount: Int) -> [Double]? {
            guard rightHandSideCount > 0, b.count == size * rightHandSideCount else { return nil }
            var lu = columnMajorLU
            var pivots = ipiv
            var rhs = b
            var trans = Int8(UnicodeScalar("N").value)
            var n = LAPACKInt(size)
            var nrhs = LAPACKInt(rightHandSideCount)
            var lda = LAPACKInt(size)
            var ldb = LAPACKInt(size)
            var info: LAPACKInt = 0

            dgetrs_(&trans, &n, &nrhs, &lu, &lda, &pivots, &rhs, &ldb, &info)

            guard info == 0 else { return nil }
            return rhs
        }
    }

    /// Factors a `size × size` row-major flat matrix `a` (`a[row*size+col]`)
    /// once via LAPACK `dgetrf_`. Returns `nil` if singular or LAPACK is
    /// unavailable — callers should fall back to `solveLinearSystem(a:b:size:)`
    /// per right-hand side in that case.
    static func factorLinearSystem(a: [Double], size: Int) -> LUFactorization? {
        guard size > 0 else { return nil }
        var columnMajor = [Double](repeating: 0, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                columnMajor[column * size + row] = a[row * size + column]
            }
        }
        var m = LAPACKInt(size)
        var n = LAPACKInt(size)
        var lda = LAPACKInt(size)
        var ipiv = [LAPACKInt](repeating: 0, count: size)
        var info: LAPACKInt = 0

        dgetrf_(&m, &n, &columnMajor, &lda, &ipiv, &info)

        guard info == 0 else { return nil }
        return LUFactorization(columnMajorLU: columnMajor, ipiv: ipiv, size: size)
    }

    private static func solveLinearSystemLAPACK(a: [Double], b: [Double], size: Int) -> [Double]? {
        // dgesv_ expects column-major storage; `a` here is row-major
        // (a[row*size+col]). Transposing is O(n²), negligible next to the
        // O(n³) solve it enables using LAPACK for.
        var columnMajor = [Double](repeating: 0, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                columnMajor[column * size + row] = a[row * size + column]
            }
        }
        var rhs = b
        var n = LAPACKInt(size)
        var nrhs = LAPACKInt(1)
        var lda = LAPACKInt(size)
        var ipiv = [LAPACKInt](repeating: 0, count: size)
        var ldb = LAPACKInt(size)
        var info: LAPACKInt = 0

        dgesv_(&n, &nrhs, &columnMajor, &lda, &ipiv, &rhs, &ldb, &info)

        guard info == 0 else { return nil }
        return rhs
    }

    private static func solveLinearSystemGaussJordan(a: inout [Double], b: inout [Double], size: Int) -> [Double]? {
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
        var dimension = LAPACKInt(n)
        var leadingDimension = LAPACKInt(n)
        var queryWork = 0.0
        var querySize = LAPACKInt(-1)
        var info = LAPACKInt(0)

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

        var workSize = LAPACKInt(max(Int(queryWork.rounded(.up)), 3 * n - 1))
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
