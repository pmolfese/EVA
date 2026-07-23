//
//  CWLCorrectorEngine.swift
//  EVA Helper
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
//  Configurable Carbon Wire Loop regression backends for the helper.
//

import Foundation
import Metal

nonisolated enum CWLCorrectorEngine {
    enum Error: LocalizedError {
        case noReferenceChannels
        case inconsistentSampleCounts
        case tooShortForWindow(windowSamples: Int, sampleCount: Int)
        case tooManyRegressors(actual: Int, maximum: Int)
        case noSolvableWindows
        case noMetalDevice
        case failedToBuildLibrary(String)
        case failedToCreatePipeline(String)
        case failedToCreateBuffer(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .noReferenceChannels:
                return "No CWL reference channels were selected."
            case .inconsistentSampleCounts:
                return "CWL correction requires EEG and CWL reference channels with matching sample counts."
            case .tooShortForWindow(let windowSamples, let sampleCount):
                return "Recording (\(sampleCount) samples) is shorter than the CWL regression window (\(windowSamples) samples)."
            case .tooManyRegressors(let actual, let maximum):
                return "CWL design has \(actual) lagged regressors, but this helper supports at most \(maximum)."
            case .noSolvableWindows:
                return "No CWL regression windows were long enough and numerically solvable."
            case .noMetalDevice:
                return "No Metal GPU device is available for CWL correction."
            case .failedToBuildLibrary(let details):
                return "Unable to build the Metal CWL shader: \(details)"
            case .failedToCreatePipeline(let details):
                return "Unable to create the Metal CWL pipeline: \(details)"
            case .failedToCreateBuffer(let name):
                return "Unable to allocate Metal buffer for \(name)."
            case .commandFailed(let details):
                return "Metal CWL command failed: \(details)"
            }
        }
    }

    enum Backend: String {
        case metal
        case cpu
        case compare
    }

    enum GPUKernel: String {
        case serial
        case sampleParallel = "sample-parallel"
    }

    enum Phase: String {
        case preparingCPU = "cpu-prepare"
        case submittingGPU = "gpu-submit"
        case correctingCPU = "cpu-correct"
        case comparing = "compare"
        case finished
    }

    struct ProgressUpdate {
        var fraction: Double
        var phase: Phase
        var message: String
        var detail: String?
    }

    struct Config {
        var backend = Backend.metal
        var gpuKernel = GPUKernel.sampleParallel
        var gpuBatchWindows = 1
        var lagRangeMs: ClosedRange<Double> = -50...150
        var lagStepMs = 10.0
        var windowSeconds = 4.0
        var hopSeconds: Double?
    }

    struct RunInfo {
        var corrected: [[Float]]
        var backendDescription: String
        var deviceName: String?
        var windowCount: Int
        var regressorCount: Int
        var cpuSeconds: Double?
        var gpuSeconds: Double?
        var comparison: Comparison?
    }

    struct Comparison {
        var maxAbsoluteDifference: Double
        var rmsDifference: Double
        var relativeMaxDifference: Double?
        var relativeRMSDifference: Double?
        var maxChannel: Int
        var maxSample: Int
        var leftValue: Float
        var rightValue: Float
    }

    private static let maxColumns = 256
    private static let correctionProgressStart = 0.24

    static func correct(
        eeg: [[Float]],
        references: [[Float]],
        samplingRate: Double,
        config: Config,
        progress: ((ProgressUpdate) -> Void)? = nil,
        verbose: ((String) -> Void)? = nil
    ) throws -> RunInfo {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let prepared = try prepare(
            eeg: eeg,
            references: references,
            samplingRate: samplingRate,
            config: config,
            progress: progress,
            verbose: verbose
        )

        switch config.backend {
        case .metal:
            let metalStart = DispatchTime.now().uptimeNanoseconds
            let gpu = try runMetal(prepared: prepared, config: config, progress: progress, verbose: verbose)
            return RunInfo(
                corrected: gpu.corrected,
                backendDescription: "Metal \(config.gpuKernel.rawValue)",
                deviceName: gpu.deviceName,
                windowCount: prepared.windows.count,
                regressorCount: prepared.columnCount,
                cpuSeconds: nil,
                gpuSeconds: seconds(from: metalStart),
                comparison: nil
            )

        case .cpu:
            let cpuStart = DispatchTime.now().uptimeNanoseconds
            let corrected = runCPU(prepared: prepared, progress: progress, verbose: verbose)
            return RunInfo(
                corrected: corrected,
                backendDescription: "CPU/LAPACK",
                deviceName: nil,
                windowCount: prepared.windows.count,
                regressorCount: prepared.columnCount,
                cpuSeconds: seconds(from: cpuStart),
                gpuSeconds: nil,
                comparison: nil
            )

        case .compare:
            verbose?("CWL compare: running Metal backend first")
            let metalStart = DispatchTime.now().uptimeNanoseconds
            let gpu = try runMetal(
                prepared: prepared,
                config: config,
                progress: remapCorrectionProgress(progress, start: correctionProgressStart, end: 0.68),
                verbose: verbose
            )
            let gpuSeconds = seconds(from: metalStart)

            verbose?("CWL compare: running CPU/LAPACK baseline")
            let cpuStart = DispatchTime.now().uptimeNanoseconds
            let cpu = runCPU(
                prepared: prepared,
                progress: remapCorrectionProgress(progress, start: 0.68, end: 0.98),
                verbose: verbose
            )
            let cpuSeconds = seconds(from: cpuStart)
            var comparison = compare(gpu.corrected, cpu)
            let gpuDelta = compare(gpu.corrected, prepared.eeg)
            let cpuDelta = compare(cpu, prepared.eeg)
            comparison.relativeMaxDifference = comparison.maxAbsoluteDifference
                / max(gpuDelta.maxAbsoluteDifference, cpuDelta.maxAbsoluteDifference, 1e-12)
            comparison.relativeRMSDifference = comparison.rmsDifference
                / max(gpuDelta.rmsDifference, cpuDelta.rmsDifference, 1e-12)
            progress?(ProgressUpdate(
                fraction: 1,
                phase: .comparing,
                message: "Compared CWL backends",
                detail: String(format: "max %.6g, rms %.6g", comparison.maxAbsoluteDifference, comparison.rmsDifference)
            ))
            verbose?(
                String(
                    format: "CWL compare: gpu %.3fs, cpu %.3fs, max diff %.6g, rms diff %.6g, elapsed %.3fs",
                    gpuSeconds,
                    cpuSeconds,
                    comparison.maxAbsoluteDifference,
                    comparison.rmsDifference,
                    seconds(from: startedAt)
                )
            )
            verbose?(
                String(
                    format: "CWL compare detail: max at channel %d sample %d, metal %.6g, cpu %.6g",
                    comparison.maxChannel + 1,
                    comparison.maxSample,
                    comparison.leftValue,
                    comparison.rightValue
                )
            )
            verbose?(
                String(
                    format: "CWL compare deltas vs original: metal rms %.6g max %.6g; cpu rms %.6g max %.6g",
                    gpuDelta.rmsDifference,
                    gpuDelta.maxAbsoluteDifference,
                    cpuDelta.rmsDifference,
                    cpuDelta.maxAbsoluteDifference
                )
            )
            if let relativeMax = comparison.relativeMaxDifference,
               let relativeRMS = comparison.relativeRMSDifference {
                verbose?(
                    String(
                        format: "CWL compare relative to correction: max %.6g, rms %.6g",
                        relativeMax,
                        relativeRMS
                    )
                )
            }
            return RunInfo(
                corrected: gpu.corrected,
                backendDescription: "Metal \(config.gpuKernel.rawValue) + CPU/LAPACK compare",
                deviceName: gpu.deviceName,
                windowCount: prepared.windows.count,
                regressorCount: prepared.columnCount,
                cpuSeconds: cpuSeconds,
                gpuSeconds: gpuSeconds,
                comparison: comparison
            )
        }
    }

    private static func remapCorrectionProgress(
        _ progress: ((ProgressUpdate) -> Void)?,
        start: Double,
        end: Double
    ) -> ((ProgressUpdate) -> Void)? {
        guard let progress else { return nil }
        return { update in
            let denominator = max(1 - correctionProgressStart, 1e-12)
            let normalized = min(max((update.fraction - correctionProgressStart) / denominator, 0), 1)
            progress(ProgressUpdate(
                fraction: start + (end - start) * normalized,
                phase: update.phase,
                message: update.message,
                detail: update.detail
            ))
        }
    }

    private struct Prepared {
        var eeg: [[Float]]
        var design: [[Float]]
        var windows: [PreparedWindow]
        var windowChannelMeans: [Float]
        var triangularWeights: [Float]
        var weightSum: [Float]
        var sampleCount: Int
        var channelCount: Int
        var columnCount: Int
        var windowSamples: Int
        var hopSamples: Int
    }

    private struct PreparedWindow {
        var range: Range<Int>
        var designMeans: [Double]
        var inverseXtXRowMajor: [Float]
    }

    private struct MetalResult {
        var corrected: [[Float]]
        var deviceName: String
    }

    private struct KernelParams {
        var sampleCount: UInt32
        var channelCount: UInt32
        var windowStart: UInt32
        var windowLength: UInt32
        var columnCount: UInt32
        var windowSamples: UInt32
        var windowIndex: UInt32
        var padding: UInt32
    }

    private static func prepare(
        eeg: [[Float]],
        references: [[Float]],
        samplingRate: Double,
        config: Config,
        progress: ((ProgressUpdate) -> Void)?,
        verbose: ((String) -> Void)?
    ) throws -> Prepared {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard !references.isEmpty, let sampleCount = references.first?.count, sampleCount > 0 else {
            throw Error.noReferenceChannels
        }
        guard eeg.allSatisfy({ $0.count == sampleCount }),
              references.allSatisfy({ $0.count == sampleCount }) else {
            throw Error.inconsistentSampleCounts
        }

        let windowSamples = max(Int((config.windowSeconds * samplingRate).rounded()), 8)
        guard sampleCount >= windowSamples else {
            throw Error.tooShortForWindow(windowSamples: windowSamples, sampleCount: sampleCount)
        }
        let hopSeconds = config.hopSeconds ?? (config.windowSeconds / 2)
        let hopSamples = max(Int((hopSeconds * samplingRate).rounded()), 1)

        progress?(ProgressUpdate(
            fraction: 0,
            phase: .preparingCPU,
            message: "Preparing CWL on CPU",
            detail: "\(references.count) reference channel\(references.count == 1 ? "" : "s")"
        ))
        verbose?(
            String(
                format: "CWL CPU prepare: channels=%d refs=%d samples=%d rate=%.3fHz window=%d samples hop=%d samples",
                eeg.count,
                references.count,
                sampleCount,
                samplingRate,
                windowSamples,
                hopSamples
            )
        )

        let lagSamples = stride(from: config.lagRangeMs.lowerBound, through: config.lagRangeMs.upperBound, by: max(config.lagStepMs, 1))
            .map { Int(($0 / 1000.0 * samplingRate).rounded()) }
        let uniqueLags = Array(Set(lagSamples)).sorted()
        let designStartedAt = DispatchTime.now().uptimeNanoseconds
        let design = buildLaggedDesign(references: references, lags: uniqueLags)

        let columnCount = design.count
        guard columnCount > 0 else { throw Error.noReferenceChannels }
        guard columnCount <= maxColumns else {
            throw Error.tooManyRegressors(actual: columnCount, maximum: maxColumns)
        }

        verbose?(
            String(
                format: "CWL CPU prepare: built lagged design, lags=%d, regressors=%d, elapsed=%.3fs",
                uniqueLags.count,
                columnCount,
                seconds(from: designStartedAt)
            )
        )
        let windowsStartedAt = DispatchTime.now().uptimeNanoseconds
        let windows = try prepareWindows(
            design: design,
            sampleCount: sampleCount,
            windowSamples: windowSamples,
            hopSamples: hopSamples
        ) { fraction in
            progress?(ProgressUpdate(
                fraction: 0.20 * fraction,
                phase: .preparingCPU,
                message: "Preparing CWL windows on CPU",
                detail: "\(Int((fraction * 100).rounded()))%"
            ))
        }
        guard !windows.isEmpty else { throw Error.noSolvableWindows }
        verbose?(
            String(
                format: "CWL CPU prepare: prepared regression windows in parallel, windows=%d, elapsed=%.3fs",
                windows.count,
                seconds(from: windowsStartedAt)
            )
        )

        let meanStartedAt = DispatchTime.now().uptimeNanoseconds
        let windowChannelMeans = buildWindowChannelMeans(
            channels: eeg,
            windows: windows,
            sampleCount: sampleCount
        ) { fraction in
            progress?(ProgressUpdate(
                fraction: 0.20 + 0.04 * fraction,
                phase: .preparingCPU,
                message: "Preparing CWL EEG window means on CPU",
                detail: "\(Int((fraction * 100).rounded()))%"
            ))
        }
        verbose?(
            String(
                format: "CWL CPU prepare: cached EEG window means, values=%d, elapsed=%.3fs",
                windowChannelMeans.count,
                seconds(from: meanStartedAt)
            )
        )

        let triangularWeights = triangularWindow(windowSamples)
        let weightSum = overlapWeightSum(
            sampleCount: sampleCount,
            windows: windows,
            windowSamples: windowSamples,
            triangularWeights: triangularWeights
        )
        verbose?(
            String(
                format: "CWL CPU prepare: windows=%d, elapsed=%.3fs",
                windows.count,
                seconds(from: startedAt)
            )
        )
        return Prepared(
            eeg: eeg,
            design: design,
            windows: windows,
            windowChannelMeans: windowChannelMeans,
            triangularWeights: triangularWeights,
            weightSum: weightSum,
            sampleCount: sampleCount,
            channelCount: eeg.count,
            columnCount: columnCount,
            windowSamples: windowSamples,
            hopSamples: hopSamples
        )
    }

    private static func buildLaggedDesign(references: [[Float]], lags: [Int]) -> [[Float]] {
        let columnCount = references.count * lags.count
        guard columnCount > 0 else { return [] }
        var design = Array(repeating: [Float](), count: columnCount)
        design.withUnsafeMutableBufferPointer { output in
            nonisolated(unsafe) let output = output
            evaConcurrentPerform(iterations: columnCount) { columnIndex in
                let referenceIndex = columnIndex / lags.count
                let lagIndex = columnIndex % lags.count
                output[columnIndex] = shifted(references[referenceIndex], by: lags[lagIndex])
            }
        }
        return design
    }

    private static func prepareWindows(
        design: [[Float]],
        sampleCount: Int,
        windowSamples: Int,
        hopSamples: Int,
        progress: @escaping (Double) -> Void
    ) throws -> [PreparedWindow] {
        let columnCount = design.count
        var ranges: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + windowSamples, sampleCount)
            if end - start >= columnCount + 1 {
                ranges.append(start..<end)
            }
            if end == sampleCount { break }
            start += hopSamples
        }

        guard !ranges.isEmpty else { return [] }

        let capturedRanges = ranges
        let rangeCount = capturedRanges.count
        var windows = Array<PreparedWindow?>(repeating: nil, count: rangeCount)
        let reportEvery = max(1, rangeCount / 100)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0
        windows.withUnsafeMutableBufferPointer { output in
            nonisolated(unsafe) let output = output
            evaConcurrentPerform(iterations: rangeCount) { index in
                output[index] = prepareWindow(design: design, range: capturedRanges[index])

                progressLock.lock()
                completed += 1
                let done = completed
                progressLock.unlock()
                if done % reportEvery == 0 || done == rangeCount {
                    progress(Double(done) / Double(rangeCount))
                }
            }
        }
        return windows.compactMap { $0 }
    }

    private static func buildWindowChannelMeans(
        channels: [[Float]],
        windows: [PreparedWindow],
        sampleCount: Int,
        progress: @escaping (Double) -> Void
    ) -> [Float] {
        guard !channels.isEmpty, !windows.isEmpty, sampleCount > 0 else {
            progress(1)
            return []
        }

        let channelCount = channels.count
        var means = [Float](repeating: 0, count: windows.count * channelCount)
        let reportEvery = max(1, channelCount / 100)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0

        means.withUnsafeMutableBufferPointer { output in
            nonisolated(unsafe) let output = output
            evaConcurrentPerform(iterations: channelCount) { channel in
                var prefix = [Double](repeating: 0, count: sampleCount + 1)
                let values = channels[channel]
                for sample in 0..<min(values.count, sampleCount) {
                    prefix[sample + 1] = prefix[sample] + Double(values[sample])
                }

                for (windowIndex, window) in windows.enumerated() {
                    let start = max(0, min(window.range.lowerBound, sampleCount))
                    let end = max(start, min(window.range.upperBound, sampleCount))
                    let length = max(end - start, 1)
                    output[windowIndex * channelCount + channel] = Float(
                        (prefix[end] - prefix[start]) / Double(length)
                    )
                }

                progressLock.lock()
                completed += 1
                let done = completed
                progressLock.unlock()
                if done % reportEvery == 0 || done == channelCount {
                    progress(Double(done) / Double(channelCount))
                }
            }
        }
        return means
    }

    private static func prepareWindow(design: [[Float]], range: Range<Int>) -> PreparedWindow? {
        let columnCount = design.count
        let means = design.map { mean(of: $0, in: range) }
        var xtx = [Double](repeating: 0, count: columnCount * columnCount)

        for sample in range {
            for row in 0..<columnCount {
                let rowValue = Double(design[row][sample]) - means[row]
                for column in row..<columnCount {
                    let value = rowValue * (Double(design[column][sample]) - means[column])
                    xtx[row * columnCount + column] += value
                    if row != column {
                        xtx[column * columnCount + row] += value
                    }
                }
            }
        }

        let diagonalMean = (0..<columnCount).reduce(0.0) { $0 + xtx[$1 * columnCount + $1] } / Double(columnCount)
        let ridge = 1e-6 * diagonalMean + 1e-12
        for index in 0..<columnCount {
            xtx[index * columnCount + index] += ridge
        }

        guard let factorization = LinearAlgebra.factorLinearSystem(a: xtx, size: columnCount) else {
            return nil
        }
        var identityColumnMajor = [Double](repeating: 0, count: columnCount * columnCount)
        for index in 0..<columnCount {
            identityColumnMajor[index + index * columnCount] = 1
        }
        guard let inverseColumnMajor = factorization.solve(identityColumnMajor, rightHandSideCount: columnCount) else {
            return nil
        }

        var inverseRowMajor = [Float](repeating: 0, count: columnCount * columnCount)
        for row in 0..<columnCount {
            for column in 0..<columnCount {
                inverseRowMajor[row * columnCount + column] = Float(inverseColumnMajor[row + column * columnCount])
            }
        }
        return PreparedWindow(range: range, designMeans: means, inverseXtXRowMajor: inverseRowMajor)
    }

    private static func runCPU(
        prepared: Prepared,
        progress: ((ProgressUpdate) -> Void)?,
        verbose: ((String) -> Void)?
    ) -> [[Float]] {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        verbose?("CWL CPU correct: starting channel-parallel correction")
        progress?(ProgressUpdate(
            fraction: correctionProgressStart,
            phase: .correctingCPU,
            message: "Correcting CWL on CPU",
            detail: "\(prepared.channelCount) EEG channel\(prepared.channelCount == 1 ? "" : "s")"
        ))

        var result = prepared.eeg
        let progressLock = NSLock()
        nonisolated(unsafe) var completedWork = 0
        let totalWork = max(prepared.channelCount * prepared.windows.count, 1)
        let reportEvery = max(1, totalWork / 500)
        let windowCompleted: ((Int, Int) -> Void)?
        if let progress {
            windowCompleted = { channel, windowIndex in
                progressLock.lock()
                completedWork += 1
                let done = completedWork
                if done % reportEvery == 0 || done == totalWork {
                    progress(ProgressUpdate(
                        fraction: correctionProgressStart
                            + (1 - correctionProgressStart) * Double(done) / Double(totalWork),
                        phase: .correctingCPU,
                        message: "Correcting CWL on CPU",
                        detail: "channel \(channel + 1)/\(prepared.channelCount), window \(windowIndex + 1)/\(prepared.windows.count)"
                    ))
                }
                progressLock.unlock()
            }
        } else {
            windowCompleted = nil
        }

        result.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: prepared.channelCount) { channel in
                out[channel] = correctCPUChannel(
                    channel: prepared.eeg[channel],
                    channelIndex: channel,
                    prepared: prepared,
                    windowCompleted: windowCompleted.map { callback in
                        { windowIndex in callback(channel, windowIndex) }
                    }
                )
            }
        }
        verbose?(String(format: "CWL CPU correct: finished, elapsed=%.3fs", seconds(from: startedAt)))
        return result
    }

    private static func correctCPUChannel(
        channel: [Float],
        channelIndex: Int,
        prepared: Prepared,
        windowCompleted: ((Int) -> Void)? = nil
    ) -> [Float] {
        var corrected = channel
        var xty = [Float](repeating: 0, count: prepared.columnCount)
        var beta = [Float](repeating: 0, count: prepared.columnCount)

        for (windowIndex, window) in prepared.windows.enumerated() {
            defer { windowCompleted?(windowIndex) }
            let length = window.range.count
            guard length > 0 else { continue }
            let meanIndex = windowIndex * prepared.channelCount + channelIndex
            let yMean = prepared.windowChannelMeans.indices.contains(meanIndex)
                ? prepared.windowChannelMeans[meanIndex]
                : Float(mean(of: channel, in: window.range))
            for column in 0..<prepared.columnCount {
                xty[column] = 0
                beta[column] = 0
            }

            for (offset, sample) in window.range.enumerated() {
                let y = channel[sample] - yMean
                for column in 0..<prepared.columnCount {
                    let x = Float(Double(prepared.design[column][sample]) - window.designMeans[column])
                    xty[column] = xty[column].addingProduct(x, y)
                }
                _ = offset
            }

            for row in 0..<prepared.columnCount {
                var total: Float = 0
                let inverseBase = row * prepared.columnCount
                for column in 0..<prepared.columnCount {
                    total = total.addingProduct(window.inverseXtXRowMajor[inverseBase + column], xty[column])
                }
                beta[row] = total
            }

            let fullLengthWindow = length == prepared.windowSamples
            for (offset, sample) in window.range.enumerated() {
                guard sample < prepared.weightSum.count, prepared.weightSum[sample] > 0 else { continue }
                let weight = fullLengthWindow && offset < prepared.triangularWeights.count
                    ? prepared.triangularWeights[offset]
                    : 1
                var fitted: Float = 0
                for column in 0..<prepared.columnCount {
                    let x = Float(Double(prepared.design[column][sample]) - window.designMeans[column])
                    fitted = fitted.addingProduct(x, beta[column])
                }
                corrected[sample] -= fitted * weight / prepared.weightSum[sample]
            }
        }

        return corrected
    }

    private static func runMetal(
        prepared: Prepared,
        config: Config,
        progress: ((ProgressUpdate) -> Void)?,
        verbose: ((String) -> Void)?
    ) throws -> MetalResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw Error.noMetalDevice
        }
        verbose?("CWL Metal: using device \(device.name)")
        verbose?("CWL Metal: compiling helper shader")

        let library: MTLLibrary
        do {
            let options = MTLCompileOptions()
            if #available(macOS 15.0, *) {
                options.mathMode = .safe
            } else {
                options.fastMathEnabled = false
            }
            library = try device.makeLibrary(source: metalSource, options: options)
        } catch {
            throw Error.failedToBuildLibrary(error.localizedDescription)
        }

        let serialPipeline = try makePipeline(name: "cwl_correct_window", library: library, device: device)
        let solvePipeline = try makePipeline(name: "cwl_solve_window", library: library, device: device)
        let subtractPipeline = try makePipeline(name: "cwl_subtract_window", library: library, device: device)
        guard let queue = device.makeCommandQueue() else {
            throw Error.failedToCreatePipeline("unable to create Metal command queue")
        }
        let sampleParallelFence = config.gpuKernel == .sampleParallel ? device.makeFence() : nil

        let flatEEG = flatten(prepared.eeg)
        guard let eegBuffer = makeBuffer(device: device, values: flatEEG, name: "EEG") else {
            throw Error.failedToCreateBuffer("EEG")
        }
        guard let correctedBuffer = makeBuffer(device: device, values: flatEEG, name: "corrected EEG") else {
            throw Error.failedToCreateBuffer("corrected EEG")
        }
        guard let weightSumBuffer = makeBuffer(device: device, values: prepared.weightSum, name: "overlap weights") else {
            throw Error.failedToCreateBuffer("overlap weights")
        }
        guard let triangularBuffer = makeBuffer(device: device, values: prepared.triangularWeights, name: "triangular weights") else {
            throw Error.failedToCreateBuffer("triangular weights")
        }
        guard let windowMeansBuffer = makeBuffer(device: device, values: prepared.windowChannelMeans, name: "EEG window means") else {
            throw Error.failedToCreateBuffer("EEG window means")
        }

        progress?(ProgressUpdate(
            fraction: correctionProgressStart,
            phase: .submittingGPU,
            message: "Submitting CWL to GPU",
            detail: "\(prepared.windows.count) window\(prepared.windows.count == 1 ? "" : "s")"
        ))

        let batchSize = max(config.gpuBatchWindows, 1)
        verbose?(
            "CWL Metal: kernel=\(config.gpuKernel.rawValue), batchWindows=\(batchSize), windows=\(prepared.windows.count)"
        )
        if config.gpuKernel == .sampleParallel {
            verbose?("CWL Metal: sample-parallel solve/subtract path uses an explicit Metal fence")
        }

        var windowIndex = 0
        while windowIndex < prepared.windows.count {
            let batchEnd = min(windowIndex + batchSize, prepared.windows.count)
            verbose?("CWL Metal: encoding windows \(windowIndex + 1)-\(batchEnd)")
            guard let commandBuffer = queue.makeCommandBuffer() else {
                throw Error.commandFailed("unable to create command buffer")
            }
            var retainedBuffers: [MTLBuffer] = []
            for index in windowIndex..<batchEnd {
                let window = prepared.windows[index]
                let centeredDesign = centeredDesignRowMajor(design: prepared.design, range: window.range, means: window.designMeans)
                guard let designBuffer = makeBuffer(device: device, values: centeredDesign, name: "centered design") else {
                    throw Error.failedToCreateBuffer("centered design")
                }
                guard let inverseBuffer = makeBuffer(device: device, values: window.inverseXtXRowMajor, name: "inverse design covariance") else {
                    throw Error.failedToCreateBuffer("inverse design covariance")
                }
                retainedBuffers.append(designBuffer)
                retainedBuffers.append(inverseBuffer)

                var params = KernelParams(
                    sampleCount: UInt32(prepared.sampleCount),
                    channelCount: UInt32(prepared.channelCount),
                    windowStart: UInt32(window.range.lowerBound),
                    windowLength: UInt32(window.range.count),
                    columnCount: UInt32(prepared.columnCount),
                    windowSamples: UInt32(prepared.windowSamples),
                    windowIndex: UInt32(index),
                    padding: 0
                )

                switch config.gpuKernel {
                case .serial:
                    try encodeSerial(
                        commandBuffer: commandBuffer,
                        pipeline: serialPipeline,
                        eegBuffer: eegBuffer,
                        correctedBuffer: correctedBuffer,
                        designBuffer: designBuffer,
                        inverseBuffer: inverseBuffer,
                        weightSumBuffer: weightSumBuffer,
                        triangularBuffer: triangularBuffer,
                        windowMeansBuffer: windowMeansBuffer,
                        params: &params,
                        channelCount: prepared.channelCount
                    )
                case .sampleParallel:
                    guard let betaBuffer = device.makeBuffer(
                        length: prepared.channelCount * prepared.columnCount * MemoryLayout<Float>.stride,
                        options: .storageModeShared
                    ) else {
                        throw Error.failedToCreateBuffer("CWL beta")
                    }
                    retainedBuffers.append(betaBuffer)
                    try encodeSampleParallel(
                        commandBuffer: commandBuffer,
                        solvePipeline: solvePipeline,
                        subtractPipeline: subtractPipeline,
                        eegBuffer: eegBuffer,
                        correctedBuffer: correctedBuffer,
                        designBuffer: designBuffer,
                        inverseBuffer: inverseBuffer,
                        weightSumBuffer: weightSumBuffer,
                        triangularBuffer: triangularBuffer,
                        windowMeansBuffer: windowMeansBuffer,
                        betaBuffer: betaBuffer,
                        fence: sampleParallelFence,
                        params: &params,
                        channelCount: prepared.channelCount,
                        windowLength: window.range.count
                    )
                }
            }

            verbose?("CWL Metal: committing \(batchEnd - windowIndex) window\(batchEnd - windowIndex == 1 ? "" : "s")")
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            _ = retainedBuffers

            if let error = commandBuffer.error {
                throw Error.commandFailed(error.localizedDescription)
            }
            windowIndex = batchEnd
            progress?(ProgressUpdate(
                fraction: correctionProgressStart
                    + (1 - correctionProgressStart) * Double(windowIndex) / Double(max(prepared.windows.count, 1)),
                phase: .submittingGPU,
                message: "Running CWL on GPU",
                detail: "window \(windowIndex)/\(prepared.windows.count)"
            ))
        }

        let totalCount = prepared.channelCount * prepared.sampleCount
        let pointer = correctedBuffer.contents().bindMemory(to: Float.self, capacity: totalCount)
        let output = Array(UnsafeBufferPointer(start: pointer, count: totalCount))
        verbose?(String(format: "CWL Metal: finished, elapsed=%.3fs", seconds(from: startedAt)))
        return MetalResult(
            corrected: unflatten(output, channelCount: prepared.channelCount, sampleCount: prepared.sampleCount),
            deviceName: device.name
        )
    }

    private static func makePipeline(name: String, library: MTLLibrary, device: MTLDevice) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw Error.failedToCreatePipeline("kernel \(name) was not found")
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw Error.failedToCreatePipeline(error.localizedDescription)
        }
    }

    private static func encodeSerial(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLComputePipelineState,
        eegBuffer: MTLBuffer,
        correctedBuffer: MTLBuffer,
        designBuffer: MTLBuffer,
        inverseBuffer: MTLBuffer,
        weightSumBuffer: MTLBuffer,
        triangularBuffer: MTLBuffer,
        windowMeansBuffer: MTLBuffer,
        params: inout KernelParams,
        channelCount: Int
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw Error.commandFailed("unable to create serial command encoder")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(eegBuffer, offset: 0, index: 0)
        encoder.setBuffer(correctedBuffer, offset: 0, index: 1)
        encoder.setBuffer(designBuffer, offset: 0, index: 2)
        encoder.setBuffer(inverseBuffer, offset: 0, index: 3)
        encoder.setBuffer(weightSumBuffer, offset: 0, index: 4)
        encoder.setBuffer(triangularBuffer, offset: 0, index: 5)
        encoder.setBuffer(windowMeansBuffer, offset: 0, index: 6)
        encoder.setBytes(&params, length: MemoryLayout<KernelParams>.stride, index: 7)
        let width = min(max(pipeline.maxTotalThreadsPerThreadgroup, 1), 64)
        encoder.dispatchThreads(
            MTLSize(width: channelCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
    }

    private static func encodeSampleParallel(
        commandBuffer: MTLCommandBuffer,
        solvePipeline: MTLComputePipelineState,
        subtractPipeline: MTLComputePipelineState,
        eegBuffer: MTLBuffer,
        correctedBuffer: MTLBuffer,
        designBuffer: MTLBuffer,
        inverseBuffer: MTLBuffer,
        weightSumBuffer: MTLBuffer,
        triangularBuffer: MTLBuffer,
        windowMeansBuffer: MTLBuffer,
        betaBuffer: MTLBuffer,
        fence: MTLFence?,
        params: inout KernelParams,
        channelCount: Int,
        windowLength: Int
    ) throws {
        guard let solveEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw Error.commandFailed("unable to create solve command encoder")
        }
        solveEncoder.setComputePipelineState(solvePipeline)
        solveEncoder.setBuffer(eegBuffer, offset: 0, index: 0)
        solveEncoder.setBuffer(designBuffer, offset: 0, index: 1)
        solveEncoder.setBuffer(inverseBuffer, offset: 0, index: 2)
        solveEncoder.setBuffer(betaBuffer, offset: 0, index: 3)
        solveEncoder.setBuffer(windowMeansBuffer, offset: 0, index: 4)
        solveEncoder.setBytes(&params, length: MemoryLayout<KernelParams>.stride, index: 5)
        let solveWidth = min(max(solvePipeline.maxTotalThreadsPerThreadgroup, 1), 64)
        solveEncoder.dispatchThreads(
            MTLSize(width: channelCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: solveWidth, height: 1, depth: 1)
        )
        if let fence {
            solveEncoder.updateFence(fence)
        }
        solveEncoder.endEncoding()

        guard let subtractEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw Error.commandFailed("unable to create subtract command encoder")
        }
        if let fence {
            subtractEncoder.waitForFence(fence)
        }
        subtractEncoder.setComputePipelineState(subtractPipeline)
        subtractEncoder.setBuffer(correctedBuffer, offset: 0, index: 0)
        subtractEncoder.setBuffer(designBuffer, offset: 0, index: 1)
        subtractEncoder.setBuffer(betaBuffer, offset: 0, index: 2)
        subtractEncoder.setBuffer(weightSumBuffer, offset: 0, index: 3)
        subtractEncoder.setBuffer(triangularBuffer, offset: 0, index: 4)
        subtractEncoder.setBytes(&params, length: MemoryLayout<KernelParams>.stride, index: 5)
        subtractEncoder.dispatchThreads(
            MTLSize(width: channelCount, height: windowLength, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        subtractEncoder.endEncoding()
    }

    private static func overlapWeightSum(
        sampleCount: Int,
        windows: [PreparedWindow],
        windowSamples: Int,
        triangularWeights: [Float]
    ) -> [Float] {
        var weightSum = [Float](repeating: 0, count: sampleCount)
        for window in windows {
            let fullLengthWindow = window.range.count == windowSamples
            for offset in 0..<window.range.count {
                let sample = window.range.lowerBound + offset
                guard sample < sampleCount else { continue }
                weightSum[sample] += fullLengthWindow && offset < triangularWeights.count
                    ? triangularWeights[offset]
                    : 1
            }
        }
        return weightSum
    }

    private static func centeredDesignRowMajor(
        design: [[Float]],
        range: Range<Int>,
        means: [Double]
    ) -> [Float] {
        let columnCount = design.count
        var matrix = [Float](repeating: 0, count: range.count * columnCount)
        for (row, sample) in range.enumerated() {
            let base = row * columnCount
            for column in 0..<columnCount {
                matrix[base + column] = Float(Double(design[column][sample]) - means[column])
            }
        }
        return matrix
    }

    private static func mean(of values: [Float], in range: Range<Int>) -> Double {
        guard !range.isEmpty else { return 0 }
        var total = 0.0
        for index in range {
            total += Double(values[index])
        }
        return total / Double(range.count)
    }

    private static func shifted(_ signal: [Float], by lag: Int) -> [Float] {
        guard lag != 0 else { return signal }
        let sampleCount = signal.count
        guard sampleCount > 0 else { return signal }

        var output = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            let source = min(max(sample - lag, 0), sampleCount - 1)
            output[sample] = signal[source]
        }
        return output
    }

    private static func triangularWindow(_ length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 1, count: max(length, 0)) }
        let mid = Double(length - 1) / 2.0
        return (0..<length).map { Float(1.0 - abs(Double($0) - mid) / (mid + 1)) }
    }

    private static func flatten(_ channels: [[Float]]) -> [Float] {
        channels.flatMap { $0 }
    }

    private static func unflatten(_ values: [Float], channelCount: Int, sampleCount: Int) -> [[Float]] {
        (0..<channelCount).map { channel in
            let start = channel * sampleCount
            return Array(values[start..<(start + sampleCount)])
        }
    }

    private static func makeBuffer(device: MTLDevice, values: [Float], name: String) -> MTLBuffer? {
        let byteCount = values.count * MemoryLayout<Float>.stride
        guard byteCount > 0 else { return nil }
        let buffer = values.withUnsafeBytes { rawBuffer in
            device.makeBuffer(bytes: rawBuffer.baseAddress!, length: byteCount, options: .storageModeShared)
        }
        buffer?.label = name
        return buffer
    }

    static func compare(_ lhs: [[Float]], _ rhs: [[Float]]) -> Comparison {
        var maxAbsoluteDifference = 0.0
        var squaredDifferenceSum = 0.0
        var count = 0
        var maxChannel = 0
        var maxSample = 0
        var leftValue: Float = 0
        var rightValue: Float = 0
        for channel in 0..<min(lhs.count, rhs.count) {
            for sample in 0..<min(lhs[channel].count, rhs[channel].count) {
                let difference = abs(Double(lhs[channel][sample] - rhs[channel][sample]))
                if difference > maxAbsoluteDifference {
                    maxAbsoluteDifference = difference
                    maxChannel = channel
                    maxSample = sample
                    leftValue = lhs[channel][sample]
                    rightValue = rhs[channel][sample]
                }
                squaredDifferenceSum += difference * difference
                count += 1
            }
        }
        let rms = count > 0 ? sqrt(squaredDifferenceSum / Double(count)) : 0
        return Comparison(
            maxAbsoluteDifference: maxAbsoluteDifference,
            rmsDifference: rms,
            relativeMaxDifference: nil,
            relativeRMSDifference: nil,
            maxChannel: maxChannel,
            maxSample: maxSample,
            leftValue: leftValue,
            rightValue: rightValue
        )
    }

    private static func seconds(from startedAt: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now - startedAt) / 1_000_000_000
    }

    private static let metalSource = """
#include <metal_stdlib>
using namespace metal;

constant uint kMaxColumns = 256;

struct CWLParams {
    uint sampleCount;
    uint channelCount;
    uint windowStart;
    uint windowLength;
    uint columnCount;
    uint windowSamples;
    uint windowIndex;
    uint padding;
};

kernel void cwl_correct_window(
    device const float *eeg [[buffer(0)]],
    device float *corrected [[buffer(1)]],
    device const float *centeredDesign [[buffer(2)]],
    device const float *inverseXtX [[buffer(3)]],
    device const float *weightSum [[buffer(4)]],
    device const float *triangularWeights [[buffer(5)]],
    device const float *windowMeans [[buffer(6)]],
    constant CWLParams &params [[buffer(7)]],
    uint channel [[thread_position_in_grid]]
) {
    if (channel >= params.channelCount || params.columnCount == 0 || params.columnCount > kMaxColumns) {
        return;
    }

    const uint base = channel * params.sampleCount;
    const float yMean = windowMeans[params.windowIndex * params.channelCount + channel];

    float xty[kMaxColumns];
    float beta[kMaxColumns];
    for (uint column = 0; column < params.columnCount; ++column) {
        xty[column] = 0.0f;
        beta[column] = 0.0f;
    }

    for (uint offset = 0; offset < params.windowLength; ++offset) {
        const float y = eeg[base + params.windowStart + offset] - yMean;
        const uint designBase = offset * params.columnCount;
        for (uint column = 0; column < params.columnCount; ++column) {
            xty[column] = fma(centeredDesign[designBase + column], y, xty[column]);
        }
    }

    for (uint row = 0; row < params.columnCount; ++row) {
        float sum = 0.0f;
        const uint inverseBase = row * params.columnCount;
        for (uint column = 0; column < params.columnCount; ++column) {
            sum = fma(inverseXtX[inverseBase + column], xty[column], sum);
        }
        beta[row] = sum;
    }

    const bool fullLengthWindow = params.windowLength == params.windowSamples;
    for (uint offset = 0; offset < params.windowLength; ++offset) {
        const uint sample = params.windowStart + offset;
        if (sample >= params.sampleCount || weightSum[sample] <= 0.0f) {
            continue;
        }

        const float weight = (fullLengthWindow && offset < params.windowSamples)
            ? triangularWeights[offset]
            : 1.0f;
        const float scale = weight / weightSum[sample];
        const uint designBase = offset * params.columnCount;
        float fitted = 0.0f;
        for (uint column = 0; column < params.columnCount; ++column) {
            fitted = fma(centeredDesign[designBase + column], beta[column], fitted);
        }
        corrected[base + sample] -= fitted * scale;
    }
}

kernel void cwl_solve_window(
    device const float *eeg [[buffer(0)]],
    device const float *centeredDesign [[buffer(1)]],
    device const float *inverseXtX [[buffer(2)]],
    device float *betaOut [[buffer(3)]],
    device const float *windowMeans [[buffer(4)]],
    constant CWLParams &params [[buffer(5)]],
    uint channel [[thread_position_in_grid]]
) {
    if (channel >= params.channelCount || params.columnCount == 0 || params.columnCount > kMaxColumns) {
        return;
    }

    const uint base = channel * params.sampleCount;
    const float yMean = windowMeans[params.windowIndex * params.channelCount + channel];

    float xty[kMaxColumns];
    for (uint column = 0; column < params.columnCount; ++column) {
        xty[column] = 0.0f;
    }

    for (uint offset = 0; offset < params.windowLength; ++offset) {
        const float y = eeg[base + params.windowStart + offset] - yMean;
        const uint designBase = offset * params.columnCount;
        for (uint column = 0; column < params.columnCount; ++column) {
            xty[column] = fma(centeredDesign[designBase + column], y, xty[column]);
        }
    }

    const uint betaBase = channel * params.columnCount;
    for (uint row = 0; row < params.columnCount; ++row) {
        float sum = 0.0f;
        const uint inverseBase = row * params.columnCount;
        for (uint column = 0; column < params.columnCount; ++column) {
            sum = fma(inverseXtX[inverseBase + column], xty[column], sum);
        }
        betaOut[betaBase + row] = sum;
    }
}

kernel void cwl_subtract_window(
    device float *corrected [[buffer(0)]],
    device const float *centeredDesign [[buffer(1)]],
    device const float *beta [[buffer(2)]],
    device const float *weightSum [[buffer(3)]],
    device const float *triangularWeights [[buffer(4)]],
    constant CWLParams &params [[buffer(5)]],
    uint2 position [[thread_position_in_grid]]
) {
    const uint channel = position.x;
    const uint offset = position.y;
    if (channel >= params.channelCount || offset >= params.windowLength || params.columnCount > kMaxColumns) {
        return;
    }

    const uint sample = params.windowStart + offset;
    if (sample >= params.sampleCount || weightSum[sample] <= 0.0f) {
        return;
    }

    const bool fullLengthWindow = params.windowLength == params.windowSamples;
    const float weight = (fullLengthWindow && offset < params.windowSamples)
        ? triangularWeights[offset]
        : 1.0f;
    const float scale = weight / weightSum[sample];
    const uint designBase = offset * params.columnCount;
    const uint betaBase = channel * params.columnCount;
    float fitted = 0.0f;
    for (uint column = 0; column < params.columnCount; ++column) {
        fitted = fma(centeredDesign[designBase + column], beta[betaBase + column], fitted);
    }

    corrected[channel * params.sampleCount + sample] -= fitted * scale;
}
"""
}
