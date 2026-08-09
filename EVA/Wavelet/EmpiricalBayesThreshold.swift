//
//  EmpiricalBayesThreshold.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Empirical Bayes threshold selection for wavelet detail bands, with the
//  quasi-Cauchy (heavy-tailed) nonzero prior.
//
//  Method:
//    Johnstone, I. M. & Silverman, B. W. (2005). "Empirical Bayes selection of
//    wavelet thresholds." The Annals of Statistics 33(4), 1700–1752.
//    doi:10.1214/009053605000000345
//
//  This is an independent implementation written from the published mathematics
//  — §2.2 (generic calculations: posterior median, marginal maximum likelihood
//  score) and §2.3 (the closed forms for the quasi-Cauchy prior). No code was
//  derived from, or consulted in, any existing implementation, so the file
//  carries no third-party licence obligation. The authors' own R package
//  (EbayesThresh, GPL-2.0-or-later / GPL-3.0-or-later) was used solely as an
//  external oracle to check numeric agreement in `EmpiricalBayesThresholdTests`;
//  running a program to compare outputs creates no derivative work.
//
//  Why this exists: a common reference pipeline, HAPPE, selects MATLAB
//  `wdenoise` with `'DenoisingMethod','Bayes'`, whose documented behavior maps
//  to this estimator — a sparse mixture prior fitted per level by marginal
//  maximum likelihood — and *not* BayesShrink despite the shared word. The two
//  adapt in opposite directions on artifact-laden EEG; see `WaveletReducer`'s
//  header. HAPPE source code is not incorporated or translated here.
//
//  ── The estimator ─────────────────────────────────────────────────────────
//  Each detail coefficient is modelled as z = µ + ε, ε ~ N(0,1) after dividing
//  the band by its noise σ, with the prior
//
//      µ ~ (1 − w)·δ₀ + w·γ,        γ = the quasi-Cauchy density, eq. (13)
//
//  The sparsity weight w is fitted by maximising the marginal log-likelihood
//  (eq. 5) subject to the threshold not exceeding the universal threshold
//  √(2 ln N) (§1.3), and the returned gate is the value of |z| at which the
//  posterior median first becomes nonzero (eq. 16), rescaled by σ.
//
//  ── Algebra used here ─────────────────────────────────────────────────────
//  For the quasi-Cauchy prior §2.3 gives the marginal density and the tail of
//  the nonzero part of the posterior:
//
//      g(z)      = (2π)^(−1/2) z^(−2) (1 − e^(−z²/2))
//      F̃₁(µ|z)  = (1 − e^(−z²/2))^(−1) [ Φ̃(µ−z) − zφ(µ−z)
//                                        + (µz − 1) e^(µz − z²/2) Φ̃(µ) ]
//
//  Two forms are derived from those and used below; both are this file's own
//  reduction of the published expressions.
//
//  1. The marginal ratio β of eq. (17), factored so the weight drops out:
//
//         β(z) = g(z)/φ(z) − 1 = (e^(z²/2) − 1)/z² − 1
//
//     and then β(z,w) = β(z) / (1 + w·β(z)), so the score of eq. (18) is
//     S(w) = Σᵢ β(zᵢ)/(1 + w·β(zᵢ)) — one pass over precomputed β values per
//     candidate w, which is what makes the fit cheap.
//
//  2. The posterior-median threshold equation. Substituting g and F̃₁(0|z)
//     into the boundary case of eq. (16), w_post(z)·F̃₁(0|z) = ½, clearing the
//     common (2π)^(−1/2)(1 − e^(−z²/2)) factor and multiplying through by
//     z²e^(z²/2) collapses to
//
//         w·e^(z²/2)·A(z) = ½(1 − w)z²,      A(z) = Φ(z) − ½ − zφ(z)
//
//     whose positive root is t(w). Solving the same equation for w instead of
//     z inverts the relation in closed form:
//
//         w(t) = t² / ( t² + 2 e^(t²/2) A(t) )
//
//     which is how the lower end of the weight search bracket — the w whose
//     threshold is exactly the universal threshold — is obtained without a
//     second root-find.
//

import Foundation

/// Johnstone–Silverman empirical Bayes threshold selection with the
/// quasi-Cauchy prior. Stateless; all entry points are pure functions.
nonisolated enum EmpiricalBayesThreshold {

    // MARK: - Public entry point

    /// The artifact gate for one detail band, in the band's own units.
    ///
    /// `populationCount` is the size of the band this sample stands in for — the
    /// `N` in the universal threshold √(2 ln N) that bounds the fitted
    /// threshold from above. Callers holding a strided subsample (the GPU path)
    /// pass the full band length so the bound is not systematically loosened.
    /// The likelihood root itself is unaffected by subsampling: scaling `S(w)`
    /// by a constant does not move its zero.
    ///
    /// Returns 0 when the band is degenerate (too short, or a robust σ of zero,
    /// which means the band is constant or nearly all zeros). Callers should
    /// treat 0 as "no estimate" and fall back.
    static func threshold(for values: [Double], populationCount: Int? = nil) -> Double {
        guard values.count > 2 else { return 0 }
        let sigma = robustSigma(values)
        guard sigma > 1e-12, sigma.isFinite else { return 0 }

        let n = max(populationCount ?? values.count, 2)
        let normalized = values.map { $0 / sigma }
        let weight = fittedWeight(normalized, populationCount: n)
        let bound = universalThreshold(populationCount: n)
        let gate = threshold(forWeight: weight, upperBound: bound)
        guard gate.isFinite, gate > 0 else { return 0 }
        return sigma * gate
    }

    /// The universal threshold √(2 ln N), which §1.3 imposes as the upper limit
    /// on the fitted threshold (equivalently, a lower limit on `w`).
    static func universalThreshold(populationCount: Int) -> Double {
        (2 * log(Double(max(populationCount, 2)))).squareRoot()
    }

    // MARK: - Noise scale

    /// Median absolute deviation *about the median*, scaled to a Gaussian σ.
    ///
    /// Deliberately not `WaveletReducer.robustSigma`, which uses median(|x|)
    /// and so assumes the band is centred at zero. The two agree closely on
    /// clean detail coefficients, but the empirical Bayes fit is more sensitive
    /// to the normalisation than a fixed rule is — the weight is read off the
    /// shape of the standardised band — and a band carrying a large low-frequency
    /// artifact can have a distinctly nonzero median. Deviations about the
    /// median are also the scale estimate this method was developed and
    /// published against (§1.4).
    ///
    /// The band itself is *not* re-centred: only the scale is estimated
    /// robustly, matching the model in which the coefficients are noisy
    /// observations of mostly-zero means.
    static func robustSigma(_ values: [Double]) -> Double {
        let finite = values.filter { $0.isFinite }
        guard !finite.isEmpty else { return 0 }
        let center = median(finite)
        return 1.4826 * median(finite.map { abs($0 - center) })
    }

    // MARK: - Quasi-Cauchy marginal

    /// β(z) = g(z)/φ(z) − 1 for the quasi-Cauchy prior; see header item 1.
    ///
    /// Ranges from −½ at z = 0 (where the closed form is a removable 0/0) up to
    /// +∞. Returns `.infinity` once z²/2 exceeds the exponential's range; the
    /// score handles that limit analytically rather than propagating a NaN.
    static func marginalRatio(_ z: Double) -> Double {
        let half = 0.5 * z * z
        guard half.isFinite else { return .infinity }
        if half > 700 { return .infinity }
        if half < 1e-12 { return -0.5 }
        return expm1(half) / (z * z) - 1
    }

    /// A(z) = Φ(z) − ½ − z·φ(z), the bracketed factor of the threshold
    /// equation in header item 2. Positive and increasing for z > 0.
    ///
    /// The two terms cancel to leading and next-to-leading order as z → 0, so
    /// the closed form loses roughly the last log₁₀(3/z²) digits there. That is
    /// mild until z gets very small — at z = 0.05 it costs about three digits —
    /// so the closed form is used down to 0.05 and the Maclaurin series of the
    /// difference, φ(0)·(z³/3 − z⁵/10 + z⁷/56 − z⁹/432 + …), takes over below
    /// it. Four terms put the series' truncation error at ~1e-13 relative at
    /// the switch point, where the closed form is at ~3e-14, and the series only
    /// improves from there.
    static func standardNormalGap(_ z: Double) -> Double {
        let z2 = z * z
        if z < 0.05 {
            let series = 1.0 / 3.0 - z2 / 10.0 + z2 * z2 / 56.0 - z2 * z2 * z2 / 432.0
            return invSqrt2Pi * z * z2 * series
        }
        return 0.5 * erf(z / 2.0.squareRoot()) - z * standardNormalDensity(z)
    }

    static func standardNormalDensity(_ z: Double) -> Double {
        invSqrt2Pi * exp(-0.5 * z * z)
    }

    private static let invSqrt2Pi = 0.39894228040143267794

    // MARK: - Weight ↔ threshold

    /// The mixing weight whose posterior-median threshold is exactly `t`; the
    /// closed-form inversion in header item 2. `t` must be > 0.
    static func weight(forThreshold t: Double) -> Double {
        guard t > 0 else { return 1 }
        let t2 = t * t
        let denominator = t2 + 2 * exp(0.5 * t2) * standardNormalGap(t)
        guard denominator > 0, denominator.isFinite else { return 0 }
        return min(max(t2 / denominator, 0), 1)
    }

    /// The posterior-median threshold t(w): the positive root of
    /// `w·e^(z²/2)·A(z) − ½(1 − w)z²`, which is negative just above 0 and
    /// positive at `upperBound` for any w above the bracket's lower end.
    ///
    /// Solved by bisection on [0, upperBound]. Fixed 64 halvings: that takes an
    /// initial bracket of ~6 (the widest √(2 ln N) reached in practice) below
    /// double precision, so there is nothing to gain from a tolerance test, and
    /// a fixed count keeps the cost of the fit predictable. z = 0 is a root of
    /// the objective as written and would defeat a sign test, so the lower end
    /// is never evaluated — only midpoints, which are strictly positive.
    static func threshold(forWeight w: Double, upperBound: Double) -> Double {
        guard upperBound > 0 else { return 0 }
        guard w > 0 else { return upperBound }
        guard w < 1 else { return 0 }
        var low = 0.0
        var high = upperBound
        for _ in 0..<64 {
            let mid = 0.5 * (low + high)
            if thresholdObjective(mid, weight: w) < 0 {
                low = mid
            } else {
                high = mid
            }
        }
        return 0.5 * (low + high)
    }

    private static func thresholdObjective(_ z: Double, weight w: Double) -> Double {
        let half = 0.5 * z * z
        guard half < 700 else { return .infinity }
        return w * exp(half) * standardNormalGap(z) - 0.5 * (1 - w) * z * z
    }

    // MARK: - Marginal maximum likelihood weight

    /// The score S(w) = Σ β(zᵢ)/(1 + w·β(zᵢ)) of eq. (18), evaluated from
    /// precomputed β values. Strictly decreasing in w, so the likelihood has at
    /// most one interior maximum.
    ///
    /// Since β ≥ −½ and w ≤ 1, the denominator is bounded below by ½ and needs
    /// no guarding. A β of +∞ (a coefficient far enough out that the marginal
    /// overflows) contributes its limit, 1/w.
    static func score(weight w: Double, betas: [Double]) -> Double {
        var total = 0.0
        for beta in betas {
            total += beta.isInfinite ? 1 / w : beta / (1 + w * beta)
        }
        return total
    }

    /// Marginal-MLE weight for a σ-normalised band, maximising eq. (5) over
    /// `[w(√(2 ln N)), 1]`.
    ///
    /// The two degenerate cases are the ones that matter in practice: a band of
    /// pure noise drives the root below the bracket (S ≤ 0 throughout, so the
    /// constrained maximum sits at the lower end and the gate is exactly the
    /// universal threshold), while a dense band pushes it above 1 (S ≥ 0
    /// throughout, w = 1, gate 0 — nothing is called artifact-free).
    ///
    /// Bisection is on ln w rather than w: the bracket spans several orders of
    /// magnitude — its lower end is ≈ 2 ln N / N — and the interesting sparse
    /// solutions all sit near that end, where a linear bisection would spend
    /// most of its iterations. 96 halvings of that log interval is far inside
    /// double precision for any N; as with the threshold solve, a fixed count
    /// is preferred over a tolerance test for predictable cost.
    static func fittedWeight(_ normalized: [Double], populationCount: Int) -> Double {
        let lower = weight(forThreshold: universalThreshold(populationCount: populationCount))
        guard lower > 0, lower < 1 else { return min(max(lower, 0), 1) }

        let betas = normalized.map { marginalRatio(abs($0)) }
        guard score(weight: lower, betas: betas) > 0 else { return lower }
        guard score(weight: 1, betas: betas) < 0 else { return 1 }

        var low = log(lower)
        var high = 0.0
        for _ in 0..<96 {
            let mid = 0.5 * (low + high)
            if score(weight: exp(mid), betas: betas) > 0 {
                low = mid
            } else {
                high = mid
            }
        }
        return exp(0.5 * (low + high))
    }

    // MARK: - Small math

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return 0.5 * (sorted[middle - 1] + sorted[middle])
    }
}
