//
//  WaveletArtifactAnalyzer.swift
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
//  Multiscale, wavelet-like artifact evidence for health features, template
//  matching, and topography-trajectory matching.
//

import Dispatch
import Foundation

nonisolated struct WaveletArtifactConfiguration: Sendable {
    var name: String
    var eventCode: String
    var selectedChannelIndices: [Int]
    var topographyChannelIndices: [Int]
    var exemplarRange: ClosedRange<Int>
    var matchThreshold: Double
    var windowSizeSeconds: Double
    var downsampleRate: Double
    var mergeWindowSeconds: Double
    var polarity: ArtifactTemplatePolarity
    var scansWaveform: Bool
    var scansTopography: Bool
    var levelCount: Int
    var thresholdScale: Double
    var topographyMetric: ArtifactTopographyMetric
}

nonisolated struct WaveletArtifactDetectionResult: Sendable {
    var waveformEvents: [MFFEvent]
    var topographyEvents: [MFFEvent]
    var waveformAverage: ArtifactTemplateAverage?
    var topographyReference: ArtifactTemplateTopography?
    var featureSummary: WaveletArtifactFeatureSummary
    var waveformScores: WaveletArtifactScoreSummary?
    var topographyScores: WaveletArtifactScoreSummary?

    var hasWaveformMatches: Bool {
        !waveformEvents.isEmpty
    }

    var hasTopographyMatches: Bool {
        !topographyEvents.isEmpty
    }
}

nonisolated struct WaveletArtifactScoreSummary: Sendable {
    var candidateCount: Int
    var matchCount: Int
    var bestScore: Double
    var medianMatchScore: Double
}

nonisolated struct WaveletArtifactFeatureSummary: Sendable {
    var channelCount: Int
    var levelCount: Int
    var analyzedSampleCount: Int
    var effectiveSamplingRate: Double
    var artifactEnergyFraction: Double
    var strongestChannels: [WaveletArtifactChannelSummary]
    var levelSummaries: [WaveletArtifactLevelSummary]
}

nonisolated struct WaveletArtifactChannelSummary: Identifiable, Sendable {
    var channelIndex: Int
    var artifactEnergyFraction: Double
    var peakArtifactMagnitude: Float
    var dominantLevel: Int

    var id: Int { channelIndex }
}

nonisolated struct WaveletArtifactLevelSummary: Identifiable, Sendable {
    var level: Int
    var artifactEnergyFraction: Double
    var centerFrequencyHz: Double

    var id: Int { level }
}

nonisolated struct WaveletArtifactExplorerConfiguration: Sendable {
    var channelIndices: [Int]
    var downsampleRate: Double
    var levelCount: Int
    var thresholdScale: Double
    var cleaningMode: WaveletCleaningMode
    var intensity: Double
    var waveletFamily: WaveletCleaningFamily
    var thresholdRule: WaveletCleaningThresholdRule
    var thresholdModel: WaveletCleaningThresholdModel
    var mergeWindowSeconds: Double
    var minimumDurationSeconds: Double
    var maximumCandidates: Int
}

nonisolated struct WaveletArtifactExplorerProgress: Sendable {
    var fraction: Double
    var title: String
    var detail: String
}

nonisolated struct WaveletArtifactExplorerResult: Sendable {
    var summary: WaveletArtifactFeatureSummary
    var candidates: [WaveletArtifactCandidate]
    var channelCount: Int
    var effectiveSamplingRate: Double
    var candidateThreshold: Double
    var analyzedDurationSeconds: Double
}

nonisolated struct WaveletArtifactCandidate: Identifiable, Sendable {
    var id: String
    var rank: Int
    var startSample: Int
    var endSample: Int
    var peakSample: Int
    var startTimeSeconds: Double
    var endTimeSeconds: Double
    var peakTimeSeconds: Double
    var durationSeconds: Double
    var score: Double
    var peakEnergy: Double
    var channelIndex: Int
    var dominantLevel: Int
    var contributingChannelCount: Int
}

nonisolated struct WaveletChannelGoodnessConfiguration: Sendable {
    var channelIndices: [Int]
    var downsampleRate: Double
    var levelCount: Int
    var thresholdScale: Double
    var cleaningMode: WaveletCleaningMode
    var intensity: Double
    var waveletFamily: WaveletCleaningFamily
    var thresholdRule: WaveletCleaningThresholdRule
    var thresholdModel: WaveletCleaningThresholdModel
}

nonisolated struct WaveletChannelGoodnessResult: Identifiable, Sendable {
    var channelIndex: Int
    var goodnessScore: Double
    var artifactEnergyFraction: Double
    var burstFraction: Double
    var peakArtifactMagnitude: Float
    var dominantLevel: Int

    var id: Int { channelIndex }
}

nonisolated enum WaveletArtifactAnalyzer {
    static let defaultLevelCount = 5
    static let maximumLevelCount = 11

    static func analyze(
        signal: MFFSignalData,
        channelIndices requestedChannels: [Int],
        downsampleRate: Double,
        levelCount requestedLevelCount: Int = defaultLevelCount,
        thresholdScale: Double = 1
    ) -> WaveletArtifactFeatureSummary {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 2 else {
            return emptySummary(effectiveSamplingRate: 0)
        }

        let decimation = decimationFactor(samplingRate: signal.samplingRate, targetRate: downsampleRate)
        let effectiveRate = signal.samplingRate / Double(decimation)
        let channels = SignalSelection.validChannels(requestedChannels, in: signal)
        let levelCount = boundedLevelCount(requestedLevelCount, sampleCount: max(sampleCount / decimation, 1))
        let data = prepareChannels(
            signal: signal,
            channelIndices: channels,
            decimation: decimation,
            levelCount: levelCount,
            thresholdScale: thresholdScale,
            waveletFamily: .bior44,
            thresholdRule: .hard,
            thresholdModel: .robustUniversal
        )
        return featureSummary(from: data, effectiveSamplingRate: effectiveRate)
    }

    static func detect(
        in signal: MFFSignalData,
        configuration: WaveletArtifactConfiguration
    ) -> WaveletArtifactDetectionResult {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 2 else {
            let summary = emptySummary(effectiveSamplingRate: 0)
            return WaveletArtifactDetectionResult(
                waveformEvents: [],
                topographyEvents: [],
                waveformAverage: nil,
                topographyReference: nil,
                featureSummary: summary,
                waveformScores: nil,
                topographyScores: nil
            )
        }

        let decimation = decimationFactor(
            samplingRate: signal.samplingRate,
            targetRate: configuration.downsampleRate
        )
        let effectiveRate = signal.samplingRate / Double(decimation)
        let selectedChannels = SignalSelection.validChannels(configuration.selectedChannelIndices, in: signal)
        let topographyChannels = SignalSelection.validChannels(configuration.topographyChannelIndices, in: signal)
        let analysisChannels = Array(Set(selectedChannels + topographyChannels)).sorted()
        let levelCount = boundedLevelCount(
            configuration.levelCount,
            sampleCount: max(sampleCount / decimation, 1)
        )
        let waveletData = prepareChannels(
            signal: signal,
            channelIndices: analysisChannels,
            decimation: decimation,
            levelCount: levelCount,
            thresholdScale: configuration.thresholdScale,
            waveletFamily: .bior44,
            thresholdRule: .hard,
            thresholdModel: .robustUniversal
        )
        let summary = featureSummary(from: waveletData, effectiveSamplingRate: effectiveRate)
        let exemplar = exemplarWindow(
            range: configuration.exemplarRange,
            windowSeconds: configuration.windowSizeSeconds,
            sampleCount: sampleCount,
            samplingRate: signal.samplingRate,
            decimation: decimation
        )

        var waveformEvents: [MFFEvent] = []
        var waveformScores: WaveletArtifactScoreSummary?
        if configuration.scansWaveform {
            let detection = detectWaveform(
                data: waveletData,
                channelIndices: selectedChannels,
                exemplar: exemplar,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate,
                decimation: decimation,
                configuration: configuration
            )
            waveformEvents = detection.events
            waveformScores = detection.summary
        }

        var topographyEvents: [MFFEvent] = []
        var topographyReference: ArtifactTemplateTopography?
        var topographyScores: WaveletArtifactScoreSummary?
        if configuration.scansTopography {
            let detection = detectTopographyTrajectory(
                signal: signal,
                data: waveletData,
                channelIndices: topographyChannels,
                exemplar: exemplar,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate,
                decimation: decimation,
                configuration: configuration
            )
            topographyEvents = detection.events
            topographyReference = detection.reference
            topographyScores = detection.summary
        }

        return WaveletArtifactDetectionResult(
            waveformEvents: waveformEvents,
            topographyEvents: topographyEvents,
            waveformAverage: average(
                signal: signal,
                events: waveformEvents,
                selectedChannelIndices: selectedChannels,
                windowSamples: max(Int((configuration.windowSizeSeconds * signal.samplingRate).rounded()), 3)
            ),
            topographyReference: topographyReference,
            featureSummary: summary,
            waveformScores: waveformScores,
            topographyScores: topographyScores
        )
    }

    static func explore(
        in signal: MFFSignalData,
        configuration: WaveletArtifactExplorerConfiguration,
        progress: (@Sendable (WaveletArtifactExplorerProgress) -> Void)? = nil
    ) -> WaveletArtifactExplorerResult {
        func report(_ fraction: Double, _ title: String, _ detail: String) {
            progress?(WaveletArtifactExplorerProgress(
                fraction: min(max(fraction, 0), 1),
                title: title,
                detail: detail
            ))
        }

        report(0.01, "Preparing wavelet artifact explorer", "Checking signal dimensions, sampling rate, and requested channel scope.")
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 2 else {
            let summary = emptySummary(effectiveSamplingRate: 0)
            report(1.0, "Wavelet scan skipped", "The signal did not contain enough samples to analyze.")
            return WaveletArtifactExplorerResult(
                summary: summary,
                candidates: [],
                channelCount: 0,
                effectiveSamplingRate: 0,
                candidateThreshold: 0,
                analyzedDurationSeconds: 0
            )
        }

        let decimation = decimationFactor(
            samplingRate: signal.samplingRate,
            targetRate: configuration.downsampleRate
        )
        let effectiveRate = signal.samplingRate / Double(decimation)
        let channels = SignalSelection.validChannels(configuration.channelIndices, in: signal)
        let levelCount = boundedLevelCount(
            configuration.levelCount,
            sampleCount: max(sampleCount / decimation, 1)
        )
        report(
            0.05,
            "Wavelet scan configured",
            "Using \(channels.count) channels, \(waveletWorkerCount(for: channels.count)) wavelet workers, \(String(format: "%.1f", effectiveRate)) Hz effective sampling, \(configuration.cleaningMode.rawValue), intensity \(String(format: "%.2f", configuration.intensity)), \(configuration.waveletFamily.rawValue), \(configuration.thresholdModel.rawValue), \(configuration.thresholdRule.rawValue.lowercased()) thresholding, \(levelCount) levels, and a \(String(format: "%.2f", configuration.thresholdScale))x effective coefficient gate."
        )

        let data = prepareChannels(
            signal: signal,
            channelIndices: channels,
            decimation: decimation,
            levelCount: levelCount,
            thresholdScale: configuration.thresholdScale,
            waveletFamily: configuration.waveletFamily,
            thresholdRule: configuration.thresholdRule,
            thresholdModel: configuration.thresholdModel
        ) { completed, channelIndex, total in
            let denominator = max(total, 1)
            let fraction = 0.08 + 0.48 * (Double(completed) / Double(denominator))
            report(
                fraction,
                "Finished Ch \(channelIndex + 1)",
                "Completed \(completed) of \(total) channel decompositions using \(waveletWorkerCount(for: total)) workers: downsampling, demeaning, applying \(configuration.waveletFamily.rawValue) smoothing, computing \(levelCount) undecimated detail levels, and retaining \(configuration.thresholdModel.rawValue) outlier coefficients."
            )
        }
        report(0.58, "Summarizing wavelet evidence", "Aggregating artifact-energy fractions across channels and levels.")

        let summary = featureSummary(from: data, effectiveSamplingRate: effectiveRate)
        report(0.66, "Building temporal evidence curve", "Combining normalized wavelet salience across \(data.count) analyzed channels.")
        let projection = explorerProjection(from: data)

        report(0.74, "Estimating candidate threshold", "Measuring the robust baseline of the combined wavelet-energy curve.")
        let threshold = explorerCandidateThreshold(for: projection)
        let minimumDurationSamples = max(Int((configuration.minimumDurationSeconds * effectiveRate).rounded()), 1)
        let mergeSamples = max(Int((configuration.mergeWindowSeconds * effectiveRate).rounded()), 1)

        report(
            0.82,
            "Extracting wavelet bursts",
            "Walking \(projection.count) downsampled time points, requiring at least \(minimumDurationSamples) samples over threshold, then merging bursts within \(mergeSamples) samples."
        )
        let candidates = explorerCandidates(
            projection: projection,
            threshold: threshold,
            data: data,
            sampleCount: sampleCount,
            samplingRate: signal.samplingRate,
            decimation: decimation,
            minimumDurationSamples: minimumDurationSamples,
            mergeSamples: mergeSamples,
            maximumCandidates: max(configuration.maximumCandidates, 1)
        )

        report(
            0.94,
            "Ranking artifact candidates",
            "Sorting \(candidates.count) candidate bursts by peak multichannel wavelet score and preserving peak channel/level metadata."
        )
        report(
            1.0,
            "Wavelet artifact explorer scan complete",
            "Finished with \(candidates.count) ranked candidates, \(summary.strongestChannels.count) channel summaries, and \(summary.levelSummaries.count) level summaries."
        )
        return WaveletArtifactExplorerResult(
            summary: summary,
            candidates: candidates,
            channelCount: data.count,
            effectiveSamplingRate: effectiveRate,
            candidateThreshold: Double(threshold),
            analyzedDurationSeconds: Double(sampleCount) / signal.samplingRate
        )
    }

    static func channelGoodness(
        in signal: MFFSignalData,
        configuration: WaveletChannelGoodnessConfiguration,
        progress: (@Sendable (WaveletArtifactExplorerProgress) -> Void)? = nil
    ) -> [Int: WaveletChannelGoodnessResult] {
        func report(_ fraction: Double, _ title: String, _ detail: String) {
            progress?(WaveletArtifactExplorerProgress(
                fraction: min(max(fraction, 0), 1),
                title: title,
                detail: detail
            ))
        }

        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 2 else {
            return [:]
        }

        let decimation = decimationFactor(
            samplingRate: signal.samplingRate,
            targetRate: configuration.downsampleRate
        )
        let channels = SignalSelection.validChannels(configuration.channelIndices, in: signal)
        let levelCount = boundedLevelCount(
            configuration.levelCount,
            sampleCount: max(sampleCount / decimation, 1)
        )
        report(
            0.04,
            "Wavelet channel-goodness configured",
            "Scoring \(channels.count) channels with \(configuration.cleaningMode.rawValue), intensity \(String(format: "%.2f", configuration.intensity)), \(configuration.waveletFamily.rawValue), \(configuration.thresholdModel.rawValue), and \(levelCount) levels."
        )

        let data = prepareChannels(
            signal: signal,
            channelIndices: channels,
            decimation: decimation,
            levelCount: levelCount,
            thresholdScale: configuration.thresholdScale,
            waveletFamily: configuration.waveletFamily,
            thresholdRule: configuration.thresholdRule,
            thresholdModel: configuration.thresholdModel
        ) { completed, channelIndex, total in
            report(
                0.06 + 0.74 * Double(completed) / Double(max(total, 1)),
                "Wavelet-scored Ch \(channelIndex + 1)",
                "Completed \(completed) of \(total) channel decompositions for wavelet goodness."
            )
        }

        report(0.86, "Normalizing wavelet channel burden", "Comparing transient wavelet burden across channels.")
        let energyFractions = data.map { channel -> Double in
            let total = channel.totalEnergyByLevel.reduce(0, +)
            let artifact = channel.artifactEnergyByLevel.reduce(0, +)
            return total > 1e-12 ? artifact / total : 0
        }
        let peaks = data.map { channel in
            channel.signedSalience.map(abs).max() ?? 0
        }
        let bursts = data.map(channelBurstFraction)
        let medianEnergy = medianPositive(energyFractions, fallback: 0.001)
        let medianPeak = medianPositive(peaks.map(Double.init), fallback: 0.001)
        let medianBurst = medianPositive(bursts, fallback: 0.001)

        var results: [Int: WaveletChannelGoodnessResult] = [:]
        results.reserveCapacity(data.count)
        for (offset, channel) in data.enumerated() {
            let artifactFraction = energyFractions[offset]
            let peak = peaks[offset]
            let burstFraction = bursts[offset]
            let energyScore = HealthScoring.scoreUpperRatio(artifactFraction / medianEnergy, green: 2.0, red: 8.0)
            let peakScore = HealthScoring.scoreUpperRatio(Double(peak) / medianPeak, green: 2.5, red: 9.0)
            let burstScore = HealthScoring.scoreUpperRatio(burstFraction / medianBurst, green: 2.0, red: 8.0)
            let goodness = 0.46 * energyScore + 0.30 * burstScore + 0.24 * peakScore
            let dominantLevel = channel.artifactEnergyByLevel.indices.max {
                channel.artifactEnergyByLevel[$0] < channel.artifactEnergyByLevel[$1]
            } ?? 0

            results[channel.channelIndex] = WaveletChannelGoodnessResult(
                channelIndex: channel.channelIndex,
                goodnessScore: min(max(goodness, 0), 1),
                artifactEnergyFraction: artifactFraction,
                burstFraction: burstFraction,
                peakArtifactMagnitude: peak,
                dominantLevel: dominantLevel + 1
            )
        }
        report(1.0, "Wavelet channel-goodness complete", "Added multiscale transient-burden evidence for \(results.count) channels.")
        return results
    }

    static func cleaningPreview(
        in signal: MFFSignalData,
        candidate: WaveletArtifactCandidate,
        configuration: WaveletCleaningConfiguration
    ) -> WaveletCleaningPreviewResult? {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 2,
              signal.numberOfChannels > 0 else {
            return nil
        }

        let paddingSamples = max(Int((configuration.paddingSeconds * signal.samplingRate).rounded()), 0)
        let startSample = min(max(candidate.startSample - paddingSamples, 0), sampleCount - 1)
        let endSample = min(max(candidate.endSample + paddingSamples, startSample), sampleCount - 1)
        let windowSamples = endSample - startSample + 1
        guard windowSamples > 2 else { return nil }

        let channels = SignalSelection.validChannels(configuration.channelIndices, in: signal)
        let levelCount = boundedLevelCount(configuration.levelCount, sampleCount: windowSamples)
        var beforeSamples = Array(repeating: [Float](repeating: 0, count: windowSamples), count: signal.numberOfChannels)
        var artifactSamples = Array(repeating: [Float](repeating: 0, count: windowSamples), count: signal.numberOfChannels)
        var afterSamples = Array(repeating: [Float](repeating: 0, count: windowSamples), count: signal.numberOfChannels)

        for channelIndex in signal.data.indices {
            guard signal.data[channelIndex].count == sampleCount else { continue }
            let window = Array(signal.data[channelIndex][startSample...endSample])
            beforeSamples[channelIndex] = window
            afterSamples[channelIndex] = window
        }

        for channelIndex in channels where beforeSamples.indices.contains(channelIndex) {
            let artifact = reconstructedArtifactSignal(
                beforeSamples[channelIndex],
                levelCount: levelCount,
                thresholdScale: configuration.thresholdScale,
                waveletFamily: configuration.waveletFamily,
                thresholdRule: configuration.thresholdRule,
                thresholdModel: configuration.thresholdModel
            )
            artifactSamples[channelIndex] = artifact
            for sample in 0..<min(windowSamples, artifact.count) {
                afterSamples[channelIndex][sample] = beforeSamples[channelIndex][sample] - artifact[sample]
            }
        }

        let highlightedChannels = [candidate.channelIndex].filter { signal.data.indices.contains($0) }
        let beforeAverage = averageFromSamples(
            beforeSamples,
            selectedChannelIndices: highlightedChannels,
            samplingRate: signal.samplingRate
        )
        let artifactAverage = averageFromSamples(
            artifactSamples,
            selectedChannelIndices: highlightedChannels,
            samplingRate: signal.samplingRate
        )
        let afterAverage = averageFromSamples(
            afterSamples,
            selectedChannelIndices: highlightedChannels,
            samplingRate: signal.samplingRate
        )

        return WaveletCleaningPreviewResult(
            beforeAverage: beforeAverage,
            artifactAverage: artifactAverage,
            afterAverage: afterAverage,
            metrics: cleaningPreviewMetrics(
                before: beforeSamples,
                after: afterSamples,
                artifact: artifactSamples,
                channelIndices: channels
            ),
            channelRemovedEnergy: cleaningPreviewChannelEnergy(
                before: beforeSamples,
                artifact: artifactSamples,
                channelIndices: channels
            ),
            startTimeSeconds: Double(startSample) / signal.samplingRate,
            endTimeSeconds: Double(endSample) / signal.samplingRate
        )
    }

    // MARK: - Wavelet preparation

    private struct ChannelWaveletData {
        var channelIndex: Int
        var samples: [Float]
        var details: [[Float]]
        var artifactDetails: [[Float]]
        var signedSalience: [Float]
        var energySalience: [Float]
        var totalEnergyByLevel: [Double]
        var artifactEnergyByLevel: [Double]
    }

    private struct ExemplarWindow {
        var start: Int
        var end: Int
        var length: Int
        var centerOriginalSample: Int
    }

    private struct WaveletFeatureVector {
        var series: [Float]
        var template: [Float]
        var weight: Float
    }

    private static func prepareChannels(
        signal: MFFSignalData,
        channelIndices: [Int],
        decimation: Int,
        levelCount: Int,
        thresholdScale: Double,
        waveletFamily: WaveletCleaningFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel,
        progress: ((Int, Int, Int) -> Void)? = nil
    ) -> [ChannelWaveletData] {
        guard !channelIndices.isEmpty else { return [] }
        let workerCount = waveletWorkerCount(for: channelIndices.count)
        if workerCount == 1 {
            return channelIndices.enumerated().compactMap { offset, channelIndex in
                let data = prepareChannel(
                    signal: signal,
                    channelIndex: channelIndex,
                    decimation: decimation,
                    levelCount: levelCount,
                    thresholdScale: thresholdScale,
                    waveletFamily: waveletFamily,
                    thresholdRule: thresholdRule,
                    thresholdModel: thresholdModel
                )
                progress?(offset + 1, channelIndex, channelIndices.count)
                return data
            }
        }

        var results = Array<ChannelWaveletData?>(repeating: nil, count: channelIndices.count)
        var completedCount = 0
        let resultLock = NSLock()
        let progressLock = NSLock()

        evaConcurrentPerform(iterations: workerCount) { workerIndex in
            var offset = workerIndex
            while offset < channelIndices.count {
                let channelIndex = channelIndices[offset]
                let data = prepareChannel(
                    signal: signal,
                    channelIndex: channelIndex,
                    decimation: decimation,
                    levelCount: levelCount,
                    thresholdScale: thresholdScale,
                    waveletFamily: waveletFamily,
                    thresholdRule: thresholdRule,
                    thresholdModel: thresholdModel
                )

                resultLock.lock()
                results[offset] = data
                resultLock.unlock()

                progressLock.lock()
                completedCount += 1
                let finished = completedCount
                progressLock.unlock()

                progress?(finished, channelIndex, channelIndices.count)
                offset += workerCount
            }
        }

        return results.compactMap { $0 }
    }

    private static func waveletWorkerCount(for channelCount: Int) -> Int {
        min(evaMaxWorkers, max(channelCount, 1))
    }

    private static func prepareChannel(
        signal: MFFSignalData,
        channelIndex: Int,
        decimation: Int,
        levelCount: Int,
        thresholdScale: Double,
        waveletFamily: WaveletCleaningFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel
    ) -> ChannelWaveletData? {
        guard signal.data.indices.contains(channelIndex) else { return nil }
        let samples = downsampleAndDemean(signal.data[channelIndex], by: decimation)
        guard samples.count > 2 else { return nil }
        let decomposition = undecimatedDetails(
            samples,
            levelCount: levelCount,
            thresholdScale: thresholdScale,
            waveletFamily: waveletFamily,
            thresholdRule: thresholdRule,
            thresholdModel: thresholdModel
        )
        var signedSalience = [Float](repeating: 0, count: samples.count)
        var energySalience = [Float](repeating: 0, count: samples.count)
        var totalEnergyByLevel = [Double](repeating: 0, count: decomposition.details.count)
        var artifactEnergyByLevel = [Double](repeating: 0, count: decomposition.details.count)

        for level in decomposition.details.indices {
            let detail = decomposition.details[level]
            let artifact = decomposition.artifactDetails[level]
            for sample in detail.indices {
                let detailValue = Double(detail[sample])
                let artifactValue = Double(artifact[sample])
                totalEnergyByLevel[level] += detailValue * detailValue
                artifactEnergyByLevel[level] += artifactValue * artifactValue
                signedSalience[sample] += artifact[sample]
                energySalience[sample] += abs(artifact[sample])
            }
        }

        return ChannelWaveletData(
            channelIndex: channelIndex,
            samples: samples,
            details: decomposition.details,
            artifactDetails: decomposition.artifactDetails,
            signedSalience: signedSalience,
            energySalience: energySalience,
            totalEnergyByLevel: totalEnergyByLevel,
            artifactEnergyByLevel: artifactEnergyByLevel
        )
    }

    private static func undecimatedDetails(
        _ samples: [Float],
        levelCount: Int,
        thresholdScale: Double,
        waveletFamily: WaveletCleaningFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel
    ) -> (details: [[Float]], artifactDetails: [[Float]]) {
        var smooth = samples
        var details: [[Float]] = []
        var artifactDetails: [[Float]] = []
        details.reserveCapacity(levelCount)
        artifactDetails.reserveCapacity(levelCount)
        let kernel = smoothingKernel(for: waveletFamily)

        for level in 0..<levelCount {
            let step = 1 << level
            var low = [Float](repeating: 0, count: smooth.count)
            var detail = [Float](repeating: 0, count: smooth.count)

            for index in smooth.indices {
                low[index] = smoothedValue(smooth, at: index, step: step, kernel: kernel)
                detail[index] = smooth[index] - low[index]
            }

            let threshold = coefficientThreshold(for: detail, model: thresholdModel) * Float(max(thresholdScale, 0.05))
            let artifacts = detail.map { thresholdCoefficient($0, threshold: threshold, rule: thresholdRule) }
            details.append(detail)
            artifactDetails.append(artifacts)
            smooth = low
        }

        return (details, artifactDetails)
    }

    private static func thresholdCoefficient(
        _ value: Float,
        threshold: Float,
        rule: WaveletCleaningThresholdRule
    ) -> Float {
        guard abs(value) >= threshold else { return 0 }
        switch rule {
        case .hard:
            return value
        case .soft:
            return value.sign == .minus
                ? -(abs(value) - threshold)
                : abs(value) - threshold
        }
    }

    private static func smoothingKernel(for family: WaveletCleaningFamily) -> [Float] {
        let coefficients: [Float]
        switch family {
        case .bior44:
            coefficients = [
                0.0378284555, -0.0238494650, -0.1106244044,
                0.3774028556, 0.8526986790, 0.3774028556,
                -0.1106244044, -0.0238494650, 0.0378284555
            ]
        case .coif4:
            coefficients = [
                -0.0000017850, -0.0000032597, 0.0000312299, 0.0000623390,
                -0.0002599746, -0.0005890208, 0.0012665619, 0.0037514362,
                -0.0056582867, -0.0152117315, 0.0250822618, 0.0393344271,
                -0.0962204420, -0.0666274743, 0.4343860565, 0.7822389309,
                0.4153084070, -0.0560773133, -0.0812666997, 0.0266823002,
                0.0160689440, -0.0073461663, -0.0016294920, 0.0008923137
            ]
        }

        let sum = coefficients.reduce(Float(0), +)
        guard abs(sum) > 1e-12 else { return [0.25, 0.5, 0.25] }
        return coefficients.map { $0 / sum }
    }

    private static func smoothedValue(
        _ samples: [Float],
        at index: Int,
        step: Int,
        kernel: [Float]
    ) -> Float {
        guard !samples.isEmpty, !kernel.isEmpty else { return 0 }
        let center = kernel.count / 2
        var sum: Float = 0
        for offset in kernel.indices {
            let sampleIndex = clamped(
                index + (offset - center) * step,
                lower: 0,
                upper: samples.count - 1
            )
            sum += kernel[offset] * samples[sampleIndex]
        }
        return sum
    }

    private static func coefficientThreshold(
        for values: [Float],
        model: WaveletCleaningThresholdModel
    ) -> Float {
        guard values.count > 2 else { return 0 }
        let sigma = robustSigma(values)
        let universalThreshold: Float
        if sigma > 1e-12 {
            universalThreshold = sigma * Float(sqrt(2 * log(Double(max(values.count, 2)))))
        } else {
            let rmsValue = rms(values)
            universalThreshold = rmsValue > 0 ? rmsValue * 2.5 : 0
        }

        guard model == .bayesShrink, sigma > 1e-12 else {
            return universalThreshold
        }

        let observedVariance = variance(values)
        let noiseVariance = Double(sigma * sigma)
        let signalVariance = max(observedVariance - noiseVariance, 0)
        guard signalVariance > 1e-12 else {
            return universalThreshold
        }

        let bayesThreshold = Float(noiseVariance / sqrt(signalVariance))
        guard bayesThreshold.isFinite, bayesThreshold > 0 else {
            return universalThreshold
        }

        let lowerBound = sigma * 0.25
        return min(universalThreshold, max(bayesThreshold, lowerBound))
    }

    private static func robustSigma(_ values: [Float]) -> Float {
        let stride = max(values.count / 4_000, 1)
        var absValues: [Float] = []
        absValues.reserveCapacity(values.count / stride + 1)
        for index in Swift.stride(from: 0, to: values.count, by: stride) {
            let value = values[index]
            if value.isFinite {
                absValues.append(abs(value))
            }
        }
        guard !absValues.isEmpty else { return 0 }
        absValues.sort()
        return percentile(absValues, fraction: 0.5) / 0.6745
    }

    // MARK: - Waveform matching

    private static func detectWaveform(
        data: [ChannelWaveletData],
        channelIndices: [Int],
        exemplar: ExemplarWindow,
        sampleCount: Int,
        samplingRate: Double,
        decimation: Int,
        configuration: WaveletArtifactConfiguration
    ) -> (events: [MFFEvent], summary: WaveletArtifactScoreSummary?) {
        let selectedData = channelIndices.compactMap { requested in
            data.first { $0.channelIndex == requested }
        }
        guard !selectedData.isEmpty,
              exemplar.length >= 3,
              let analyzedCount = selectedData.first?.samples.count,
              exemplar.end <= analyzedCount else {
            return ([], nil)
        }

        var vectors: [WaveletFeatureVector] = []
        for channel in selectedData {
            for level in channel.details.indices {
                let artifactSeries = channel.artifactDetails[level]
                let templateArtifact = Array(artifactSeries[exemplar.start..<exemplar.end])
                let series: [Float]
                let templateOriginal: [Float]
                if vectorEnergy(templateArtifact) > 1e-12 {
                    series = artifactSeries
                    templateOriginal = templateArtifact
                } else {
                    series = channel.details[level]
                    templateOriginal = Array(series[exemplar.start..<exemplar.end])
                }
                let normalizedTemplate = normalized(templateOriginal).normalized
                let weight = max(rms(templateOriginal), 0.0001)
                guard normalizedTemplate.count == exemplar.length else { continue }
                vectors.append(WaveletFeatureVector(
                    series: series,
                    template: normalizedTemplate,
                    weight: weight
                ))
            }
        }
        guard !vectors.isEmpty else { return ([], nil) }

        let projection = selectedData.reduce(into: [Float](repeating: 0, count: analyzedCount)) { partial, channel in
            for sample in channel.energySalience.indices {
                partial[sample] += channel.energySalience[sample]
            }
        }
        let candidates = candidateStarts(
            projection: projection,
            templateLength: exemplar.length
        )
        let totalWeight = max(vectors.reduce(Float(0)) { $0 + $1.weight }, 0.0001)
        let mergeSamples = max(Int((configuration.mergeWindowSeconds * samplingRate / Double(decimation)).rounded()), 1)
        var hits: [(start: Int, score: Float)] = []

        for start in candidates where start >= 0 && start + exemplar.length <= analyzedCount {
            var weightedScore: Float = 0
            for vector in vectors {
                let window = normalized(Array(vector.series[start..<(start + exemplar.length)])).normalized
                guard window.count == exemplar.length else { continue }
                var dot: Float = 0
                for offset in window.indices {
                    dot += vector.template[offset] * window[offset]
                }
                let score: Float
                switch configuration.polarity {
                case .same:
                    score = dot
                case .opposite:
                    score = -dot
                case .either:
                    score = abs(dot)
                }
                weightedScore += score * vector.weight
            }

            let score = weightedScore / totalWeight
            if Double(score) >= configuration.matchThreshold {
                hits.append((start, score))
            }
        }

        let merged = SignalSelection.mergeNearbyStarts(hits, mergeSamples: mergeSamples)
        let events = eventsFromHits(
            merged,
            templateLength: exemplar.length,
            sampleCount: sampleCount,
            samplingRate: samplingRate,
            decimation: decimation,
            eventCode: configuration.eventCode,
            idPrefix: "artifact-wavelet-waveform",
            sourceLabel: "Wavelet waveform",
            threshold: configuration.matchThreshold
        )
        return (events, scoreSummary(candidates: candidates, hits: merged))
    }

    // MARK: - Topography trajectory matching

    private static func detectTopographyTrajectory(
        signal: MFFSignalData,
        data: [ChannelWaveletData],
        channelIndices: [Int],
        exemplar: ExemplarWindow,
        sampleCount: Int,
        samplingRate: Double,
        decimation: Int,
        configuration: WaveletArtifactConfiguration
    ) -> (events: [MFFEvent], reference: ArtifactTemplateTopography?, summary: WaveletArtifactScoreSummary?) {
        let channels = channelIndices.compactMap { requested in
            data.first { $0.channelIndex == requested }
        }
        guard channels.count >= 3,
              exemplar.length >= 3,
              let analyzedCount = channels.first?.samples.count,
              exemplar.end <= analyzedCount else {
            return ([], nil, nil)
        }

        let trajectoryStride = max(exemplar.length / 64, 1)
        var templateMaps: [(offset: Int, values: [Float])] = []
        for offset in Swift.stride(from: 0, to: exemplar.length, by: trajectoryStride) {
            let sample = exemplar.start + offset
            let map = normalizedSpatial(channels.map { $0.signedSalience[sample] })
            if !map.isEmpty {
                templateMaps.append((offset, map))
            }
        }
        guard !templateMaps.isEmpty else { return ([], nil, nil) }

        let projection = channels.reduce(into: [Float](repeating: 0, count: analyzedCount)) { partial, channel in
            for sample in channel.energySalience.indices {
                partial[sample] += channel.energySalience[sample]
            }
        }
        let candidates = candidateStarts(
            projection: projection,
            templateLength: exemplar.length
        )
        let mergeSamples = max(Int((configuration.mergeWindowSeconds * samplingRate / Double(decimation)).rounded()), 1)
        var hits: [(start: Int, score: Float)] = []

        for start in candidates where start >= 0 && start + exemplar.length <= analyzedCount {
            var scoreSum: Float = 0
            var scoreCount: Float = 0
            for templateMap in templateMaps {
                let sample = start + templateMap.offset
                let candidateMap = normalizedSpatial(channels.map { $0.signedSalience[sample] })
                guard candidateMap.count == templateMap.values.count else { continue }
                var dot: Float = 0
                for index in candidateMap.indices {
                    dot += templateMap.values[index] * candidateMap[index]
                }
                let score: Float
                switch configuration.topographyMetric {
                case .pearson:
                    score = dot
                case .negativePearson:
                    score = -dot
                case .absolutePearson:
                    score = abs(dot)
                }
                scoreSum += score
                scoreCount += 1
            }
            guard scoreCount > 0 else { continue }
            let score = scoreSum / scoreCount
            if Double(score) >= configuration.matchThreshold {
                hits.append((start, score))
            }
        }

        let merged = SignalSelection.mergeNearbyStarts(hits, mergeSamples: mergeSamples)
        let events = eventsFromHits(
            merged,
            templateLength: exemplar.length,
            sampleCount: sampleCount,
            samplingRate: samplingRate,
            decimation: decimation,
            eventCode: configuration.eventCode,
            idPrefix: "artifact-wavelet-topography",
            sourceLabel: "Wavelet topography",
            threshold: configuration.matchThreshold
        )
        let channelValues = waveletTopographyValues(
            channelCount: signal.numberOfChannels,
            channels: channels,
            exemplar: exemplar
        )
        let reference = ArtifactTemplateTopography(
            mode: .average,
            referenceSample: exemplar.centerOriginalSample,
            referenceTimeSeconds: Double(exemplar.centerOriginalSample) / samplingRate,
            channelValues: channelValues,
            channelIndices: channelIndices,
            matchThreshold: configuration.matchThreshold,
            matchCount: events.count
        )
        return (events, reference, scoreSummary(candidates: candidates, hits: merged))
    }

    private static func waveletTopographyValues(
        channelCount: Int,
        channels: [ChannelWaveletData],
        exemplar: ExemplarWindow
    ) -> [Float] {
        var values = [Float](repeating: 0, count: channelCount)
        let count = max(exemplar.end - exemplar.start, 1)
        for channel in channels {
            guard values.indices.contains(channel.channelIndex),
                  exemplar.end <= channel.signedSalience.count else {
                continue
            }
            var sum: Float = 0
            for sample in exemplar.start..<exemplar.end {
                sum += channel.signedSalience[sample]
            }
            values[channel.channelIndex] = sum / Float(count)
        }
        return values
    }

    // MARK: - Features

    private static func featureSummary(
        from data: [ChannelWaveletData],
        effectiveSamplingRate: Double
    ) -> WaveletArtifactFeatureSummary {
        guard !data.isEmpty else {
            return emptySummary(effectiveSamplingRate: effectiveSamplingRate)
        }

        let levelCount = data.map(\.artifactEnergyByLevel.count).max() ?? 0
        var totalEnergyByLevel = [Double](repeating: 0, count: levelCount)
        var artifactEnergyByLevel = [Double](repeating: 0, count: levelCount)

        var channelSummaries: [WaveletArtifactChannelSummary] = []
        channelSummaries.reserveCapacity(data.count)

        for channel in data {
            for level in channel.totalEnergyByLevel.indices {
                totalEnergyByLevel[level] += channel.totalEnergyByLevel[level]
                artifactEnergyByLevel[level] += channel.artifactEnergyByLevel[level]
            }
            let channelTotal = channel.totalEnergyByLevel.reduce(0, +)
            let channelArtifact = channel.artifactEnergyByLevel.reduce(0, +)
            let dominantOffset = channel.artifactEnergyByLevel.indices.max {
                channel.artifactEnergyByLevel[$0] < channel.artifactEnergyByLevel[$1]
            } ?? 0
            channelSummaries.append(WaveletArtifactChannelSummary(
                channelIndex: channel.channelIndex,
                artifactEnergyFraction: safeFraction(channelArtifact, channelTotal),
                peakArtifactMagnitude: channel.energySalience.map(abs).max() ?? 0,
                dominantLevel: dominantOffset + 1
            ))
        }

        let levelSummaries = (0..<levelCount).map { offset in
            WaveletArtifactLevelSummary(
                level: offset + 1,
                artifactEnergyFraction: safeFraction(artifactEnergyByLevel[offset], totalEnergyByLevel[offset]),
                centerFrequencyHz: effectiveSamplingRate / pow(2, Double(offset + 2))
            )
        }

        let totalEnergy = totalEnergyByLevel.reduce(0, +)
        let artifactEnergy = artifactEnergyByLevel.reduce(0, +)
        return WaveletArtifactFeatureSummary(
            channelCount: data.count,
            levelCount: levelCount,
            analyzedSampleCount: data.first?.samples.count ?? 0,
            effectiveSamplingRate: effectiveSamplingRate,
            artifactEnergyFraction: safeFraction(artifactEnergy, totalEnergy),
            strongestChannels: channelSummaries.sorted {
                if $0.peakArtifactMagnitude == $1.peakArtifactMagnitude {
                    return $0.channelIndex < $1.channelIndex
                }
                return $0.peakArtifactMagnitude > $1.peakArtifactMagnitude
            },
            levelSummaries: levelSummaries
        )
    }

    private static func emptySummary(effectiveSamplingRate: Double) -> WaveletArtifactFeatureSummary {
        WaveletArtifactFeatureSummary(
            channelCount: 0,
            levelCount: 0,
            analyzedSampleCount: 0,
            effectiveSamplingRate: effectiveSamplingRate,
            artifactEnergyFraction: 0,
            strongestChannels: [],
            levelSummaries: []
        )
    }

    // MARK: - Cleaning preview

    private static func reconstructedArtifactSignal(
        _ samples: [Float],
        levelCount: Int,
        thresholdScale: Double,
        waveletFamily: WaveletCleaningFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel
    ) -> [Float] {
        guard samples.count > 2 else { return [Float](repeating: 0, count: samples.count) }
        let centered = demean(samples)
        let decomposition = undecimatedDetails(
            centered,
            levelCount: levelCount,
            thresholdScale: thresholdScale,
            waveletFamily: waveletFamily,
            thresholdRule: thresholdRule,
            thresholdModel: thresholdModel
        )
        var artifact = [Float](repeating: 0, count: samples.count)
        for level in decomposition.artifactDetails {
            for index in 0..<min(artifact.count, level.count) {
                artifact[index] += level[index]
            }
        }
        return artifact
    }

    private static func averageFromSamples(
        _ samples: [[Float]],
        selectedChannelIndices: [Int],
        samplingRate: Double
    ) -> ArtifactTemplateAverage {
        let summaries = samples.indices.map { channelIndex in
            let channelSamples = samples[channelIndex]
            return ArtifactTemplateChannelSummary(
                channelIndex: channelIndex,
                peakAbsoluteMicrovolts: channelSamples.map(abs).max() ?? 0,
                rmsMicrovolts: rms(channelSamples)
            )
        }
        .sorted {
            if $0.peakAbsoluteMicrovolts == $1.peakAbsoluteMicrovolts {
                return $0.channelIndex < $1.channelIndex
            }
            return $0.peakAbsoluteMicrovolts > $1.peakAbsoluteMicrovolts
        }

        return ArtifactTemplateAverage(
            samplingRate: samplingRate,
            windowSizeSeconds: Double(samples.first?.count ?? 0) / max(samplingRate, 1),
            eventCount: 1,
            selectedChannelIndices: selectedChannelIndices,
            allChannelSamples: samples,
            channelSummaries: summaries
        )
    }

    private static func cleaningPreviewMetrics(
        before: [[Float]],
        after: [[Float]],
        artifact: [[Float]],
        channelIndices: [Int]
    ) -> WaveletCleaningPreviewMetrics {
        let validChannels = channelIndices.filter {
            before.indices.contains($0) && after.indices.contains($0) && artifact.indices.contains($0)
        }
        let beforeValues = validChannels.flatMap { before[$0] }
        let afterValues = validChannels.flatMap { after[$0] }
        let artifactValues = validChannels.flatMap { artifact[$0] }

        let beforeVariance = variance(beforeValues)
        let afterVariance = variance(afterValues)
        let beforePeak = beforeValues.map(abs).max() ?? 0
        let afterPeak = afterValues.map(abs).max() ?? 0
        let peakReduction = beforePeak > 1e-9
            ? Double(max(beforePeak - afterPeak, 0) / beforePeak) * 100
            : 0

        return WaveletCleaningPreviewMetrics(
            varianceRetainedPercent: beforeVariance > 1e-12 ? afterVariance / beforeVariance * 100 : 0,
            correlation: correlation(beforeValues, afterValues),
            removedRMSMicrovolts: Double(rms(artifactValues)),
            peakReductionPercent: peakReduction
        )
    }

    private static func cleaningPreviewChannelEnergy(
        before: [[Float]],
        artifact: [[Float]],
        channelIndices: [Int]
    ) -> [WaveletCleaningChannelEnergy] {
        let validChannels = channelIndices.filter {
            before.indices.contains($0) && artifact.indices.contains($0)
        }
        guard !validChannels.isEmpty else { return [] }

        var energies: [WaveletCleaningChannelEnergy] = []
        energies.reserveCapacity(validChannels.count)
        for channelIndex in validChannels {
            let beforeEnergy = vectorEnergy(before[channelIndex])
            let removedEnergy = vectorEnergy(artifact[channelIndex])
            let removedRMS = Double(rms(artifact[channelIndex]))
            let peakRemoved = artifact[channelIndex].map(abs).max() ?? 0
            energies.append(WaveletCleaningChannelEnergy(
                channelIndex: channelIndex,
                removedRMSMicrovolts: removedRMS,
                removedEnergyFraction: beforeEnergy > 1e-12 ? removedEnergy / beforeEnergy : 0,
                peakRemovedMicrovolts: peakRemoved,
                normalizedRemovedEnergy: 0
            ))
        }

        let maxEnergy = max(energies.map { $0.removedRMSMicrovolts * $0.removedRMSMicrovolts }.max() ?? 0, 1e-12)
        return energies.map { energy in
            var energy = energy
            let removedEnergy = energy.removedRMSMicrovolts * energy.removedRMSMicrovolts
            energy.normalizedRemovedEnergy = min(max(removedEnergy / maxEnergy, 0), 1)
            return energy
        }
    }

    // MARK: - Explorer candidates

    private static func explorerProjection(from data: [ChannelWaveletData]) -> [Float] {
        guard let sampleCount = data.first?.energySalience.count, sampleCount > 0 else { return [] }
        var projection = [Float](repeating: 0, count: sampleCount)

        for channel in data {
            let scale = explorerChannelScale(channel.energySalience)
            guard scale > 1e-12 else { continue }
            for sample in 0..<min(sampleCount, channel.energySalience.count) {
                projection[sample] += channel.energySalience[sample] / scale
            }
        }

        let divisor = Float(max(data.count, 1))
        return projection.map { $0 / divisor }
    }

    private static func explorerChannelScale(_ values: [Float]) -> Float {
        let sampled = sampledFiniteValues(values).filter { $0 > 0 }.sorted()
        guard !sampled.isEmpty else { return 0 }
        return max(percentile(sampled, fraction: 0.95), 1e-9)
    }

    private static func channelBurstFraction(_ channel: ChannelWaveletData) -> Double {
        let sampled = sampledFiniteValues(channel.energySalience).filter { $0 > 0 }.sorted()
        guard !sampled.isEmpty else { return 0 }
        let medianValue = percentile(sampled, fraction: 0.50)
        let highValue = percentile(sampled, fraction: 0.95)
        let threshold = max(medianValue + (highValue - medianValue) * 0.75, 1e-9)
        let burstCount = channel.energySalience.filter { $0 >= threshold }.count
        return Double(burstCount) / Double(max(channel.energySalience.count, 1))
    }

    private static func medianPositive(_ values: [Double], fallback: Double) -> Double {
        let finite = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !finite.isEmpty else { return fallback }
        let position = 0.5 * Double(finite.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, finite.count - 1)
        let weight = position - Double(lower)
        return max(finite[lower] * (1 - weight) + finite[upper] * weight, fallback)
    }

    private static func explorerCandidateThreshold(for projection: [Float]) -> Float {
        let sampled = sampledFiniteValues(projection).sorted()
        guard !sampled.isEmpty else { return 0 }
        let medianValue = percentile(sampled, fraction: 0.50)
        let highValue = percentile(sampled, fraction: 0.985)
        let positiveValues = sampled.filter { $0 > 0 }
        if positiveValues.isEmpty {
            return max(highValue, 0.0001)
        }
        let positiveMedian = percentile(positiveValues, fraction: 0.50)
        let positiveHigh = percentile(positiveValues, fraction: 0.95)
        return max(highValue, positiveMedian + (positiveHigh - positiveMedian) * 0.75, medianValue + 0.0001)
    }

    private static func explorerCandidates(
        projection: [Float],
        threshold: Float,
        data: [ChannelWaveletData],
        sampleCount: Int,
        samplingRate: Double,
        decimation: Int,
        minimumDurationSamples: Int,
        mergeSamples: Int,
        maximumCandidates: Int
    ) -> [WaveletArtifactCandidate] {
        guard !projection.isEmpty, threshold > 0, samplingRate > 0 else { return [] }

        var ranges: [(start: Int, end: Int, peak: Int, peakValue: Float)] = []
        var index = 0
        while index < projection.count {
            guard projection[index] >= threshold else {
                index += 1
                continue
            }

            let start = index
            var end = index
            var peak = index
            var peakValue = projection[index]
            while end + 1 < projection.count, projection[end + 1] >= threshold {
                end += 1
                if projection[end] > peakValue {
                    peak = end
                    peakValue = projection[end]
                }
            }

            if end - start + 1 >= minimumDurationSamples {
                ranges.append((start, end, peak, peakValue))
            }
            index = end + 1
        }

        let mergedRanges = mergeExplorerRanges(ranges, mergeSamples: mergeSamples)
        let ranked = mergedRanges.sorted {
            if $0.peakValue == $1.peakValue {
                return $0.peak < $1.peak
            }
            return $0.peakValue > $1.peakValue
        }
        .prefix(maximumCandidates)

        return ranked.enumerated().map { offset, range in
            let peakMetadata = explorerPeakMetadata(at: range.peak, data: data, threshold: threshold)
            let startSample = min(max(range.start * decimation, 0), max(sampleCount - 1, 0))
            let endSample = min(max((range.end + 1) * decimation - 1, startSample), max(sampleCount - 1, 0))
            let peakSample = min(max(range.peak * decimation, startSample), endSample)
            let durationSeconds = Double(max(endSample - startSample + 1, 1)) / samplingRate
            let peakTime = Double(peakSample) / samplingRate
            return WaveletArtifactCandidate(
                id: "wavelet-explorer-\(offset + 1)-\(peakSample)",
                rank: offset + 1,
                startSample: startSample,
                endSample: endSample,
                peakSample: peakSample,
                startTimeSeconds: Double(startSample) / samplingRate,
                endTimeSeconds: Double(endSample) / samplingRate,
                peakTimeSeconds: peakTime,
                durationSeconds: durationSeconds,
                score: Double(range.peakValue),
                peakEnergy: Double(peakMetadata.peakEnergy),
                channelIndex: peakMetadata.channelIndex,
                dominantLevel: peakMetadata.dominantLevel,
                contributingChannelCount: peakMetadata.contributingChannelCount
            )
        }
    }

    private static func mergeExplorerRanges(
        _ ranges: [(start: Int, end: Int, peak: Int, peakValue: Float)],
        mergeSamples: Int
    ) -> [(start: Int, end: Int, peak: Int, peakValue: Float)] {
        guard !ranges.isEmpty else { return [] }
        var merged: [(start: Int, end: Int, peak: Int, peakValue: Float)] = []
        for range in ranges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            if range.start - last.end <= mergeSamples {
                var combined = last
                combined.end = max(last.end, range.end)
                if range.peakValue > last.peakValue {
                    combined.peak = range.peak
                    combined.peakValue = range.peakValue
                }
                merged[merged.count - 1] = combined
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func explorerPeakMetadata(
        at sample: Int,
        data: [ChannelWaveletData],
        threshold: Float
    ) -> (channelIndex: Int, dominantLevel: Int, peakEnergy: Float, contributingChannelCount: Int) {
        var channelIndex = data.first?.channelIndex ?? 0
        var dominantLevel = 1
        var peakEnergy: Float = 0
        var contributingChannels = 0

        for channel in data where channel.energySalience.indices.contains(sample) {
            let energy = channel.energySalience[sample]
            if energy >= threshold * 0.25 {
                contributingChannels += 1
            }
            guard energy > peakEnergy else { continue }
            peakEnergy = energy
            channelIndex = channel.channelIndex
            let level = channel.artifactDetails.indices.max {
                abs(channel.artifactDetails[$0][sample]) < abs(channel.artifactDetails[$1][sample])
            } ?? 0
            dominantLevel = level + 1
        }

        return (channelIndex, dominantLevel, peakEnergy, contributingChannels)
    }

    private static func sampledFiniteValues(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let stride = max(values.count / 8_000, 1)
        var sampled: [Float] = []
        sampled.reserveCapacity(values.count / stride + 1)
        for index in Swift.stride(from: 0, to: values.count, by: stride) {
            let value = values[index]
            if value.isFinite {
                sampled.append(value)
            }
        }
        return sampled
    }

    // MARK: - Event and average helpers

    private static func eventsFromHits(
        _ hits: [(start: Int, score: Float)],
        templateLength: Int,
        sampleCount: Int,
        samplingRate: Double,
        decimation: Int,
        eventCode: String,
        idPrefix: String,
        sourceLabel: String,
        threshold: Double
    ) -> [MFFEvent] {
        hits.enumerated().map { index, hit in
            let centerSample = min(max((hit.start + templateLength / 2) * decimation, 0), sampleCount - 1)
            let time = Double(centerSample) / samplingRate
            return MFFEvent(
                id: "\(idPrefix)-\(index)-\(centerSample)",
                code: eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: String(format: "\(sourceLabel) %.0f%%", threshold * 100)
            )
        }
    }

    private static func average(
        signal: MFFSignalData,
        events: [MFFEvent],
        selectedChannelIndices: [Int],
        windowSamples: Int
    ) -> ArtifactTemplateAverage? {
        guard !events.isEmpty,
              windowSamples > 1,
              let sampleCount = signal.data.first?.count,
              sampleCount >= windowSamples else {
            return nil
        }

        var averages = Array(repeating: [Float](repeating: 0, count: windowSamples), count: signal.numberOfChannels)
        var accepted = 0
        for event in events {
            let center = Int((event.beginTimeSeconds * signal.samplingRate).rounded())
            let start = center - windowSamples / 2
            let end = start + windowSamples
            guard start >= 0, end <= sampleCount else { continue }

            for channelIndex in signal.data.indices where signal.data[channelIndex].count >= end {
                for offset in 0..<windowSamples {
                    averages[channelIndex][offset] += signal.data[channelIndex][start + offset]
                }
            }
            accepted += 1
        }

        guard accepted > 0 else { return nil }
        let divisor = Float(accepted)
        for channel in averages.indices {
            for sample in averages[channel].indices {
                averages[channel][sample] /= divisor
            }
        }

        let summaries = averages.indices.map { channelIndex in
            let samples = averages[channelIndex]
            return ArtifactTemplateChannelSummary(
                channelIndex: channelIndex,
                peakAbsoluteMicrovolts: samples.map(abs).max() ?? 0,
                rmsMicrovolts: rms(samples)
            )
        }
        .sorted {
            if $0.peakAbsoluteMicrovolts == $1.peakAbsoluteMicrovolts {
                return $0.channelIndex < $1.channelIndex
            }
            return $0.peakAbsoluteMicrovolts > $1.peakAbsoluteMicrovolts
        }

        return ArtifactTemplateAverage(
            samplingRate: signal.samplingRate,
            windowSizeSeconds: Double(windowSamples) / signal.samplingRate,
            eventCount: accepted,
            selectedChannelIndices: selectedChannelIndices,
            allChannelSamples: averages,
            channelSummaries: summaries
        )
    }

    // MARK: - Matching helpers

    private static func exemplarWindow(
        range: ClosedRange<Int>,
        windowSeconds: Double,
        sampleCount: Int,
        samplingRate: Double,
        decimation: Int
    ) -> ExemplarWindow {
        let boundedLower = min(max(range.lowerBound, 0), max(sampleCount - 1, 0))
        let boundedUpper = min(max(range.upperBound, boundedLower), max(sampleCount - 1, 0))
        let center = (boundedLower + boundedUpper) / 2
        let windowSamples = max(Int((windowSeconds * samplingRate / Double(decimation)).rounded()), 3)
        let analyzedCount = max(sampleCount / decimation, 1)
        let centerDownsampled = min(max(center / decimation, 0), max(analyzedCount - 1, 0))
        let start = min(max(centerDownsampled - windowSamples / 2, 0), max(analyzedCount - windowSamples, 0))
        let end = min(start + windowSamples, analyzedCount)
        return ExemplarWindow(
            start: start,
            end: end,
            length: max(end - start, 0),
            centerOriginalSample: center
        )
    }

    private static func candidateStarts(
        projection: [Float],
        templateLength: Int
    ) -> [Int] {
        guard projection.count >= templateLength, templateLength >= 3 else { return [] }
        let mean = projection.reduce(Float(0), +) / Float(max(projection.count, 1))
        let variance = projection.reduce(Float(0)) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Float(max(projection.count, 1))
        let threshold = mean + max(sqrt(variance) * 1.25, 0.0001)
        let minimumDistance = max(templateLength / 3, 1)

        var candidates: [Int] = []
        var lastAccepted = -minimumDistance
        for sample in 1..<(max(projection.count - 1, 1)) {
            guard projection[sample] >= threshold,
                  projection[sample] >= projection[sample - 1],
                  projection[sample] >= projection[sample + 1],
                  sample - lastAccepted >= minimumDistance else {
                continue
            }
            candidates.append(min(max(sample - templateLength / 2, 0), projection.count - templateLength))
            lastAccepted = sample
        }

        if candidates.count < 12 {
            let fallbackStride = max(templateLength / 4, 1)
            candidates = Array(Swift.stride(from: 0, through: projection.count - templateLength, by: fallbackStride))
        }

        return Array(Set(candidates)).sorted()
    }

    private static func scoreSummary(
        candidates: [Int],
        hits: [(start: Int, score: Float)]
    ) -> WaveletArtifactScoreSummary {
        let scores = hits.map { Double($0.score) }.sorted()
        return WaveletArtifactScoreSummary(
            candidateCount: candidates.count,
            matchCount: hits.count,
            bestScore: scores.last ?? 0,
            medianMatchScore: median(scores)
        )
    }

    // MARK: - Small math helpers

    private static func decimationFactor(samplingRate: Double, targetRate: Double) -> Int {
        Downsampler.factor(sourceRate: samplingRate, targetRate: targetRate)
    }

    private static func boundedLevelCount(_ requested: Int, sampleCount: Int) -> Int {
        let maximumBySamples = max(Int(floor(log2(Double(max(sampleCount, 2))))) - 1, 1)
        return min(max(requested, 1), maximumLevelCount, maximumBySamples)
    }

    private static func downsampleAndDemean(_ samples: [Float], by decimation: Int) -> [Float] {
        let values = Downsampler.strided(samples, by: max(decimation, 1)).map { $0.isFinite ? $0 : 0 }
        return demean(values)
    }

    private static func demean(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let mean = samples.reduce(Float(0), +) / Float(samples.count)
        return samples.map { $0 - mean }
    }

    private static func normalized(_ samples: [Float]) -> (original: [Float], normalized: [Float]) {
        guard !samples.isEmpty else { return (samples, []) }
        let mean = samples.reduce(Float(0), +) / Float(samples.count)
        var centered = samples.map { $0 - mean }
        let norm = sqrt(centered.reduce(Float(0)) { $0 + ($1 * $1) })
        guard norm > 1e-12 else { return (samples, []) }
        for index in centered.indices {
            centered[index] /= norm
        }
        return (samples, centered)
    }

    private static func normalizedSpatial(_ values: [Float]) -> [Float] {
        guard values.count >= 3 else { return [] }
        let mean = values.reduce(Float(0), +) / Float(values.count)
        var centered = values.map { $0 - mean }
        let norm = sqrt(centered.reduce(Float(0)) { $0 + ($1 * $1) })
        guard norm > 1e-12 else { return [] }
        for index in centered.indices {
            centered[index] /= norm
        }
        return centered
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + ($1 * $1) }
        return sqrt(sumSquares / Float(samples.count))
    }

    private static func vectorEnergy(_ samples: [Float]) -> Double {
        samples.reduce(0) { $0 + Double($1 * $1) }
    }

    private static func variance(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(Double(0)) { $0 + Double($1) } / Double(samples.count)
        return samples.reduce(Double(0)) { partial, value in
            let delta = Double(value) - mean
            return partial + delta * delta
        } / Double(samples.count)
    }

    private static func correlation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 1 else { return 0 }
        let lhsMean = lhs.prefix(count).reduce(Double(0)) { $0 + Double($1) } / Double(count)
        let rhsMean = rhs.prefix(count).reduce(Double(0)) { $0 + Double($1) } / Double(count)
        var numerator = 0.0
        var lhsDenominator = 0.0
        var rhsDenominator = 0.0
        for index in 0..<count {
            let left = Double(lhs[index]) - lhsMean
            let right = Double(rhs[index]) - rhsMean
            numerator += left * right
            lhsDenominator += left * left
            rhsDenominator += right * right
        }
        let denominator = sqrt(lhsDenominator * rhsDenominator)
        guard denominator > 1e-12 else { return 0 }
        return numerator / denominator
    }

    private static func percentile(_ sortedValues: [Float], fraction: Double) -> Float {
        guard !sortedValues.isEmpty else { return 0 }
        let clampedFraction = min(max(fraction, 0), 1)
        let position = clampedFraction * Double(sortedValues.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sortedValues[lower] }
        let weight = Float(position - Double(lower))
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    private static func safeFraction(_ numerator: Double, _ denominator: Double) -> Double {
        guard denominator > 1e-12 else { return 0 }
        return max(0, min(1, numerator / denominator))
    }

    private static func clamped(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
