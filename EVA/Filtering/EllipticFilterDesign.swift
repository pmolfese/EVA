//
//  EllipticFilterDesign.swift
//  EVA
//
//  Elliptic (Cauer) IIR design in zero-pole-gain form, converted to stable
//  second-order sections. The prototype equations follow Orfanidis, "Lecture
//  Notes on Elliptic Filter Design" (equations 49 and 56), with a bilinear
//  transform and cutoff prewarping for the digital filter.
//

import Foundation

/// A compact elliptic-filter designer specialized for EVA's even-order
/// low-pass and high-pass edges. Keeping the output as second-order sections
/// avoids the numerical conditioning problems of a single high-order transfer
/// function.
nonisolated enum EllipticFilterDesign {
    struct Section: Sendable {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    enum Edge { case lowPass, highPass }

    static func sections(
        cutoff: Double,
        samplingRate: Double,
        order: Int,
        edge: Edge,
        passbandRippleDB: Double,
        stopbandAttenuationDB: Double
    ) -> [Section] {
        guard cutoff > 0, samplingRate > 0, cutoff < samplingRate / 2 else { return [] }
        let n = max(2, order + order % 2)
        let ripple = max(passbandRippleDB, 0.001)
        let stopband = max(stopbandAttenuationDB, ripple + 1)
        guard var design = analogPrototype(order: n, rippleDB: ripple, stopbandDB: stopband) else {
            return []
        }

        // Prewarp so the requested digital critical frequency remains the
        // first point below the specified passband ripple after Tustin's map.
        let warpedCutoff = 2 * samplingRate * tan(Double.pi * cutoff / samplingRate)
        switch edge {
        case .lowPass:
            design.zeros = design.zeros.map { $0 * warpedCutoff }
            design.poles = design.poles.map { $0 * warpedCutoff }
            let relativeDegree = design.poles.count - design.zeros.count
            design.gain *= pow(warpedCutoff, Double(relativeDegree))
        case .highPass:
            let oldZeros = design.zeros
            let oldPoles = design.poles
            design.zeros = oldZeros.map { warpedCutoff / $0 }
            design.poles = oldPoles.map { warpedCutoff / $0 }
            let relativeDegree = oldPoles.count - oldZeros.count
            design.zeros.append(contentsOf: Array(repeating: .zero, count: relativeDegree))
            design.gain *= (product(oldZeros.map { -$0 }) / product(oldPoles.map { -$0 })).real
        }

        let twiceRate = 2 * samplingRate
        let analogZeros = design.zeros
        let analogPoles = design.poles
        design.zeros = analogZeros.map { (twiceRate + $0) / (twiceRate - $0) }
        design.poles = analogPoles.map { (twiceRate + $0) / (twiceRate - $0) }
        let relativeDegree = analogPoles.count - analogZeros.count
        design.zeros.append(contentsOf: Array(repeating: Complex(-1, 0), count: relativeDegree))
        design.gain *= (product(analogZeros.map { twiceRate - $0 })
            / product(analogPoles.map { twiceRate - $0 })).real

        return secondOrderSections(zeros: design.zeros, poles: design.poles, gain: design.gain)
    }

    private struct Design {
        var zeros: [Complex]
        var poles: [Complex]
        var gain: Double
    }

    private static func analogPrototype(order n: Int, rippleDB: Double, stopbandDB: Double) -> Design? {
        let epsilonSquared = pow(10, 0.1 * rippleDB) - 1
        let epsilon = sqrt(epsilonSquared)
        let complementaryParameter = epsilonSquared / (pow(10, 0.1 * stopbandDB) - 1)
        guard complementaryParameter > 0, complementaryParameter < 1 else { return nil }

        let parameter = ellipticDegree(order: n, complementaryParameter: complementaryParameter)
        guard parameter > 0, parameter < 1 else { return nil }
        let completeK = completeEllipticK(parameter)

        // Even orders are deliberate: every pole and zero can be represented
        // by a real-coefficient biquad with its complex conjugate.
        let indices = stride(from: 1, to: n, by: 2).map(Double.init)
        let jacobi = indices.map { jacobiElliptic($0 * completeK / Double(n), parameter: parameter) }

        var positiveZeros: [Complex] = []
        positiveZeros.reserveCapacity(n / 2)
        for value in jacobi where abs(value.sn) > 2e-16 {
            positiveZeros.append(Complex(0, 1 / (sqrt(parameter) * value.sn)))
        }
        let zeros = positiveZeros + positiveZeros.map(\.conjugate)

        let inverseSC = inverseJacobiSC(1 / epsilon, complementaryTo: complementaryParameter)
        let v0 = completeK * inverseSC / (Double(n) * completeEllipticK(complementaryParameter))
        let shifted = jacobiElliptic(v0, parameter: 1 - parameter)

        var halfPoles: [Complex] = []
        halfPoles.reserveCapacity(n / 2)
        for value in jacobi {
            let denominator = 1 - pow(value.dn * shifted.sn, 2)
            let real = -(value.cn * value.dn * shifted.sn * shifted.cn) / denominator
            let imaginary = -(value.sn * shifted.dn) / denominator
            halfPoles.append(Complex(real, imaginary))
        }
        let poles = halfPoles + halfPoles.map(\.conjugate)

        var gain = (product(poles.map { -$0 }) / product(zeros.map { -$0 })).real
        gain /= sqrt(1 + epsilonSquared) // even-order DC gain is -ripple dB
        guard gain.isFinite, gain > 0 else { return nil }
        return Design(zeros: zeros, poles: poles, gain: gain)
    }

    /// Solves the elliptic degree equation through the nome expansion.
    private static func ellipticDegree(order: Int, complementaryParameter m1: Double) -> Double {
        let k1 = completeEllipticK(m1)
        let k1Prime = completeEllipticK(1 - m1)
        let q1 = exp(-Double.pi * k1Prime / k1)
        let q = pow(q1, 1 / Double(order))
        let numerator = (0...7).reduce(0.0) { sum, index in
            sum + pow(q, Double(index * (index + 1)))
        }
        let denominator = 1 + 2 * (1...8).reduce(0.0) { sum, index in
            sum + pow(q, Double(index * index))
        }
        return 16 * q * pow(numerator / denominator, 4)
    }

    private static func completeEllipticK(_ parameter: Double) -> Double {
        var a = 1.0
        var b = sqrt(max(0, 1 - parameter))
        for _ in 0..<50 {
            let nextA = (a + b) / 2
            let nextB = sqrt(a * b)
            a = nextA
            b = nextB
            if abs(a - b) <= a * 1e-15 { break }
        }
        return Double.pi / (2 * a)
    }

    private struct JacobiValues {
        var sn: Double
        var cn: Double
        var dn: Double
    }

    /// Real Jacobi sn/cn/dn via the descending arithmetic-geometric mean.
    private static func jacobiElliptic(_ u: Double, parameter m: Double) -> JacobiValues {
        if m <= 1e-15 {
            return JacobiValues(sn: sin(u), cn: cos(u), dn: 1)
        }
        if 1 - m <= 1e-15 {
            let sn = tanh(u)
            return JacobiValues(sn: sn, cn: 1 / cosh(u), dn: 1 / cosh(u))
        }

        var a = [1.0]
        var c = [sqrt(m)]
        var b = sqrt(1 - m)
        var powerOfTwo = 1.0
        for _ in 0..<20 {
            let currentA = a[a.count - 1]
            let nextC = (currentA - b) / 2
            let nextA = (currentA + b) / 2
            c.append(nextC)
            a.append(nextA)
            b = sqrt(currentA * b)
            powerOfTwo *= 2
            if abs(nextC) <= nextA * 1e-15 { break }
        }

        var phi = powerOfTwo * a[a.count - 1] * u
        if a.count > 1 {
            for index in stride(from: a.count - 1, through: 1, by: -1) {
                let ratio = max(-1, min(1, c[index] * sin(phi) / a[index]))
                phi = (asin(ratio) + phi) / 2
            }
        }
        let sn = sin(phi)
        let cn = cos(phi)
        return JacobiValues(sn: sn, cn: cn, dn: sqrt(max(0, 1 - m * sn * sn)))
    }

    /// Finds z where sc(z, 1-m) = w. On the first real quarter period sc is
    /// monotonic, so bisection is both simpler and more stable than complex
    /// inverse-Jacobi arithmetic.
    private static func inverseJacobiSC(_ w: Double, complementaryTo m: Double) -> Double {
        let parameter = 1 - m
        var lower = 0.0
        var upper = completeEllipticK(parameter) * (1 - 1e-12)
        for _ in 0..<100 {
            let midpoint = (lower + upper) / 2
            let value = jacobiElliptic(midpoint, parameter: parameter)
            if value.sn / max(value.cn, Double.leastNonzeroMagnitude) < w {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return (lower + upper) / 2
    }

    private static func secondOrderSections(
        zeros: [Complex],
        poles: [Complex],
        gain: Double
    ) -> [Section] {
        var remainingZeros = zeros.filter { $0.imaginary > 1e-10 }
        let sectionPoles = poles.filter { $0.imaginary > 1e-10 }
        guard !sectionPoles.isEmpty, remainingZeros.count == sectionPoles.count else { return [] }

        let sectionGain = pow(max(gain, Double.leastNonzeroMagnitude), 1 / Double(sectionPoles.count))
        var result: [Section] = []
        result.reserveCapacity(sectionPoles.count)

        // Nearest-zero pairing limits the peak gain of individual sections.
        for pole in sectionPoles.sorted(by: { abs(1 - $0.magnitude) < abs(1 - $1.magnitude) }) {
            let zeroIndex = remainingZeros.indices.min { lhs, rhs in
                (remainingZeros[lhs] - pole).magnitude < (remainingZeros[rhs] - pole).magnitude
            }!
            let zero = remainingZeros.remove(at: zeroIndex)
            result.append(Section(
                b0: sectionGain,
                b1: -2 * zero.real * sectionGain,
                b2: zero.magnitudeSquared * sectionGain,
                a1: -2 * pole.real,
                a2: pole.magnitudeSquared
            ))
        }
        return result
    }

    private static func product(_ values: [Complex]) -> Complex {
        values.reduce(Complex(1, 0), *)
    }
}

private nonisolated struct Complex: Sendable {
    var real: Double
    var imaginary: Double

    init(_ real: Double, _ imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }

    static let zero = Complex(0, 0)
    var conjugate: Complex { Complex(real, -imaginary) }
    var magnitudeSquared: Double { real * real + imaginary * imaginary }
    var magnitude: Double { sqrt(magnitudeSquared) }

    static prefix func - (value: Complex) -> Complex {
        Complex(-value.real, -value.imaginary)
    }

    static func + (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real + rhs.real, lhs.imaginary + rhs.imaginary)
    }

    static func + (lhs: Double, rhs: Complex) -> Complex { Complex(lhs, 0) + rhs }
    static func - (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real - rhs.real, lhs.imaginary - rhs.imaginary)
    }
    static func - (lhs: Double, rhs: Complex) -> Complex { Complex(lhs, 0) - rhs }

    static func * (lhs: Complex, rhs: Complex) -> Complex {
        Complex(
            lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
            lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
        )
    }

    static func * (lhs: Complex, rhs: Double) -> Complex {
        Complex(lhs.real * rhs, lhs.imaginary * rhs)
    }
    static func * (lhs: Double, rhs: Complex) -> Complex { rhs * lhs }

    static func / (lhs: Complex, rhs: Complex) -> Complex {
        let denominator = rhs.magnitudeSquared
        return Complex(
            (lhs.real * rhs.real + lhs.imaginary * rhs.imaginary) / denominator,
            (lhs.imaginary * rhs.real - lhs.real * rhs.imaginary) / denominator
        )
    }

    static func / (lhs: Double, rhs: Complex) -> Complex { Complex(lhs, 0) / rhs }
}
