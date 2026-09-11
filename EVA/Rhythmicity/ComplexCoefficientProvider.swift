//
//  ComplexCoefficientProvider.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Direct, double-precision coefficient path for the LAVI paper convention.
//  This is intentionally separate from ComplexMorlet, whose sampled kernel is
//  kept MNE-compatible for EVA's ERSP and ITPC implementation.
//

import Foundation

nonisolated struct ComplexCoefficientTile: Sendable, Equatable {
    var frequencyHz: Double
    var real: [Double]
    var imaginary: [Double]
    /// Coefficients whose full wavelet support is immersed in the input.
    var validSampleRange: Range<Int>
}

nonisolated protocol ComplexCoefficientProvider: Sendable {
    /// Produces one frequency tile. Callers can reduce and release the tile
    /// before requesting the next frequency, avoiding a frequency × time cube.
    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile
}

/// Five-cycle Morlet sampling convention used by the maintained LAVI reference.
/// The formula follows the paper's FieldTrip-style ±3σ Gaussian support and
/// deliberately permits an even tap count with a half-sample phase center.
nonisolated enum LAVI2026Morlet {
    struct Kernel: Sendable, Equatable {
        var real: [Double]
        var imaginary: [Double]
        var frequencyHz: Double
        var widthCycles: Double
        var count: Int { real.count }
    }

    static func kernel(
        frequencyHz: Double,
        widthCycles: Double,
        samplingRate: Double
    ) -> Kernel {
        precondition(
            frequencyHz.isFinite && frequencyHz > 0
                && widthCycles.isFinite && widthCycles > 0
                && samplingRate.isFinite && samplingRate > 0,
            "LAVI Morlet parameters must be finite and positive"
        )

        let sigmaFrequency = frequencyHz / widthCycles
        let sigmaTime = 1.0 / (2.0 * Double.pi * sigmaFrequency)
        let supportSamples = 6.0 * sigmaTime * samplingRate
        let tapCount = max(Int(floor(supportSamples + 1e-12)) + 1, 1)
        let amplitude = 1.0 / sqrt(sigmaTime * sqrt(Double.pi))
        // The maintained finite-signal reference applies this transform scale.
        // It cancels from LAVI, but retaining it also pins coefficient fixtures.
        let transformScale = sqrt(2.0 / samplingRate)
        let phaseStep = 2.0 * Double.pi * frequencyHz / samplingRate
        let phaseStart = -Double(tapCount - 1) / 2.0
        let envelopeStart = -3.0 * sigmaTime

        var real = [Double](repeating: 0, count: tapCount)
        var imaginary = [Double](repeating: 0, count: tapCount)
        for index in 0..<tapCount {
            let envelopeTime = envelopeStart + Double(index) / samplingRate
            let envelope = amplitude
                * exp(-(envelopeTime * envelopeTime) / (2.0 * sigmaTime * sigmaTime))
                * transformScale
            let phase = (phaseStart + Double(index)) * phaseStep
            real[index] = envelope * cos(phase)
            imaginary[index] = envelope * sin(phase)
        }
        return Kernel(
            real: real,
            imaginary: imaginary,
            frequencyHz: frequencyHz,
            widthCycles: widthCycles
        )
    }

    /// Exact translation of the reference's one-based immersion inequalities:
    /// `time >= tapCount/2 && time < sampleCount - tapCount/2`.
    static func validSampleRange(sampleCount: Int, tapCount: Int) -> Range<Int> {
        guard sampleCount > 0, tapCount > 0 else { return 0..<0 }
        let lower = min(max(Int(ceil(Double(tapCount) / 2.0)) - 1, 0), sampleCount)
        let upper = max(
            min(
                Int(ceil(Double(sampleCount) - Double(tapCount) / 2.0 - 1.0)),
                sampleCount
            ),
            0
        )
        guard upper > lower else { return lower..<lower }
        return lower..<upper
    }
}

/// Canonical correctness implementation. Production all-channel analysis will
/// add an FFT tile provider without changing this protocol or reference path.
nonisolated struct DirectComplexCoefficientProvider: ComplexCoefficientProvider {
    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile {
        try cancellation.check()
        let kernel = LAVI2026Morlet.kernel(
            frequencyHz: frequencyHz,
            widthCycles: widthCycles,
            samplingRate: samplingRate
        )
        guard !signal.isEmpty else {
            return ComplexCoefficientTile(
                frequencyHz: frequencyHz,
                real: [],
                imaginary: [],
                validSampleRange: 0..<0
            )
        }

        let sampleCount = signal.count
        let tapCount = kernel.count
        var outputReal = [Double](repeating: 0, count: sampleCount)
        var outputImaginary = [Double](repeating: 0, count: sampleCount)

        // Full linear convolution, cropped with ceil((tapCount - 1) / 2).
        // For even kernels this is one sample to the right of NumPy's default
        // `same` crop and matches the maintained LAVI FFT/fftshift alignment.
        let cropOffset = tapCount / 2
        for outputIndex in 0..<sampleCount {
            if outputIndex & 0x7f == 0 { try cancellation.check() }
            let fullIndex = outputIndex + cropOffset
            let firstTap = max(0, fullIndex - (sampleCount - 1))
            let lastTap = min(tapCount - 1, fullIndex)
            guard firstTap <= lastTap else { continue }

            var real = 0.0
            var imaginary = 0.0
            for tapIndex in firstTap...lastTap {
                let signalIndex = fullIndex - tapIndex
                let sample = signal[signalIndex]
                real += sample * kernel.real[tapIndex]
                imaginary += sample * kernel.imaginary[tapIndex]
            }
            outputReal[outputIndex] = real
            outputImaginary[outputIndex] = imaginary
        }

        let validRange: Range<Int>
        switch edgePolicy {
        case .referenceSamePadding:
            validRange = 0..<sampleCount
        case .validOnly:
            validRange = LAVI2026Morlet.validSampleRange(
                sampleCount: sampleCount,
                tapCount: tapCount
            )
        }
        return ComplexCoefficientTile(
            frequencyHz: frequencyHz,
            real: outputReal,
            imaginary: outputImaginary,
            validSampleRange: validRange
        )
    }
}
