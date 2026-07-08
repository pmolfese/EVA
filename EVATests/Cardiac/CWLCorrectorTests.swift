//
//  CWLCorrectorTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//

import Accelerate
import XCTest
@testable import EVA

final class CWLCorrectorTests: XCTestCase {
    func testCachedWindowRegressionMatchesLegacyPerChannelSolve() throws {
        let samplingRate = 250.0
        let sampleCount = 720
        let lagRange = -20.0...40.0
        let lagStep = 20.0
        let windowSeconds = 0.40

        let references = makeReferences(sampleCount: sampleCount, samplingRate: samplingRate)
        let eeg = makeEEG(references: references, samplingRate: samplingRate)
        let progressRecorder = ProgressRecorder()

        let cached = try CWLCorrector.correct(
            eeg: eeg,
            references: references,
            samplingRate: samplingRate,
            lagRangeMs: lagRange,
            lagStepMs: lagStep,
            windowSeconds: windowSeconds,
            algorithm: .evaFast,
            progress: { progressRecorder.append($0.fraction) }
        )
        let legacy = try legacyCorrect(
            eeg: eeg,
            references: references,
            samplingRate: samplingRate,
            lagRangeMs: lagRange,
            lagStepMs: lagStep,
            windowSeconds: windowSeconds
        )

        XCTAssertEqual(cached.count, legacy.count)
        XCTAssertEqual(cached.first?.count, legacy.first?.count)

        var maxAbsoluteDifference = 0.0
        var squaredDifferenceSum = 0.0
        var valueCount = 0
        for channel in cached.indices {
            for sample in cached[channel].indices {
                let difference = abs(Double(cached[channel][sample] - legacy[channel][sample]))
                maxAbsoluteDifference = max(maxAbsoluteDifference, difference)
                squaredDifferenceSum += difference * difference
                valueCount += 1
            }
        }

        let rmsDifference = sqrt(squaredDifferenceSum / Double(max(valueCount, 1)))
        XCTAssertLessThan(maxAbsoluteDifference, 1e-4)
        XCTAssertLessThan(rmsDifference, 1e-5)
        XCTAssertEqual(progressRecorder.values.last ?? -1, 1, accuracy: 1e-12)
    }

    func testDownsampledRegressionReturnsDownsampledShapeByDefault() throws {
        let samplingRate = 1000.0
        let sampleCount = 1200
        let references = makeReferences(sampleCount: sampleCount, samplingRate: samplingRate)
        let eeg = makeEEG(references: references, samplingRate: samplingRate)
        let progressRecorder = ProgressRecorder()

        let corrected = try CWLCorrector.correct(
            eeg: eeg,
            references: references,
            samplingRate: samplingRate,
            lagRangeMs: -20...40,
            lagStepMs: 20,
            windowSeconds: 0.4,
            algorithm: .evaFast,
            downsampleFactor: 2,
            progress: { progressRecorder.append($0.fraction) }
        )

        XCTAssertEqual(corrected.count, eeg.count)
        XCTAssertEqual(corrected.map(\.count), Array(repeating: 600, count: eeg.count))
        XCTAssertEqual(progressRecorder.values.last ?? -1, 1, accuracy: 1e-12)
    }

    func testDownsampledRegressionCanUpsampleToOriginalShape() throws {
        let samplingRate = 1000.0
        let sampleCount = 1200
        let references = makeReferences(sampleCount: sampleCount, samplingRate: samplingRate)
        let eeg = makeEEG(references: references, samplingRate: samplingRate)
        let progressRecorder = ProgressRecorder()

        let corrected = try CWLCorrector.correct(
            eeg: eeg,
            references: references,
            samplingRate: samplingRate,
            lagRangeMs: -20...40,
            lagStepMs: 20,
            windowSeconds: 0.4,
            algorithm: .evaFast,
            downsampleFactor: 2,
            upsampleToOriginalRate: true,
            progress: { progressRecorder.append($0.fraction) }
        )

        XCTAssertEqual(corrected.count, eeg.count)
        XCTAssertEqual(corrected.map(\.count), eeg.map(\.count))
        XCTAssertEqual(progressRecorder.values.last ?? -1, 1, accuracy: 1e-12)
    }

    func testCWRegrToolCompatibleRegressionRunsByDefault() throws {
        let samplingRate = 250.0
        let sampleCount = 2200
        let references = makeReferences(sampleCount: sampleCount, samplingRate: samplingRate)
        let eeg = makeEEG(references: references, samplingRate: samplingRate)
        let progressRecorder = ProgressRecorder()

        let corrected = try CWLCorrector.correct(
            eeg: eeg,
            references: references,
            samplingRate: samplingRate,
            cwlToolDelayMs: 20,
            windowSeconds: 1.0,
            progress: { progressRecorder.append($0.fraction) }
        )

        XCTAssertEqual(corrected.count, eeg.count)
        XCTAssertEqual(corrected.map(\.count), eeg.map(\.count))
        XCTAssertEqual(progressRecorder.values.last ?? -1, 1, accuracy: 1e-12)
        XCTAssertNotEqual(corrected[0], eeg[0])
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func makeReferences(sampleCount: Int, samplingRate: Double) -> [[Float]] {
    (0..<2).map { referenceIndex in
        (0..<sampleCount).map { sample in
            let t = Double(sample) / samplingRate
            let cardiac = sin(2.0 * .pi * (1.1 + 0.08 * Double(referenceIndex)) * t)
            let harmonic = 0.35 * sin(2.0 * .pi * (2.2 + 0.05 * Double(referenceIndex)) * t + 0.4)
            let drift = 0.08 * sin(2.0 * .pi * 0.16 * t + Double(referenceIndex))
            return Float(cardiac + harmonic + drift)
        }
    }
}

private func makeEEG(references: [[Float]], samplingRate: Double) -> [[Float]] {
    let sampleCount = references.first?.count ?? 0
    return (0..<4).map { channelIndex in
        let shiftedA = legacyShifted(references[0], by: channelIndex - 1)
        let shiftedB = legacyShifted(references[1], by: 2 - channelIndex)
        return (0..<sampleCount).map { sample in
            let t = Double(sample) / samplingRate
            let neural = 0.18 * sin(2.0 * .pi * (8.0 + Double(channelIndex)) * t + 0.2)
            let artifact = (0.62 + 0.05 * Double(channelIndex)) * Double(shiftedA[sample])
                - (0.31 - 0.02 * Double(channelIndex)) * Double(shiftedB[sample])
            let slow = 0.04 * sin(2.0 * .pi * 0.07 * t + Double(channelIndex))
            return Float(neural + artifact + slow)
        }
    }
}

private func legacyCorrect(
    eeg: [[Float]],
    references: [[Float]],
    samplingRate: Double,
    lagRangeMs: ClosedRange<Double>,
    lagStepMs: Double,
    windowSeconds: Double
) throws -> [[Float]] {
    guard !references.isEmpty, let sampleCount = references.first?.count, sampleCount > 0 else {
        throw CWLCorrector.CWLCorrectorError.noReferenceChannels
    }

    let windowSamples = max(Int(windowSeconds * samplingRate), 8)
    guard sampleCount >= windowSamples else {
        throw CWLCorrector.CWLCorrectorError.tooShortForWindow(
            windowSamples: windowSamples,
            sampleCount: sampleCount
        )
    }

    let lagSamples = stride(from: lagRangeMs.lowerBound, through: lagRangeMs.upperBound, by: max(lagStepMs, 1))
        .map { Int(($0 / 1000.0 * samplingRate).rounded()) }
    let uniqueLags = Array(Set(lagSamples)).sorted()

    var design: [[Float]] = []
    design.reserveCapacity(references.count * uniqueLags.count)
    for reference in references {
        for lag in uniqueLags {
            design.append(legacyShifted(reference, by: lag))
        }
    }

    return eeg.map { channel in
        legacyCorrectChannel(channel, design: design, windowSamples: windowSamples)
    }
}

private func legacyCorrectChannel(
    _ channel: [Float],
    design: [[Float]],
    windowSamples: Int
) -> [Float] {
    let sampleCount = channel.count
    let hop = max(windowSamples / 2, 1)
    let columnCount = design.count
    guard columnCount > 0 else { return channel }

    var artifactEstimate = [Double](repeating: 0, count: sampleCount)
    var weightSum = [Double](repeating: 0, count: sampleCount)
    let triangularWeights = legacyTriangularWindow(windowSamples)

    var start = 0
    while start < sampleCount {
        let end = min(start + windowSamples, sampleCount)
        let length = end - start
        if length >= columnCount + 1,
           let fitted = legacyRegressWindow(y: channel, design: design, range: start..<end) {
            for i in 0..<length {
                let weight = length == windowSamples ? triangularWeights[i] : 1.0
                artifactEstimate[start + i] += Double(fitted[i]) * weight
                weightSum[start + i] += weight
            }
        }
        if end == sampleCount { break }
        start += hop
    }

    var corrected = channel
    for sample in 0..<sampleCount where weightSum[sample] > 0 {
        corrected[sample] -= Float(artifactEstimate[sample] / weightSum[sample])
    }
    return corrected
}

private func legacyRegressWindow(
    y: [Float],
    design: [[Float]],
    range: Range<Int>
) -> [Float]? {
    let length = range.count
    let columnCount = design.count

    var yMean: Float = 0
    vDSP_meanv(Array(y[range]), 1, &yMean, vDSP_Length(length))
    let yCentered = y[range].map { Double($0) - Double(yMean) }

    var columns: [[Double]] = []
    columns.reserveCapacity(columnCount)
    for column in design {
        var mean: Float = 0
        let slice = Array(column[range])
        vDSP_meanv(slice, 1, &mean, vDSP_Length(length))
        columns.append(slice.map { Double($0) - Double(mean) })
    }

    var xtx = [Double](repeating: 0, count: columnCount * columnCount)
    var xty = [Double](repeating: 0, count: columnCount)
    for i in 0..<columnCount {
        xty[i] = LinearAlgebra.dot(columns[i], yCentered)
        for j in i..<columnCount {
            let value = LinearAlgebra.dot(columns[i], columns[j])
            xtx[i * columnCount + j] = value
            xtx[j * columnCount + i] = value
        }
    }

    let diagonalMean = (0..<columnCount).reduce(0.0) { $0 + xtx[$1 * columnCount + $1] } / Double(columnCount)
    let ridge = 1e-6 * diagonalMean + 1e-12
    for i in 0..<columnCount { xtx[i * columnCount + i] += ridge }

    guard let beta = LinearAlgebra.solveLinearSystem(a: &xtx, b: &xty, size: columnCount) else {
        return nil
    }

    var fitted = [Float](repeating: 0, count: length)
    for i in 0..<length {
        var sum = 0.0
        for column in 0..<columnCount {
            sum += beta[column] * columns[column][i]
        }
        fitted[i] = Float(sum)
    }
    return fitted
}

private func legacyShifted(_ signal: [Float], by lag: Int) -> [Float] {
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

private func legacyTriangularWindow(_ length: Int) -> [Double] {
    guard length > 1 else { return [Double](repeating: 1, count: max(length, 0)) }
    let mid = Double(length - 1) / 2.0
    return (0..<length).map { 1.0 - abs(Double($0) - mid) / (mid + 1) }
}
