//
//  OriginalCWLCorrectorEngine.swift
//  EVA Helper
//
//  MATLAB CWRegrTool-style Carbon Wire Loop regression path.
//

import Accelerate
import Foundation

nonisolated enum OriginalCWLCorrectorEngine {
    struct Config {
        var windowSeconds = 4.0
        var delaySeconds = 0.021
        var taperFactor = 1
    }

    static func correct(
        eeg: [[Float]],
        references: [[Float]],
        samplingRate: Double,
        config: Config,
        progress: ((CWLCorrectorEngine.ProgressUpdate) -> Void)? = nil,
        verbose: ((String) -> Void)? = nil
    ) throws -> CWLCorrectorEngine.RunInfo {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard !references.isEmpty, let sampleCount = references.first?.count, sampleCount > 0 else {
            throw CWLCorrectorEngine.Error.noReferenceChannels
        }
        guard eeg.allSatisfy({ $0.count == sampleCount }),
              references.allSatisfy({ $0.count == sampleCount }) else {
            throw CWLCorrectorEngine.Error.inconsistentSampleCounts
        }

        let taperFactor = max(config.taperFactor, 1)
        let nSteps = 1 << taperFactor
        var windowSamples = max(Int((samplingRate * config.windowSeconds + 1).rounded(.down)), 2)
        while (windowSamples - 1) % nSteps != 0 {
            windowSamples += 1
        }
        guard sampleCount > windowSamples else {
            throw CWLCorrectorEngine.Error.tooShortForWindow(
                windowSamples: windowSamples,
                sampleCount: sampleCount
            )
        }

        let stepSamples = max((windowSamples - 1) / nSteps, 1)
        let delaySamples = max(Int((samplingRate * config.delaySeconds).rounded(.down)), 0)
        let delayCount = 1 + 2 * delaySamples
        let regressorCount = references.count * delayCount
        guard regressorCount > 0 else { throw CWLCorrectorEngine.Error.noReferenceChannels }

        progress?(CWLCorrectorEngine.ProgressUpdate(
            fraction: 0,
            phase: .preparingCPU,
            message: "Preparing original CWL",
            detail: "\(references.count) reference channel\(references.count == 1 ? "" : "s")"
        ))
        verbose?(
            String(
                format: "Original CWL: refs=%d channels=%d samples=%d rate=%.3fHz window=%d step=%d delay=%d regressors=%d taper=%d",
                references.count,
                eeg.count,
                sampleCount,
                samplingRate,
                windowSamples,
                stepSamples,
                delaySamples,
                regressorCount,
                taperFactor
            )
        )

        let window = hannWindow(windowSamples)
        let storedWindowCount = 2 * (nSteps - 1) + 1
        var storedFits = [Float](
            repeating: 0,
            count: storedWindowCount * max(eeg.count, 1) * windowSamples
        )
        var storedWeights = [Float](repeating: 0, count: storedWindowCount * windowSamples)
        var artifact = eeg.map { [Float](repeating: 0, count: $0.count) }
        var artifactWeights = [Float](repeating: 0, count: sampleCount)
        var windowIndex = 0
        var currentStart = 0
        let maxWindows = max((sampleCount - windowSamples + stepSamples - 1) / stepSamples, 1)

        while currentStart + 1 < sampleCount - windowSamples {
            if currentStart >= windowSamples - 1 {
                accumulateOriginalWindowArtifact(
                    storedFits: storedFits,
                    storedWeights: storedWeights,
                    channelCount: eeg.count,
                    windowSamples: windowSamples,
                    storedWindowCount: storedWindowCount,
                    nSteps: nSteps,
                    stepSamples: stepSamples,
                    currentStart: currentStart,
                    artifact: &artifact,
                    artifactWeights: &artifactWeights
                )
            }

            let range = currentStart..<(currentStart + windowSamples)
            let fitted = fitOriginalWindow(
                eeg: eeg,
                references: references,
                range: range,
                window: window,
                delaySamples: delaySamples
            )

            shiftStoredOriginalWindows(
                fits: &storedFits,
                weights: &storedWeights,
                channelCount: eeg.count,
                windowSamples: windowSamples,
                storedWindowCount: storedWindowCount
            )
            storeOriginalWindow(
                fitted: fitted,
                window: window,
                fits: &storedFits,
                weights: &storedWeights,
                channelCount: eeg.count,
                windowSamples: windowSamples
            )

            windowIndex += 1
            if windowIndex % max(1, maxWindows / 500) == 0 || currentStart + stepSamples + 1 >= sampleCount - windowSamples {
                progress?(CWLCorrectorEngine.ProgressUpdate(
                    fraction: min(0.98, Double(windowIndex) / Double(maxWindows)),
                    phase: .correctingCPU,
                    message: "Correcting original CWL on CPU",
                    detail: "window \(windowIndex)/\(maxWindows)"
                ))
            }
            currentStart += stepSamples
        }

        for sample in 0..<sampleCount where artifactWeights[sample] > 0 {
            let scale = 1 / artifactWeights[sample]
            for channel in artifact.indices {
                artifact[channel][sample] *= scale
            }
        }

        var corrected = eeg
        for channel in corrected.indices {
            for sample in corrected[channel].indices {
                corrected[channel][sample] -= artifact[channel][sample]
            }
        }

        progress?(CWLCorrectorEngine.ProgressUpdate(
            fraction: 1,
            phase: .finished,
            message: "Original CWL complete",
            detail: "\(windowIndex) window\(windowIndex == 1 ? "" : "s")"
        ))
        verbose?(String(format: "Original CWL: finished, elapsed=%.3fs", seconds(from: startedAt)))
        return CWLCorrectorEngine.RunInfo(
            corrected: corrected,
            backendDescription: "Original MATLAB-style tapered Hann CPU",
            deviceName: nil,
            windowCount: windowIndex,
            regressorCount: regressorCount,
            cpuSeconds: seconds(from: startedAt),
            gpuSeconds: nil,
            comparison: nil
        )
    }

    private static func fitOriginalWindow(
        eeg: [[Float]],
        references: [[Float]],
        range: Range<Int>,
        window: [Float],
        delaySamples: Int
    ) -> [[Float]] {
        let sampleCount = range.count
        let channelCount = eeg.count
        let regressorCount = references.count * (1 + 2 * delaySamples)
        guard sampleCount > 0, channelCount > 0, regressorCount > 0 else {
            return eeg.map { _ in [Float](repeating: 0, count: sampleCount) }
        }

        var design = [Double](repeating: 0, count: sampleCount * regressorCount)
        for sampleOffset in 0..<sampleCount {
            var column = 0
            for delayIndex in 0..<(1 + 2 * delaySamples) {
                let sourceOffset = reflectedIndex(sampleOffset + delayIndex - delaySamples, count: sampleCount)
                let source = range.lowerBound + sourceOffset
                for reference in references {
                    design[sampleOffset * regressorCount + column] =
                        Double(reference[source] * window[sampleOffset])
                    column += 1
                }
            }
        }

        var rhs = [Double](repeating: 0, count: sampleCount * channelCount)
        for sampleOffset in 0..<sampleCount {
            let sample = range.lowerBound + sampleOffset
            for channel in 0..<channelCount {
                rhs[sampleOffset * channelCount + channel] =
                    Double(eeg[channel][sample] * window[sampleOffset])
            }
        }

        guard let coefficients = solveLeastSquaresSVD(
            designRowMajor: design,
            rows: sampleCount,
            columns: regressorCount,
            rhsRowMajor: rhs,
            rightHandSideCount: channelCount
        ) else {
            return eeg.map { _ in [Float](repeating: 0, count: sampleCount) }
        }

        var fitted = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channelCount)
        for sampleOffset in 0..<sampleCount {
            let designBase = sampleOffset * regressorCount
            for channel in 0..<channelCount {
                var total = 0.0
                for column in 0..<regressorCount {
                    total += design[designBase + column] * coefficients[column * channelCount + channel]
                }
                fitted[channel][sampleOffset] = Float(total)
            }
        }
        return fitted
    }

    private static func solveLeastSquaresSVD(
        designRowMajor: [Double],
        rows: Int,
        columns: Int,
        rhsRowMajor: [Double],
        rightHandSideCount: Int
    ) -> [Double]? {
        guard rows > 0, columns > 0, rightHandSideCount > 0 else { return nil }

        var a = [Double](repeating: 0, count: rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                a[column * rows + row] = designRowMajor[row * columns + column]
            }
        }

        let ldbValue = max(rows, columns)
        var b = [Double](repeating: 0, count: ldbValue * rightHandSideCount)
        for row in 0..<rows {
            for rhs in 0..<rightHandSideCount {
                b[row + rhs * ldbValue] = rhsRowMajor[row * rightHandSideCount + rhs]
            }
        }

        var m = LAPACKInt(rows)
        var n = LAPACKInt(columns)
        var nrhs = LAPACKInt(rightHandSideCount)
        var lda = LAPACKInt(rows)
        var ldb = LAPACKInt(ldbValue)
        var singularValues = [Double](repeating: 0, count: min(rows, columns))
        var rcond = -1.0
        var rank = LAPACKInt(0)
        var info = LAPACKInt(0)
        var query = [Double](repeating: 0, count: 1)
        var lwork = LAPACKInt(-1)

        dgelss_(&m, &n, &nrhs, &a, &lda, &b, &ldb, &singularValues, &rcond, &rank, &query, &lwork, &info)
        guard info == 0 else { return nil }
        lwork = max(LAPACKInt(query[0]), 1)
        var work = [Double](repeating: 0, count: Int(lwork))

        dgelss_(&m, &n, &nrhs, &a, &lda, &b, &ldb, &singularValues, &rcond, &rank, &work, &lwork, &info)
        guard info == 0 else { return nil }

        var coefficients = [Double](repeating: 0, count: columns * rightHandSideCount)
        for column in 0..<columns {
            for rhs in 0..<rightHandSideCount {
                coefficients[column * rightHandSideCount + rhs] = b[column + rhs * ldbValue]
            }
        }
        return coefficients
    }

    private static func accumulateOriginalWindowArtifact(
        storedFits: [Float],
        storedWeights: [Float],
        channelCount: Int,
        windowSamples: Int,
        storedWindowCount: Int,
        nSteps: Int,
        stepSamples: Int,
        currentStart: Int,
        artifact: inout [[Float]],
        artifactWeights: inout [Float]
    ) {
        let subtractStart = currentStart - stepSamples + 1
        guard subtractStart >= 0 else { return }

        for offset in 1...stepSamples {
            let sample = subtractStart + offset - 1
            guard sample < artifactWeights.count else { continue }

            var weightTotal: Float = 0
            for storedIndex in 0..<min(nSteps, storedWindowCount) {
                let sourceOffset = storedIndex * stepSamples + offset
                guard sourceOffset < windowSamples else { continue }
                weightTotal += storedWeights[storedIndex * windowSamples + sourceOffset]
                for channel in 0..<channelCount {
                    artifact[channel][sample] += storedFits[
                        fitIndex(
                            storedIndex: storedIndex,
                            channel: channel,
                            offset: sourceOffset,
                            channelCount: channelCount,
                            windowSamples: windowSamples
                        )
                    ]
                }
            }
            artifactWeights[sample] = weightTotal
        }
    }

    private static func shiftStoredOriginalWindows(
        fits: inout [Float],
        weights: inout [Float],
        channelCount: Int,
        windowSamples: Int,
        storedWindowCount: Int
    ) {
        guard storedWindowCount > 1 else { return }
        let fitStride = channelCount * windowSamples
        for storedIndex in stride(from: storedWindowCount - 1, through: 1, by: -1) {
            let destination = storedIndex * fitStride
            let source = (storedIndex - 1) * fitStride
            fits[destination..<(destination + fitStride)] = fits[source..<(source + fitStride)]

            let weightDestination = storedIndex * windowSamples
            let weightSource = (storedIndex - 1) * windowSamples
            weights[weightDestination..<(weightDestination + windowSamples)] =
                weights[weightSource..<(weightSource + windowSamples)]
        }
    }

    private static func storeOriginalWindow(
        fitted: [[Float]],
        window: [Float],
        fits: inout [Float],
        weights: inout [Float],
        channelCount: Int,
        windowSamples: Int
    ) {
        for channel in 0..<channelCount {
            for offset in 0..<windowSamples {
                fits[fitIndex(
                    storedIndex: 0,
                    channel: channel,
                    offset: offset,
                    channelCount: channelCount,
                    windowSamples: windowSamples
                )] = fitted[channel][offset]
            }
        }
        for offset in 0..<windowSamples {
            weights[offset] = window[offset]
        }
    }

    private static func fitIndex(
        storedIndex: Int,
        channel: Int,
        offset: Int,
        channelCount: Int,
        windowSamples: Int
    ) -> Int {
        storedIndex * channelCount * windowSamples + channel * windowSamples + offset
    }

    private static func reflectedIndex(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        if index < 0 {
            return min(-index - 1, count - 1)
        }
        if index >= count {
            return max(0, 2 * count - index - 1)
        }
        return index
    }

    private static func hannWindow(_ length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 1, count: max(length, 0)) }
        if length % 2 == 1 {
            let halfCount = (length + 1) / 2
            let firstHalf = (0..<halfCount).map { index -> Float in
                let x = Double(index) / Double(length - 1)
                return Float(0.5 - 0.5 * cos(2 * Double.pi * x))
            }
            return firstHalf + firstHalf.dropLast().reversed()
        } else {
            let halfCount = length / 2
            let firstHalf = (0..<halfCount).map { index -> Float in
                let x = Double(index) / Double(length - 1)
                return Float(0.5 - 0.5 * cos(2 * Double.pi * x))
            }
            return firstHalf + firstHalf.reversed()
        }
    }

    private static func seconds(from startedAt: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now - startedAt) / 1_000_000_000
    }
}
