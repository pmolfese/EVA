//
//  WaveletScalogram.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Time-frequency-power view ("what does this look like to the wavelet?")
//  for a single channel window, built on the existing continuous wavelet
//  transform (`ContinuousWaveletTransform.swift`) — shares nothing with the
//  discrete DWT/SWT engine in `WaveletReducer.swift` beyond the folder, same
//  as that file's own header note.
//

import Foundation

nonisolated struct WaveletScalogramResult: Sendable {
    /// `power[frequencyIndex][timeIndex]`, frequency ascending (row 0 = lowest).
    var power: [[Double]]
    /// Center frequency (Hz) for each row of `power`, ascending.
    var frequenciesHz: [Double]
    var startTimeSeconds: Double
    var endTimeSeconds: Double
    var effectiveSamplingRate: Double
    /// The raw (time-domain) trace actually analyzed, for an optional overlay.
    var trace: [Float]
}

nonisolated enum WaveletScalogram {
    /// Morlet's standard central frequency constant (w0 = 6), used to convert
    /// between CWT scale and pseudo-frequency: `f = (w0 / 2π) * fs / scale`.
    private static let morletCenterFrequency = 6.0 / (2 * Double.pi)

    /// Computes a scalogram for one candidate's channel, over its detected
    /// window plus context padding on each side. Downsamples first so the
    /// direct-convolution CWT (`O(scales × samples × kernelWidth)`, and low
    /// frequencies need wide kernels) stays fast enough for an interactive
    /// popover — this is a "get a feel for it" view, not a publication-grade
    /// analysis, so trading some time resolution for speed is the right call.
    static func compute(
        signal: MFFSignalData,
        channelIndex: Int,
        startSample: Int,
        endSample: Int,
        contextSeconds: Double = 0.5,
        frequencyBandCount: Int = 32,
        maximumAnalysisSamples: Int = 1200,
        wavelet: CWTWavelet = .morlet
    ) -> WaveletScalogramResult? {
        guard signal.samplingRate > 0,
              signal.data.indices.contains(channelIndex),
              endSample > startSample else { return nil }
        let channel = signal.data[channelIndex]
        guard !channel.isEmpty else { return nil }

        let contextSamples = max(Int((contextSeconds * signal.samplingRate).rounded()), 0)
        let paddedStart = max(startSample - contextSamples, 0)
        let paddedEnd = min(endSample + contextSamples, channel.count - 1)
        guard paddedEnd > paddedStart else { return nil }

        let windowSamples = Array(channel[paddedStart...paddedEnd])
        let decimation = max(Int((Double(windowSamples.count) / Double(max(maximumAnalysisSamples, 32))).rounded(.up)), 1)
        let analyzed = decimation > 1 ? Downsampler.windowedSincDecimated(windowSamples, by: decimation) : windowSamples
        guard analyzed.count > 8 else { return nil }
        let effectiveRate = signal.samplingRate / Double(decimation)

        let mean = analyzed.reduce(Float(0), +) / Float(analyzed.count)
        let centered = analyzed.map { Double($0 - mean) }

        // Log-spaced frequencies from ~2 Hz (or whatever the window's
        // duration can resolve) up to a comfortable margin below the
        // (decimated) Nyquist rate.
        let minFrequency = max(2.0, 1.0 / (Double(analyzed.count) / effectiveRate))
        let maxFrequency = max(minFrequency * 1.5, effectiveRate / 2.5)
        let frequencies: [Double] = (0..<frequencyBandCount).map { index in
            let t = Double(index) / Double(max(frequencyBandCount - 1, 1))
            return minFrequency * pow(maxFrequency / minFrequency, t)
        }
        let scales = frequencies.map { frequency in
            morletCenterFrequency * effectiveRate / max(frequency, 1e-6)
        }

        let coefficients = ContinuousWaveletTransform.transform(centered, wavelet: wavelet, scales: scales)
        guard coefficients.count == frequencies.count else { return nil }
        let power = coefficients.map { row in row.map { $0 * $0 } }

        return WaveletScalogramResult(
            power: power,
            frequenciesHz: frequencies,
            startTimeSeconds: Double(paddedStart) / signal.samplingRate,
            endTimeSeconds: Double(paddedEnd) / signal.samplingRate,
            effectiveSamplingRate: effectiveRate,
            trace: analyzed
        )
    }
}
