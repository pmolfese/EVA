//
//  MuscleBSSCCACorrection.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  MAAC-4 muscle-artifact correction. A CCA between multichannel EEG and its
//  one-sample-delayed copy orders latent sources by temporal autocorrelation.
//  Components with a De Vos-style high/low spectral-power ratio are removed.
//  The operator is estimated near 250 Hz, then applied to the native-rate data.
//
//  References:
//  De Clercq et al. (2006), IEEE TBME 53(12), 2583-2587.
//  De Vos et al. (2010), Neuroinformatics 8(2), 135-150.
//

import Accelerate
import Foundation

nonisolated enum MuscleBSSCCARangeMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "Automatic"
    case continuousWindows = "Overlapped continuous windows"
    case epochSegments = "Recorded epoch boundaries"

    var id: String { rawValue }
}

nonisolated struct MuscleBSSCCAComponentOverride: Codable, Sendable, Equatable, Hashable {
    var rangeStartSample: Int
    var componentIndex: Int
    var removes: Bool
}

nonisolated struct MuscleBSSCCAConfiguration: Codable, Sendable, Equatable {
    var rangeMode: MuscleBSSCCARangeMode = .automatic
    var continuousWindowSeconds: Double = 10
    var continuousOverlapFraction: Double = 0.5
    var analysisSamplingRate: Double = 250
    var eegBandLowHz: Double = 1
    var eegBandHighHz: Double = 15
    var emgBandLowHz: Double = 15
    var emgBandHighHz: Double = 30
    var minimumEMGToEEGPowerRatio: Double = 1.0 / 7.0
    var componentOverrides: [MuscleBSSCCAComponentOverride] = []

    static let `default` = MuscleBSSCCAConfiguration()
}

nonisolated struct MuscleBSSCCAComponentDiagnostic: Sendable, Equatable, Identifiable {
    var componentIndex: Int
    var canonicalCorrelation: Double
    var lagOneAutocorrelation: Double
    var emgToEEGPowerRatio: Double
    var automaticallyRemoved: Bool
    var removed: Bool
    var wasOverridden: Bool

    var id: Int { componentIndex }
}

nonisolated struct MuscleBSSCCAWindowDiagnostic: Sendable, Equatable, Identifiable {
    var sampleRange: Range<Int>
    var usableChannelCount: Int
    var analysisSamplingRate: Double
    var components: [MuscleBSSCCAComponentDiagnostic]
    var skippedReason: String?

    var id: Int { sampleRange.lowerBound }
    var removedComponentCount: Int { components.count(where: \.removed) }
}

nonisolated struct MuscleBSSCCADiagnostics: Sendable, Equatable {
    var requestedMode: MuscleBSSCCARangeMode
    var resolvedMode: MuscleBSSCCARangeMode
    var windows: [MuscleBSSCCAWindowDiagnostic]

    var analyzedWindowCount: Int { windows.count(where: { $0.skippedReason == nil }) }
    var skippedWindowCount: Int { windows.count - analyzedWindowCount }
    var removedComponentCount: Int { windows.reduce(0) { $0 + $1.removedComponentCount } }
    var affectedWindowCount: Int { windows.count(where: { $0.removedComponentCount > 0 }) }
}

nonisolated struct MuscleBSSCCACorrectionResult: Sendable {
    var correctedData: [[Float]]
    var diagnostics: MuscleBSSCCADiagnostics
}

nonisolated struct MuscleBSSCCAProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case preparing = "Preparing BSS-CCA ranges"
        case decomposing = "Lagged CCA + spectral classification"
        case assembling = "Assembling review results"
        case complete = "MAAC-4 analysis complete"
    }

    var phase: Phase
    var completedWindowCount: Int
    var totalWindowCount: Int
    var completedSampleCount: Int
    var totalSampleCount: Int
    var analyzedWindowCount: Int
    var affectedWindowCount: Int
    var skippedWindowCount: Int
    var classifiedComponentCount: Int
    var selectedComponentCount: Int
    var elapsedSeconds: Double

    var fraction: Double {
        switch phase {
        case .preparing:
            return 0.02
        case .decomposing:
            let workFraction = Double(completedSampleCount) / Double(max(totalSampleCount, 1))
            return min(max(0.05 + 0.90 * workFraction, 0.05), 0.95)
        case .assembling:
            return 0.98
        case .complete:
            return 1
        }
    }

    var windowsPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(completedWindowCount) / elapsedSeconds
    }

    var estimatedSecondsRemaining: Double? {
        guard completedSampleCount > 0,
              completedSampleCount < totalSampleCount,
              elapsedSeconds > 0 else { return nil }
        let samplesPerSecond = Double(completedSampleCount) / elapsedSeconds
        guard samplesPerSecond > 0 else { return nil }
        return Double(totalSampleCount - completedSampleCount) / samplesPerSecond
    }
}

nonisolated enum MuscleBSSCCAArtifactMarkerBuilder {
    static let eventCode = "EMG"
    static let sourceFile = "MAAC-4 Muscle BSS-CCA"

    static func events(
        from diagnostics: MuscleBSSCCADiagnostics,
        samplingRate: Double
    ) -> [MFFEvent] {
        guard samplingRate.isFinite, samplingRate > 0 else { return [] }
        return diagnostics.windows.enumerated().compactMap { index, window in
            guard window.removedComponentCount > 0 else { return nil }
            let onset = Double(window.sampleRange.lowerBound) / samplingRate
            let duration = Double(window.sampleRange.count) / samplingRate
            let largestRatio = window.components
                .filter(\.removed)
                .map(\.emgToEEGPowerRatio)
                .max() ?? 0
            return MFFEvent(
                id: "maac-muscle-\(index)-\(window.sampleRange.lowerBound)-\(window.sampleRange.upperBound)",
                code: eventCode,
                label: "MAAC Muscle",
                eventDescription: String(
                    format: "%d BSS-CCA component(s) selected; largest EMG/EEG ratio %.3f",
                    window.removedComponentCount,
                    largestRatio
                ),
                beginTimeSeconds: onset,
                rawBeginTime: String(format: "%.6f", onset),
                sourceFile: sourceFile,
                durationSeconds: duration,
                timeAnchor: .onset
            )
        }
    }
}

nonisolated enum MuscleBSSCCAError: Error, LocalizedError, Equatable {
    case invalidSignal
    case invalidSamplingRate
    case invalidConfiguration
    case noEpochSegments
    case insufficientBandwidth(requiredHz: Double, nyquistHz: Double)

    var errorDescription: String? {
        switch self {
        case .invalidSignal:
            return "MAAC-4 needs a rectangular, non-empty multichannel signal."
        case .invalidSamplingRate:
            return "MAAC-4 needs a positive sampling rate."
        case .invalidConfiguration:
            return "MAAC-4 settings contain an invalid window, overlap, band, sampling-rate, or power-ratio value."
        case .noEpochSegments:
            return "Recorded epoch boundaries were requested, but this signal contains no epochs."
        case let .insufficientBandwidth(required, nyquist):
            return String(
                format: "MAAC-4 needs signal bandwidth through %.1f Hz, but the Nyquist limit is %.1f Hz.",
                required, nyquist
            )
        }
    }
}

nonisolated enum MuscleBSSCCACorrector {
    private static let minimumSamples = 16
    private static let minimumChannels = 3

    static func analyze(
        data: [[Float]],
        samplingRate: Double,
        epochSegments: [EpochSegment] = [],
        configuration: MuscleBSSCCAConfiguration = .default,
        excluding excludedChannels: Set<Int> = [],
        progress: (@Sendable (MuscleBSSCCAProgress) -> Void)? = nil
    ) throws -> MuscleBSSCCADiagnostics {
        try process(
            data: data,
            samplingRate: samplingRate,
            epochSegments: epochSegments,
            configuration: configuration,
            excludedChannels: excludedChannels,
            appliesCorrection: false,
            progress: progress
        ).diagnostics
    }

    static func correct(
        data: [[Float]],
        samplingRate: Double,
        epochSegments: [EpochSegment] = [],
        configuration: MuscleBSSCCAConfiguration = .default,
        excluding excludedChannels: Set<Int> = [],
        progress: (@Sendable (MuscleBSSCCAProgress) -> Void)? = nil
    ) throws -> MuscleBSSCCACorrectionResult {
        try process(
            data: data,
            samplingRate: samplingRate,
            epochSegments: epochSegments,
            configuration: configuration,
            excludedChannels: excludedChannels,
            appliesCorrection: true,
            progress: progress
        )
    }

    static func analysisRanges(
        sampleCount: Int,
        samplingRate: Double,
        epochSegments: [EpochSegment],
        configuration: MuscleBSSCCAConfiguration
    ) throws -> (mode: MuscleBSSCCARangeMode, ranges: [Range<Int>]) {
        guard sampleCount > 0 else { throw MuscleBSSCCAError.invalidSignal }
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw MuscleBSSCCAError.invalidSamplingRate
        }
        try validate(configuration)
        let mode: MuscleBSSCCARangeMode
        switch configuration.rangeMode {
        case .automatic:
            mode = epochSegments.isEmpty ? .continuousWindows : .epochSegments
        case .continuousWindows:
            mode = .continuousWindows
        case .epochSegments:
            guard !epochSegments.isEmpty else { throw MuscleBSSCCAError.noEpochSegments }
            mode = .epochSegments
        }

        switch mode {
        case .automatic:
            preconditionFailure("Automatic MAAC-4 range mode must resolve before use.")
        case .epochSegments:
            let ranges = epochSegments
                .sorted { $0.startSample < $1.startSample }
                .compactMap { segment -> Range<Int>? in
                    let lower = min(max(segment.startSample, 0), sampleCount)
                    let inclusiveEnd = segment.endSample == Int.max ? Int.max : segment.endSample + 1
                    let upper = min(max(inclusiveEnd, lower), sampleCount)
                    return upper > lower ? lower..<upper : nil
                }
            guard !ranges.isEmpty else { throw MuscleBSSCCAError.noEpochSegments }
            return (mode, ranges)
        case .continuousWindows:
            let requestedSamples = configuration.continuousWindowSeconds * samplingRate
            let window = max(Int(min(requestedSamples, Double(sampleCount)).rounded()), 1)
            guard sampleCount > window else { return (mode, [0..<sampleCount]) }
            let step = max(Int((Double(window) * (1 - configuration.continuousOverlapFraction)).rounded()), 1)
            var starts: [Int] = []
            var start = 0
            while start + window < sampleCount {
                starts.append(start)
                start += step
            }
            starts.append(max(sampleCount - window, 0))
            let ranges = Array(Set(starts)).sorted().map { $0..<min($0 + window, sampleCount) }
            return (mode, ranges)
        }
    }

    private static func process(
        data: [[Float]],
        samplingRate: Double,
        epochSegments: [EpochSegment],
        configuration: MuscleBSSCCAConfiguration,
        excludedChannels: Set<Int>,
        appliesCorrection: Bool,
        progress: (@Sendable (MuscleBSSCCAProgress) -> Void)?
    ) throws -> MuscleBSSCCACorrectionResult {
        guard samplingRate.isFinite, samplingRate > 0 else { throw MuscleBSSCCAError.invalidSamplingRate }
        guard let sampleCount = data.first?.count,
              sampleCount > 0,
              data.count >= minimumChannels,
              data.allSatisfy({ $0.count == sampleCount }) else {
            throw MuscleBSSCCAError.invalidSignal
        }
        try validate(configuration)
        let nyquist = samplingRate / 2
        guard nyquist >= configuration.emgBandHighHz else {
            throw MuscleBSSCCAError.insufficientBandwidth(
                requiredHz: configuration.emgBandHighHz,
                nyquistHz: nyquist
            )
        }
        let rangePlan = try analysisRanges(
            sampleCount: sampleCount,
            samplingRate: samplingRate,
            epochSegments: epochSegments,
            configuration: configuration
        )
        let channels = data.indices.filter { !excludedChannels.contains($0) }
        var diagnostics: [MuscleBSSCCAWindowDiagnostic] = []
        diagnostics.reserveCapacity(rangePlan.ranges.count)
        var removedSum = data.map { [Float](repeating: 0, count: $0.count) }
        var accumulatedWeight = [Double](repeating: 0, count: sampleCount)
        let startedAt = Date()
        let totalWorkSamples = rangePlan.ranges.reduce(0) { $0 + $1.count }
        var completedSamples = 0
        var analyzedWindows = 0
        var affectedWindows = 0
        var skippedWindows = 0
        var classifiedComponents = 0
        var selectedComponents = 0

        func report(_ phase: MuscleBSSCCAProgress.Phase) {
            progress?(MuscleBSSCCAProgress(
                phase: phase,
                completedWindowCount: diagnostics.count,
                totalWindowCount: rangePlan.ranges.count,
                completedSampleCount: completedSamples,
                totalSampleCount: totalWorkSamples,
                analyzedWindowCount: analyzedWindows,
                affectedWindowCount: affectedWindows,
                skippedWindowCount: skippedWindows,
                classifiedComponentCount: classifiedComponents,
                selectedComponentCount: selectedComponents,
                elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
        }
        report(.preparing)

        for range in rangePlan.ranges {
            if Task.isCancelled { break }
            let result = correctWindow(
                data: data,
                range: range,
                channels: channels,
                samplingRate: samplingRate,
                configuration: configuration
            )
            diagnostics.append(result.diagnostic)
            completedSamples += range.count
            classifiedComponents += result.diagnostic.components.count
            selectedComponents += result.diagnostic.removedComponentCount
            if result.diagnostic.skippedReason == nil {
                analyzedWindows += 1
                if result.diagnostic.removedComponentCount > 0 { affectedWindows += 1 }
            } else {
                skippedWindows += 1
            }
            if result.diagnostic.skippedReason == nil, appliesCorrection {
                for local in 0..<range.count {
                    let weight = rangePlan.mode == .continuousWindows
                        ? overlapWeight(local: local, count: range.count)
                        : 1
                    accumulatedWeight[range.lowerBound + local] += weight
                    for (channel, removed) in result.removedRows {
                        removedSum[channel][range.lowerBound + local] += Float(weight * removed[local])
                    }
                }
            }
            report(.decomposing)
        }
        if Task.isCancelled { throw CancellationError() }

        report(.assembling)
        var corrected = data
        if appliesCorrection {
            for channel in channels {
                for sample in 0..<sampleCount where accumulatedWeight[sample] > 0 {
                    corrected[channel][sample] -= Float(Double(removedSum[channel][sample]) / accumulatedWeight[sample])
                }
            }
        }
        report(.complete)
        return MuscleBSSCCACorrectionResult(
            correctedData: corrected,
            diagnostics: MuscleBSSCCADiagnostics(
                requestedMode: configuration.rangeMode,
                resolvedMode: rangePlan.mode,
                windows: diagnostics
            )
        )
    }

    private static func validate(_ configuration: MuscleBSSCCAConfiguration) throws {
        guard configuration.continuousWindowSeconds.isFinite,
              configuration.continuousWindowSeconds > 0,
              configuration.continuousOverlapFraction.isFinite,
              configuration.continuousOverlapFraction >= 0,
              configuration.continuousOverlapFraction < 1,
              configuration.analysisSamplingRate.isFinite,
              configuration.analysisSamplingRate > 0,
              configuration.eegBandLowHz.isFinite,
              configuration.eegBandHighHz.isFinite,
              configuration.emgBandLowHz.isFinite,
              configuration.emgBandHighHz.isFinite,
              configuration.eegBandLowHz >= 0,
              configuration.eegBandLowHz < configuration.eegBandHighHz,
              configuration.eegBandHighHz <= configuration.emgBandLowHz,
              configuration.emgBandLowHz < configuration.emgBandHighHz,
              configuration.minimumEMGToEEGPowerRatio.isFinite,
              configuration.minimumEMGToEEGPowerRatio > 0 else {
            throw MuscleBSSCCAError.invalidConfiguration
        }
    }

    private struct WindowResult {
        var removedRows: [(channel: Int, samples: [Double])]
        var diagnostic: MuscleBSSCCAWindowDiagnostic
    }

    private static func correctWindow(
        data: [[Float]],
        range: Range<Int>,
        channels: [Int],
        samplingRate: Double,
        configuration: MuscleBSSCCAConfiguration
    ) -> WindowResult {
        guard range.count >= minimumSamples else {
            return skipped(range, channels: channels.count, reason: "fewer than \(minimumSamples) samples")
        }
        let usable = channels.filter { data[$0][range].allSatisfy(\.isFinite) }
        guard usable.count >= minimumChannels else {
            return skipped(range, channels: usable.count, reason: "fewer than \(minimumChannels) finite, usable channels")
        }

        let factor = Downsampler.factor(
            sourceRate: samplingRate,
            targetRate: min(configuration.analysisSamplingRate, samplingRate)
        )
        let effectiveRate = Downsampler.effectiveRate(sourceRate: samplingRate, factor: factor)
        guard effectiveRate / 2 >= configuration.emgBandHighHz else {
            return skipped(range, channels: usable.count, reason: "analysis rate does not cover the configured EMG band")
        }
        let native = usable.map { Array(data[$0][range]) }
        let analyzed = native.map { Downsampler.windowedSincDecimated($0, by: factor).map(Double.init) }
        guard let analyzedCount = analyzed.first?.count, analyzedCount >= minimumSamples else {
            return skipped(range, channels: usable.count, reason: "too few samples after analysis-rate conversion")
        }
        let centeredAnalysis = centerRows(analyzed)
        guard let decomposition = decompose(centeredAnalysis) else {
            return skipped(range, channels: usable.count, reason: "CCA decomposition was numerically singular")
        }

        // Treat replay payloads defensively: if an older/manual payload contains
        // duplicate decisions, the last stored decision wins deterministically.
        var overrides: [Int: Bool] = [:]
        for override in configuration.componentOverrides
        where override.rangeStartSample == range.lowerBound {
            overrides[override.componentIndex] = override.removes
        }
        var componentDiagnostics: [MuscleBSSCCAComponentDiagnostic] = []
        var removedComponents: [Int] = []
        for component in 0..<decomposition.sources.rows {
            let source = decomposition.sources.row(component)
            let ratio = spectralPowerRatio(
                source,
                samplingRate: effectiveRate,
                configuration: configuration
            ) ?? 0
            let automaticallyRemoved = ratio >= configuration.minimumEMGToEEGPowerRatio
            let displayedIndex = component + 1
            let override = overrides[displayedIndex]
            let removes = override ?? automaticallyRemoved
            componentDiagnostics.append(MuscleBSSCCAComponentDiagnostic(
                componentIndex: displayedIndex,
                canonicalCorrelation: decomposition.correlations[component],
                lagOneAutocorrelation: lagOneAutocorrelation(source),
                emgToEEGPowerRatio: ratio,
                automaticallyRemoved: automaticallyRemoved,
                removed: removes,
                wasOverridden: override != nil
            ))
            if removes { removedComponents.append(component) }
        }

        // A malformed/manual payload must never erase an entire window. The
        // most autocorrelated component is the conservative one to preserve.
        if removedComponents.count == decomposition.sources.rows, !removedComponents.isEmpty {
            removedComponents.removeAll(where: { $0 == 0 })
            componentDiagnostics[0].removed = false
        }

        let nativeDouble = native.map { $0.map(Double.init) }
        let centeredNative = centerRows(nativeDouble)
        let nativeSources = decomposition.unmixing.multiply(
            MuscleCCAMatrix(rows: centeredNative.count, cols: range.count, rowsData: centeredNative)
        )
        var removedRows = usable.map { ($0, [Double](repeating: 0, count: range.count)) }
        if !removedComponents.isEmpty {
            for (localChannel, _) in usable.enumerated() {
                for sample in 0..<range.count {
                    var value = 0.0
                    for component in removedComponents {
                        value += decomposition.mixing[localChannel, component] * nativeSources[component, sample]
                    }
                    removedRows[localChannel].1[sample] = value
                }
            }
        }
        return WindowResult(
            removedRows: removedRows,
            diagnostic: MuscleBSSCCAWindowDiagnostic(
                sampleRange: range,
                usableChannelCount: usable.count,
                analysisSamplingRate: effectiveRate,
                components: componentDiagnostics,
                skippedReason: nil
            )
        )
    }

    private struct Decomposition {
        var unmixing: MuscleCCAMatrix
        var mixing: MuscleCCAMatrix
        var sources: MuscleCCAMatrix
        var correlations: [Double]
    }

    private static func decompose(_ centered: [[Double]]) -> Decomposition? {
        guard let sampleCount = centered.first?.count,
              centered.count >= minimumChannels,
              sampleCount >= minimumSamples,
              centered.allSatisfy({ $0.count == sampleCount }) else { return nil }
        let channelCount = centered.count
        let pairCount = sampleCount - 1
        var covariance00 = [[Double]](repeating: [Double](repeating: 0, count: channelCount), count: channelCount)
        var covariance11 = covariance00
        var covariance01 = covariance00
        let scale = 1.0 / Double(max(pairCount - 1, 1))
        for first in 0..<channelCount {
            for second in 0..<channelCount {
                var c00 = 0.0, c11 = 0.0, c01 = 0.0
                for sample in 0..<pairCount {
                    let currentFirst = centered[first][sample + 1]
                    let currentSecond = centered[second][sample + 1]
                    let delayedFirst = centered[first][sample]
                    let delayedSecond = centered[second][sample]
                    c00 += currentFirst * currentSecond
                    c11 += delayedFirst * delayedSecond
                    c01 += currentFirst * delayedSecond
                }
                covariance00[first][second] = c00 * scale
                covariance11[first][second] = c11 * scale
                covariance01[first][second] = c01 * scale
            }
        }
        guard let whitening0 = whitener(covariance00),
              let whitening1 = whitener(covariance11) else { return nil }
        let rank = min(whitening0.rows, whitening1.rows)
        guard rank >= 2 else { return nil }
        let w0 = whitening0.prefixRows(rank)
        let w1 = whitening1.prefixRows(rank)
        let cross = MuscleCCAMatrix(rows: channelCount, cols: channelCount, rowsData: covariance01)
        let canonical = w0.multiply(cross).multiply(w1.transposed())
        guard let svd = try? canonical.svd(), svd.s.count >= rank else { return nil }
        let unmixing = svd.u.transposed().multiply(w0)
        guard let mixing = try? unmixing.pseudoinverse() else { return nil }
        let observations = MuscleCCAMatrix(rows: channelCount, cols: sampleCount, rowsData: centered)
        let sources = unmixing.multiply(observations)
        return Decomposition(
            unmixing: unmixing,
            mixing: mixing,
            sources: sources,
            correlations: Array(svd.s.prefix(rank)).map { min(max($0, 0), 1) }
        )
    }

    private static func whitener(_ covariance: [[Double]]) -> MuscleCCAMatrix? {
        let eigen = LinearAlgebra.symmetricEigenDecomposition(covariance)
        guard let largest = eigen.values.max(), largest.isFinite, largest > 0 else { return nil }
        let cutoff = largest * 1e-10
        let selected = eigen.values.indices
            .filter { eigen.values[$0].isFinite && eigen.values[$0] > cutoff }
            .sorted { eigen.values[$0] > eigen.values[$1] }
        guard selected.count >= 2 else { return nil }
        var result = MuscleCCAMatrix(rows: selected.count, cols: covariance.count)
        for (row, index) in selected.enumerated() {
            let scale = 1 / sqrt(eigen.values[index])
            for channel in covariance.indices {
                result[row, channel] = eigen.vectors[channel][index] * scale
            }
        }
        return result
    }

    private static func centerRows(_ rows: [[Double]]) -> [[Double]] {
        rows.map { row in
            let mean = row.reduce(0, +) / Double(max(row.count, 1))
            return row.map { $0 - mean }
        }
    }

    private static func spectralPowerRatio(
        _ source: [Double],
        samplingRate: Double,
        configuration: MuscleBSSCCAConfiguration
    ) -> Double? {
        var window = 1
        while window * 2 <= min(source.count, 256) { window *= 2 }
        guard window >= minimumSamples,
              let spectrum = try? AperiodicSpectrumEstimator.welch(
                samples: source,
                samplingRate: samplingRate,
                segments: [0..<source.count],
                windowSamples: window,
                overlapFraction: 0.5,
                includeNyquist: true
              ) else { return nil }
        func meanPower(low: Double, high: Double) -> Double? {
            let values = spectrum.frequenciesHz.indices.compactMap { index -> Double? in
                let frequency = spectrum.frequenciesHz[index]
                let power = spectrum.power[index]
                return frequency >= low && frequency < high && power.isFinite ? power : nil
            }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        guard let eeg = meanPower(low: configuration.eegBandLowHz, high: configuration.eegBandHighHz),
              let emg = meanPower(low: configuration.emgBandLowHz, high: configuration.emgBandHighHz),
              eeg > 0 else { return nil }
        return emg / eeg
    }

    private static func lagOneAutocorrelation(_ values: [Double]) -> Double {
        guard values.count > 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var numerator = 0.0
        var denominator = 0.0
        for index in values.indices {
            let centered = values[index] - mean
            denominator += centered * centered
            if index > 0 { numerator += centered * (values[index - 1] - mean) }
        }
        return denominator > 0 ? numerator / denominator : 0
    }

    private static func overlapWeight(local: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        let phase = Double(local) + 0.5
        let sine = sin(Double.pi * phase / Double(count))
        return max(sine * sine, 1e-12)
    }

    private static func skipped(_ range: Range<Int>, channels: Int, reason: String) -> WindowResult {
        WindowResult(
            removedRows: [],
            diagnostic: MuscleBSSCCAWindowDiagnostic(
                sampleRange: range,
                usableChannelCount: channels,
                analysisSamplingRate: 0,
                components: [],
                skippedReason: reason
            )
        )
    }
}

private nonisolated struct MuscleCCAMatrix {
    enum Error: Swift.Error { case decomposition(Int), singular }

    var rows: Int
    var cols: Int
    var grid: [Double]

    init(rows: Int, cols: Int, repeating value: Double = 0) {
        self.rows = rows
        self.cols = cols
        grid = [Double](repeating: value, count: rows * cols)
    }

    init(rows: Int, cols: Int, rowsData: [[Double]]) {
        precondition(rowsData.count == rows && rowsData.allSatisfy { $0.count == cols })
        self.rows = rows
        self.cols = cols
        grid = rowsData.flatMap { $0 }
    }

    init(rows: Int, cols: Int, rowMajor: [Double]) {
        precondition(rowMajor.count == rows * cols)
        self.rows = rows
        self.cols = cols
        grid = rowMajor
    }

    subscript(_ row: Int, _ column: Int) -> Double {
        get { grid[row * cols + column] }
        set { grid[row * cols + column] = newValue }
    }

    func row(_ row: Int) -> [Double] {
        Array(grid[(row * cols)..<((row + 1) * cols)])
    }

    func prefixRows(_ count: Int) -> Self {
        let retained = min(max(count, 0), rows)
        return Self(rows: retained, cols: cols, rowMajor: Array(grid.prefix(retained * cols)))
    }

    func transposed() -> Self {
        var result = Self(rows: cols, cols: rows)
        for row in 0..<rows {
            for column in 0..<cols { result[column, row] = self[row, column] }
        }
        return result
    }

    func multiply(_ other: Self) -> Self {
        precondition(cols == other.rows)
        var result = Self(rows: rows, cols: other.cols)
        cblas_dgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans,
            Int32(rows), Int32(other.cols), Int32(cols),
            1, grid, Int32(cols), other.grid, Int32(other.cols),
            0, &result.grid, Int32(other.cols)
        )
        return result
    }

    func svd() throws -> (u: Self, s: [Double], vt: Self) {
        let minimum = min(rows, cols)
        var columnMajor = [Double](repeating: 0, count: rows * cols)
        for row in 0..<rows {
            for column in 0..<cols { columnMajor[column * rows + row] = self[row, column] }
        }
        var singular = [Double](repeating: 0, count: minimum)
        var u = [Double](repeating: 0, count: rows * minimum)
        var vt = [Double](repeating: 0, count: minimum * cols)
        var jobU: CChar = 83
        var jobVT: CChar = 83
        var m = LAPACKInt(rows), n = LAPACKInt(cols)
        var lda = m, ldu = m, ldvt = LAPACKInt(minimum)
        var info = LAPACKInt(0), workCount = LAPACKInt(-1)
        var query = 0.0
        dgesvd_(&jobU, &jobVT, &m, &n, &columnMajor, &lda, &singular, &u, &ldu, &vt, &ldvt, &query, &workCount, &info)
        guard info == 0 else { throw Error.decomposition(Int(info)) }
        workCount = max(LAPACKInt(query.rounded(.up)), 1)
        var work = [Double](repeating: 0, count: Int(workCount))
        dgesvd_(&jobU, &jobVT, &m, &n, &columnMajor, &lda, &singular, &u, &ldu, &vt, &ldvt, &work, &workCount, &info)
        guard info == 0 else { throw Error.decomposition(Int(info)) }
        var rowMajorU = [Double](repeating: 0, count: rows * minimum)
        for row in 0..<rows {
            for column in 0..<minimum { rowMajorU[row * minimum + column] = u[column * rows + row] }
        }
        var rowMajorVT = [Double](repeating: 0, count: minimum * cols)
        for row in 0..<minimum {
            for column in 0..<cols { rowMajorVT[row * cols + column] = vt[column * minimum + row] }
        }
        return (
            Self(rows: rows, cols: minimum, rowMajor: rowMajorU),
            singular,
            Self(rows: minimum, cols: cols, rowMajor: rowMajorVT)
        )
    }

    func pseudoinverse(relativeTolerance: Double = 1e-12) throws -> Self {
        let decomposition = try svd()
        let cutoff = relativeTolerance * Double(max(rows, cols)) * (decomposition.s.first ?? 0)
        guard decomposition.s.contains(where: { $0 > cutoff }) else { throw Error.singular }
        var v = decomposition.vt.transposed()
        for component in decomposition.s.indices {
            let scale = decomposition.s[component] > cutoff ? 1 / decomposition.s[component] : 0
            for row in 0..<v.rows { v[row, component] *= scale }
        }
        return v.multiply(decomposition.u.transposed())
    }
}
