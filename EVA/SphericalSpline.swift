//
//  SphericalSpline.swift
//  SummerEEGDemo
//
//  Spherical-spline interpolation of scalp potentials (Perrin et al., 1989,
//  "Spherical splines for scalp potential and current density mapping").
//
//  To replace a bad channel, we fit a spherical spline through the good
//  electrodes and evaluate it at the bad electrode's position. Because the
//  fitting matrix depends only on geometry (not the data), the evaluation
//  reduces to a fixed weight vector over the good channels: the interpolated
//  time series is just a weighted sum of the good channels' time series.
//

import Foundation
import simd

enum SphericalSpline {
    /// Computes interpolation weights for `target` from the `good` electrodes.
    ///
    /// - Returns: parallel arrays `(indices, weights)` such that the
    ///   interpolated value is `Σ weights[k] * value(indices[k])`, or `nil` if
    ///   the geometry is insufficient or the system is singular.
    static func interpolationWeights(
        target: Int,
        good: [Int],
        positions: [Int: SIMD3<Double>],
        order m: Int = 4,
        terms: Int = 40,
        lambda: Double = 1e-5
    ) -> (indices: [Int], weights: [Double])? {
        guard let targetPos = positions[target] else { return nil }
        let indices = good.filter { positions[$0] != nil }
        let n = indices.count
        guard n >= 3 else { return nil }

        let pos = indices.map { positions[$0]! }

        // Precompute g(cosγ) on a fine grid would help, but n is small enough
        // to evaluate directly.
        // Augmented system A (size n+1):
        //   [ G+λI  1 ] [c ]   [g_target]
        //   [ 1ᵀ    0 ] [c0] = [   1    ]
        // Solving A·w = rhs gives weights = w[0..<n] (see file header).
        let size = n + 1
        var a = [Double](repeating: 0, count: size * size)
        var rhs = [Double](repeating: 0, count: size)

        for i in 0..<n {
            for j in 0..<n {
                let dot = simd_dot(pos[i], pos[j])
                a[i * size + j] = g(dot, order: m, terms: terms)
            }
            a[i * size + i] += lambda
            a[i * size + n] = 1
            a[n * size + i] = 1
            rhs[i] = g(simd_dot(targetPos, pos[i]), order: m, terms: terms)
        }
        a[n * size + n] = 0
        rhs[n] = 1

        guard let solution = solveLinearSystem(a: &a, b: &rhs, size: size) else { return nil }
        return (indices, Array(solution[0..<n]))
    }

    /// Perrin g-function: g(x) = 1/(4π) Σₙ (2n+1)/(n(n+1))^m · Pₙ(x).
    private static func g(_ x: Double, order m: Int, terms: Int) -> Double {
        let cosine = max(-1, min(1, x))
        var pPrev = 1.0        // P₀
        var pCurr = cosine     // P₁
        var sum = 0.0
        for n in 1...terms {
            let pn: Double
            if n == 1 {
                pn = pCurr
            } else {
                // Bonnet recurrence: Pₙ = ((2n−1)x·Pₙ₋₁ − (n−1)Pₙ₋₂) / n
                let k = Double(n)
                pn = ((2 * k - 1) * cosine * pCurr - (k - 1) * pPrev) / k
                pPrev = pCurr
                pCurr = pn
            }
            let nn = Double(n)
            let denom = pow(nn * (nn + 1), Double(m))
            sum += (2 * nn + 1) / denom * pn
        }
        return sum / (4 * Double.pi)
    }

    /// Solves `a · x = b` (row-major `a`, size×size) via Gaussian elimination
    /// with partial pivoting. Mutates `a` and `b`; returns `x` or `nil` if
    /// singular.
    private static func solveLinearSystem(a: inout [Double], b: inout [Double], size: Int) -> [Double]? {
        for col in 0..<size {
            // Partial pivot.
            var pivotRow = col
            var pivotMag = abs(a[col * size + col])
            for r in (col + 1)..<size {
                let mag = abs(a[r * size + col])
                if mag > pivotMag { pivotMag = mag; pivotRow = r }
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
        for i in 0..<size {
            x[i] = b[i] / a[i * size + i]
        }
        return x
    }
}
