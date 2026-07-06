//
//  CWLCorrector.swift
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
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Carbon-wire-loop (CWL) artifact correction: a direct EEG correction method
//  (no beat/event detection step, unlike the other BCGDetectionMethod cases)
//  that regresses each EEG channel against a set of external CWL reference
//  channels — the wire-loop pickups, imported as PNS channels — at a small
//  range of time lags, and subtracts the fit.
//
//  This is an original Swift implementation (sliding-window multi-lag linear
//  regression via overlap-add reconstruction), written with reference to the
//  adaptive-regression CWL correction method described in:
//
//    Masterton, R. A. J., Abbott, D. F., Fleming, S. W., & Jackson, G. D. (2007).
//    Measurement and reduction of motion and ballistocardiogram artefacts from
//    simultaneous EEG and fMRI recordings. NeuroImage, 37(1), 202-211.
//
//  and the public CWL-Webinar reference materials / CWRegrTool (MIT License),
//  https://github.com/brain-products/CWL-Webinar — see THIRD_PARTY_NOTICES.md.
//  No code was copied from CWRegrTool (MATLAB); the regression scheme below is
//  a fresh implementation tailored to EVA's Accelerate/LAPACK plumbing
//  (`LinearAlgebra.solveLinearSystem`, `evaConcurrentPerform`).
//

import Accelerate
import Foundation

nonisolated enum CWLCorrector {
    enum CWLCorrectorError: LocalizedError {
        case noReferenceChannels
        case tooShortForWindow(windowSamples: Int, sampleCount: Int)

        var errorDescription: String? {
            switch self {
            case .noReferenceChannels:
                return "No CWL reference channels were selected."
            case .tooShortForWindow(let windowSamples, let sampleCount):
                return "Recording (\(sampleCount) samples) is shorter than the regression window (\(windowSamples) samples)."
            }
        }
    }

    /// Runs CWL regression on `eeg` (shape: channels × time), using
    /// `references` (the selected CWL PNS channels, same sample rate/length
    /// as `eeg`) as the regressors.
    ///
    /// - Parameters:
    ///   - lagRangeMs: Range of time shifts applied to each reference channel
    ///     before regression, capturing the mechanical/hemodynamic delay
    ///     between wire-loop motion and its EEG signature.
    ///   - lagStepMs: Spacing between lag taps within `lagRangeMs`.
    ///   - windowSeconds: Length of the sliding regression window. Windows
    ///     overlap 50% and are cross-faded (triangular weights) on
    ///     reconstruction, which is what makes the fit "adaptive" — the
    ///     coupling coefficients can drift slowly over the recording instead
    ///     of being fixed globally.
    ///   - progress: Optional 0...1 completion callback (per output channel).
    /// - Returns: Corrected channels, same shape as `eeg`.
    nonisolated static func correct(
        eeg: [[Float]],
        references: [[Float]],
        samplingRate: Double,
        lagRangeMs: ClosedRange<Double> = -50...150,
        lagStepMs: Double = 10,
        windowSeconds: Double = 4.0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [[Float]] {
        try Task.checkCancellation()
        guard !references.isEmpty, let sampleCount = references.first?.count, sampleCount > 0 else {
            throw CWLCorrectorError.noReferenceChannels
        }

        let windowSamples = max(Int(windowSeconds * samplingRate), 8)
        guard sampleCount >= windowSamples else {
            throw CWLCorrectorError.tooShortForWindow(windowSamples: windowSamples, sampleCount: sampleCount)
        }

        // Build the lagged design matrix once — each reference channel
        // contributes one shifted copy per lag tap. Shift by `+lag` means the
        // regressor value at time t is the reference's value at t - lag,
        // i.e. a positive lag models the EEG artifact trailing the wire-loop
        // signal (edge-clamped, not zero-padded, to avoid an artificial
        // transient at the recording boundary).
        let lagSamples = stride(from: lagRangeMs.lowerBound, through: lagRangeMs.upperBound, by: max(lagStepMs, 1))
            .map { Int(($0 / 1000.0 * samplingRate).rounded()) }
        let uniqueLags = Array(Set(lagSamples)).sorted()

        var design: [[Float]] = []
        design.reserveCapacity(references.count * uniqueLags.count)
        for ref in references {
            for lag in uniqueLags {
                design.append(shifted(ref, by: lag))
            }
        }

        let channelCount = eeg.count
        var result = eeg

        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0
        let reportEvery = max(1, channelCount / 100)
        nonisolated(unsafe) let capturedDesign = design

        result.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: channelCount) { c in
                guard !Task.isCancelled else { return }
                out[c] = correctChannel(eeg[c], design: capturedDesign, windowSamples: windowSamples)

                if let progress {
                    progressLock.lock()
                    completed += 1
                    let done = completed
                    progressLock.unlock()
                    if done % reportEvery == 0 || done == channelCount {
                        progress(Double(done) / Double(channelCount))
                    }
                }
            }
        }

        return result
    }

    // MARK: - Per-channel sliding regression

    /// Fits and subtracts the CWL-coupled artifact from a single channel via
    /// 50%-overlap sliding windows, cross-fading (triangular weights) the
    /// per-window artifact estimates on reconstruction so the coupling
    /// coefficients can drift smoothly across the recording.
    private static func correctChannel(
        _ channel: [Float],
        design: [[Float]],
        windowSamples: Int
    ) -> [Float] {
        let n = channel.count
        let hop = max(windowSamples / 2, 1)
        let nCols = design.count
        guard nCols > 0 else { return channel }

        var artifactEstimate = [Double](repeating: 0, count: n)
        var weightSum = [Double](repeating: 0, count: n)
        let triangularWeights = triangularWindow(windowSamples)

        var start = 0
        while start < n {
            guard !Task.isCancelled else { return channel }
            let end = min(start + windowSamples, n)
            let length = end - start
            if length >= nCols + 1 {
                if let fitted = regressWindow(y: channel, design: design, range: start..<end) {
                    for i in 0..<length {
                        let w = length == windowSamples ? triangularWeights[i] : 1.0
                        artifactEstimate[start + i] += Double(fitted[i]) * w
                        weightSum[start + i] += w
                    }
                }
            }
            if end == n { break }
            start += hop
        }

        var corrected = channel
        for i in 0..<n where weightSum[i] > 0 {
            corrected[i] -= Float(artifactEstimate[i] / weightSum[i])
        }
        return corrected
    }

    /// Ordinary least squares of `y[range]` on the mean-centred design columns
    /// (also restricted to `range`), solved via the normal equations. Returns
    /// the fitted (reconstructed) artifact estimate over `range`, or `nil` if
    /// the window is degenerate (e.g. a rank-deficient/near-constant design).
    private static func regressWindow(
        y: [Float],
        design: [[Float]],
        range: Range<Int>
    ) -> [Float]? {
        let length = range.count
        let nCols = design.count

        var yMean: Float = 0
        vDSP_meanv(Array(y[range]), 1, &yMean, vDSP_Length(length))
        let yCentered = y[range].map { Double($0) - Double(yMean) }

        var columns: [[Double]] = []
        columns.reserveCapacity(nCols)
        for col in design {
            var mean: Float = 0
            let slice = Array(col[range])
            vDSP_meanv(slice, 1, &mean, vDSP_Length(length))
            columns.append(slice.map { Double($0) - Double(mean) })
        }

        // Normal equations: (XᵀX) beta = Xᵀy
        var xtx = [Double](repeating: 0, count: nCols * nCols)
        var xty = [Double](repeating: 0, count: nCols)
        for i in 0..<nCols {
            xty[i] = LinearAlgebra.dot(columns[i], yCentered)
            for j in i..<nCols {
                let value = LinearAlgebra.dot(columns[i], columns[j])
                xtx[i * nCols + j] = value
                xtx[j * nCols + i] = value
            }
        }
        // Ridge regularization: the lag taps of a slowly-varying reference are
        // highly collinear, so a small diagonal load keeps the normal
        // equations well-conditioned without materially biasing the fit.
        let diagonalMean = (0..<nCols).reduce(0.0) { $0 + xtx[$1 * nCols + $1] } / Double(nCols)
        let ridge = 1e-6 * diagonalMean + 1e-12
        for i in 0..<nCols { xtx[i * nCols + i] += ridge }

        guard let beta = LinearAlgebra.solveLinearSystem(a: &xtx, b: &xty, size: nCols) else { return nil }

        var fitted = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var sum = 0.0
            for c in 0..<nCols { sum += beta[c] * columns[c][i] }
            fitted[i] = Float(sum)
        }
        return fitted
    }

    // MARK: - Utilities

    /// Shifts `signal` by `lag` samples (positive = regressor lags behind,
    /// i.e. `shifted[t] = signal[t - lag]`), clamping at the edges instead of
    /// zero-padding so the regression doesn't see an artificial transient.
    private static func shifted(_ signal: [Float], by lag: Int) -> [Float] {
        guard lag != 0 else { return signal }
        let n = signal.count
        guard n > 0 else { return signal }
        var out = [Float](repeating: 0, count: n)
        for t in 0..<n {
            let src = min(max(t - lag, 0), n - 1)
            out[t] = signal[src]
        }
        return out
    }

    private static func triangularWindow(_ length: Int) -> [Double] {
        guard length > 1 else { return [Double](repeating: 1, count: max(length, 0)) }
        let mid = Double(length - 1) / 2.0
        return (0..<length).map { 1.0 - abs(Double($0) - mid) / (mid + 1) }
    }
}
