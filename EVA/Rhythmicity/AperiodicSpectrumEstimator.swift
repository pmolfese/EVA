//
//  AperiodicSpectrumEstimator.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Segment-aware Welch estimation and power-law fitting shared by channel
//  health and Rhythmicity Explorer surrogate generation.
//

import Accelerate
import Foundation

nonisolated struct WelchSpectrum: Sendable, Equatable {
    var frequenciesHz: [Double]
    var power: [Double]
    var windowSamples: Int
    var overlapSamples: Int
    var windowCount: Int
}

nonisolated enum AperiodicSpectrumError: Error, Sendable, Equatable, LocalizedError {
    case invalidSamplingRate(Double)
    case insufficientSamples
    case invalidFitRange(lower: Double, upper: Double)
    case insufficientFitBins(Int)
    case transformUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidSamplingRate(value):
            return "Aperiodic estimation requires a finite positive sampling rate; received \(value)."
        case .insufficientSamples:
            return "Aperiodic estimation requires at least eight finite samples in one segment."
        case let .invalidFitRange(lower, upper):
            return "Aperiodic fit range \(lower)...\(upper) Hz is invalid."
        case let .insufficientFitBins(count):
            return "Aperiodic fitting requires at least four usable frequency bins; found \(count)."
        case let .transformUnavailable(count):
            return "Accelerate could not create a complex DFT of length \(count)."
        }
    }
}

nonisolated enum AperiodicSpectrumEstimator {
    /// Paper-compatible path: a two-second periodic Hann Welch estimate with
    /// 50% overlap, followed by a positive power-law fit in linear power.
    static func estimate(
        samples: [Double],
        samplingRate: Double,
        segments: [Range<Int>],
        fitRangeHz: ClosedRange<Double>,
        excludedRangesHz: [ClosedRange<Double>] = [],
        cancellation: RhythmicityCancellation = RhythmicityCancellation()
    ) throws -> AperiodicSpectrumFit {
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw AperiodicSpectrumError.invalidSamplingRate(samplingRate)
        }
        guard fitRangeHz.lowerBound.isFinite,
              fitRangeHz.upperBound.isFinite,
              fitRangeHz.lowerBound > 0,
              fitRangeHz.lowerBound < fitRangeHz.upperBound else {
            throw AperiodicSpectrumError.invalidFitRange(
                lower: fitRangeHz.lowerBound,
                upper: fitRangeHz.upperBound
            )
        }
        let longest = segments.map(\.count).max() ?? 0
        let requested = min(max(Int(samplingRate.rounded()) * 2, 8), longest)
        let spectrum = try welch(
            samples: samples,
            samplingRate: samplingRate,
            segments: segments,
            windowSamples: requested,
            overlapFraction: 0.5,
            includeNyquist: true,
            cancellation: cancellation
        )
        return try fitPowerLaw(
            spectrum: spectrum,
            fitRangeHz: fitRangeHz,
            excludedRangesHz: excludedRangesHz
        )
    }

    /// Reusable Welch primitive. A window is accepted only when it lies wholly
    /// inside one supplied segment and contains finite values.
    static func welch(
        samples: [Double],
        samplingRate: Double,
        segments: [Range<Int>],
        windowSamples: Int,
        overlapFraction: Double = 0.5,
        includeNyquist: Bool = true,
        cancellation: RhythmicityCancellation = RhythmicityCancellation()
    ) throws -> WelchSpectrum {
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw AperiodicSpectrumError.invalidSamplingRate(samplingRate)
        }
        guard windowSamples >= 8,
              windowSamples <= samples.count,
              overlapFraction.isFinite,
              overlapFraction >= 0,
              overlapFraction < 1 else {
            throw AperiodicSpectrumError.insufficientSamples
        }
        try cancellation.check()
        let plan = try RhythmicityDFTPlan(count: windowSamples)
        let overlap = min(Int((Double(windowSamples) * overlapFraction).rounded()), windowSamples - 1)
        let step = max(windowSamples - overlap, 1)
        let outputCount = includeNyquist ? windowSamples / 2 + 1 : windowSamples / 2
        var accumulated = [Double](repeating: 0, count: outputCount)
        let window = periodicHann(count: windowSamples)
        let windowEnergy = window.reduce(0) { $0 + $1 * $1 }
        var accepted = 0

        for range in segments {
            guard range.lowerBound >= 0, range.upperBound <= samples.count else { continue }
            var start = range.lowerBound
            while start + windowSamples <= range.upperBound {
                if accepted & 0x0f == 0 { try cancellation.check() }
                let slice = samples[start..<(start + windowSamples)]
                if slice.allSatisfy(\.isFinite) {
                    let mean = slice.reduce(0, +) / Double(windowSamples)
                    var real = [Double](repeating: 0, count: windowSamples)
                    for local in 0..<windowSamples {
                        real[local] = (samples[start + local] - mean) * window[local]
                    }
                    let transformed = plan.forward(real)
                    for bin in 0..<outputCount {
                        let re = transformed.real[bin]
                        let im = transformed.imaginary[bin]
                        var value = (re * re + im * im) / (samplingRate * windowEnergy)
                        let isNyquist = windowSamples.isMultiple(of: 2) && bin == windowSamples / 2
                        if bin > 0 && !isNyquist { value *= 2 }
                        accumulated[bin] += value
                    }
                    accepted += 1
                }
                start += step
            }
        }
        guard accepted > 0 else { throw AperiodicSpectrumError.insufficientSamples }
        let divisor = Double(accepted)
        let frequencies = (0..<outputCount).map { Double($0) * samplingRate / Double(windowSamples) }
        return WelchSpectrum(
            frequenciesHz: frequencies,
            power: accumulated.map { $0 / divisor },
            windowSamples: windowSamples,
            overlapSamples: overlap,
            windowCount: accepted
        )
    }

    static func fitPowerLaw(
        spectrum: WelchSpectrum,
        fitRangeHz: ClosedRange<Double>,
        excludedRangesHz: [ClosedRange<Double>] = []
    ) throws -> AperiodicSpectrumFit {
        guard fitRangeHz.lowerBound.isFinite,
              fitRangeHz.upperBound.isFinite,
              fitRangeHz.lowerBound > 0,
              fitRangeHz.lowerBound < fitRangeHz.upperBound else {
            throw AperiodicSpectrumError.invalidFitRange(
                lower: fitRangeHz.lowerBound,
                upper: fitRangeHz.upperBound
            )
        }
        let indices = spectrum.frequenciesHz.indices.filter { index in
            let frequency = spectrum.frequenciesHz[index]
            let power = spectrum.power[index]
            return fitRangeHz.contains(frequency)
                && !excludedRangesHz.contains(where: { $0.contains(frequency) })
                && frequency > 0 && frequency.isFinite && power > 0 && power.isFinite
        }
        guard indices.count >= 4 else {
            throw AperiodicSpectrumError.insufficientFitBins(indices.count)
        }

        // Start at the closed-form log/log fit, then minimize error in linear
        // power. The latter matches the power-law fit used for paper surrogates
        // while the log parameterization guarantees a positive coefficient.
        let initial = logLinearStart(
            frequencies: indices.map { spectrum.frequenciesHz[$0] },
            power: indices.map { spectrum.power[$0] }
        )
        let optimum = nelderMead(initial: initial) { parameters in
            let coefficient = pow(10, parameters.0)
            var error = 0.0
            var scale = 0.0
            for index in indices {
                let observed = spectrum.power[index]
                let fitted = coefficient * pow(spectrum.frequenciesHz[index], parameters.1)
                let difference = observed - fitted
                error += difference * difference
                scale += observed * observed
            }
            return error / max(scale, Double.leastNonzeroMagnitude)
        }
        let coefficient = pow(10, optimum.0)
        let fitted = spectrum.frequenciesHz.map { frequency in
            frequency > 0 ? coefficient * pow(frequency, optimum.1) : 0
        }
        let observedFit = indices.map { spectrum.power[$0] }
        let fittedFit = indices.map { fitted[$0] }
        let mean = observedFit.reduce(0, +) / Double(observedFit.count)
        let residual = zip(observedFit, fittedFit).reduce(0.0) { partial, pair in
            partial + (pair.0 - pair.1) * (pair.0 - pair.1)
        }
        let total = observedFit.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        let rSquared = total > 0 ? 1 - residual / total : (residual == 0 ? 1 : .nan)
        return AperiodicSpectrumFit(
            frequenciesHz: spectrum.frequenciesHz,
            observedPower: spectrum.power,
            fittedPower: fitted,
            exponent: optimum.1,
            intercept: optimum.0,
            fitRangeHz: fitRangeHz,
            excludedRangesHz: excludedRangesHz,
            rSquared: rSquared,
            welchWindowSamples: spectrum.windowSamples,
            welchOverlapSamples: spectrum.overlapSamples,
            welchWindowCount: spectrum.windowCount
        )
    }

    /// Symmetric DFT magnitudes with zero DC. Overall magnitude is immaterial
    /// after IAAFT's rank remapping; retaining the fitted scale aids diagnostics.
    static func targetFourierMagnitudes(
        sampleCount: Int,
        samplingRate: Double,
        fit: AperiodicSpectrumFit
    ) -> [Double] {
        guard sampleCount > 0 else { return [] }
        let coefficient = pow(10, fit.intercept)
        return (0..<sampleCount).map { bin in
            if bin == 0 { return 0 }
            let mirroredBin = min(bin, sampleCount - bin)
            let frequency = Double(mirroredBin) * samplingRate / Double(sampleCount)
            let fittedPSD = max(coefficient * pow(frequency, fit.exponent), 0)
            let isNyquist = sampleCount.isMultiple(of: 2) && mirroredBin == sampleCount / 2
            let oneSidedScale = isNyquist ? 1.0 : 0.5
            return sqrt(fittedPSD * samplingRate * Double(sampleCount) * oneSidedScale)
        }
    }

    /// Shared log/log slope used by Channel Health. Rhythmicity inference uses
    /// the linear-power fit above; keeping both policies named prevents a quiet
    /// change to the established health score.
    static func logLogExponent(
        power: [Double],
        binHz: Double,
        fitRangeHz: ClosedRange<Double>,
        excludedRangesHz: [ClosedRange<Double>] = [],
        minimumBinCount: Int = 8
    ) -> Double? {
        guard binHz > 0, fitRangeHz.lowerBound > 0,
              fitRangeHz.lowerBound < fitRangeHz.upperBound else { return nil }
        let lowBin = max(Int((fitRangeHz.lowerBound / binHz).rounded(.down)), 1)
        let highBin = min(Int((fitRangeHz.upperBound / binHz).rounded(.up)), power.count - 1)
        guard highBin >= lowBin else { return nil }
        var xs: [Double] = []
        var ys: [Double] = []
        for bin in lowBin...highBin {
            let frequency = Double(bin) * binHz
            let value = power[bin]
            guard value > 0, value.isFinite,
                  !excludedRangesHz.contains(where: { $0.contains(frequency) }) else { continue }
            xs.append(log10(frequency))
            ys.append(log10(value))
        }
        guard xs.count >= minimumBinCount else { return nil }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var sxx = 0.0
        var sxy = 0.0
        for index in xs.indices {
            let dx = xs[index] - meanX
            sxx += dx * dx
            sxy += dx * (ys[index] - meanY)
        }
        return sxx > 1e-12 ? sxy / sxx : nil
    }

    private static func periodicHann(count: Int) -> [Double] {
        (0..<count).map { index in
            0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count))
        }
    }

    private static func logLinearStart(
        frequencies: [Double],
        power: [Double]
    ) -> (Double, Double) {
        let xs = frequencies.map(log10)
        let ys = power.map(log10)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var sxx = 0.0
        var sxy = 0.0
        for index in xs.indices {
            let dx = xs[index] - meanX
            sxx += dx * dx
            sxy += dx * (ys[index] - meanY)
        }
        let exponent = sxx > 0 ? sxy / sxx : -1
        return (meanY - exponent * meanX, exponent)
    }

    private static func nelderMead(
        initial: (Double, Double),
        objective: ((Double, Double)) -> Double
    ) -> (Double, Double) {
        var simplex = [initial, (initial.0 + 0.05, initial.1), (initial.0, initial.1 + 0.05)]
        var values = simplex.map(objective)
        for _ in 0..<500 {
            let order = values.indices.sorted { values[$0] < values[$1] }
            simplex = order.map { simplex[$0] }
            values = order.map { values[$0] }
            if abs(values[2] - values[0]) < 1e-14 { break }
            let centroid = ((simplex[0].0 + simplex[1].0) / 2, (simplex[0].1 + simplex[1].1) / 2)
            let reflected = (2 * centroid.0 - simplex[2].0, 2 * centroid.1 - simplex[2].1)
            let reflectedValue = objective(reflected)
            if reflectedValue < values[0] {
                let expanded = (3 * centroid.0 - 2 * simplex[2].0, 3 * centroid.1 - 2 * simplex[2].1)
                let expandedValue = objective(expanded)
                (simplex[2], values[2]) = expandedValue < reflectedValue
                    ? (expanded, expandedValue) : (reflected, reflectedValue)
            } else if reflectedValue < values[1] {
                (simplex[2], values[2]) = (reflected, reflectedValue)
            } else {
                let contracted = reflectedValue < values[2]
                    ? ((centroid.0 + reflected.0) / 2, (centroid.1 + reflected.1) / 2)
                    : ((centroid.0 + simplex[2].0) / 2, (centroid.1 + simplex[2].1) / 2)
                let contractedValue = objective(contracted)
                if contractedValue < min(reflectedValue, values[2]) {
                    (simplex[2], values[2]) = (contracted, contractedValue)
                } else {
                    simplex[1] = ((simplex[0].0 + simplex[1].0) / 2, (simplex[0].1 + simplex[1].1) / 2)
                    simplex[2] = ((simplex[0].0 + simplex[2].0) / 2, (simplex[0].1 + simplex[2].1) / 2)
                    values[1] = objective(simplex[1])
                    values[2] = objective(simplex[2])
                }
            }
        }
        let best = values.indices.min { values[$0] < values[$1] } ?? 0
        return simplex[best]
    }
}

/// Shared Double-precision DFT plan. Accelerate's inverse complex transform is
/// unnormalized, so inverse output is divided by N here once for every caller.
nonisolated final class RhythmicityDFTPlan {
    let count: Int
    private let forwardPlan: vDSP.DiscreteFourierTransform<Double>?
    private let inversePlan: vDSP.DiscreteFourierTransform<Double>?
    private let convolutionCount: Int
    private let convolutionForward: vDSP.DiscreteFourierTransform<Double>?
    private let convolutionInverse: vDSP.DiscreteFourierTransform<Double>?
    private let chirpCosine: [Double]
    private let chirpSine: [Double]
    private let bSpectrumReal: [Double]
    private let bSpectrumImaginary: [Double]

    init(count: Int) throws {
        guard count > 0 else { throw AperiodicSpectrumError.transformUnavailable(count) }
        let forward = try? vDSP.DiscreteFourierTransform(
                previous: nil,
                count: count,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Double.self
              )
        let inverse = try? vDSP.DiscreteFourierTransform(
                previous: nil,
                count: count,
                direction: .inverse,
                transformType: .complexComplex,
                ofType: Double.self
              )
        self.count = count
        self.forwardPlan = forward
        self.inversePlan = inverse
        if forward != nil, inverse != nil {
            self.convolutionCount = 0
            self.convolutionForward = nil
            self.convolutionInverse = nil
            self.chirpCosine = []
            self.chirpSine = []
            self.bSpectrumReal = []
            self.bSpectrumImaginary = []
        } else {
            var length = 1
            while length < 2 * count - 1 { length <<= 1 }
            guard let convolutionForward = try? vDSP.DiscreteFourierTransform(
                previous: nil,
                count: length,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Double.self
            ), let convolutionInverse = try? vDSP.DiscreteFourierTransform(
                previous: nil,
                count: length,
                direction: .inverse,
                transformType: .complexComplex,
                ofType: Double.self
            ) else {
                throw AperiodicSpectrumError.transformUnavailable(count)
            }
            self.convolutionCount = length
            self.convolutionForward = convolutionForward
            self.convolutionInverse = convolutionInverse
            let cosine = (0..<count).map { index in
                cos(Double.pi * Double(index) * Double(index) / Double(count))
            }
            let sine = (0..<count).map { index in
                sin(Double.pi * Double(index) * Double(index) / Double(count))
            }
            var bReal = [Double](repeating: 0, count: length)
            var bImaginary = [Double](repeating: 0, count: length)
            for index in 0..<count {
                bReal[index] = cosine[index]
                bImaginary[index] = sine[index]
                if index > 0 {
                    bReal[length - index] = cosine[index]
                    bImaginary[length - index] = sine[index]
                }
            }
            let b = convolutionForward.transform(real: bReal, imaginary: bImaginary)
            self.chirpCosine = cosine
            self.chirpSine = sine
            self.bSpectrumReal = b.real
            self.bSpectrumImaginary = b.imaginary
        }
    }

    func forward(_ real: [Double]) -> (real: [Double], imaginary: [Double]) {
        if let forwardPlan {
            return forwardPlan.transform(
                real: real,
                imaginary: [Double](repeating: 0, count: count)
            )
        }
        return bluesteinForward(
            real: real,
            imaginary: [Double](repeating: 0, count: count)
        )
    }

    func inverse(real: [Double], imaginary: [Double]) -> [Double] {
        let scale = 1 / Double(count)
        if let inversePlan {
            let transformed = inversePlan.transform(real: real, imaginary: imaginary)
            return transformed.real.map { $0 * scale }
        }
        // IDFT(x) = conj(DFT(conj(x))) / N.
        let transformed = bluesteinForward(real: real, imaginary: imaginary.map(-))
        return transformed.real.map { $0 * scale }
    }

    private func bluesteinForward(
        real: [Double],
        imaginary: [Double]
    ) -> (real: [Double], imaginary: [Double]) {
        guard let convolutionForward, let convolutionInverse else {
            return ([], [])
        }
        var aReal = [Double](repeating: 0, count: convolutionCount)
        var aImaginary = [Double](repeating: 0, count: convolutionCount)
        for index in 0..<count {
            let cosine = chirpCosine[index]
            let sine = chirpSine[index]
            aReal[index] = real[index] * cosine + imaginary[index] * sine
            aImaginary[index] = imaginary[index] * cosine - real[index] * sine
        }
        let a = convolutionForward.transform(real: aReal, imaginary: aImaginary)
        var productReal = [Double](repeating: 0, count: convolutionCount)
        var productImaginary = [Double](repeating: 0, count: convolutionCount)
        for index in 0..<convolutionCount {
            productReal[index] = a.real[index] * bSpectrumReal[index]
                - a.imaginary[index] * bSpectrumImaginary[index]
            productImaginary[index] = a.real[index] * bSpectrumImaginary[index]
                + a.imaginary[index] * bSpectrumReal[index]
        }
        let convolution = convolutionInverse.transform(
            real: productReal,
            imaginary: productImaginary
        )
        let convolutionScale = 1 / Double(convolutionCount)
        var outputReal = [Double](repeating: 0, count: count)
        var outputImaginary = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let cosine = chirpCosine[index]
            let sine = chirpSine[index]
            let convolvedReal = convolution.real[index] * convolutionScale
            let convolvedImaginary = convolution.imaginary[index] * convolutionScale
            outputReal[index] = convolvedReal * cosine + convolvedImaginary * sine
            outputImaginary[index] = convolvedImaginary * cosine - convolvedReal * sine
        }
        return (outputReal, outputImaginary)
    }
}
