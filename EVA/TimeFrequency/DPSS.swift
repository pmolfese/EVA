//
//  DPSS.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Discrete Prolate Spheroidal Sequences (Slepian tapers) for the multitaper
//  time-frequency path. This reproduces `scipy.signal.windows.dpss(M, NW, Kmax,
//  sym=False, norm=2, return_ratios=True)` — the exact tapers MNE's
//  `_make_dpss` uses — so the multitaper ERSP cross-checks against MNE to
//  floating-point tolerance.
//
//  Method (Percival & Walden 1993, Slepian 1978): the tapers are the L2-
//  normalized eigenvectors of the symmetric tridiagonal matrix
//    diag[i]    = ((N-1-2i)/2)² · cos(2πW),   W = NW/N
//    offdiag[k] = k·(N-k)/2
//  for the Kmax largest eigenvalues, solved with LAPACK `dstevr_`. The spectral
//  concentration ratios (the eigenvalues of the original band-limiting problem,
//  distinct from the tridiagonal's eigenvalues) come from the autocorrelation ·
//  sinc identity (Percival & Walden pg 390).
//

import Foundation
import Accelerate

nonisolated enum DPSS {

    /// Tapers of length `length`, orders 0…(kMax-1), plus their concentration
    /// ratios. `halfNBW` is the standardized half-bandwidth (NW). Tapers with
    /// concentration ≤ 0.9 are dropped (`low_bias`), matching MNE.
    ///
    /// Mirrors scipy's `sym=False`: the problem is solved at length `N = length +
    /// 1` and each taper's trailing sample is dropped, while ratios are computed
    /// on the full length-N sequence before truncation.
    static func tapers(length: Int, halfNBW: Double, kMax: Int) -> (tapers: [[Double]], ratios: [Double]) {
        guard length > 1, kMax >= 1, halfNBW > 0 else {
            return (tapers: [[Double]](repeating: [Double](repeating: 1, count: max(length, 1)), count: 1), ratios: [1])
        }
        let n = length + 1                    // scipy `_extend(M, sym=False)`
        let w = halfNBW / Double(n)
        let cos2piW = cos(2.0 * Double.pi * w)

        var diagonal = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let term = (Double(n - 1 - 2 * i)) / 2.0
            diagonal[i] = term * term * cos2piW
        }
        // Off-diagonal e[k] = k·(N-k)/2 for k = 1…N-1 (length n-1).
        var offDiagonal = [Double](repeating: 0, count: n - 1)
        for k in 1..<n { offDiagonal[k - 1] = Double(k) * Double(n - k) / 2.0 }

        guard var vectors = topEigenvectors(diagonal: diagonal, offDiagonal: offDiagonal, count: n, kMax: kMax) else {
            return (tapers: [], ratios: [])
        }
        // `vectors[k]` is order k (k = 0 → largest eigenvalue), length n.

        applySignConventions(&vectors, n: n)
        let ratios = concentrationRatios(vectors, n: n, w: w)

        // Truncate to the requested length (drop the trailing sample) and apply
        // the low-bias filter.
        var keptTapers: [[Double]] = []
        var keptRatios: [Double] = []
        for k in vectors.indices where ratios[k] > 0.9 {
            keptTapers.append(Array(vectors[k].prefix(length)))
            keptRatios.append(ratios[k])
        }
        if keptTapers.isEmpty, let best = ratios.indices.max(by: { ratios[$0] < ratios[$1] }) {
            keptTapers.append(Array(vectors[best].prefix(length)))
            keptRatios.append(ratios[best])
        }
        return (tapers: keptTapers, ratios: keptRatios)
    }

    // MARK: LAPACK tridiagonal eigensolver

    /// The `kMax` eigenvectors of the symmetric tridiagonal (diag, offDiag) with
    /// the largest eigenvalues, ordered by descending eigenvalue. Each returned
    /// vector has length `count`.
    private static func topEigenvectors(diagonal: [Double], offDiagonal: [Double], count n: Int, kMax: Int) -> [[Double]]? {
        var jobz: CChar = 0x56          // 'V' — eigenvalues and eigenvectors
        var range: CChar = 0x49         // 'I' — the IL..IU-th eigenvalues
        var order = LAPACKInt(n)
        var d = diagonal
        // dstevr wants E of length n (only the first n-1 entries are used).
        var e = offDiagonal + [0.0]
        var vl = 0.0, vu = 0.0
        var il = LAPACKInt(n - kMax + 1)   // 1-based, the smallest of the top kMax
        var iu = LAPACKInt(n)
        var abstol = 0.0
        var found: LAPACKInt = 0
        var eigenvalues = [Double](repeating: 0, count: n)
        let wanted = kMax
        var z = [Double](repeating: 0, count: n * wanted)  // column-major, ldz × wanted
        var ldz = LAPACKInt(n)
        var isuppz = [LAPACKInt](repeating: 0, count: 2 * max(wanted, 1))
        var info: LAPACKInt = 0

        // Workspace query.
        var work = [Double](repeating: 0, count: 1)
        var lwork = LAPACKInt(-1)
        var iwork = [LAPACKInt](repeating: 0, count: 1)
        var liwork = LAPACKInt(-1)
        dstevr_(&jobz, &range, &order, &d, &e, &vl, &vu, &il, &iu, &abstol,
                &found, &eigenvalues, &z, &ldz, &isuppz,
                &work, &lwork, &iwork, &liwork, &info)
        guard info == 0 else { return nil }
        lwork = LAPACKInt(work[0])
        liwork = iwork[0]
        work = [Double](repeating: 0, count: Int(max(lwork, 1)))
        iwork = [LAPACKInt](repeating: 0, count: Int(max(liwork, 1)))

        dstevr_(&jobz, &range, &order, &d, &e, &vl, &vu, &il, &iu, &abstol,
                &found, &eigenvalues, &z, &ldz, &isuppz,
                &work, &lwork, &iwork, &liwork, &info)
        guard info == 0, found >= 1 else { return nil }

        let m = Int(found)
        // dstevr returns eigenvalues ascending; reverse so column m-1 (largest)
        // becomes order 0, matching scipy's `[::-1]`.
        var result: [[Double]] = []
        result.reserveCapacity(m)
        for col in stride(from: m - 1, through: 0, by: -1) {
            var vector = [Double](repeating: 0, count: n)
            for row in 0..<n { vector[row] = z[col * n + row] }
            result.append(vector)
        }
        return result
    }

    // MARK: Sign conventions (Percival & Walden pg 379)

    private static func applySignConventions(_ vectors: inout [[Double]], n: Int) {
        let thresh = max(1e-7, 1.0 / Double(n))
        for k in vectors.indices {
            if k % 2 == 0 {
                // Symmetric tapers: positive average.
                let sum = vectors[k].reduce(0, +)
                if sum < 0 { for i in 0..<n { vectors[k][i] *= -1 } }
            } else {
                // Antisymmetric tapers: first point above the noise floor is positive.
                if let first = vectors[k].first(where: { $0 * $0 > thresh }), first < 0 {
                    for i in 0..<n { vectors[k][i] *= -1 }
                }
            }
        }
    }

    // MARK: Concentration ratios (Percival & Walden pg 390)

    /// `ratio_k = Σ_l rxx_k[l] · r[l]`, with one-sided autocorrelation
    /// `rxx_k[l] = Σ_i v_k[i]·v_k[i+l]` and `r[l] = 4W·sinc(2Wl)`, `r[0] = 2W`.
    private static func concentrationRatios(_ vectors: [[Double]], n: Int, w: Double) -> [Double] {
        var r = [Double](repeating: 0, count: n)
        r[0] = 2.0 * w
        for l in 1..<n { r[l] = 4.0 * w * sinc(2.0 * w * Double(l)) }

        return vectors.map { v in
            var ratio = 0.0
            for l in 0..<n {
                var acc = 0.0
                for i in 0..<(n - l) { acc += v[i] * v[i + l] }
                ratio += acc * r[l]
            }
            return ratio
        }
    }

    /// numpy `sinc(x) = sin(πx)/(πx)`.
    private static func sinc(_ x: Double) -> Double {
        if x == 0 { return 1 }
        let px = Double.pi * x
        return sin(px) / px
    }
}
