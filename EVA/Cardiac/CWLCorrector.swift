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

    struct ProgressUpdate: Sendable {
        enum Phase: String, Sendable {
            case preparing
            case cachingWindows
            case correcting
            case finished
        }

        let fraction: Double
        let phase: Phase
        let message: String
        let detail: String?
    }

    enum DownsampleFilter: String, CaseIterable, Identifiable, Sendable {
        case windowedSinc
        case blockAverage

        var id: String { rawValue }

        var label: String {
            switch self {
            case .windowedSinc:
                return "Windowed-sinc low-pass"
            case .blockAverage:
                return "Block average (fast)"
            }
        }

        var shortLabel: String {
            switch self {
            case .windowedSinc:
                return "windowed-sinc"
            case .blockAverage:
                return "block average"
            }
        }
    }

    enum Algorithm: String, Sendable {
        case cwRegrTool
        case evaFast

        var label: String {
            switch self {
            case .cwRegrTool:
                return "CWRegrTool-compatible"
            case .evaFast:
                return "EVA Fast CWR"
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
    ///   - progress: Optional 0...1 completion callback with phase details.
    ///   - debugLog: Optional diagnostic logger for long-running corrections.
    /// - Returns: Corrected channels, same shape as `eeg`.
    nonisolated static func correct(
        eeg: [[Float]],
        references: [[Float]],
        samplingRate: Double,
        lagRangeMs: ClosedRange<Double> = -50...150,
        lagStepMs: Double = 10,
        cwlToolDelayMs: Double = 21,
        windowSeconds: Double = 4.0,
        algorithm: Algorithm = .cwRegrTool,
        downsampleFactor: Int = 1,
        downsampleFilter: DownsampleFilter = .windowedSinc,
        upsampleToOriginalRate: Bool = false,
        progress: (@Sendable (ProgressUpdate) -> Void)? = nil,
        debugLog: (@Sendable (String) -> Void)? = nil
    ) throws -> [[Float]] {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        try Task.checkCancellation()
        guard !references.isEmpty, let sampleCount = references.first?.count, sampleCount > 0 else {
            throw CWLCorrectorError.noReferenceChannels
        }

        let requestedDownsampleFactor = max(downsampleFactor, 1)
        if requestedDownsampleFactor > 1 {
            return try correctDownsampled(
                eeg: eeg,
                references: references,
                samplingRate: samplingRate,
                lagRangeMs: lagRangeMs,
                lagStepMs: lagStepMs,
                cwlToolDelayMs: cwlToolDelayMs,
                windowSeconds: windowSeconds,
                algorithm: algorithm,
                downsampleFactor: requestedDownsampleFactor,
                downsampleFilter: downsampleFilter,
                upsampleToOriginalRate: upsampleToOriginalRate,
                progress: progress,
                debugLog: debugLog
            )
        }

        if algorithm == .cwRegrTool {
            return try correctCWRegrToolCompatible(
                eeg: eeg,
                references: references,
                samplingRate: samplingRate,
                delayMs: cwlToolDelayMs,
                windowSeconds: windowSeconds,
                progress: progress,
                debugLog: debugLog
            )
        }

        let windowSamples = max(Int(windowSeconds * samplingRate), 8)
        guard sampleCount >= windowSamples else {
            throw CWLCorrectorError.tooShortForWindow(windowSamples: windowSamples, sampleCount: sampleCount)
        }

        let channelCount = eeg.count
        debugLog?(
            "CWL: starting correction; EEG channels=\(channelCount), references=\(references.count), " +
            "samples=\(sampleCount), samplingRate=\(format(samplingRate)) Hz, " +
            "window=\(windowSamples) samples (\(format(windowSeconds)) s)"
        )
        progress?(
            ProgressUpdate(
                fraction: 0,
                phase: .preparing,
                message: "Preparing CWL correction",
                detail: "\(references.count) reference channel\(references.count == 1 ? "" : "s")"
            )
        )

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

        var result = eeg
        guard channelCount > 0 else {
            progress?(
                ProgressUpdate(
                    fraction: 1,
                    phase: .finished,
                    message: "CWL correction complete",
                    detail: "No EEG channels"
                )
            )
            return result
        }

        debugLog?(
            "CWL: built lagged design; lags=\(uniqueLags.count), columns=\(design.count), " +
            "lagRange=\(format(lagRangeMs.lowerBound))...\(format(lagRangeMs.upperBound)) ms, " +
            "lagStep=\(format(lagStepMs)) ms"
        )
        let windows = try makeRegressionWindows(
            design: design,
            sampleCount: sampleCount,
            windowSamples: windowSamples
        ) { fraction in
            progress?(
                ProgressUpdate(
                    fraction: 0.12 * fraction,
                    phase: .cachingWindows,
                    message: "Preparing CWL windows",
                    detail: "\(Int((fraction * 100).rounded()))% of windows"
                )
            )
        }
        let triangularWeights = triangularWindow(windowSamples)
        let weightSum = overlapWeightSum(
            sampleCount: sampleCount,
            windows: windows,
            windowSamples: windowSamples,
            triangularWeights: triangularWeights
        )
        let channelRanges = channelBatches(channelCount: channelCount)
        let usableWindowCount = windows.filter { canSolve($0) }.count
        debugLog?(
            "CWL: window cache ready; windows=\(windows.count), usable=\(usableWindowCount), " +
            "batches=\(channelRanges.count), elapsed=\(elapsedString(since: startedAt))"
        )
        progress?(
            ProgressUpdate(
                fraction: 0.12,
                phase: .correcting,
                message: "Correcting CWL",
                detail: "\(channelRanges.count) channel batch\(channelRanges.count == 1 ? "" : "es"), \(windows.count) windows"
            )
        )

        let progressLock = NSLock()
        let logLock = NSLock()
        nonisolated(unsafe) var completedWindowBatches = 0
        nonisolated(unsafe) var lastLogTick = DispatchTime.now().uptimeNanoseconds
        let totalWindowBatches = max(channelRanges.count * max(windows.count, 1), 1)
        let reportEvery = max(1, totalWindowBatches / 250)
        let capturedDesign = design
        let capturedWindows = windows
        let capturedTriangularWeights = triangularWeights
        let capturedWeightSum = weightSum
        let capturedRanges = channelRanges

        result.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: capturedRanges.count) { batchIndex in
                guard !Task.isCancelled else { return }
                let range = capturedRanges[batchIndex]
                let batchStartedAt = DispatchTime.now().uptimeNanoseconds
                debugLog?(
                    "CWL: batch \(batchIndex + 1)/\(capturedRanges.count) started; " +
                    "channels \(range.lowerBound + 1)-\(range.upperBound)"
                )
                let correctedBatch = correctChannelBatch(
                    eeg: eeg,
                    channelRange: range,
                    design: capturedDesign,
                    windows: capturedWindows,
                    windowSamples: windowSamples,
                    triangularWeights: capturedTriangularWeights,
                    weightSum: capturedWeightSum
                ) { windowIndex in
                    progressLock.lock()
                    completedWindowBatches += 1
                    let done = completedWindowBatches
                    progressLock.unlock()

                    if let progress, done % reportEvery == 0 || done == totalWindowBatches {
                        progress(
                            ProgressUpdate(
                                fraction: 0.12 + 0.88 * Double(done) / Double(totalWindowBatches),
                                phase: .correcting,
                                message: "Correcting CWL",
                                detail: "batch \(batchIndex + 1)/\(capturedRanges.count), window \(windowIndex + 1)/\(capturedWindows.count)"
                            )
                        )
                    }

                    guard let debugLog else { return }
                    let now = DispatchTime.now().uptimeNanoseconds
                    logLock.lock()
                    let shouldLog = now - lastLogTick >= 5_000_000_000 || done == totalWindowBatches
                    if shouldLog {
                        lastLogTick = now
                    }
                    logLock.unlock()
                    if shouldLog {
                        debugLog(
                            "CWL: correcting \(done)/\(totalWindowBatches) batch-windows " +
                            "(\(Int((Double(done) / Double(totalWindowBatches) * 100).rounded()))% of correction phase), " +
                            "elapsed=\(elapsedString(since: startedAt, now: now))"
                        )
                    }
                }
                for (offset, channel) in range.enumerated() {
                    out[channel] = correctedBatch[offset]
                }

                debugLog?(
                    "CWL: batch \(batchIndex + 1)/\(capturedRanges.count) finished; " +
                    "elapsed=\(elapsedString(since: batchStartedAt))"
                )
            }
        }

        debugLog?("CWL: correction complete; elapsed=\(elapsedString(since: startedAt))")
        progress?(
            ProgressUpdate(
                fraction: 1,
                phase: .finished,
                message: "CWL correction complete",
                detail: "elapsed \(elapsedString(since: startedAt))"
            )
        )
        return result
    }

    // MARK: - CWRegrTool-compatible tapered Hann regression

    private static func correctCWRegrToolCompatible(
        eeg: [[Float]],
        references: [[Float]],
        samplingRate: Double,
        delayMs: Double,
        windowSeconds: Double,
        progress: (@Sendable (ProgressUpdate) -> Void)?,
        debugLog: (@Sendable (String) -> Void)?
    ) throws -> [[Float]] {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        try Task.checkCancellation()
        guard let sampleCount = references.first?.count, sampleCount > 0 else {
            throw CWLCorrectorError.noReferenceChannels
        }

        let channelCount = eeg.count
        guard channelCount > 0 else {
            progress?(
                ProgressUpdate(
                    fraction: 1,
                    phase: .finished,
                    message: "CWL correction complete",
                    detail: "No EEG channels"
                )
            )
            return eeg
        }

        let delaySamples = max(Int(floor(samplingRate * max(delayMs, 0) / 1000.0)), 0)
        let windowSamples = cwRegrToolWindowSamples(samplingRate: samplingRate, windowSeconds: windowSeconds)
        guard sampleCount >= windowSamples else {
            throw CWLCorrectorError.tooShortForWindow(windowSamples: windowSamples, sampleCount: sampleCount)
        }

        let stepSamples = max((windowSamples - 1) / 2, 1)
        let lags = Array(stride(from: delaySamples, through: -delaySamples, by: -1))
        let columnCount = references.count * lags.count
        let hann = hannWindow(windowSamples)
        let starts = cwRegrToolWindowStarts(sampleCount: sampleCount, windowSamples: windowSamples, stepSamples: stepSamples)
        debugLog?(
            "CWL: starting CWRegrTool-compatible correction; EEG channels=\(channelCount), " +
            "references=\(references.count), samples=\(sampleCount), samplingRate=\(format(samplingRate)) Hz, " +
            "delay=\(delaySamples) samples (\(format(delayMs)) ms), window=\(windowSamples) samples, " +
            "columns=\(columnCount), windows=\(starts.count)"
        )
        progress?(
            ProgressUpdate(
                fraction: 0,
                phase: .preparing,
                message: "Preparing CWRegrTool CWR",
                detail: "\(references.count) reference channel\(references.count == 1 ? "" : "s"), ±\(delaySamples) samples"
            )
        )

        var artifactSum = Array(
            repeating: [Double](repeating: 0, count: sampleCount),
            count: channelCount
        )
        var weightSum = [Double](repeating: 0, count: sampleCount)
        let reportEvery = max(1, starts.count / 250)

        for (windowIndex, start) in starts.enumerated() {
            try Task.checkCancellation()
            let design = cwRegrToolDesignColumnMajor(
                references: references,
                start: start,
                windowSamples: windowSamples,
                lags: lags,
                window: hann
            )
            let rhs = cwRegrToolRHSColumnMajor(
                eeg: eeg,
                start: start,
                windowSamples: windowSamples,
                window: hann
            )
            guard let fitted = fitCWRegrToolWindow(
                designColumnMajor: design,
                rhsColumnMajor: rhs,
                rows: windowSamples,
                columns: columnCount,
                rightHandSideCount: channelCount
            ) else {
                debugLog?("CWL: CWRegrTool-compatible window \(windowIndex + 1)/\(starts.count) failed to solve; skipping")
                continue
            }

            for offset in 0..<windowSamples {
                let sample = start + offset
                guard sample < sampleCount else { continue }
                let weight = hann[offset]
                guard weight > 0 else { continue }
                weightSum[sample] += weight
                for channel in 0..<channelCount {
                    artifactSum[channel][sample] += fitted[channel * windowSamples + offset]
                }
            }

            if let progress, (windowIndex + 1) % reportEvery == 0 || windowIndex + 1 == starts.count {
                progress(
                    ProgressUpdate(
                        fraction: Double(windowIndex + 1) / Double(max(starts.count, 1)),
                        phase: .correcting,
                        message: "Correcting CWRegrTool CWR",
                        detail: "window \(windowIndex + 1)/\(starts.count)"
                    )
                )
            }
        }

        var corrected = eeg
        for channel in 0..<channelCount {
            for sample in 0..<sampleCount where weightSum[sample] > 0 {
                corrected[channel][sample] -= Float(artifactSum[channel][sample] / weightSum[sample])
            }
        }

        debugLog?("CWL: CWRegrTool-compatible correction complete; elapsed=\(elapsedString(since: startedAt))")
        progress?(
            ProgressUpdate(
                fraction: 1,
                phase: .finished,
                message: "CWL correction complete",
                detail: "CWRegrTool-compatible, elapsed \(elapsedString(since: startedAt))"
            )
        )
        return corrected
    }

    private static func cwRegrToolWindowSamples(samplingRate: Double, windowSeconds: Double) -> Int {
        var windowSamples = max(Int(floor(samplingRate * windowSeconds + 1)), 8)
        while (windowSamples - 1) % 2 != 0 {
            windowSamples += 1
        }
        return windowSamples
    }

    private static func cwRegrToolWindowStarts(
        sampleCount: Int,
        windowSamples: Int,
        stepSamples: Int
    ) -> [Int] {
        guard sampleCount >= windowSamples else { return [] }
        var starts: [Int] = []
        var start = 0
        while start + windowSamples <= sampleCount {
            starts.append(start)
            start += stepSamples
        }
        let finalStart = sampleCount - windowSamples
        if starts.last != finalStart {
            starts.append(finalStart)
        }
        return starts
    }

    private static func cwRegrToolDesignColumnMajor(
        references: [[Float]],
        start: Int,
        windowSamples: Int,
        lags: [Int],
        window: [Double]
    ) -> [Double] {
        let columnCount = references.count * lags.count
        var design = [Double](repeating: 0, count: windowSamples * columnCount)
        var column = 0
        for reference in references {
            for lag in lags {
                let base = column * windowSamples
                for row in 0..<windowSamples {
                    let sourceOffset = reflectedIndex(row - lag, count: windowSamples)
                    design[base + row] = Double(reference[start + sourceOffset]) * window[row]
                }
                column += 1
            }
        }
        return design
    }

    private static func cwRegrToolRHSColumnMajor(
        eeg: [[Float]],
        start: Int,
        windowSamples: Int,
        window: [Double]
    ) -> [Double] {
        var rhs = [Double](repeating: 0, count: windowSamples * eeg.count)
        for channel in eeg.indices {
            let base = channel * windowSamples
            for row in 0..<windowSamples {
                rhs[base + row] = Double(eeg[channel][start + row]) * window[row]
            }
        }
        return rhs
    }

    private static func fitCWRegrToolWindow(
        designColumnMajor: [Double],
        rhsColumnMajor: [Double],
        rows: Int,
        columns: Int,
        rightHandSideCount: Int
    ) -> [Double]? {
        guard rows > 0, columns > 0, rightHandSideCount > 0 else { return nil }
        guard designColumnMajor.count == rows * columns,
              rhsColumnMajor.count == rows * rightHandSideCount else {
            return nil
        }
        guard let beta = solveLeastSquaresSVD(
            designColumnMajor: designColumnMajor,
            rhsColumnMajor: rhsColumnMajor,
            rows: rows,
            columns: columns,
            rightHandSideCount: rightHandSideCount
        ) else {
            return nil
        }

        var fitted = [Double](repeating: 0, count: rows * rightHandSideCount)
        cblas_dgemm(
            CblasColMajor,
            CblasNoTrans,
            CblasNoTrans,
            Int32(rows),
            Int32(rightHandSideCount),
            Int32(columns),
            1.0,
            designColumnMajor,
            Int32(rows),
            beta,
            Int32(columns),
            0.0,
            &fitted,
            Int32(rows)
        )
        return fitted
    }

    private static func solveLeastSquaresSVD(
        designColumnMajor: [Double],
        rhsColumnMajor: [Double],
        rows: Int,
        columns: Int,
        rightHandSideCount: Int
    ) -> [Double]? {
        let leadingB = max(rows, columns)
        var paddedRHS = [Double](repeating: 0, count: leadingB * rightHandSideCount)
        for rhs in 0..<rightHandSideCount {
            for row in 0..<rows {
                paddedRHS[rhs * leadingB + row] = rhsColumnMajor[rhs * rows + row]
            }
        }

        var m = LAPACKInt(rows)
        var n = LAPACKInt(columns)
        var nrhs = LAPACKInt(rightHandSideCount)
        var lda = LAPACKInt(rows)
        var ldb = LAPACKInt(leadingB)
        var singularValues = [Double](repeating: 0, count: min(rows, columns))
        var rcond = -1.0
        var rank = LAPACKInt(0)
        var lwork = LAPACKInt(-1)
        var workQuery = [Double](repeating: 0, count: 1)
        var iwork = [LAPACKInt](repeating: 0, count: gelsdIWorkLength(rows: rows, columns: columns))
        var info = LAPACKInt(0)
        var queryA = designColumnMajor
        var queryB = paddedRHS

        dgelsd_(
            &m,
            &n,
            &nrhs,
            &queryA,
            &lda,
            &queryB,
            &ldb,
            &singularValues,
            &rcond,
            &rank,
            &workQuery,
            &lwork,
            &iwork,
            &info
        )
        guard info == 0, workQuery[0].isFinite else { return nil }

        lwork = LAPACKInt(max(1, Int(workQuery[0].rounded(.up))))
        var work = [Double](repeating: 0, count: Int(lwork))
        var a = designColumnMajor
        var b = paddedRHS
        singularValues = [Double](repeating: 0, count: min(rows, columns))
        iwork = [LAPACKInt](repeating: 0, count: gelsdIWorkLength(rows: rows, columns: columns))
        info = 0

        dgelsd_(
            &m,
            &n,
            &nrhs,
            &a,
            &lda,
            &b,
            &ldb,
            &singularValues,
            &rcond,
            &rank,
            &work,
            &lwork,
            &iwork,
            &info
        )
        guard info == 0 else { return nil }

        var beta = [Double](repeating: 0, count: columns * rightHandSideCount)
        for rhs in 0..<rightHandSideCount {
            for row in 0..<columns {
                beta[rhs * columns + row] = b[rhs * leadingB + row]
            }
        }
        return beta
    }

    private static func gelsdIWorkLength(rows: Int, columns: Int) -> Int {
        let minDimension = max(min(rows, columns), 1)
        let smallSize = 25
        let ratio = Double(minDimension) / Double(smallSize + 1)
        let levels = max(0, Int(floor(log2(max(ratio, 1))))) + 1
        return max(1, 3 * minDimension * levels + 11 * minDimension)
    }

    private static func correctDownsampled(
        eeg: [[Float]],
        references: [[Float]],
        samplingRate: Double,
        lagRangeMs: ClosedRange<Double>,
        lagStepMs: Double,
        cwlToolDelayMs: Double,
        windowSeconds: Double,
        algorithm: Algorithm,
        downsampleFactor: Int,
        downsampleFilter: DownsampleFilter,
        upsampleToOriginalRate: Bool,
        progress: (@Sendable (ProgressUpdate) -> Void)?,
        debugLog: (@Sendable (String) -> Void)?
    ) throws -> [[Float]] {
        let factor = max(downsampleFactor, 1)
        guard factor > 1, let sampleCount = eeg.first?.count, sampleCount > factor * 8 else {
            debugLog?("CWL: downsample request skipped; recording is too short for factor \(downsampleFactor)")
            return try correct(
                eeg: eeg,
                references: references,
                samplingRate: samplingRate,
                lagRangeMs: lagRangeMs,
                lagStepMs: lagStepMs,
                cwlToolDelayMs: cwlToolDelayMs,
                windowSeconds: windowSeconds,
                algorithm: algorithm,
                downsampleFactor: 1,
                downsampleFilter: downsampleFilter,
                upsampleToOriginalRate: false,
                progress: progress,
                debugLog: debugLog
            )
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let effectiveRate = Downsampler.effectiveRate(sourceRate: samplingRate, factor: factor)
        debugLog?(
            "CWL: internal downsample enabled; factor=\(factor), " +
            "effectiveRate=\(format(effectiveRate)) Hz, originalRate=\(format(samplingRate)) Hz, " +
            "filter=\(downsampleFilter.shortLabel)"
        )
        progress?(
            ProgressUpdate(
                fraction: 0,
                phase: .preparing,
                message: "Downsampling CWL input",
                detail: "\(format(samplingRate)) Hz to \(format(effectiveRate)) Hz, \(downsampleFilter.shortLabel)"
            )
        )

        let downsampledEEG = downsampleChannels(eeg, factor: factor, filter: downsampleFilter)
        let downsampledReferences = downsampleChannels(references, factor: factor, filter: downsampleFilter)
        try Task.checkCancellation()

        let correctedDownsampled = try correct(
            eeg: downsampledEEG,
            references: downsampledReferences,
            samplingRate: effectiveRate,
            lagRangeMs: lagRangeMs,
            lagStepMs: lagStepMs,
            cwlToolDelayMs: cwlToolDelayMs,
            windowSeconds: windowSeconds,
            algorithm: algorithm,
            downsampleFactor: 1,
            downsampleFilter: downsampleFilter,
            upsampleToOriginalRate: false,
            progress: { update in
                let mappedFraction = 0.04 + (upsampleToOriginalRate ? 0.86 : 0.96) * min(max(update.fraction, 0), 1)
                let mappedMessage = update.phase == .finished && upsampleToOriginalRate
                    ? "Reconstructing CWL correction"
                    : update.message
                let mappedDetail: String?
                if update.phase == .finished {
                    mappedDetail = upsampleToOriginalRate
                        ? "mapping \(format(effectiveRate)) Hz estimate to \(format(samplingRate)) Hz"
                        : "output \(format(effectiveRate)) Hz"
                } else {
                    mappedDetail = update.detail
                }
                progress?(
                    ProgressUpdate(
                        fraction: mappedFraction,
                        phase: update.phase == .finished && upsampleToOriginalRate ? .correcting : update.phase,
                        message: mappedMessage,
                        detail: mappedDetail
                    )
                )
            },
            debugLog: debugLog
        )

        guard upsampleToOriginalRate else {
            debugLog?("CWL: downsampled correction complete; elapsed=\(elapsedString(since: startedAt))")
            progress?(
                ProgressUpdate(
                    fraction: 1,
                    phase: .finished,
                    message: "CWL correction complete",
                    detail: "fit and output at \(format(effectiveRate)) Hz with \(downsampleFilter.shortLabel)"
                )
            )
            return correctedDownsampled
        }

        progress?(
            ProgressUpdate(
                fraction: 0.92,
                phase: .correcting,
                message: "Reconstructing CWL correction",
                detail: "full-rate output"
            )
        )
        let corrected = reconstructFullRateCorrection(
            originalEEG: eeg,
            downsampledEEG: downsampledEEG,
            correctedDownsampled: correctedDownsampled,
            factor: factor
        )
        debugLog?("CWL: downsampled correction reconstructed; elapsed=\(elapsedString(since: startedAt))")
        progress?(
            ProgressUpdate(
                fraction: 1,
                phase: .finished,
                message: "CWL correction complete",
                detail: "fit at \(format(effectiveRate)) Hz with \(downsampleFilter.shortLabel), output \(format(samplingRate)) Hz"
            )
        )
        return corrected
    }

    private static func downsampleChannels(
        _ channels: [[Float]],
        factor: Int,
        filter: DownsampleFilter
    ) -> [[Float]] {
        guard factor > 1, !channels.isEmpty else { return channels }
        var downsampled = Array(repeating: [Float](), count: channels.count)
        downsampled.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: channels.count) { channel in
                switch filter {
                case .windowedSinc:
                    out[channel] = Downsampler.windowedSincDecimated(channels[channel], by: factor)
                case .blockAverage:
                    out[channel] = Downsampler.blockAveraged(channels[channel], by: factor)
                }
            }
        }
        return downsampled
    }

    private static func reconstructFullRateCorrection(
        originalEEG: [[Float]],
        downsampledEEG: [[Float]],
        correctedDownsampled: [[Float]],
        factor: Int
    ) -> [[Float]] {
        guard factor > 1, !originalEEG.isEmpty else { return originalEEG }
        var corrected = originalEEG
        corrected.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: originalEEG.count) { channel in
                guard downsampledEEG.indices.contains(channel),
                      correctedDownsampled.indices.contains(channel) else { return }
                let lowOriginal = downsampledEEG[channel]
                let lowCorrected = correctedDownsampled[channel]
                let lowCount = min(lowOriginal.count, lowCorrected.count)
                guard lowCount > 0 else { return }

                var lowArtifact = [Double](repeating: 0, count: lowCount)
                for index in 0..<lowCount {
                    lowArtifact[index] = Double(lowOriginal[index] - lowCorrected[index])
                }
                let artifact = Downsampler.linearUpsample(
                    lowArtifact,
                    toLength: originalEEG[channel].count,
                    factor: factor
                )
                for sample in originalEEG[channel].indices {
                    out[channel][sample] = originalEEG[channel][sample] - Float(artifact[sample])
                }
            }
        }
        return corrected
    }

    // MARK: - Per-channel sliding regression

    private struct RegressionWindow: Sendable {
        let range: Range<Int>
        let designMeans: [Double]
        let fallbackMatrix: [Double]
        let factorization: LinearAlgebra.LUFactorization?
    }

    private static func makeRegressionWindows(
        design: [[Float]],
        sampleCount: Int,
        windowSamples: Int,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [RegressionWindow] {
        let nCols = design.count
        guard nCols > 0 else {
            progress?(1)
            return []
        }

        let hop = max(windowSamples / 2, 1)
        var ranges: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + windowSamples, sampleCount)
            if end - start >= nCols + 1 {
                ranges.append(start..<end)
            }
            if end == sampleCount { break }
            start += hop
        }

        guard !ranges.isEmpty else {
            progress?(1)
            return []
        }

        let finalizedRanges = ranges
        let workerCount = min(finalizedRanges.count, evaMaxWorkers)
        var windows = [RegressionWindow?](repeating: nil, count: finalizedRanges.count)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0
        let reportEvery = max(1, finalizedRanges.count / 100)

        windows.withUnsafeMutableBufferPointer { buffer in
            let output = GradientUnsafeSendable(base: buffer.baseAddress!)
            evaConcurrentPerform(iterations: workerCount) { worker in
                var offset = worker
                while offset < finalizedRanges.count {
                    guard !Task.isCancelled else { return }
                    output.base[offset] = makeRegressionWindow(
                        design: design,
                        nCols: nCols,
                        range: finalizedRanges[offset]
                    )

                    if let progress {
                        progressLock.lock()
                        completed += 1
                        let done = completed
                        progressLock.unlock()
                        if done % reportEvery == 0 || done == finalizedRanges.count {
                            progress(Double(done) / Double(finalizedRanges.count))
                        }
                    }
                    offset += workerCount
                }
            }
        }

        try Task.checkCancellation()
        return windows.compactMap { $0 }
    }

    private static func makeRegressionWindow(
        design: [[Float]],
        nCols: Int,
        range: Range<Int>
    ) -> RegressionWindow {
        let means = design.map { mean(of: $0, in: range) }
        let centeredDesign = centeredDesignRowMajor(design: design, range: range, means: means)
        var xtx = [Double](repeating: 0, count: nCols * nCols)
        cblas_dgemm(
            CblasRowMajor,
            CblasTrans,
            CblasNoTrans,
            Int32(nCols),
            Int32(nCols),
            Int32(range.count),
            1.0,
            centeredDesign,
            Int32(nCols),
            centeredDesign,
            Int32(nCols),
            0.0,
            &xtx,
            Int32(nCols)
        )

        let diagonalMean = (0..<nCols).reduce(0.0) { $0 + xtx[$1 * nCols + $1] } / Double(nCols)
        let ridge = 1e-6 * diagonalMean + 1e-12
        for i in 0..<nCols { xtx[i * nCols + i] += ridge }

        let factorization = LinearAlgebra.factorLinearSystem(a: xtx, size: nCols)
        return RegressionWindow(
            range: range,
            designMeans: means,
            fallbackMatrix: factorization == nil ? xtx : [],
            factorization: factorization
        )
    }

    private static func overlapWeightSum(
        sampleCount: Int,
        windows: [RegressionWindow],
        windowSamples: Int,
        triangularWeights: [Double]
    ) -> [Double] {
        var weightSum = [Double](repeating: 0, count: sampleCount)
        for window in windows where canSolve(window) {
            let length = window.range.count
            let fullLengthWindow = length == windowSamples
            for offset in 0..<length {
                let sample = window.range.lowerBound + offset
                guard sample < sampleCount else { continue }
                weightSum[sample] += fullLengthWindow && offset < triangularWeights.count
                    ? triangularWeights[offset]
                    : 1.0
            }
        }
        return weightSum
    }

    private static func channelBatches(channelCount: Int) -> [Range<Int>] {
        guard channelCount > 0 else { return [] }
        let targetWorkers = max(evaMaxWorkers, 1)
        let batchSize = max(1, min(16, Int(ceil(Double(channelCount) / Double(targetWorkers)))))
        var ranges: [Range<Int>] = []
        var start = 0
        while start < channelCount {
            let end = min(start + batchSize, channelCount)
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// Fits and subtracts the CWL-coupled artifact from a channel batch via
    /// BLAS/LAPACK: X'Y for all channels in the batch, one multi-RHS solve,
    /// then Xβ reconstruction. Windows are cross-faded with precomputed
    /// overlap weights so we do not need a full-size artifact accumulation
    /// buffer per channel.
    private static func correctChannelBatch(
        eeg: [[Float]],
        channelRange: Range<Int>,
        design: [[Float]],
        windows: [RegressionWindow],
        windowSamples: Int,
        triangularWeights: [Double],
        weightSum: [Double],
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [[Float]] {
        let channels = Array(channelRange)
        var corrected = channels.map { eeg[$0] }
        let nCols = design.count
        let batchCount = channels.count
        guard !windows.isEmpty, nCols > 0, batchCount > 0 else { return corrected }

        for (windowIndex, window) in windows.enumerated() {
            defer { progress?(windowIndex) }
            guard !Task.isCancelled else { return corrected }
            let length = window.range.count
            guard canSolve(window), length > 0, window.designMeans.count == nCols else { continue }

            let centeredDesign = centeredDesignRowMajor(
                design: design,
                range: window.range,
                means: window.designMeans
            )
            let centeredY = centeredYRowMajor(eeg: eeg, channels: channels, range: window.range)

            var xtyRowMajor = [Double](repeating: 0, count: nCols * batchCount)
            cblas_dgemm(
                CblasRowMajor,
                CblasTrans,
                CblasNoTrans,
                Int32(nCols),
                Int32(batchCount),
                Int32(length),
                1.0,
                centeredDesign,
                Int32(nCols),
                centeredY,
                Int32(batchCount),
                0.0,
                &xtyRowMajor,
                Int32(batchCount)
            )

            let rhsColumnMajor = rowMajorToColumnMajor(xtyRowMajor, rows: nCols, columns: batchCount)
            guard let betaColumnMajor = solveWindowRHS(
                window: window,
                rhsColumnMajor: rhsColumnMajor,
                nCols: nCols,
                rightHandSideCount: batchCount
            ) else {
                continue
            }

            let betaRowMajor = columnMajorToRowMajor(betaColumnMajor, rows: nCols, columns: batchCount)
            var fitted = [Double](repeating: 0, count: length * batchCount)
            cblas_dgemm(
                CblasRowMajor,
                CblasNoTrans,
                CblasNoTrans,
                Int32(length),
                Int32(batchCount),
                Int32(nCols),
                1.0,
                centeredDesign,
                Int32(nCols),
                betaRowMajor,
                Int32(batchCount),
                0.0,
                &fitted,
                Int32(batchCount)
            )

            subtractFitted(
                fitted,
                from: &corrected,
                range: window.range,
                windowSamples: windowSamples,
                triangularWeights: triangularWeights,
                weightSum: weightSum,
                batchCount: batchCount
            )
        }

        return corrected
    }

    private static func solveWindowRHS(
        window: RegressionWindow,
        rhsColumnMajor: [Double],
        nCols: Int,
        rightHandSideCount: Int
    ) -> [Double]? {
        if let factorization = window.factorization {
            return factorization.solve(rhsColumnMajor, rightHandSideCount: rightHandSideCount)
        }

        guard window.fallbackMatrix.count == nCols * nCols else { return nil }
        var solvedColumnMajor = [Double](repeating: 0, count: nCols * rightHandSideCount)
        for rhsIndex in 0..<rightHandSideCount {
            var xtx = window.fallbackMatrix
            var rhs = [Double](repeating: 0, count: nCols)
            for row in 0..<nCols {
                rhs[row] = rhsColumnMajor[row + rhsIndex * nCols]
            }
            guard let solved = LinearAlgebra.solveLinearSystem(a: &xtx, b: &rhs, size: nCols) else {
                return nil
            }
            for row in 0..<nCols {
                solvedColumnMajor[row + rhsIndex * nCols] = solved[row]
            }
        }
        return solvedColumnMajor
    }

    private static func subtractFitted(
        _ fitted: [Double],
        from corrected: inout [[Float]],
        range: Range<Int>,
        windowSamples: Int,
        triangularWeights: [Double],
        weightSum: [Double],
        batchCount: Int
    ) {
        let length = range.count
        let fullLengthWindow = length == windowSamples
        for offset in 0..<length {
            let sample = range.lowerBound + offset
            guard sample < weightSum.count, weightSum[sample] > 0 else { continue }
            let weight = fullLengthWindow && offset < triangularWeights.count
                ? triangularWeights[offset]
                : 1.0
            let scale = weight / weightSum[sample]
            for batchOffset in 0..<batchCount {
                corrected[batchOffset][sample] -= Float(fitted[offset * batchCount + batchOffset] * scale)
            }
        }
    }

    // MARK: - Utilities

    private static func canSolve(_ window: RegressionWindow) -> Bool {
        window.factorization != nil || !window.fallbackMatrix.isEmpty
    }

    private static func centeredDesignRowMajor(
        design: [[Float]],
        range: Range<Int>,
        means: [Double]
    ) -> [Double] {
        let nCols = design.count
        var matrix = [Double](repeating: 0, count: range.count * nCols)
        for (row, sample) in range.enumerated() {
            let base = row * nCols
            for col in 0..<nCols {
                matrix[base + col] = Double(design[col][sample]) - means[col]
            }
        }
        return matrix
    }

    private static func centeredYRowMajor(
        eeg: [[Float]],
        channels: [Int],
        range: Range<Int>
    ) -> [Double] {
        let batchCount = channels.count
        let means = channels.map { mean(of: eeg[$0], in: range) }
        var matrix = [Double](repeating: 0, count: range.count * batchCount)
        for (row, sample) in range.enumerated() {
            let base = row * batchCount
            for (offset, channel) in channels.enumerated() {
                matrix[base + offset] = Double(eeg[channel][sample]) - means[offset]
            }
        }
        return matrix
    }

    private static func rowMajorToColumnMajor(_ values: [Double], rows: Int, columns: Int) -> [Double] {
        var converted = [Double](repeating: 0, count: rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                converted[row + column * rows] = values[row * columns + column]
            }
        }
        return converted
    }

    private static func columnMajorToRowMajor(_ values: [Double], rows: Int, columns: Int) -> [Double] {
        var converted = [Double](repeating: 0, count: rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                converted[row * columns + column] = values[row + column * rows]
            }
        }
        return converted
    }

    private static func mean(of values: [Float], in range: Range<Int>) -> Double {
        guard !range.isEmpty else { return 0 }
        var total = 0.0
        for index in range {
            total += Double(values[index])
        }
        return total / Double(range.count)
    }

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

    private static func reflectedIndex(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        if index < 0 {
            return min(-index - 1, count - 1)
        }
        if index >= count {
            return max(2 * count - index - 1, 0)
        }
        return index
    }

    private static func hannWindow(_ length: Int) -> [Double] {
        guard length > 1 else { return [Double](repeating: 1, count: max(length, 0)) }
        return (0..<length).map { sample in
            0.5 - 0.5 * cos(2.0 * Double.pi * Double(sample) / Double(length - 1))
        }
    }

    private static func triangularWindow(_ length: Int) -> [Double] {
        guard length > 1 else { return [Double](repeating: 1, count: max(length, 0)) }
        let mid = Double(length - 1) / 2.0
        return (0..<length).map { 1.0 - abs(Double($0) - mid) / (mid + 1) }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3g", value)
    }

    private static func elapsedString(since startedAt: UInt64, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> String {
        String(format: "%.2fs", Double(now - startedAt) / 1_000_000_000.0)
    }
}
