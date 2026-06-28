//
//  DSP.swift
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
//  SPDX-License-Identifier: GPL-3.0-only
//
//  General-purpose digital-signal-processing primitives shared across EVA. These
//  are deliberately algorithm-agnostic (FIR design, zero-phase filtering, integer
//  resampling, LMS adaptive filtering, PCA, correlation) so tools beyond the
//  fMRI-gradient correction (e.g. FASTR/FACET) can reuse them.
//
//  All routines operate on Double for numerical headroom and convert at the
//  boundaries where callers use Float.
//

import Accelerate
import Foundation

nonisolated enum DSP {

    // MARK: - Correlation

    /// Pearson correlation coefficient between two equal-length vectors.
    /// Mirrors FMRIB's `prcorr2` (which falls back to MATLAB's `corrcoef`).
    static func pearson(_ a: ArraySlice<Double>, _ b: ArraySlice<Double>) -> Double {
        precondition(a.count == b.count)
        let n = Double(a.count)
        guard n > 1 else { return 0 }
        let ai = Array(a), bi = Array(b)
        var ma = 0.0, mb = 0.0
        vDSP_meanvD(ai, 1, &ma, vDSP_Length(ai.count))
        vDSP_meanvD(bi, 1, &mb, vDSP_Length(bi.count))
        var sa = 0.0, sb = 0.0, sab = 0.0
        for i in 0..<ai.count {
            let da = ai[i] - ma
            let db = bi[i] - mb
            sa += da * da
            sb += db * db
            sab += da * db
        }
        let denom = (sa * sb).squareRoot()
        return denom == 0 ? 0 : sab / denom
    }

    // MARK: - FIR design (least squares)

    /// Least-squares linear-phase FIR design, equivalent to MATLAB/Octave
    /// `firls(numtaps-1, F, A)` for a Type-I (odd length, even order) filter.
    ///
    /// `bands` and `desired` are paired band edges and amplitudes in normalized
    /// frequency where 1.0 == Nyquist. Gaps between consecutive bands are
    /// unconstrained transition regions (exactly as MATLAB treats them).
    ///
    /// Derivation: the amplitude response of a Type-I filter is
    ///   A(f) = sum_{k=0}^{M} g_k cos(pi k f),  M = (numtaps-1)/2
    /// Minimizing the weighted integral squared error over the bands gives the
    /// normal equations  Q g = b  with closed-form (cosine-integral) entries.
    static func firls(numtaps: Int,
                      bands: [(Double, Double)],
                      desired: [(Double, Double)],
                      weights: [Double]? = nil) -> [Double] {
        precondition(numtaps % 2 == 1, "firls requires an odd numtaps (Type-I)")
        precondition(bands.count == desired.count)
        let m = (numtaps - 1) / 2
        let w = weights ?? Array(repeating: 1.0, count: bands.count)

        // q[k] = sum_b w_b * \int_{f1}^{f2} cos(pi k f) df, k = 0...2M
        func qValue(_ k: Int) -> Double {
            var sum = 0.0
            for (i, band) in bands.enumerated() {
                let (f1, f2) = band
                if k == 0 {
                    sum += w[i] * (f2 - f1)
                } else {
                    let a = Double.pi * Double(k)
                    sum += w[i] * (sin(a * f2) - sin(a * f1)) / a
                }
            }
            return sum
        }
        var q = [Double](repeating: 0, count: 2 * m + 1)
        for k in 0...(2 * m) { q[k] = qValue(k) }

        // b[j] = sum_b w_b * \int (slope f + intercept) cos(pi j f) df, j = 0...M
        func bValue(_ j: Int) -> Double {
            var sum = 0.0
            for (i, band) in bands.enumerated() {
                let (f1, f2) = band
                let (d1, d2) = desired[i]
                let slope = (f2 == f1) ? 0 : (d2 - d1) / (f2 - f1)
                let intercept = d1 - slope * f1
                if j == 0 {
                    sum += w[i] * (slope * (f2 * f2 - f1 * f1) / 2 + intercept * (f2 - f1))
                } else {
                    let a = Double.pi * Double(j)
                    func antideriv(_ f: Double) -> Double {
                        // \int (slope f + intercept) cos(a f) df
                        slope * (cos(a * f) + a * f * sin(a * f)) / (a * a)
                            + intercept * sin(a * f) / a
                    }
                    sum += w[i] * (antideriv(f2) - antideriv(f1))
                }
            }
            return sum
        }
        var bVec = [Double](repeating: 0, count: m + 1)
        for j in 0...m { bVec[j] = bValue(j) }

        // Q[j][k] = 0.5 (q[|j-k|] + q[j+k])
        var qMat = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: m + 1)
        for j in 0...m {
            for k in 0...m {
                qMat[j][k] = 0.5 * (q[abs(j - k)] + q[j + k])
            }
        }

        guard let g = LinearAlgebra.solveLinearSystem(qMat, bVec) else {
            return [Double](repeating: 0, count: numtaps)
        }

        // Symmetric coefficients: h[M] = g0, h[M±k] = g_k / 2
        var h = [Double](repeating: 0, count: numtaps)
        h[m] = g[0]
        for k in 1...m {
            h[m + k] = g[k] / 2
            h[m - k] = g[k] / 2
        }
        return h
    }

    /// Windowed-sinc (Hamming) low-pass FIR, gain `gain`, cutoff in normalized
    /// frequency (1.0 == Nyquist). `numtaps` should be odd for linear phase.
    static func windowedSincLowPass(numtaps: Int, cutoff: Double, gain: Double = 1) -> [Double] {
        let n = numtaps % 2 == 1 ? numtaps : numtaps + 1
        let mid = (n - 1) / 2
        var h = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let k = Double(i - mid)
            let sinc: Double = k == 0 ? cutoff : sin(Double.pi * cutoff * k) / (Double.pi * k)
            let window = 0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            h[i] = sinc * window
            sum += h[i]
        }
        // normalize DC gain to `gain`
        let scale = gain / sum
        for i in 0..<n { h[i] *= scale }
        return h
    }

    // MARK: - FIR filtering

    /// Causal FIR filtering, MATLAB `filter(b, 1, x)` (same length as input).
    static func firFilter(_ b: [Double], _ x: [Double]) -> [Double] {
        let nb = b.count
        var y = [Double](repeating: 0, count: x.count)
        for n in 0..<x.count {
            var acc = 0.0
            let kMax = min(nb - 1, n)
            for k in 0...kMax { acc += b[k] * x[n - k] }
            y[n] = acc
        }
        return y
    }

    /// Zero-phase FIR filtering for a linear-phase (symmetric) kernel: full
    /// convolution with the symmetric-delay center extracted, so the output is
    /// the same length as `x` with no net group delay.
    static func convolveSame(_ b: [Double], _ x: [Double]) -> [Double] {
        let nb = b.count
        let nx = x.count
        let delay = (nb - 1) / 2
        var full = [Double](repeating: 0, count: nx + nb - 1)
        for n in 0..<nx {
            let xn = x[n]
            if xn == 0 { continue }
            for k in 0..<nb { full[n + k] += b[k] * xn }
        }
        return Array(full[delay..<(delay + nx)])
    }

    /// Zero-phase forward-backward FIR filtering, approximating MATLAB
    /// `filtfilt(b, 1, x)` with reflection padding to suppress edge transients.
    static func filtfiltFIR(_ b: [Double], _ x: [Double]) -> [Double] {
        let nb = b.count
        guard nb > 1, x.count > 3 * (nb - 1) else {
            // Too short to pad meaningfully; fall back to a single zero-phase pass.
            return convolveSame(b, x)
        }
        let pad = 3 * (nb - 1)
        // Odd (point-symmetric) reflection padding, like scipy's default.
        var ext = [Double]()
        ext.reserveCapacity(x.count + 2 * pad)
        for i in stride(from: pad, through: 1, by: -1) { ext.append(2 * x[0] - x[i]) }
        ext.append(contentsOf: x)
        let last = x.count - 1
        for i in 1...pad { ext.append(2 * x[last] - x[last - i]) }

        var y = firFilter(b, ext)
        y.reverse()
        y = firFilter(b, y)
        y.reverse()
        return Array(y[pad..<(pad + x.count)])
    }

    // MARK: - Integer resampling

    /// Upsample by integer `factor` with anti-imaging low-pass, MATLAB
    /// `interp(x, factor, n, 1)`-style. Output length = x.count * factor.
    static func interp(_ x: [Double], factor: Int, halfTaps: Int = 4) -> [Double] {
        guard factor > 1 else { return x }
        var up = [Double](repeating: 0, count: x.count * factor)
        for i in 0..<x.count { up[i * factor] = x[i] }
        // Low-pass at the new Nyquist/factor, gain = factor to preserve amplitude.
        let taps = 2 * halfTaps * factor + 1
        let lp = windowedSincLowPass(numtaps: taps, cutoff: 1.0 / Double(factor), gain: Double(factor))
        return convolveSame(lp, up)
    }

    /// Decimate by integer `factor` with anti-alias low-pass (FIR, zero-phase),
    /// MATLAB `decimate(x, factor, 'FIR')`-style. Output length ≈ x.count/factor.
    static func decimate(_ x: [Double], factor: Int, taps: Int = 31) -> [Double] {
        guard factor > 1 else { return x }
        let n = taps % 2 == 1 ? taps : taps + 1
        let lp = windowedSincLowPass(numtaps: n, cutoff: 1.0 / Double(factor), gain: 1)
        let filtered = convolveSame(lp, x)
        var out = [Double]()
        out.reserveCapacity(x.count / factor + 1)
        var i = 0
        while i < filtered.count { out.append(filtered[i]); i += factor }
        return out
    }

    // MARK: - LMS adaptive filter (fastranc)

    /// Adaptive noise cancellation via normalized LMS, a direct port of FMRIB's
    /// `fastranc`. Returns the cleaned signal (`out`, the error signal) and the
    /// estimated noise (`y`).
    ///
    /// - Parameters:
    ///   - reference: reference noise channel.
    ///   - data: signal to be cleaned (same length as `reference`).
    ///   - order: filter order N (uses N+1 taps).
    ///   - mu: LMS step size.
    static func lmsAdaptiveFilter(reference: [Double], data: [Double], order n: Int, mu: Double)
        -> (out: [Double], noise: [Double]) {
        precondition(reference.count == data.count)
        let m = data.count
        var w = [Double](repeating: 0, count: n + 1)
        var r = [Double](repeating: 0, count: n + 1)  // most-recent-first delay line
        var out = [Double](repeating: 0, count: m)
        var y = [Double](repeating: 0, count: m)

        guard m > n else { return (data, y) }
        for e in n..<m {
            // r = [refs(E); r(1:end-1)]
            r.removeLast()
            r.insert(reference[e], at: 0)
            var yi = 0.0
            for k in 0...n { yi += w[k] * r[k] }
            let err = data[e] - yi
            y[e] = yi
            out[e] = err
            let step = 2 * mu * err
            for k in 0...n { w[k] += step * r[k] }
        }
        return (out, y)
    }

    // MARK: - PCA

    /// PCA of an epoch matrix for optimal-basis-set residual fitting.
    ///
    /// `epochs[i]` is one (already mean-removed) residual epoch of length L.
    /// Returns the basis vectors (each length L, the OBS components scaled by
    /// their singular value — equivalent to FMRIB `pca_calc`'s `ascore`) ordered
    /// by descending variance, plus `oev`, the percent variance explained.
    ///
    /// Implemented via the small Gram matrix (epochs × epochs) so the cost scales
    /// with the number of epochs, not the (much larger) epoch length.
    static func pca(epochs: [[Double]]) -> (basis: [[Double]], oev: [Double]) {
        let p = epochs.count
        guard p > 1, let length = epochs.first?.count, length > 0 else {
            return (basis: [], oev: [])
        }
        // Gram matrix G = R R^T  (p × p), R rows = epochs.
        var g = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        for i in 0..<p {
            for j in i..<p {
                var acc = 0.0
                let ei = epochs[i], ej = epochs[j]
                for s in 0..<length { acc += ei[s] * ej[s] }
                g[i][j] = acc
                g[j][i] = acc
            }
        }
        let (values, vectors) = LinearAlgebra.symmetricEigenDecomposition(g)
        // Sort eigenpairs by descending eigenvalue.
        let order = values.indices.sorted { values[$0] > values[$1] }
        let sortedValues = order.map { max(values[$0], 0) }
        let total = sortedValues.reduce(0, +)
        let oev = total > 0 ? sortedValues.map { 100 * $0 / total } : sortedValues

        // OBS basis vector for component c: u_c = R^T v_c (length = epoch length).
        var basis = [[Double]]()
        basis.reserveCapacity(p)
        for c in order {
            // Eigenvector c is column c of `vectors` (vectors[row][col]).
            let v = (0..<p).map { vectors[$0][c] }  // length p
            var u = [Double](repeating: 0, count: length)
            for i in 0..<p {
                let vi = v[i]
                if vi == 0 { continue }
                let ei = epochs[i]
                for s in 0..<length { u[s] += ei[s] * vi }
            }
            basis.append(u)
        }
        return (basis, oev)
    }

    // MARK: - FFT & fractional shift

    /// In-place iterative radix-2 Cooley-Tukey FFT. `re`/`im` length must be a
    /// power of two. `inverse` performs the unnormalized inverse transform.
    static func fft(re: inout [Double], im: inout [Double], inverse: Bool) {
        let n = re.count
        precondition(im.count == n && (n & (n - 1)) == 0, "fft length must be power of two")
        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        let sign: Double = inverse ? 1 : -1
        while len <= n {
            let ang = sign * 2 * Double.pi / Double(len)
            let wlenRe = cos(ang), wlenIm = sin(ang)
            var i = 0
            while i < n {
                var wRe = 1.0, wIm = 0.0
                for k in 0..<(len / 2) {
                    let uRe = re[i + k], uIm = im[i + k]
                    let vRe = re[i + k + len / 2] * wRe - im[i + k + len / 2] * wIm
                    let vIm = re[i + k + len / 2] * wIm + im[i + k + len / 2] * wRe
                    re[i + k] = uRe + vRe
                    im[i + k] = uIm + vIm
                    re[i + k + len / 2] = uRe - vRe
                    im[i + k + len / 2] = uIm - vIm
                    let nwRe = wRe * wlenRe - wIm * wlenIm
                    wIm = wRe * wlenIm + wIm * wlenRe
                    wRe = nwRe
                }
                i += len
            }
            len <<= 1
        }
    }

    /// Shift a signal by a (possibly fractional) number of samples via a
    /// frequency-domain linear phase ramp, as in FACET's sub-sample alignment.
    /// Positive `delta` delays the signal.
    static func fractionalShift(_ x: [Double], by delta: Double) -> [Double] {
        if delta == 0 { return x }
        let n = x.count
        var size = 1
        while size < n { size <<= 1 }
        var re = x + [Double](repeating: 0, count: size - n)
        var im = [Double](repeating: 0, count: size)
        fft(re: &re, im: &im, inverse: false)
        for k in 0..<size {
            // frequency index in [-size/2, size/2)
            let f = k <= size / 2 ? Double(k) : Double(k - size)
            let phase = -2 * Double.pi * f * delta / Double(size)
            let c = cos(phase), s = sin(phase)
            let nr = re[k] * c - im[k] * s
            let ni = re[k] * s + im[k] * c
            re[k] = nr; im[k] = ni
        }
        fft(re: &re, im: &im, inverse: true)
        let scale = 1.0 / Double(size)
        return (0..<n).map { re[$0] * scale }
    }

    /// Least-squares fit of `target` onto the columns of `design` (each a basis
    /// vector of the same length), returning the fitted vector
    /// `design * pinv(design) * target`. Used to project residuals onto the OBS.
    static func leastSquaresFit(target: [Double], design columns: [[Double]]) -> [Double] {
        let k = columns.count
        let n = target.count
        guard k > 0 else { return [Double](repeating: 0, count: n) }
        // Normal equations: (A^T A) coeff = A^T y.
        var ata = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var aty = [Double](repeating: 0, count: k)
        for a in 0..<k {
            let ca = columns[a]
            for b in a..<k {
                let cb = columns[b]
                var acc = 0.0
                for s in 0..<n { acc += ca[s] * cb[s] }
                ata[a][b] = acc
                ata[b][a] = acc
            }
            var accY = 0.0
            for s in 0..<n { accY += ca[s] * target[s] }
            aty[a] = accY
        }
        guard let coeff = LinearAlgebra.solveLinearSystem(ata, aty) else {
            return [Double](repeating: 0, count: n)
        }
        var fitted = [Double](repeating: 0, count: n)
        for a in 0..<k {
            let c = coeff[a]
            let col = columns[a]
            for s in 0..<n { fitted[s] += c * col[s] }
        }
        return fitted
    }
}
