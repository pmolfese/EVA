//
//  ClusterStatisticsDistributions.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Student-t and Fisher-F tail probabilities, and their inverses, so a
//  cluster-forming threshold can be entered as a p-value rather than as a raw
//  statistic. A raw threshold means different things as trial counts change —
//  |t| = 2.0 is p = .046 at 60 trials but p = .184 at 2 — so a df-aware
//  threshold keeps the cluster-forming step comparable across analyses.
//
//  Both tails reduce to the regularized incomplete beta function, implemented
//  here from its classical continued fraction (DLMF 8.17.22) rather than
//  ported from any existing library.
//

import Foundation

nonisolated enum ClusterStatisticsDistributions {
    /// Absolute machine-precision floor used to stop the continued fraction.
    private static let relativeTolerance = 1e-14
    private static let tiny = 1e-300
    private static let maximumIterations = 400

    // MARK: - Student t

    /// Two-tailed tail area `P(|T| >= t)` for `t >= 0`.
    static func twoTailedTProbability(_ t: Double, degreesOfFreedom: Double) -> Double {
        guard degreesOfFreedom > 0, t.isFinite else { return .nan }
        guard t > 0 else { return 1 }
        let x = degreesOfFreedom / (degreesOfFreedom + t * t)
        return regularizedIncompleteBeta(a: degreesOfFreedom / 2, b: 0.5, x: x)
    }

    /// The `|t|` at which the two-tailed area equals `alpha`. This is the
    /// cluster-forming threshold conventionally quoted as "p < .05 uncorrected"
    /// — it does not itself control any family-wise error rate.
    static func criticalT(twoTailedAlpha alpha: Double, degreesOfFreedom: Double) -> Double? {
        guard degreesOfFreedom > 0, alpha > 0, alpha < 1 else { return nil }
        return invertUpperTail(target: alpha) { value in
            twoTailedTProbability(value, degreesOfFreedom: degreesOfFreedom)
        }
    }

    // MARK: - Fisher F

    /// Upper tail area `P(F >= f)` for `f >= 0`.
    static func upperTailFProbability(
        _ f: Double,
        numeratorDegreesOfFreedom d1: Double,
        denominatorDegreesOfFreedom d2: Double
    ) -> Double {
        guard d1 > 0, d2 > 0, f.isFinite else { return .nan }
        guard f > 0 else { return 1 }
        let x = d2 / (d2 + d1 * f)
        return regularizedIncompleteBeta(a: d2 / 2, b: d1 / 2, x: x)
    }

    /// The `F` at which the upper tail area equals `alpha`.
    static func criticalF(
        alpha: Double,
        numeratorDegreesOfFreedom d1: Double,
        denominatorDegreesOfFreedom d2: Double
    ) -> Double? {
        guard d1 > 0, d2 > 0, alpha > 0, alpha < 1 else { return nil }
        return invertUpperTail(target: alpha) { value in
            upperTailFProbability(value, numeratorDegreesOfFreedom: d1, denominatorDegreesOfFreedom: d2)
        }
    }

    // MARK: - Inversion

    /// Bracket-then-bisect on a monotonically decreasing tail function. Newton
    /// would need the density as well and buys nothing here: ~60 bisections
    /// reach the precision of the tail function itself, and the whole inversion
    /// runs once per analysis, not once per permutation.
    private static func invertUpperTail(
        target: Double,
        tail: (Double) -> Double
    ) -> Double? {
        var low = 0.0
        var high = 1.0
        var guard_ = 0
        while tail(high) > target {
            low = high
            high *= 2
            guard_ += 1
            if guard_ > 200 || !high.isFinite { return nil }
        }
        for _ in 0..<200 {
            let mid = (low + high) / 2
            if mid <= low || mid >= high { break }
            if tail(mid) > target { low = mid } else { high = mid }
        }
        let result = (low + high) / 2
        return result.isFinite ? result : nil
    }

    // MARK: - Regularized incomplete beta

    /// `I_x(a, b)`. Uses the symmetry `I_x(a,b) = 1 - I_{1-x}(b,a)` to keep the
    /// continued fraction in its rapidly converging regime.
    static func regularizedIncompleteBeta(a: Double, b: Double, x: Double) -> Double {
        guard a > 0, b > 0, x.isFinite else { return .nan }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }

        let logPrefix = logGamma(a + b) - logGamma(a) - logGamma(b)
            + a * log(x) + b * log1p(-x)
        let prefix = exp(logPrefix)
        if x < (a + 1) / (a + b + 2) {
            return prefix * betaContinuedFraction(a: a, b: b, x: x) / a
        }
        return 1 - prefix * betaContinuedFraction(a: b, b: a, x: 1 - x) / b
    }

    /// Modified Lentz evaluation of the DLMF 8.17.22 continued fraction.
    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double {
        let qab = a + b
        let qap = a + 1
        let qam = a - 1

        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var fraction = d

        for iteration in 1...maximumIterations {
            let m = Double(iteration)
            let evenNumerator = m * (b - m) * x / ((qam + 2 * m) * (a + 2 * m))
            d = 1 + evenNumerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + evenNumerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            fraction *= d * c

            let oddNumerator = -(a + m) * (qab + m) * x / ((a + 2 * m) * (qap + 2 * m))
            d = 1 + oddNumerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + oddNumerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            fraction *= delta

            if abs(delta - 1) < relativeTolerance { break }
        }
        return fraction
    }

    /// Lanczos approximation, g = 7, n = 9. Accurate to ~15 significant digits
    /// over the range of degrees of freedom any epoch set can produce.
    static func logGamma(_ x: Double) -> Double {
        guard x > 0 else { return .nan }
        let coefficients: [Double] = [
            0.999_999_999_999_809_93,
            676.520_368_121_885_1,
            -1_259.139_216_722_402_8,
            771.323_428_777_653_13,
            -176.615_029_162_140_6,
            12.507_343_278_686_905,
            -0.138_571_095_265_720_12,
            9.984_369_578_019_572e-6,
            1.505_632_735_149_311_6e-7,
        ]
        if x < 0.5 {
            // Reflection keeps the series in its valid domain.
            return log(Double.pi / abs(sin(Double.pi * x))) - logGamma(1 - x)
        }
        let z = x - 1
        var series = coefficients[0]
        for index in 1..<coefficients.count {
            series += coefficients[index] / (z + Double(index))
        }
        let t = z + 7.5
        return 0.5 * log(2 * Double.pi) + (z + 0.5) * log(t) - t + log(series)
    }
}
