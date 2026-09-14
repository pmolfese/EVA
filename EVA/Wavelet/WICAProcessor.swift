//
//  WICAProcessor.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Wavelet-enhanced ICA (W-ICA): estimate full-rate ICA activations, wavelet-
//  threshold selected component time series, then reconstruct by subtracting
//  the back-projected wavelet artifact residual. With a full-rank ICA this is
//  algebraically identical to back-projecting every cleaned component; with a
//  rank-reduced ICA it additionally preserves the unmodelled PCA residual.
//  This preserves neural activity that shares an ICA
//  component with an artifact instead of rejecting the whole component.
//
//  The implementation is independent and follows the method-level description
//  in Castellanos & Makarov (2006), J Neurosci Methods 158:300-312.
//  `WaveletReducer` remains the single wavelet implementation and supplies both
//  bounded CPU parallelism and the optional Metal backend.
//

import Accelerate
import Foundation

nonisolated struct WICAConfiguration: Sendable {
    var wavelet: WaveletReductionConfiguration
    var coreCount: Int = WaveletReducer.defaultCoreCount
    /// Bounds peak component-space memory on high-density, long recordings.
    var componentBatchSize: Int = 16
}

nonisolated struct WICAComponentMetrics: Sendable {
    var componentIndex: Int
    var varianceRetainedPercent: Double
    var correlation: Double
    var removedRMS: Double
}

nonisolated struct WICAResult: Sendable {
    var cleaned: MFFSignalData
    var artifact: MFFSignalData
    var processedComponents: [Int]
    var perComponent: [Int: WICAComponentMetrics]
    /// Display-rate copies of the wavelet-cleaned activations. Keeping these at
    /// the ICA analysis rate makes before/after review cheap without retaining a
    /// second full-rate matrix for every component in a long recording.
    var cleanedComponentPreviews: [Int: [Double]]
    var componentPreviewSamplingRate: Double
    var varianceRetainedPercent: Double
}

nonisolated enum WICAError: LocalizedError {
    case emptySelection
    case incompatibleDecomposition
    case incompatibleActivationSignal

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select at least one ICA component for W-ICA."
        case .incompatibleDecomposition:
            return "The ICA decomposition does not match this signal's channels."
        case .incompatibleActivationSignal:
            return "The ICA activation copy does not match this signal's shape."
        }
    }
}

nonisolated enum WICAProcessor {
    /// Applies W-ICA to `componentIndices`. Pass every component for classic
    /// W-ICA, or an ICLabel/manual subset for selective W-ICA.
    ///
    /// Reconstruction uses x_clean = x - A_selected(s - s_clean). `s - s_clean`
    /// is removed wavelet activity, not a set of rejected components.
    ///
    /// `activationSignal` mirrors ICA removal: when ICA was fitted on a filtered
    /// copy, pass the equivalently filtered full-rate copy here. The removed
    /// component activity is always subtracted from `signal`, so the fit filter
    /// itself never becomes an unrecorded processing step.
    static func reduce(
        signal: MFFSignalData,
        activationSignal: MFFSignalData? = nil,
        decomposition: ICADecomposition,
        componentIndices: Set<Int>,
        configuration: WICAConfiguration,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> WICAResult {
        guard let sampleCount = signal.data.first?.count,
              sampleCount > 0,
              signal.numberOfChannels == decomposition.channelCount,
              decomposition.unmixingMatrix.count >= decomposition.componentCount,
              decomposition.mixingMatrix.count >= signal.numberOfChannels else {
            throw WICAError.incompatibleDecomposition
        }
        let activation = activationSignal?.data ?? signal.data
        guard activation.count == signal.numberOfChannels,
              activation.allSatisfy({ $0.count == sampleCount }) else {
            throw WICAError.incompatibleActivationSignal
        }

        let components = componentIndices
            .filter { $0 >= 0 && $0 < decomposition.componentCount }
            .sorted()
        guard !components.isEmpty else { throw WICAError.emptySelection }

        let channelCount = signal.numberOfChannels
        guard decomposition.unmixingMatrix.prefix(decomposition.componentCount)
                .allSatisfy({ $0.count >= channelCount }),
              decomposition.mixingMatrix.prefix(channelCount)
                .allSatisfy({ $0.count >= decomposition.componentCount }) else {
            throw WICAError.incompatibleDecomposition
        }

        let means = activationMeans(
            activation,
            channelCount: channelCount,
            averageReference: decomposition.averageReference
        )
        var cleanedData = signal.data
        var artifactData = signal.data.map { [Float](repeating: 0, count: $0.count) }
        var componentMetrics: [Int: WICAComponentMetrics] = [:]
        var cleanedComponentPreviews: [Int: [Double]] = [:]
        let batchSize = min(max(configuration.componentBatchSize, 1), components.count)
        let batches = stride(from: 0, to: components.count, by: batchSize).map {
            Array(components[$0..<min($0 + batchSize, components.count)])
        }

        for (batchNumber, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let sources = fullRateSources(
                activation: activation,
                means: means,
                averageReference: decomposition.averageReference,
                unmixing: decomposition.unmixingMatrix,
                components: batch,
                sampleCount: sampleCount
            )
            let componentSignal = MFFSignalData(
                signalURL: signal.signalURL,
                signalType: "\(signal.signalType) W-ICA Components",
                numberOfChannels: batch.count,
                samplingRate: signal.samplingRate,
                duration: signal.duration,
                recordingStartTime: signal.recordingStartTime,
                events: signal.events,
                data: sources,
                channelNames: batch.map { "IC \($0 + 1)" }
            )
            let baseProgress = Double(batchNumber) / Double(batches.count)
            let span = 1.0 / Double(batches.count)
            let reduced = WaveletReducer.reduce(
                signal: componentSignal,
                channelIndices: Array(batch.indices),
                configuration: configuration.wavelet,
                coreCount: configuration.coreCount
            ) { fraction in
                progress?(baseProgress + span * min(max(fraction, 0), 1) * 0.9)
            }
            try Task.checkCancellation()

            backProject(
                componentArtifact: reduced.artifact.data,
                mixing: decomposition.mixingMatrix,
                components: batch,
                cleaned: &cleanedData,
                artifact: &artifactData,
                sampleCount: sampleCount
            )
            for (localIndex, component) in batch.enumerated() {
                guard let metrics = reduced.perChannel[localIndex] else { continue }
                componentMetrics[component] = WICAComponentMetrics(
                    componentIndex: component,
                    varianceRetainedPercent: metrics.varianceRetainedPercent,
                    correlation: metrics.correlation,
                    removedRMS: metrics.removedRMSMicrovolts
                )
                if reduced.cleaned.data.indices.contains(localIndex) {
                    let cleaned = reduced.cleaned.data[localIndex]
                    let preview = decomposition.decimation > 1
                        ? Downsampler.windowedSincDecimated(cleaned, by: decomposition.decimation)
                        : cleaned
                    cleanedComponentPreviews[component] = preview.map(Double.init)
                }
            }
            progress?(baseProgress + span)
        }

        let originalVariance = totalVariance(signal.data)
        let cleanedVariance = totalVariance(cleanedData)
        let retained = originalVariance > 1e-12 ? cleanedVariance / originalVariance * 100 : 100
        return WICAResult(
            cleaned: signal.replacingSamples(cleanedData, signalTypeSuffix: "W-ICA Cleaned"),
            artifact: signal.replacingSamples(artifactData, signalTypeSuffix: "W-ICA Artifact"),
            processedComponents: components,
            perComponent: componentMetrics,
            cleanedComponentPreviews: cleanedComponentPreviews,
            componentPreviewSamplingRate: decomposition.analysisSamplingRate,
            varianceRetainedPercent: retained
        )
    }

    private static func activationMeans(
        _ data: [[Float]],
        channelCount: Int,
        averageReference: Bool
    ) -> [Float] {
        guard let sampleCount = data.first?.count, sampleCount > 0 else {
            return [Float](repeating: 0, count: channelCount)
        }
        var sums = [Double](repeating: 0, count: channelCount)
        if averageReference {
            for sample in 0..<sampleCount {
                var reference = 0.0
                for channel in 0..<channelCount { reference += Double(data[channel][sample]) }
                reference /= Double(max(channelCount, 1))
                for channel in 0..<channelCount {
                    sums[channel] += Double(data[channel][sample]) - reference
                }
            }
        } else {
            for channel in 0..<channelCount {
                sums[channel] = data[channel].reduce(0.0) { $0 + Double($1) }
            }
        }
        return sums.map { Float($0 / Double(sampleCount)) }
    }

    /// Materializes only one bounded component batch. The time blocking keeps
    /// the centered channel scratch small while SGEMM performs the dense work.
    private static func fullRateSources(
        activation: [[Float]],
        means: [Float],
        averageReference: Bool,
        unmixing: [[Double]],
        components: [Int],
        sampleCount: Int
    ) -> [[Float]] {
        let channelCount = activation.count
        let componentCount = components.count
        var rows = [Float](repeating: 0, count: componentCount * channelCount)
        for (rank, component) in components.enumerated() {
            for channel in 0..<channelCount {
                rows[rank * channelCount + channel] = Float(unmixing[component][channel])
            }
        }
        var sources = components.map { _ in [Float](repeating: 0, count: sampleCount) }
        let blockSize = 32_768
        for start in stride(from: 0, to: sampleCount, by: blockSize) {
            let count = min(blockSize, sampleCount - start)
            var centered = [Float](repeating: 0, count: channelCount * count)
            var reference = [Float](repeating: 0, count: count)
            if averageReference {
                for channel in 0..<channelCount {
                    activation[channel].withUnsafeBufferPointer { buffer in
                        vDSP_vadd(reference, 1, buffer.baseAddress! + start, 1,
                                  &reference, 1, vDSP_Length(count))
                    }
                }
                var inverseCount = 1 / Float(max(channelCount, 1))
                vDSP_vsmul(reference, 1, &inverseCount, &reference, 1, vDSP_Length(count))
            }
            var scratch = [Float](repeating: 0, count: count)
            for channel in 0..<channelCount {
                activation[channel].withUnsafeBufferPointer { buffer in
                    vDSP_vsub(reference, 1, buffer.baseAddress! + start, 1,
                              &scratch, 1, vDSP_Length(count))
                }
                var negativeMean = -means[channel]
                vDSP_vsadd(scratch, 1, &negativeMean,
                           &centered[channel * count], 1, vDSP_Length(count))
            }
            var sourceBlock = [Float](repeating: 0, count: componentCount * count)
            cblas_sgemm(
                CblasRowMajor, CblasNoTrans, CblasNoTrans,
                Int32(componentCount), Int32(count), Int32(channelCount),
                1, rows, Int32(channelCount), centered, Int32(count),
                0, &sourceBlock, Int32(count)
            )
            for component in 0..<componentCount {
                sources[component].replaceSubrange(
                    start..<(start + count),
                    with: sourceBlock[(component * count)..<((component + 1) * count)]
                )
            }
        }
        return sources
    }

    private static func backProject(
        componentArtifact: [[Float]],
        mixing: [[Double]],
        components: [Int],
        cleaned: inout [[Float]],
        artifact: inout [[Float]],
        sampleCount: Int
    ) {
        let channelCount = cleaned.count
        let componentCount = components.count
        var columns = [Float](repeating: 0, count: channelCount * componentCount)
        for channel in 0..<channelCount {
            for (rank, component) in components.enumerated() {
                columns[channel * componentCount + rank] = Float(mixing[channel][component])
            }
        }
        let blockSize = 32_768
        for start in stride(from: 0, to: sampleCount, by: blockSize) {
            let count = min(blockSize, sampleCount - start)
            var componentBlock = [Float](repeating: 0, count: componentCount * count)
            for component in 0..<componentCount {
                componentArtifact[component].withUnsafeBufferPointer { buffer in
                    componentBlock.replaceSubrange(
                        (component * count)..<((component + 1) * count),
                        with: UnsafeBufferPointer(start: buffer.baseAddress! + start, count: count)
                    )
                }
            }
            var sensorBlock = [Float](repeating: 0, count: channelCount * count)
            cblas_sgemm(
                CblasRowMajor, CblasNoTrans, CblasNoTrans,
                Int32(channelCount), Int32(count), Int32(componentCount),
                1, columns, Int32(componentCount), componentBlock, Int32(count),
                0, &sensorBlock, Int32(count)
            )
            for channel in 0..<channelCount {
                for offset in 0..<count {
                    let value = sensorBlock[channel * count + offset]
                    cleaned[channel][start + offset] -= value
                    artifact[channel][start + offset] += value
                }
            }
        }
    }

    private static func totalVariance(_ data: [[Float]]) -> Double {
        data.reduce(0) { total, channel in
            guard !channel.isEmpty else { return total }
            let mean = channel.reduce(0.0) { $0 + Double($1) } / Double(channel.count)
            return total + channel.reduce(0.0) {
                let delta = Double($1) - mean
                return $0 + delta * delta
            } / Double(channel.count)
        }
    }
}
