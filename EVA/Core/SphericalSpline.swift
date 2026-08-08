//
//  SphericalSpline.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
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

nonisolated enum SphericalSpline {
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

        guard let solution = LinearAlgebra.solveLinearSystem(a: &a, b: &rhs, size: size) else { return nil }
        return (indices, Array(solution[0..<n]))
    }

    /// Computes interpolation weights for MULTIPLE targets that share the
    /// SAME `good` electrode set — the common case within one epoch when
    /// several channels are bad at once. The system matrix (built from
    /// `good` alone) is identical for every target; only the right-hand side
    /// depends on the target's position. Factoring that matrix ONCE (LU via
    /// `LinearAlgebra.factorLinearSystem`) and reusing it for each target's
    /// solve turns N independent O(n³) solves into one O(n³) factorization
    /// plus N O(n²) solves — the "shared factorization" optimization.
    /// Falls back to solving each target independently if the factorization
    /// fails (singular system / LAPACK unavailable).
    static func interpolationWeightsBatch(
        targets: [Int],
        good: [Int],
        positions: [Int: SIMD3<Double>],
        order m: Int = 4,
        terms: Int = 40,
        lambda: Double = 1e-5
    ) -> [Int: (indices: [Int], weights: [Double])] {
        let indices = good.filter { positions[$0] != nil }
        let n = indices.count
        guard n >= 3 else { return [:] }
        let pos = indices.map { positions[$0]! }
        let size = n + 1

        var a = [Double](repeating: 0, count: size * size)
        for i in 0..<n {
            for j in 0..<n {
                let dot = simd_dot(pos[i], pos[j])
                a[i * size + j] = g(dot, order: m, terms: terms)
            }
            a[i * size + i] += lambda
            a[i * size + n] = 1
            a[n * size + i] = 1
        }
        a[n * size + n] = 0

        let factorization = LinearAlgebra.factorLinearSystem(a: a, size: size)

        var results: [Int: (indices: [Int], weights: [Double])] = [:]
        results.reserveCapacity(targets.count)
        for target in targets {
            guard let targetPos = positions[target] else { continue }
            var rhs = [Double](repeating: 0, count: size)
            for i in 0..<n {
                rhs[i] = g(simd_dot(targetPos, pos[i]), order: m, terms: terms)
            }
            rhs[n] = 1

            if let solution = factorization?.solve(rhs) {
                results[target] = (indices, Array(solution[0..<n]))
            } else {
                // Factorization unavailable/singular for this matrix — solve
                // this target's system independently as a fallback.
                var aCopy = a
                var rhsCopy = rhs
                if let solution = LinearAlgebra.solveLinearSystem(a: &aCopy, b: &rhsCopy, size: size) {
                    results[target] = (indices, Array(solution[0..<n]))
                }
            }
        }
        return results
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

}
