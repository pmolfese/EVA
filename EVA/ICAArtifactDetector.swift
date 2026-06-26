//
//  ICAArtifactDetector.swift
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
//  ICA artifact exploration and reconstruction.
//
//  Portions of the algorithmic structure are adapted from MNE-Python's ICA
//  and infomax implementation:
//  https://github.com/mne-tools/mne-python
//
//  MNE-Python license notice:
//
//  Copyright 2011-2025 MNE-Python authors
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  1. Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
//  3. Neither the name of the copyright holder nor the names of its
//     contributors may be used to endorse or promote products derived from
//     this software without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
//  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//  POSSIBILITY OF SUCH DAMAGE.
//

import Accelerate
import Foundation

enum ICAMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case picard
    case fastICA
    case infomax

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .picard: return "Picard"
        case .fastICA: return "FastICA"
        case .infomax: return "Infomax"
        }
    }

    var summary: String {
        switch self {
        case .picard:
            return "Preconditioned ICA (L-BFGS). Fastest; converges in a handful of iterations. Recommended."
        case .fastICA:
            return "Symmetric fixed-point ICA. Very fast, robust for clearly non-Gaussian sources."
        case .infomax:
            return "Extended Infomax (MNE/EEGLAB style). Slower, included for reference and comparison."
        }
    }
}

struct ICAConfiguration: Sendable {
    var method: ICAMethod
    var componentCount: Int
    var varianceThreshold: Double
    var averageReference: Bool
    var downsampleRate: Double
    var maxIterations: Int
    var learningRate: Double?
    var fitFilter: ICAFitFilterSettings?
    var convergenceTolerance: Double
    var minimumIterations: Int
}

struct ICAFitFilterSettings: Codable, Sendable {
    var lowCutoff: Double
    var highCutoff: Double
    var notch60HzEnabled: Bool
}

struct ICAComponentSuggestion: Sendable {
    var label: String
    var confidence: Double
    var reason: String
    var probabilities: [String: Double] = [:]
}

struct ICADecomposition: Sendable {
    var sourceSignalPath: String
    var sourceSamplingRate: Double
    var analysisSamplingRate: Double
    var decimation: Int
    var fitFilter: ICAFitFilterSettings?
    var convergenceTolerance: Double
    var minimumIterations: Int
    var finalChange: Double
    var varianceThreshold: Double
    var pcaVarianceRetained: Double
    var averageReference: Bool
    var channelCount: Int
    var sampleCount: Int
    var componentCount: Int
    var iterations: Int
    var channelMeans: [Double]
    var mixingMatrix: [[Double]]
    var unmixingMatrix: [[Double]]
    var componentMaps: [[Double]]
    var componentSources: [[Double]]
    var explainedVariance: [Double]
    var pcaExplainedVariance: [Double]
    var labels: [Int: String] = [:]
    var labelSuggestions: [Int: ICAComponentSuggestion] = [:]
    var excludedComponents: Set<Int> = []
}

struct SavedICAArtifactSet: Codable, Sendable {
    var schemaVersion: Int
    var createdAt: Date
    var sourceSignalPath: String
    var sourceSamplingRate: Double
    var analysisSamplingRate: Double
    var decimation: Int
    var fitFilter: ICAFitFilterSettings?
    var convergenceTolerance: Double
    var minimumIterations: Int
    var finalChange: Double
    var varianceThreshold: Double
    var pcaVarianceRetained: Double
    var averageReference: Bool
    var componentCount: Int
    var excludedComponents: [SavedICAComponent]
    var explainedVariance: [Double]
}

struct SavedICAComponent: Codable, Sendable {
    var index: Int
    var label: String
    var topography: [Double]
}

nonisolated enum ICAArtifactDetector {
    static func fit(
        signal: MFFSignalData,
        configuration: ICAConfiguration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ICADecomposition {
        guard signal.samplingRate > 0,
              let rawSampleCount = signal.data.first?.count,
              rawSampleCount > 2,
              !signal.data.isEmpty else {
            throw ICAError.emptySignal
        }

        progress?(0.02)
        let decimation = max(Int((signal.samplingRate / max(configuration.downsampleRate, 1)).rounded()), 1)
        let analysisSamplingRate = signal.samplingRate / Double(decimation)
        let downsampled = signal.data.map { downsample($0, by: decimation).map(Double.init) }
        let prepared = configuration.averageReference ? averageReferenced(downsampled) : downsampled
        guard let sampleCount = prepared.first?.count, sampleCount > 2 else {
            throw ICAError.emptySignal
        }

        let channelCount = prepared.count
        let maximumComponentCount = min(max(configuration.componentCount, 1), channelCount)
        let centered = center(prepared)
        progress?(0.10)
        let covariance = covarianceMatrix(centered.samples, sampleCount: sampleCount)
        progress?(0.18)
        let eigen = symmetricEigenDecomposition(covariance)
        progress?(0.34)
        let ordered = eigen.values.indices.sorted { eigen.values[$0] > eigen.values[$1] }
        let selected = selectedPCAIndices(
            ordered: ordered,
            eigenvalues: eigen.values,
            maximumComponentCount: maximumComponentCount,
            varianceThreshold: configuration.varianceThreshold
        )
        let componentCount = selected.count
        let pcaExplained = selected.map { max(eigen.values[$0], 0) }
        let pcaTotal = ordered.map { max(eigen.values[$0], 0) }.reduce(0, +)
        let pcaVarianceRetained = pcaTotal > 0 ? pcaExplained.reduce(0, +) / pcaTotal : 0

        let whitening = whiteningMatrix(eigenvectors: eigen.vectors, eigenvalues: eigen.values, selected: selected)
        let dewhitening = dewhiteningMatrix(eigenvectors: eigen.vectors, eigenvalues: eigen.values, selected: selected)
        let whitened = multiply(whitening, centered.samples)
        progress?(0.42)
        let infomax = solveICA(
            whitened,
            method: configuration.method,
            maxIterations: max(configuration.maxIterations, 1),
            learningRate: configuration.learningRate,
            convergenceTolerance: max(configuration.convergenceTolerance, 0),
            minimumIterations: max(configuration.minimumIterations, 0),
            progress: { fraction in
                progress?(0.42 + 0.44 * fraction)
            }
        )
        progress?(0.88)
        let sources = multiply(infomax.unmixing, whitened)
        let inverseRotation = pseudoInverse(infomax.unmixing)
        let mixing = multiply(dewhitening, inverseRotation)
        let unmixing = multiply(infomax.unmixing, whitening)
        let componentMaps = transpose(mixing)
        let explained = componentContributions(mixingMatrix: mixing, sources: sources)
        progress?(1.0)

        return ICADecomposition(
            sourceSignalPath: signal.signalURL.path,
            sourceSamplingRate: signal.samplingRate,
            analysisSamplingRate: analysisSamplingRate,
            decimation: decimation,
            fitFilter: configuration.fitFilter,
            convergenceTolerance: max(configuration.convergenceTolerance, 0),
            minimumIterations: max(configuration.minimumIterations, 0),
            finalChange: infomax.finalChange,
            varianceThreshold: min(max(configuration.varianceThreshold, 0), 1),
            pcaVarianceRetained: pcaVarianceRetained,
            averageReference: configuration.averageReference,
            channelCount: channelCount,
            sampleCount: sampleCount,
            componentCount: componentCount,
            iterations: infomax.iterations,
            channelMeans: centered.means,
            mixingMatrix: mixing,
            unmixingMatrix: unmixing,
            componentMaps: componentMaps,
            componentSources: sources,
            explainedVariance: explained,
            pcaExplainedVariance: pcaExplained
        )
    }

    static func cleanedSignal(
        from signal: MFFSignalData,
        activationSignal: MFFSignalData? = nil,
        decomposition: ICADecomposition,
        excluding excluded: Set<Int>
    ) -> MFFSignalData {
        guard !excluded.isEmpty,
              signal.numberOfChannels == decomposition.channelCount,
              let sampleCount = signal.data.first?.count else {
            return signal
        }

        let activationData = activationSignal?.data ?? signal.data
        guard activationData.count == signal.numberOfChannels,
              activationData.first?.count == sampleCount else {
            return signal
        }

        let selectedComponents = excluded
            .filter { $0 >= 0 && $0 < decomposition.componentCount }
            .sorted()
        guard !selectedComponents.isEmpty else { return signal }

        var cleaned = signal.data
        let channelCount = min(signal.numberOfChannels, decomposition.channelMeans.count)

        // Rank-k factorization of the artifact projection. Removing k components
        // out of n channels is artifact = mixing[:,excl] · (unmixing[excl,:] · x).
        // Applying it as two skinny matmuls (O(n·k·T)) is far cheaper than
        // forming the full n×n projection and applying it (O(n²·T)) when k ≪ n.
        let excludedCount = selectedComponents.count
        var unmixingRows = [Float](repeating: 0, count: excludedCount * channelCount) // k × n
        var mixingColumns = [Float](repeating: 0, count: channelCount * excludedCount) // n × k
        for (rank, component) in selectedComponents.enumerated() {
            for channel in 0..<channelCount {
                if component < decomposition.unmixingMatrix.count,
                   channel < decomposition.unmixingMatrix[component].count {
                    unmixingRows[rank * channelCount + channel] = Float(decomposition.unmixingMatrix[component][channel])
                }
                if channel < decomposition.mixingMatrix.count,
                   component < decomposition.mixingMatrix[channel].count {
                    mixingColumns[channel * excludedCount + rank] = Float(decomposition.mixingMatrix[channel][component])
                }
            }
        }
        let activationMeans = decomposition.averageReference
            ? averageReferencedChannelMeans(activationData, channelCount: channelCount)
            : channelMeans(activationData, channelCount: channelCount)
        let artifactLimits = artifactCorrectionLimits(
            activationData,
            means: activationMeans,
            channelCount: channelCount,
            averageReference: decomposition.averageReference
        )
        let blockSamples = 32_768

        for blockStart in stride(from: 0, to: sampleCount, by: blockSamples) {
            let blockCount = min(blockSamples, sampleCount - blockStart)
            var centeredBlock = Array(repeating: Float(0), count: channelCount * blockCount)
            var sourceBlock = Array(repeating: Float(0), count: excludedCount * blockCount)
            var artifactBlock = Array(repeating: Float(0), count: channelCount * blockCount)
            var referenceMeans = Array(repeating: Float(0), count: blockCount)

            if decomposition.averageReference {
                for sampleOffset in 0..<blockCount {
                    var total: Float = 0
                    for channel in 0..<channelCount where activationData[channel].count > blockStart + sampleOffset {
                        total += activationData[channel][blockStart + sampleOffset]
                    }
                    referenceMeans[sampleOffset] = total / Float(max(channelCount, 1))
                }
            }

            for channel in 0..<channelCount {
                guard activationData[channel].count >= blockStart + blockCount else { continue }
                let mean = activationMeans[channel]
                let rowStart = channel * blockCount
                for sampleOffset in 0..<blockCount {
                    let reference = decomposition.averageReference ? referenceMeans[sampleOffset] : 0
                    centeredBlock[rowStart + sampleOffset] = activationData[channel][blockStart + sampleOffset] - reference - mean
                }
            }

            // sources = unmixing[excl,:] · centered   (k × block)
            cblas_sgemm(
                CblasRowMajor, CblasNoTrans, CblasNoTrans,
                Int32(excludedCount), Int32(blockCount), Int32(channelCount),
                1.0,
                unmixingRows, Int32(channelCount),
                centeredBlock, Int32(blockCount),
                0.0,
                &sourceBlock, Int32(blockCount)
            )
            // artifact = mixing[:,excl] · sources   (n × block)
            cblas_sgemm(
                CblasRowMajor, CblasNoTrans, CblasNoTrans,
                Int32(channelCount), Int32(blockCount), Int32(excludedCount),
                1.0,
                mixingColumns, Int32(excludedCount),
                sourceBlock, Int32(blockCount),
                0.0,
                &artifactBlock, Int32(blockCount)
            )

            for channel in 0..<channelCount {
                guard cleaned[channel].count >= blockStart + blockCount else { continue }
                let rowStart = channel * blockCount
                let limit = artifactLimits[channel]
                for sampleOffset in 0..<blockCount {
                    let correction = artifactBlock[rowStart + sampleOffset]
                    guard correction.isFinite else { continue }
                    cleaned[channel][blockStart + sampleOffset] -= min(max(correction, -limit), limit)
                }
            }
        }

        return MFFSignalData(
            signalURL: signal.signalURL,
            signalType: "\(signal.signalType) ICA Cleaned",
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: signal.events,
            data: cleaned,
            channelNames: signal.channelNames
        )
    }

    static func savedArtifactSet(from decomposition: ICADecomposition) -> SavedICAArtifactSet {
        let components = decomposition.excludedComponents.sorted().map { index in
            SavedICAComponent(
                index: index,
                label: decomposition.labels[index] ?? "ICA \(index + 1)",
                topography: index < decomposition.componentMaps.count ? normalizedTopography(decomposition.componentMaps[index]) : []
            )
        }

        return SavedICAArtifactSet(
            schemaVersion: 1,
            createdAt: Date(),
            sourceSignalPath: decomposition.sourceSignalPath,
            sourceSamplingRate: decomposition.sourceSamplingRate,
            analysisSamplingRate: decomposition.analysisSamplingRate,
            decimation: decomposition.decimation,
            fitFilter: decomposition.fitFilter,
            convergenceTolerance: decomposition.convergenceTolerance,
            minimumIterations: decomposition.minimumIterations,
            finalChange: decomposition.finalChange,
            varianceThreshold: decomposition.varianceThreshold,
            pcaVarianceRetained: decomposition.pcaVarianceRetained,
            averageReference: decomposition.averageReference,
            componentCount: decomposition.componentCount,
            excludedComponents: components,
            explainedVariance: decomposition.explainedVariance
        )
    }
}

enum ICAError: LocalizedError {
    case emptySignal
    case singularMatrix

    var errorDescription: String? {
        switch self {
        case .emptySignal:
            return "The signal does not have enough samples for ICA."
        case .singularMatrix:
            return "ICA produced a singular matrix."
        }
    }
}

nonisolated private func downsample(_ samples: [Float], by decimation: Int) -> [Float] {
    guard decimation > 1 else { return samples }
    return stride(from: 0, to: samples.count, by: decimation).map { samples[$0] }
}

nonisolated private func averageReferenced(_ data: [[Double]]) -> [[Double]] {
    guard let sampleCount = data.first?.count,
          sampleCount > 0,
          !data.isEmpty else {
        return data
    }

    let channelCount = data.count
    guard channelCount > 1, data.allSatisfy({ $0.count == sampleCount }) else {
        // Fall back for ragged input.
        var referenced = data
        for sample in 0..<sampleCount {
            var total = 0.0
            for channel in 0..<channelCount where data[channel].count > sample {
                total += data[channel][sample]
            }
            let reference = total / Double(channelCount)
            for channel in 0..<channelCount where referenced[channel].count > sample {
                referenced[channel][sample] -= reference
            }
        }
        return referenced
    }

    // Two cache-friendly, SIMD-vectorized passes (see EEGSignalFilter notes).
    let length = vDSP_Length(sampleCount)
    var mean = [Double](repeating: 0, count: sampleCount)
    for channel in data {
        channel.withUnsafeBufferPointer { source in
            vDSP_vaddD(mean, 1, source.baseAddress!, 1, &mean, 1, length)
        }
    }
    var scale = 1 / Double(channelCount)
    vDSP_vsmulD(mean, 1, &scale, &mean, 1, length)

    var referenced = data
    for index in 0..<channelCount {
        referenced[index].withUnsafeMutableBufferPointer { destination in
            // vDSP_vsubD computes C = B - A, i.e. channel - mean.
            vDSP_vsubD(mean, 1, destination.baseAddress!, 1, destination.baseAddress!, 1, length)
        }
    }
    return referenced
}

nonisolated private func selectedPCAIndices(
    ordered: [Int],
    eigenvalues: [Double],
    maximumComponentCount: Int,
    varianceThreshold: Double
) -> [Int] {
    guard !ordered.isEmpty, maximumComponentCount > 0 else { return [] }

    let positiveValues = ordered.map { max(eigenvalues[$0], 0) }
    let total = positiveValues.reduce(0, +)
    let largest = max(positiveValues.first ?? 0, 1e-18)
    let stableCount = max(
        ordered.prefix(maximumComponentCount).prefix { max(eigenvalues[$0], 0) / largest > 1e-6 }.count,
        1
    )
    guard total > 0 else {
        return Array(ordered.prefix(min(maximumComponentCount, stableCount)))
    }

    let threshold = min(max(varianceThreshold, 0), 1)
    var cumulative = 0.0
    var thresholdCount = 0
    for value in positiveValues {
        thresholdCount += 1
        cumulative += value
        if cumulative / total >= threshold {
            break
        }
    }

    let count = min(maximumComponentCount, max(1, thresholdCount), stableCount)
    return Array(ordered.prefix(count))
}

nonisolated private func componentContributions(mixingMatrix: [[Double]], sources: [[Double]]) -> [Double] {
    sources.indices.map { component in
        let sourceVariance = variance(sources[component])
        var mapNormSquared = 0.0
        for channel in mixingMatrix.indices where component < mixingMatrix[channel].count {
            let value = mixingMatrix[channel][component]
            mapNormSquared += value * value
        }
        return max(sourceVariance * mapNormSquared, 0)
    }
}

nonisolated private func channelMeans(_ data: [[Float]], channelCount: Int) -> [Float] {
    (0..<channelCount).map { channel in
        guard channel < data.count, !data[channel].isEmpty else { return 0 }
        let total = data[channel].reduce(0.0) { $0 + Double($1) }
        return Float(total / Double(data[channel].count))
    }
}

nonisolated private func averageReferencedChannelMeans(_ data: [[Float]], channelCount: Int) -> [Float] {
    guard let sampleCount = data.first?.count,
          sampleCount > 0,
          channelCount > 0 else {
        return Array(repeating: 0, count: channelCount)
    }

    var totals = Array(repeating: 0.0, count: channelCount)
    for sample in 0..<sampleCount {
        var referenceTotal = 0.0
        for channel in 0..<channelCount where channel < data.count && data[channel].count > sample {
            referenceTotal += Double(data[channel][sample])
        }
        let reference = referenceTotal / Double(channelCount)
        for channel in 0..<channelCount where channel < data.count && data[channel].count > sample {
            totals[channel] += Double(data[channel][sample]) - reference
        }
    }

    return totals.map { Float($0 / Double(sampleCount)) }
}

nonisolated private func artifactCorrectionLimits(
    _ data: [[Float]],
    means: [Float],
    channelCount: Int,
    averageReference: Bool
) -> [Float] {
    (0..<channelCount).map { channel in
        guard channel < data.count,
              channel < means.count,
              !data[channel].isEmpty else {
            return 500
        }

        let samples = data[channel]
        let stride = max(samples.count / 8_192, 1)
        var absoluteValues: [Float] = []
        absoluteValues.reserveCapacity(samples.count / stride + 1)

        for sample in Swift.stride(from: 0, to: samples.count, by: stride) {
            let reference: Float
            if averageReference {
                var total: Float = 0
                for referenceChannel in 0..<channelCount where referenceChannel < data.count && data[referenceChannel].count > sample {
                    total += data[referenceChannel][sample]
                }
                reference = total / Float(max(channelCount, 1))
            } else {
                reference = 0
            }
            let value = abs(samples[sample] - reference - means[channel])
            if value.isFinite {
                absoluteValues.append(value)
            }
        }

        guard !absoluteValues.isEmpty else { return 500 }
        absoluteValues.sort()
        let index = min(
            max(Int((Double(absoluteValues.count - 1) * 0.99).rounded()), 0),
            absoluteValues.count - 1
        )
        let robustPeak = absoluteValues[index]
        return min(max(robustPeak * 20, 500), 5_000)
    }
}

nonisolated private func center(_ data: [[Double]], means suppliedMeans: [Double]? = nil) -> (samples: [[Double]], means: [Double]) {
    let means = suppliedMeans ?? data.map { channel in
        channel.reduce(0, +) / Double(max(channel.count, 1))
    }
    let centered = data.enumerated().map { index, channel in
        channel.map { $0 - means[index] }
    }
    return (centered, means)
}

nonisolated private func covarianceMatrix(_ data: [[Double]], sampleCount: Int) -> [[Double]] {
    let channels = data.count
    guard channels > 0, sampleCount > 0 else { return [] }

    let flattened = flatten(data)
    var covariance = Array(repeating: 0.0, count: channels * channels)
    let divisor = Double(max(sampleCount - 1, 1))

    cblas_dgemm(
        CblasRowMajor,
        CblasNoTrans,
        CblasTrans,
        Int32(channels),
        Int32(channels),
        Int32(sampleCount),
        1.0 / divisor,
        flattened,
        Int32(sampleCount),
        flattened,
        Int32(sampleCount),
        0.0,
        &covariance,
        Int32(channels)
    )

    return unflatten(covariance, rows: channels, columns: channels)
}

nonisolated private func whiteningMatrix(eigenvectors: [[Double]], eigenvalues: [Double], selected: [Int]) -> [[Double]] {
    selected.map { eigenIndex in
        let scale = 1.0 / sqrt(max(eigenvalues[eigenIndex], 1e-12))
        return eigenvectors.map { row in row[eigenIndex] * scale }
    }
}

nonisolated private func dewhiteningMatrix(eigenvectors: [[Double]], eigenvalues: [Double], selected: [Int]) -> [[Double]] {
    eigenvectors.map { row in
        selected.map { eigenIndex in
            row[eigenIndex] * sqrt(max(eigenvalues[eigenIndex], 1e-12))
        }
    }
}

// MARK: - ICA solver dispatch (flat Float / BLAS)
//
// All three solvers operate on the whitened data in a single contiguous
// row-major Float buffer (features × samples). Working in Float and reusing
// preallocated scratch buffers (instead of allocating nested [[Double]] every
// block) is what makes the decomposition fast enough to feel instant locally.

nonisolated private func solveICA(
    _ data: [[Double]],
    method: ICAMethod,
    maxIterations: Int,
    learningRate: Double?,
    convergenceTolerance: Double,
    minimumIterations: Int,
    progress: (@Sendable (Double) -> Void)? = nil
) -> (unmixing: [[Double]], iterations: Int, finalChange: Double) {
    let features = data.count
    let samples = data.first?.count ?? 0
    guard features > 0, samples > 1 else {
        progress?(1.0)
        return (identity(features), 0, 0)
    }

    // Pack whitened data into one contiguous row-major Float buffer.
    var packed = [Float](repeating: 0, count: features * samples)
    for feature in 0..<features {
        let row = data[feature]
        let base = feature * samples
        let count = min(samples, row.count)
        for sample in 0..<count {
            packed[base + sample] = Float(row[sample])
        }
    }

    switch method {
    case .infomax:
        return infomaxFloat(
            packed, features: features, samples: samples,
            maxIterations: maxIterations, learningRate: learningRate,
            convergenceTolerance: convergenceTolerance,
            minimumIterations: minimumIterations, progress: progress
        )
    case .fastICA:
        return fastICAFloat(
            packed, features: features, samples: samples,
            maxIterations: maxIterations,
            convergenceTolerance: convergenceTolerance,
            minimumIterations: minimumIterations, progress: progress
        )
    case .picard:
        return picardFloat(
            packed, features: features, samples: samples,
            maxIterations: maxIterations,
            convergenceTolerance: convergenceTolerance,
            minimumIterations: minimumIterations, progress: progress
        )
    }
}

// MARK: - BLAS / vForce helpers

@inline(__always)
nonisolated private func blasSGEMM(
    transA: Bool, transB: Bool,
    m: Int, n: Int, k: Int,
    alpha: Float,
    _ a: [Float], lda: Int,
    _ b: [Float], ldb: Int,
    beta: Float,
    _ c: inout [Float], ldc: Int
) {
    a.withUnsafeBufferPointer { ap in
        b.withUnsafeBufferPointer { bp in
            c.withUnsafeMutableBufferPointer { cp in
                cblas_sgemm(
                    CblasRowMajor,
                    transA ? CblasTrans : CblasNoTrans,
                    transB ? CblasTrans : CblasNoTrans,
                    Int32(m), Int32(n), Int32(k), alpha,
                    ap.baseAddress, Int32(lda),
                    bp.baseAddress, Int32(ldb),
                    beta, cp.baseAddress, Int32(ldc)
                )
            }
        }
    }
}

@inline(__always)
nonisolated private func tanhInPlace(_ source: [Float], into destination: inout [Float], count: Int) {
    guard count > 0 else { return }
    var elements = Int32(count)
    source.withUnsafeBufferPointer { src in
        destination.withUnsafeMutableBufferPointer { dst in
            vvtanhf(dst.baseAddress!, src.baseAddress!, &elements)
        }
    }
}

@inline(__always)
nonisolated private func identityFloat(_ size: Int) -> [Float] {
    var result = [Float](repeating: 0, count: size * size)
    for index in 0..<size {
        result[index * size + index] = 1
    }
    return result
}

@inline(__always)
nonisolated private func flatToNested(_ values: [Float], rows: Int, columns: Int) -> [[Double]] {
    (0..<rows).map { row in
        let base = row * columns
        return (0..<columns).map { Double(values[base + $0]) }
    }
}

// Symmetric decorrelation: W <- (W Wᵀ)^(-1/2) W, used by FastICA.
nonisolated private func symmetricDecorrelate(_ weights: inout [Float], features: Int) {
    var gram = [Float](repeating: 0, count: features * features)
    blasSGEMM(transA: false, transB: true,
              m: features, n: features, k: features,
              alpha: 1, weights, lda: features, weights, ldb: features,
              beta: 0, &gram, ldc: features)

    let gramDouble = (0..<features).map { row in
        (0..<features).map { Double(gram[row * features + $0]) }
    }
    let eigen = symmetricEigenDecomposition(gramDouble)
    guard eigen.values.count == features, eigen.vectors.count == features else { return }

    // P = E diag(1/sqrt(λ)) Eᵀ
    var projection = [Float](repeating: 0, count: features * features)
    for i in 0..<features {
        for j in 0..<features {
            var sum = 0.0
            for k in 0..<features {
                let scale = 1.0 / sqrt(max(eigen.values[k], 1e-12))
                sum += eigen.vectors[i][k] * scale * eigen.vectors[j][k]
            }
            projection[i * features + j] = Float(sum)
        }
    }

    var result = [Float](repeating: 0, count: features * features)
    blasSGEMM(transA: false, transB: false,
              m: features, n: features, k: features,
              alpha: 1, projection, lda: features, weights, ldb: features,
              beta: 0, &result, ldc: features)
    weights = result
}

// log|det(M)| via Gaussian elimination with partial pivoting. Returns nil if singular.
nonisolated private func logAbsDeterminant(_ matrix: [Float], features: Int) -> Double? {
    var a = (0..<features).map { row in
        (0..<features).map { Double(matrix[row * features + $0]) }
    }
    var logDet = 0.0
    for column in 0..<features {
        var pivot = column
        var pivotValue = abs(a[column][column])
        for row in (column + 1)..<features where abs(a[row][column]) > pivotValue {
            pivot = row
            pivotValue = abs(a[row][column])
        }
        if pivotValue < 1e-18 { return nil }
        if pivot != column { a.swapAt(pivot, column) }
        let diagonal = a[column][column]
        logDet += log(abs(diagonal))
        for row in (column + 1)..<features {
            let factor = a[row][column] / diagonal
            if factor == 0 { continue }
            for c in column..<features {
                a[row][c] -= factor * a[column][c]
            }
        }
    }
    return logDet
}

// MARK: - Extended Infomax (flat Float port of the previous implementation)

nonisolated private func infomaxFloat(
    _ data: [Float], features: Int, samples: Int,
    maxIterations: Int, learningRate: Double?,
    convergenceTolerance: Double, minimumIterations: Int,
    progress: (@Sendable (Double) -> Void)? = nil
) -> (unmixing: [[Double]], iterations: Int, finalChange: Double) {
    var weights = identityFloat(features)
    let startWeights = weights
    var oldWeights = weights
    var rate = Float(learningRate ?? 0.01 / log(Double(max(features * features, 2))))
    let block = max(Int(floor(sqrt(Double(max(samples, 1)) / 3.0))), 16)
    let blockEnd = max((samples / block) * block, 0)

    guard samples > block, features > 0 else {
        progress?(1.0)
        return (flatToNested(weights, rows: features, columns: features), 0, 0)
    }

    // Reused scratch buffers.
    var blockData = [Float](repeating: 0, count: features * block)
    var u = [Float](repeating: 0, count: features * block)
    var y = [Float](repeating: 0, count: features * block)
    var signedY = [Float](repeating: 0, count: features * block)
    var uyT = [Float](repeating: 0, count: features * features)
    var uuT = [Float](repeating: 0, count: features * features)
    var gradient = [Float](repeating: 0, count: features * features)
    var delta = [Float](repeating: 0, count: features * features)
    var candidate = [Float](repeating: 0, count: features * features)
    var bias = [Float](repeating: 0, count: features)

    var signs = [Float](repeating: 1, count: features)
    if features > 0 { signs[0] = -1 }
    var oldKurtosis = [Double](repeating: 0, count: features)
    var oldSigns = [Double](repeating: 0, count: features)
    var signCount = 0

    let signSampleStride = max(samples / 6_000, 1)
    let signSampleIndices = stride(from: 0, to: samples, by: signSampleStride).map { $0 }
    let signUpdateEveryBlocks = max((samples / max(block, 1)) / 20, 1)

    var oldDelta = [Double](repeating: 0, count: features * features)
    var oldChange = 0.0
    var countSmallAngle = 0
    var blockNumber = 0
    var iterations = 0
    var finalChange = Double.infinity

    let maxWeight: Float = 1e8
    let minRate: Float = 1e-10
    let annealDegrees = 60.0
    let annealStep: Float = 0.9
    let blowup = 1e4
    let blowupFactor: Float = 0.5
    let restartFactor: Float = 0.9
    let degreesPerRadian = 180.0 / Double.pi

    while iterations < maxIterations {
        var order = Array(0..<samples)
        deterministicShuffle(&order, seed: iterations + 1)
        var weightsBlewUp = false

        for start in stride(from: 0, to: blockEnd, by: block) {
            // Gather the shuffled block columns.
            for feature in 0..<features {
                let src = feature * samples
                let dst = feature * block
                for sample in 0..<block {
                    blockData[dst + sample] = data[src + order[start + sample]]
                }
            }

            // u = weights · blockData  (features × block)
            blasSGEMM(transA: false, transB: false,
                      m: features, n: block, k: features,
                      alpha: 1, weights, lda: features, blockData, ldb: block,
                      beta: 0, &u, ldc: block)
            for feature in 0..<features {
                let base = feature * block
                let b = bias[feature]
                for sample in 0..<block { u[base + sample] += b }
            }

            tanhInPlace(u, into: &y, count: features * block)

            for feature in 0..<features {
                let base = feature * block
                let s = signs[feature]
                for sample in 0..<block { signedY[base + sample] = y[base + sample] * s }
            }

            // uyT = u · signedYᵀ ; uuT = u · uᵀ  (features × features)
            blasSGEMM(transA: false, transB: true,
                      m: features, n: features, k: block,
                      alpha: 1, u, lda: block, signedY, ldb: block,
                      beta: 0, &uyT, ldc: features)
            blasSGEMM(transA: false, transB: true,
                      m: features, n: features, k: block,
                      alpha: 1, u, lda: block, u, ldb: block,
                      beta: 0, &uuT, ldc: features)

            let blockFloat = Float(block)
            for i in 0..<features {
                for j in 0..<features {
                    let idx = i * features + j
                    gradient[idx] = (i == j ? blockFloat : 0) - uyT[idx] - uuT[idx]
                }
            }

            // delta = gradientᵀ · weights
            blasSGEMM(transA: true, transB: false,
                      m: features, n: features, k: features,
                      alpha: 1, gradient, lda: features, weights, ldb: features,
                      beta: 0, &delta, ldc: features)

            var maxAbs: Float = 0
            var finite = true
            for index in 0..<(features * features) {
                let value = weights[index] + rate * delta[index]
                candidate[index] = value
                if !value.isFinite { finite = false; break }
                let magnitude = abs(value)
                if magnitude > maxAbs { maxAbs = magnitude }
            }

            if !finite || maxAbs > maxWeight {
                weightsBlewUp = true
                break
            }

            swap(&weights, &candidate)

            for feature in 0..<features {
                let base = feature * block
                var sum: Float = 0
                for sample in 0..<block { sum += y[base + sample] }
                bias[feature] += rate * -2 * sum
            }

            blockNumber += 1
            if blockNumber % signUpdateEveryBlocks == 0 {
                updateInfomaxSigns(
                    weights: weights, data: data, features: features, samples: samples,
                    indices: signSampleIndices, oldKurtosis: &oldKurtosis,
                    oldSigns: &oldSigns, signCount: &signCount, signs: &signs
                )
            }
        }

        if weightsBlewUp {
            iterations = 0
            blockNumber = 1
            rate *= restartFactor
            weights = startWeights
            oldWeights = startWeights
            for index in oldDelta.indices { oldDelta[index] = 0 }
            oldChange = 0
            for index in bias.indices { bias[index] = 0 }
            for index in oldKurtosis.indices { oldKurtosis[index] = 0 }
            for index in oldSigns.indices { oldSigns[index] = 0 }
            signCount = 0
            for index in signs.indices { signs[index] = 1 }
            if features > 0 { signs[0] = -1 }
            if rate <= minRate { break }
            continue
        }

        var change = 0.0
        var weightDelta = [Double](repeating: 0, count: features * features)
        for index in 0..<(features * features) {
            let d = Double(weights[index] - oldWeights[index])
            weightDelta[index] = d
            change += d * d
        }
        finalChange = change
        iterations += 1

        var angleDelta = 0.0
        if iterations > 2, change > 0, oldChange > 0 {
            var dot = 0.0
            for index in 0..<(features * features) { dot += weightDelta[index] * oldDelta[index] }
            let denominator = sqrt(change * oldChange)
            if denominator > 0 {
                let cosine = min(max(dot / denominator, -1.0), 1.0)
                angleDelta = acos(cosine) * degreesPerRadian
            }
        }

        oldWeights = weights
        if angleDelta > annealDegrees {
            rate *= annealStep
            oldDelta = weightDelta
            oldChange = change
            countSmallAngle = 0
        } else {
            if iterations == 1 {
                oldDelta = weightDelta
                oldChange = change
            }
            countSmallAngle += 1
            if iterations >= minimumIterations, countSmallAngle > 20 {
                progress?(Double(iterations) / Double(maxIterations))
                break
            }
        }

        progress?(Double(iterations) / Double(maxIterations))
        if iterations >= minimumIterations, iterations > 2, change < convergenceTolerance {
            break
        } else if change > blowup {
            rate *= blowupFactor
        }
    }

    progress?(1.0)
    return (flatToNested(weights, rows: features, columns: features), iterations, finalChange)
}

nonisolated private func updateInfomaxSigns(
    weights: [Float], data: [Float], features: Int, samples: Int,
    indices: [Int], oldKurtosis: inout [Double], oldSigns: inout [Double],
    signCount: inout Int, signs: inout [Float]
) {
    let count = indices.count
    guard count > 0 else { return }
    var changed = false

    for component in 0..<features {
        let wBase = component * features
        var second = 0.0
        var fourth = 0.0
        var mean = 0.0
        // First pass: source samples and mean.
        var source = [Double](repeating: 0, count: count)
        for s in 0..<count {
            let column = indices[s]
            var value = 0.0
            for k in 0..<features {
                value += Double(weights[wBase + k]) * Double(data[k * samples + column])
            }
            source[s] = value
            mean += value
        }
        mean /= Double(count)
        for value in source {
            let d = value - mean
            let d2 = d * d
            second += d2
            fourth += d2 * d2
        }
        second /= Double(count)
        fourth /= Double(count)
        let excess = second > 0 ? fourth / (second * second) - 3 : 0
        let smoothed = 0.5 * oldKurtosis[component] + 0.5 * excess
        oldKurtosis[component] = smoothed
        let sign: Double = (smoothed + 0.02 > 0) ? 1 : (smoothed + 0.02 < 0 ? -1 : 0)
        signs[component] = Float(sign)
        if sign != oldSigns[component] { changed = true }
    }

    signCount = changed ? 0 : signCount + 1
    oldSigns = signs.map { Double($0) }
}

// MARK: - FastICA (symmetric, logcosh nonlinearity)

nonisolated private func fastICAFloat(
    _ data: [Float], features: Int, samples: Int,
    maxIterations: Int, convergenceTolerance: Double, minimumIterations: Int,
    progress: (@Sendable (Double) -> Void)? = nil
) -> (unmixing: [[Double]], iterations: Int, finalChange: Double) {
    guard features > 0, samples > 1 else {
        progress?(1.0)
        return (identity(features), 0, 0)
    }

    // Deterministic pseudo-random orthonormal start.
    var weights = [Float](repeating: 0, count: features * features)
    var state = UInt64(0x9E3779B97F4A7C15)
    for index in 0..<(features * features) {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        weights[index] = Float(unit * 2 - 1)
    }
    symmetricDecorrelate(&weights, features: features)

    var u = [Float](repeating: 0, count: features * samples)
    var gU = [Float](repeating: 0, count: features * samples)
    var newWeights = [Float](repeating: 0, count: features * features)
    var gpMean = [Float](repeating: 0, count: features)

    let tolerance = max(convergenceTolerance, 1e-7)
    let invSamples = 1.0 / Float(samples)
    var iterations = 0
    var finalChange = Double.infinity

    while iterations < maxIterations {
        // u = W · X
        blasSGEMM(transA: false, transB: false,
                  m: features, n: samples, k: features,
                  alpha: 1, weights, lda: features, data, ldb: samples,
                  beta: 0, &u, ldc: samples)

        // gU = tanh(u) ; gp = 1 - tanh(u)^2 averaged per row
        tanhInPlace(u, into: &gU, count: features * samples)
        for feature in 0..<features {
            let base = feature * samples
            var sum: Float = 0
            for sample in 0..<samples {
                let g = gU[base + sample]
                sum += 1 - g * g
            }
            gpMean[feature] = sum * invSamples
        }

        // newW = (1/T) gU · Xᵀ - diag(gpMean) · W
        blasSGEMM(transA: false, transB: true,
                  m: features, n: features, k: samples,
                  alpha: invSamples, gU, lda: samples, data, ldb: samples,
                  beta: 0, &newWeights, ldc: features)
        for i in 0..<features {
            let g = gpMean[i]
            for j in 0..<features {
                newWeights[i * features + j] -= g * weights[i * features + j]
            }
        }

        symmetricDecorrelate(&newWeights, features: features)

        // Convergence: max_i | |row_i · oldRow_i| - 1 |
        var maxChange: Double = 0
        for i in 0..<features {
            var dot: Double = 0
            for j in 0..<features {
                dot += Double(newWeights[i * features + j]) * Double(weights[i * features + j])
            }
            maxChange = max(maxChange, abs(abs(dot) - 1))
        }
        finalChange = maxChange

        weights = newWeights
        iterations += 1
        progress?(Double(iterations) / Double(maxIterations))

        if iterations >= max(minimumIterations, 1), maxChange < tolerance { break }
    }

    progress?(1.0)
    return (flatToNested(weights, rows: features, columns: features), iterations, finalChange)
}

// MARK: - Picard (preconditioned ICA with L-BFGS)
//
// Maximises the likelihood for a tanh (super-Gaussian) density on the whitened
// signals, using the relative gradient preconditioned by a diagonal Hessian
// approximation and an L-BFGS memory, with a backtracking line search.

nonisolated private func picardFloat(
    _ data: [Float], features: Int, samples: Int,
    maxIterations: Int, convergenceTolerance: Double, minimumIterations: Int,
    progress: (@Sendable (Double) -> Void)? = nil
) -> (unmixing: [[Double]], iterations: Int, finalChange: Double) {
    guard features > 0, samples > 1 else {
        progress?(1.0)
        return (identity(features), 0, 0)
    }

    let n = features
    let nn = n * n
    var weights = identityFloat(n)
    var signals = data            // Y = W · X, starts at X since W = I
    let invSamples = 1.0 / Double(samples)
    let tolerance = max(convergenceTolerance, 1e-7)
    let memorySize = 7

    var psiY = [Float](repeating: 0, count: n * samples)
    var gradient = [Float](repeating: 0, count: nn)
    var hessian = [Double](repeating: 0, count: nn)   // h[i,j]
    var direction = [Float](repeating: 0, count: nn)
    var candidate = [Float](repeating: 0, count: nn)   // I + alpha·direction
    var newSignals = [Float](repeating: 0, count: n * samples)

    var sMemory: [[Float]] = []
    var yMemory: [[Float]] = []
    var rhoMemory: [Double] = []

    var iterations = 0
    var finalChange = Double.infinity

    func computeGradientAndHessian() {
        tanhInPlace(signals, into: &psiY, count: n * samples)
        // G = (1/T) psiY · Yᵀ - I
        blasSGEMM(transA: false, transB: true,
                  m: n, n: n, k: samples,
                  alpha: Float(invSamples), psiY, lda: samples, signals, ldb: samples,
                  beta: 0, &gradient, ldc: n)
        for i in 0..<n { gradient[i * n + i] -= 1 }

        // a[i] = mean_t psi'(y_i) = mean_t (1 - tanh(y_i)^2)
        // sigma2[j] = mean_t y_j^2 ; h[i,j] = a[i]·sigma2[j]
        var a = [Double](repeating: 0, count: n)
        var sigma2 = [Double](repeating: 0, count: n)
        for feature in 0..<n {
            let base = feature * samples
            var aSum = 0.0
            var vSum = 0.0
            for sample in 0..<samples {
                let g = Double(psiY[base + sample])
                aSum += 1 - g * g
                let v = Double(signals[base + sample])
                vSum += v * v
            }
            a[feature] = aSum * invSamples
            sigma2[feature] = vSum * invSamples
        }
        for i in 0..<n {
            for j in 0..<n {
                hessian[i * n + j] = a[i] * sigma2[j]
            }
        }

        // Regularize the 2×2 relative-Hessian blocks to be positive definite.
        // For super-Gaussian sources h_ij < 1, so the raw blocks are indefinite
        // (det = h_ij·h_ji − 1 < 0). Shifting the smallest block eigenvalue up to
        // lambdaMin keeps the preconditioned direction a genuine descent step.
        let lambdaMin = 1e-2
        for i in 0..<n {
            for j in 0..<n {
                let hij = hessian[i * n + j]
                let hji = hessian[j * n + i]
                let mean = 0.5 * (hij + hji)
                let half = 0.5 * (hij - hji)
                let smallestEigenvalue = mean - sqrt(half * half + 1)
                if smallestEigenvalue < lambdaMin {
                    hessian[i * n + j] += lambdaMin - smallestEigenvalue
                }
            }
        }
    }

    // z = H^{-1} G via the 2×2 block structure of the relative Hessian.
    func solveHessian(_ g: [Float], into z: inout [Float]) {
        for i in 0..<n {
            for j in 0..<n {
                let hij = hessian[i * n + j]
                let hji = hessian[j * n + i]
                let det = hij * hji - 1
                let gij = Double(g[i * n + j])
                let gji = Double(g[j * n + i])
                if det < 1e-6 {
                    z[i * n + j] = Float(gij)        // fall back to scaled gradient
                } else {
                    z[i * n + j] = Float((gij * hji - gji) / det)
                }
            }
        }
    }

    // Data term of the likelihood loss: sum over components of the per-sample
    // mean log cosh, i.e. the total divided by the sample count (NOT by n·T).
    // This is what makes the loss consistent with the (1/T)·ψ(Y)Yᵀ − I gradient.
    func dataLoss(_ buffer: [Float], elementCount: Int) -> Double {
        var total = 0.0
        for index in 0..<elementCount {
            let value = Double(abs(buffer[index]))
            total += value + log1p(exp(-2 * value))   // log cosh, dropping the constant log 2
        }
        return total / Double(samples)
    }

    func dot(_ a: [Float], _ b: [Float]) -> Double {
        var total = 0.0
        for index in 0..<a.count { total += Double(a[index]) * Double(b[index]) }
        return total
    }

    computeGradientAndHessian()

    while iterations < maxIterations {
        // L-BFGS two-loop recursion to build the search direction.
        var q = gradient
        let m = sMemory.count
        var alphas = [Double](repeating: 0, count: m)
        for idx in stride(from: m - 1, through: 0, by: -1) {
            let a = rhoMemory[idx] * dot(sMemory[idx], q)
            alphas[idx] = a
            let yMem = yMemory[idx]
            for index in 0..<nn { q[index] -= Float(a) * yMem[index] }
        }
        var z = [Float](repeating: 0, count: nn)
        solveHessian(q, into: &z)
        for idx in 0..<m {
            let beta = rhoMemory[idx] * dot(yMemory[idx], z)
            let sMem = sMemory[idx]
            let coefficient = Float(alphas[idx] - beta)
            for index in 0..<nn { z[index] += coefficient * sMem[index] }
        }
        for index in 0..<nn { direction[index] = -z[index] }

        // The L-BFGS history can produce a non-descent direction; fall back to
        // the preconditioned gradient (and drop the stale memory) if so.
        var slope = 0.0
        for index in 0..<nn { slope += Double(gradient[index]) * Double(direction[index]) }
        if slope > 0 {
            sMemory.removeAll(); yMemory.removeAll(); rhoMemory.removeAll()
            solveHessian(gradient, into: &z)
            slope = 0
            for index in 0..<nn {
                direction[index] = -z[index]
                slope += Double(gradient[index]) * Double(direction[index])
            }
        }

        // Backtracking line search with an Armijo sufficient-decrease condition.
        let currentLoss = dataLoss(signals, elementCount: n * samples)
        let armijoConstant = 1e-4
        var alpha: Float = 1
        var accepted = false
        for _ in 0..<15 {
            for i in 0..<n {
                for j in 0..<n {
                    candidate[i * n + j] = (i == j ? 1 : 0) + alpha * direction[i * n + j]
                }
            }
            guard let logDet = logAbsDeterminant(candidate, features: n) else {
                alpha *= 0.5
                continue
            }
            // newSignals = candidate · signals
            blasSGEMM(transA: false, transB: false,
                      m: n, n: samples, k: n,
                      alpha: 1, candidate, lda: n, signals, ldb: samples,
                      beta: 0, &newSignals, ldc: samples)
            let newLoss = dataLoss(newSignals, elementCount: n * samples)
            let deltaLoss = (newLoss - currentLoss) - logDet
            if deltaLoss <= armijoConstant * Double(alpha) * slope {
                accepted = true
                break
            }
            alpha *= 0.5
        }

        if !accepted {
            // A failed search with stale memory: reset and retry from the
            // preconditioned gradient before giving up.
            if !sMemory.isEmpty {
                sMemory.removeAll(); yMemory.removeAll(); rhoMemory.removeAll()
                continue
            }
            finalChange = 0
            break
        }

        // Apply the accepted step: W <- candidate · W, Y <- candidate · Y.
        var updatedWeights = [Float](repeating: 0, count: nn)
        blasSGEMM(transA: false, transB: false,
                  m: n, n: n, k: n,
                  alpha: 1, candidate, lda: n, weights, ldb: n,
                  beta: 0, &updatedWeights, ldc: n)
        weights = updatedWeights
        signals = newSignals

        let previousGradient = gradient
        computeGradientAndHessian()

        // Store the L-BFGS pair (s = α·direction, y = ΔG).
        var sVector = [Float](repeating: 0, count: nn)
        var yVector = [Float](repeating: 0, count: nn)
        for index in 0..<nn {
            sVector[index] = alpha * direction[index]
            yVector[index] = gradient[index] - previousGradient[index]
        }
        let curvature = dot(sVector, yVector)
        if curvature > 1e-10 {
            sMemory.append(sVector)
            yMemory.append(yVector)
            rhoMemory.append(1 / curvature)
            if sMemory.count > memorySize {
                sMemory.removeFirst()
                yMemory.removeFirst()
                rhoMemory.removeFirst()
            }
        }

        // Gradient norm as the stopping criterion.
        var gradNorm = 0.0
        for index in 0..<nn { gradNorm += Double(gradient[index]) * Double(gradient[index]) }
        gradNorm = sqrt(gradNorm / Double(nn))
        finalChange = gradNorm

        iterations += 1
        progress?(Double(iterations) / Double(maxIterations))
        if iterations >= max(minimumIterations, 1), gradNorm < tolerance { break }
    }

    progress?(1.0)
    return (flatToNested(weights, rows: n, columns: n), iterations, finalChange)
}

nonisolated private func deterministicShuffle(_ values: inout [Int], seed: Int) {
    var state = UInt64(seed) &* 6364136223846793005 &+ 1
    guard values.count > 1 else { return }
    for index in stride(from: values.count - 1, through: 1, by: -1) {
        state = state &* 2862933555777941757 &+ 3037000493
        let swapIndex = Int(state % UInt64(index + 1))
        values.swapAt(index, swapIndex)
    }
}


nonisolated private func variance(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    var total = 0.0
    for value in values {
        let delta = value - mean
        total += delta * delta
    }
    return total / Double(max(values.count - 1, 1))
}

nonisolated func normalizedTopography(_ values: [Double]) -> [Double] {
    guard !values.isEmpty else { return [] }
    let finiteValues = values.map { $0.isFinite ? $0 : 0 }
    let mean = finiteValues.reduce(0, +) / Double(finiteValues.count)
    let centered = finiteValues.map { $0 - mean }
    let scale = centered.map(abs).max() ?? 0
    guard scale.isFinite, scale > 1e-12 else {
        return Array(repeating: 0, count: values.count)
    }
    return centered.map { $0 / scale }
}

nonisolated private func symmetricEigenDecomposition(_ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
    let n = matrix.count
    guard n > 0, matrix.allSatisfy({ $0.count == n }) else {
        return ([], [])
    }

    var columnMajor = Array(repeating: 0.0, count: n * n)
    for row in 0..<n {
        for column in 0..<n {
            columnMajor[column * n + row] = matrix[row][column]
        }
    }

    var eigenvalues = Array(repeating: 0.0, count: n)
    var jobz = Int8(UnicodeScalar("V").value)
    var uplo = Int8(UnicodeScalar("U").value)
    var dimension = __CLPK_integer(n)
    var leadingDimension = __CLPK_integer(n)
    var queryWork = 0.0
    var querySize = __CLPK_integer(-1)
    var info = __CLPK_integer(0)

    dsyev_(
        &jobz,
        &uplo,
        &dimension,
        &columnMajor,
        &leadingDimension,
        &eigenvalues,
        &queryWork,
        &querySize,
        &info
    )

    guard info == 0 else {
        return jacobiEigenDecomposition(matrix)
    }

    var workSize = __CLPK_integer(max(Int(queryWork.rounded(.up)), 3 * n - 1))
    var work = Array(repeating: 0.0, count: Int(workSize))
    info = 0

    dsyev_(
        &jobz,
        &uplo,
        &dimension,
        &columnMajor,
        &leadingDimension,
        &eigenvalues,
        &work,
        &workSize,
        &info
    )

    guard info == 0 else {
        return jacobiEigenDecomposition(matrix)
    }

    let eigenvectors = (0..<n).map { row in
        (0..<n).map { column in
            columnMajor[column * n + row]
        }
    }
    return (eigenvalues, eigenvectors)
}

nonisolated private func jacobiEigenDecomposition(_ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
    let n = matrix.count
    var a = matrix
    var v = identity(n)
    let maxIterations = max(100, n * n * 8)

    for _ in 0..<maxIterations {
        var p = 0
        var q = 1
        var maxValue = 0.0
        for i in 0..<n {
            for j in (i + 1)..<n {
                let value = abs(a[i][j])
                if value > maxValue {
                    maxValue = value
                    p = i
                    q = j
                }
            }
        }
        if maxValue < 1e-10 { break }

        let theta = 0.5 * atan2(2 * a[p][q], a[q][q] - a[p][p])
        let c = cos(theta)
        let s = sin(theta)
        let app = c * c * a[p][p] - 2 * s * c * a[p][q] + s * s * a[q][q]
        let aqq = s * s * a[p][p] + 2 * s * c * a[p][q] + c * c * a[q][q]

        for i in 0..<n where i != p && i != q {
            let aip = a[i][p]
            let aiq = a[i][q]
            a[i][p] = c * aip - s * aiq
            a[p][i] = a[i][p]
            a[i][q] = s * aip + c * aiq
            a[q][i] = a[i][q]
        }
        a[p][p] = app
        a[q][q] = aqq
        a[p][q] = 0
        a[q][p] = 0

        for i in 0..<n {
            let vip = v[i][p]
            let viq = v[i][q]
            v[i][p] = c * vip - s * viq
            v[i][q] = s * vip + c * viq
        }
    }

    return ((0..<n).map { a[$0][$0] }, v)
}

nonisolated private func identity(_ size: Int) -> [[Double]] {
    (0..<size).map { row in
        (0..<size).map { row == $0 ? 1.0 : 0.0 }
    }
}

nonisolated private func transpose(_ matrix: [[Double]]) -> [[Double]] {
    guard let columns = matrix.first?.count else { return [] }
    return (0..<columns).map { column in
        matrix.map { $0[column] }
    }
}

nonisolated private func multiply(_ lhs: [[Double]], _ rhs: [[Double]]) -> [[Double]] {
    guard let lhsColumns = lhs.first?.count,
          lhsColumns == rhs.count,
          let rhsColumns = rhs.first?.count else {
        return []
    }

    let lhsRows = lhs.count
    let lhsValues = flatten(lhs)
    let rhsValues = flatten(rhs)
    var result = Array(repeating: 0.0, count: lhsRows * rhsColumns)

    cblas_dgemm(
        CblasRowMajor,
        CblasNoTrans,
        CblasNoTrans,
        Int32(lhsRows),
        Int32(rhsColumns),
        Int32(lhsColumns),
        1.0,
        lhsValues,
        Int32(lhsColumns),
        rhsValues,
        Int32(rhsColumns),
        0.0,
        &result,
        Int32(rhsColumns)
    )

    return unflatten(result, rows: lhsRows, columns: rhsColumns)
}

nonisolated private func flatten(_ matrix: [[Double]]) -> [Double] {
    guard let columns = matrix.first?.count else { return [] }
    var values: [Double] = []
    values.reserveCapacity(matrix.count * columns)
    for row in matrix {
        values.append(contentsOf: row)
    }
    return values
}

nonisolated private func unflatten(_ values: [Double], rows: Int, columns: Int) -> [[Double]] {
    guard rows > 0, columns > 0 else { return [] }
    return (0..<rows).map { row in
        let start = row * columns
        return Array(values[start..<(start + columns)])
    }
}

nonisolated private func pseudoInverse(_ matrix: [[Double]], relativeTolerance: Double = 1e-12) -> [[Double]] {
    guard let columns = matrix.first?.count,
          !matrix.isEmpty,
          columns > 0,
          matrix.allSatisfy({ $0.count == columns }) else {
        return []
    }

    let matrixT = transpose(matrix)
    let gram = multiply(matrixT, matrix)
    let eigen = symmetricEigenDecomposition(gram)
    guard eigen.values.count == columns, eigen.vectors.count == columns else {
        return inverse(matrix)
    }

    let maxEigenvalue = max(eigen.values.map(abs).max() ?? 0, 1e-18)
    let tolerance = maxEigenvalue * relativeTolerance
    var gramPseudoInverse = Array(repeating: Array(repeating: 0.0, count: columns), count: columns)

    for component in 0..<columns {
        let eigenvalue = eigen.values[component]
        guard eigenvalue.isFinite, eigenvalue > tolerance else { continue }
        let inverseEigenvalue = 1.0 / eigenvalue
        for row in 0..<columns {
            let rowValue = eigen.vectors[row][component]
            for column in 0..<columns {
                gramPseudoInverse[row][column] += rowValue * inverseEigenvalue * eigen.vectors[column][component]
            }
        }
    }

    return multiply(gramPseudoInverse, matrixT)
}

nonisolated private func inverse(_ matrix: [[Double]]) -> [[Double]] {
    let n = matrix.count
    var a = matrix
    var inv = identity(n)

    for i in 0..<n {
        var pivot = i
        var pivotValue = abs(a[i][i])
        for row in (i + 1)..<n where abs(a[row][i]) > pivotValue {
            pivot = row
            pivotValue = abs(a[row][i])
        }
        if pivot != i {
            a.swapAt(i, pivot)
            inv.swapAt(i, pivot)
        }
        let divisor = abs(a[i][i]) > 1e-12 ? a[i][i] : 1e-12
        for column in 0..<n {
            a[i][column] /= divisor
            inv[i][column] /= divisor
        }
        for row in 0..<n where row != i {
            let factor = a[row][i]
            for column in 0..<n {
                a[row][column] -= factor * a[i][column]
                inv[row][column] -= factor * inv[i][column]
            }
        }
    }

    return inv
}
