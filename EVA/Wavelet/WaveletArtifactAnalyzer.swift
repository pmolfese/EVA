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
    var waveletFamily: WaveletReductionFamily
    var thresholdRule: WaveletCleaningThresholdRule
    var thresholdModel: WaveletCleaningThresholdModel
    var mergeWindowSeconds: Double
    var minimumDurationSeconds: Double
    var maximumCandidates: Int
    /// Runs an extra full-rate pass over the finest levels so muscle/EMG and
    /// other fast transients — which sit above the downsampled pass's Nyquist
    /// and are otherwise invisible to it — still get found. Costs roughly a
    /// second scan.
    var detectsFastArtifacts: Bool = false
    /// Runs the wavelet decomposition on the GPU via `WaveletMetalBackend`.
    /// Falls back to the CPU silently if Metal is unavailable or the dispatch
    /// fails. Results differ slightly from the CPU path — the GPU works in
    /// float where the CPU uses double — so detection is equivalent, not
    /// bit-identical.
    var usesGPU: Bool = false
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
    /// Seconds at each end of the recording that the scan deliberately does
    /// not report candidates in — the transform's circular boundary makes
    /// coefficients there unreliable. Surfaced so "nothing found at the very
    /// start" reads as out of scope rather than as a clean result.
    var edgeMarginSeconds: Double = 0
}

/// Cross-channel spatial pattern of a candidate, classified from which
/// channels contributed and how many. Mirrors the heuristics ADJUST/ICLabel
/// use to separate ocular/muscle/movement artifacts by topography rather
/// than amplitude alone: ocular artifacts are frontal-weighted and coarse
/// (low-frequency), muscle is lateral/temporal-weighted and fine
/// (high-frequency broadband), a single contributing channel with no group
/// pattern is a channel-local artifact (electrode pop, bad contact), and
/// broadband multi-channel evidence with neither weighting is treated as
/// movement/cap-shift.
nonisolated enum WaveletArtifactType: String, Sendable {
    case ocular = "Ocular"
    case muscle = "Muscle"
    case channelLocal = "Channel-local"
    case movement = "Movement"
    case unclassified = "Unclassified"
}

/// Channel groups used to classify a merged event's spatial pattern.
/// `ocular` reuses the same curated per-net-geometry channel table as
/// `EyeArtifactThresholdDetector` (consistent with the rest of the app,
/// rather than a second hand-picked list). `lateral` has no existing table,
/// so it's derived geometrically from `sensorLayout.xml`: the most
/// laterally-displaced channels, a reasonable proxy for temporal/frontal
/// muscle-prone sites when no montage-specific table exists.
///
/// Injectable into `explore(in:configuration:channelRoles:)` so tests (whose
/// synthetic signals have no `sensorLayout.xml` on disk, and would otherwise
/// always get an empty `lateral` set) can drive classification directly.
nonisolated struct WaveletChannelRoles: Sendable {
    var ocular: Set<Int>
    var lateral: Set<Int>

    init(ocular: Set<Int>, lateral: Set<Int>) {
        self.ocular = ocular
        self.lateral = lateral
    }

    static func resolve(for signal: MFFSignalData) -> WaveletChannelRoles {
        let layout = SensorLayout.load(fromPackageContaining: signal.signalURL)
        let ocularIndices = EyeArtifactThresholdDetector.autoOcularChannelIndices(
            kind: .blink,
            channelCount: signal.numberOfChannels,
            sensorLayoutName: layout?.name
        )

        var lateralIndices: Set<Int> = []
        if let positions = layout?.positions, positions.count >= 4 {
            let lateralities = positions.map { abs($0.x) }.sorted()
            let cutoffIndex = min(Int(Double(lateralities.count) * 0.7), lateralities.count - 1)
            let cutoff = lateralities[cutoffIndex]
            lateralIndices = Set(positions.filter { abs($0.x) >= cutoff }.map(\.channelIndex))
        }

        return WaveletChannelRoles(ocular: Set(ocularIndices), lateral: lateralIndices)
    }
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
    var artifactType: WaveletArtifactType
}

nonisolated struct WaveletChannelGoodnessConfiguration: Sendable {
    var channelIndices: [Int]
    var downsampleRate: Double
    var levelCount: Int
    var thresholdScale: Double
    var cleaningMode: WaveletCleaningMode
    var intensity: Double
    var waveletFamily: WaveletReductionFamily
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
            thresholdModel: .robustUniversal,
            effectiveSamplingRate: effectiveRate,
            retention: .full
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
            thresholdModel: .robustUniversal,
            effectiveSamplingRate: effectiveRate,
            retention: .full
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
        channelRoles: WaveletChannelRoles? = nil,
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

        report(0.10, "Resolving channel roles", "Loading net geometry to weight ocular/lateral channel groups for artifact-type classification.")
        let roles = channelRoles ?? WaveletChannelRoles.resolve(for: signal)

        let primary = scanPass(
            signal: signal,
            channels: channels,
            configuration: configuration,
            decimation: decimation,
            levelCount: levelCount,
            roles: roles,
            sampleCount: sampleCount
        ) { completed, channelIndex, total in
            let denominator = max(total, 1)
            let fraction = 0.12 + 0.44 * (Double(completed) / Double(denominator))
            report(
                fraction,
                "Finished Ch \(channelIndex + 1)",
                "Completed \(completed) of \(total) channel decompositions using \(waveletWorkerCount(for: total)) workers: downsampling, demeaning, applying \(configuration.waveletFamily.rawValue) wavelet filters, computing \(levelCount) undecimated detail levels, and retaining \(configuration.thresholdModel.rawValue) outlier coefficients."
            )
        }
        let summary = primary.summary
        let representativeThreshold = primary.representativeThreshold
        var candidates = primary.candidates

        // Optional second pass at the recording's own rate. The primary pass
        // downsamples, which puts fast transients (EMG/muscle, electrode
        // pops) above its Nyquist and out of reach entirely — this pass keeps
        // full bandwidth but only decomposes the finest levels, since it
        // exists purely to catch what the primary pass can no longer see.
        if configuration.detectsFastArtifacts, decimation > 1 {
            let fastLevelCount = fastPassLevelCount(samplingRate: signal.samplingRate, sampleCount: sampleCount)
            report(
                0.62,
                "Second pass for fast artifacts",
                "Rescanning at the full \(String(format: "%.0f", signal.samplingRate)) Hz across \(fastLevelCount) fine levels to catch muscle/EMG transients above the \(String(format: "%.0f", effectiveRate / 2)) Hz limit of the primary pass."
            )
            let fast = scanPass(
                signal: signal,
                channels: channels,
                configuration: configuration,
                decimation: 1,
                levelCount: fastLevelCount,
                roles: roles,
                sampleCount: sampleCount
            ) { completed, channelIndex, total in
                let denominator = max(total, 1)
                let fraction = 0.64 + 0.22 * (Double(completed) / Double(denominator))
                report(fraction, "Fast pass Ch \(channelIndex + 1)", "Completed \(completed) of \(total) full-rate channel decompositions.")
            }
            let beforeMerge = candidates.count
            candidates = mergeCandidateLists(
                candidates,
                fast.candidates,
                samplingRate: signal.samplingRate,
                mergeWindowSeconds: configuration.mergeWindowSeconds
            )
            report(
                0.88,
                "Combining passes",
                "Added \(max(candidates.count - beforeMerge, 0)) fast-artifact candidates the downsampled pass could not represent."
            )
        }
        candidates = rankedCandidates(candidates, limit: max(configuration.maximumCandidates, 1))

        report(
            0.94,
            "Ranking artifact candidates",
            "Sorting \(candidates.count) candidate bursts by anomaly strength (sigmas above each channel's own local baseline) and preserving peak channel/level/type metadata."
        )
        report(
            1.0,
            "Wavelet artifact explorer scan complete",
            "Finished with \(candidates.count) ranked candidates, \(summary.strongestChannels.count) channel summaries, and \(summary.levelSummaries.count) level summaries."
        )
        return WaveletArtifactExplorerResult(
            summary: summary,
            candidates: candidates,
            channelCount: summary.channelCount,
            effectiveSamplingRate: effectiveRate,
            candidateThreshold: representativeThreshold,
            analyzedDurationSeconds: Double(sampleCount) / signal.samplingRate,
            edgeMarginSeconds: Double(
                edgeMargin(
                    family: configuration.waveletFamily,
                    levelCount: levelCount,
                    sampleCount: max(sampleCount / decimation, 1)
                )
            ) / max(effectiveRate, 1)
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
        let effectiveRate = signal.samplingRate / Double(decimation)
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
            thresholdModel: configuration.thresholdModel,
            effectiveSamplingRate: effectiveRate,
            retention: .goodness
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

    /// The window and channel set one preview covers. Split out from
    /// `cleaningPreview` so a batch of previews can be planned first and their
    /// transforms dispatched together — see `cleaningPreviews`.
    private struct PreviewPlan {
        var candidate: WaveletArtifactCandidate
        var configuration: WaveletCleaningConfiguration
        var startSample: Int
        var endSample: Int
        var windowSamples: Int
        var channels: [Int]
        var levelCount: Int
    }

    private static func previewPlan(
        in signal: MFFSignalData,
        candidate: WaveletArtifactCandidate,
        configuration: WaveletCleaningConfiguration
    ) -> PreviewPlan? {
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

        return PreviewPlan(
            candidate: candidate,
            configuration: configuration,
            startSample: startSample,
            endSample: endSample,
            windowSamples: windowSamples,
            channels: SignalSelection.validChannels(configuration.channelIndices, in: signal),
            levelCount: boundedLevelCount(configuration.levelCount, sampleCount: windowSamples)
        )
    }

    /// Exactly what the transform consumes for one preview window, whichever
    /// backend runs it — `reconstructedArtifactSignal` demeans before
    /// decomposing, and `undecimatedDetails` detrends on top of that.
    private static func previewTransformInput(_ window: [Float]) -> [Float] {
        detrendedForTransform(demean(window))
    }

    /// Previews for several candidates at once. With `usesGPU` the wavelet
    /// transforms for every (candidate, channel) window are grouped by window
    /// length and dispatched together — preview windows come out nearly
    /// uniform in practice (padding saturates at its cap for all but the
    /// longest candidates), so this collapses to a handful of wide batches
    /// rather than one small dispatch per preview, which would be all
    /// round-trip overhead. Falls back to the per-preview CPU path otherwise.
    static func cleaningPreviews(
        in signal: MFFSignalData,
        candidates: [WaveletArtifactCandidate],
        configurations: [WaveletCleaningConfiguration],
        usesGPU: Bool = false
    ) -> [WaveletCleaningPreviewResult?] {
        guard candidates.count == configurations.count else { return [] }
        let plans = zip(candidates, configurations).map {
            previewPlan(in: signal, candidate: $0, configuration: $1)
        }

        var precomputed: [Int: [Int: [[Float]]]] = [:]
        if usesGPU, let backend = WaveletMetalBackend.shared {
            precomputed = previewDetailsOnGPU(backend: backend, signal: signal, plans: plans)
        }

        return plans.enumerated().map { index, plan in
            guard let plan else { return nil }
            return cleaningPreview(in: signal, plan: plan, precomputedDetails: precomputed[index])
        }
    }

    /// Batched GPU transforms for a set of preview plans, keyed
    /// `[planIndex: [channelIndex: details]]`. Anything that fails is simply
    /// absent, so those windows fall back to the CPU.
    private static func previewDetailsOnGPU(
        backend: WaveletMetalBackend,
        signal: MFFSignalData,
        plans: [PreviewPlan?]
    ) -> [Int: [Int: [[Float]]]] {
        struct WindowKey: Hashable {
            var windowSamples: Int
            var levelCount: Int
            var family: WaveletReductionFamily
        }

        var grouped: [WindowKey: [(planIndex: Int, channelIndex: Int, input: [Float])]] = [:]
        for (planIndex, plan) in plans.enumerated() {
            guard let plan else { continue }
            let key = WindowKey(
                windowSamples: plan.windowSamples,
                levelCount: plan.levelCount,
                family: plan.configuration.waveletFamily
            )
            for channelIndex in plan.channels where signal.data.indices.contains(channelIndex) {
                let channel = signal.data[channelIndex]
                guard channel.count > plan.endSample else { continue }
                let window = Array(channel[plan.startSample...plan.endSample])
                grouped[key, default: []].append((planIndex, channelIndex, previewTransformInput(window)))
            }
        }

        var results: [Int: [Int: [[Float]]]] = [:]
        for (key, entries) in grouped {
            let bank = key.family.filterBank
            let lowPass = bank.decompositionLowPass.map(Float.init)
            let highPass = bank.decompositionHighPass.map(Float.init)
            let batchSize = max(
                backend.maximumBatchChannels(sampleCount: key.windowSamples, levelCount: key.levelCount),
                1
            )

            var start = 0
            while start < entries.count {
                let end = min(start + batchSize, entries.count)
                let batch = Array(entries[start..<end])
                if let details = backend.forwardSWTDetails(
                    channels: batch.map(\.input),
                    levelCount: key.levelCount,
                    lowPass: lowPass,
                    highPass: highPass
                ) {
                    for (offset, entry) in batch.enumerated() {
                        results[entry.planIndex, default: [:]][entry.channelIndex] = details[offset]
                    }
                }
                start = end
            }
        }
        return results
    }

    static func cleaningPreview(
        in signal: MFFSignalData,
        candidate: WaveletArtifactCandidate,
        configuration: WaveletCleaningConfiguration
    ) -> WaveletCleaningPreviewResult? {
        guard let plan = previewPlan(in: signal, candidate: candidate, configuration: configuration) else {
            return nil
        }
        return cleaningPreview(in: signal, plan: plan, precomputedDetails: nil)
    }

    private static func cleaningPreview(
        in signal: MFFSignalData,
        plan: PreviewPlan,
        precomputedDetails: [Int: [[Float]]]?
    ) -> WaveletCleaningPreviewResult? {
        guard let sampleCount = signal.data.first?.count else { return nil }
        let configuration = plan.configuration
        let candidate = plan.candidate
        let startSample = plan.startSample
        let endSample = plan.endSample
        let windowSamples = plan.windowSamples
        let channels = plan.channels
        let levelCount = plan.levelCount
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
                thresholdModel: configuration.thresholdModel,
                samplingRate: signal.samplingRate,
                precomputedDetails: precomputedDetails?[channelIndex]
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
        /// Empty unless `ChannelDataRetention.perLevelDetails` was requested —
        /// see that type for why.
        var details: [[Float]]
        var artifactDetails: [[Float]]
        /// Empty unless `ChannelDataRetention.signedSalience` was requested.
        var signedSalience: [Float]
        var energySalience: [Float]
        /// Per-sample dominant (1-based) level, kept as a byte map so the
        /// Explorer can report a candidate's dominant level without retaining
        /// every level's full coefficient array.
        var dominantLevels: [UInt8]
        var totalEnergyByLevel: [Double]
        var artifactEnergyByLevel: [Double]
    }

    /// Which per-channel intermediates to hold on to. At the Explorer's
    /// working scale — 256 channels x 10 min x 500 Hz x ~10 levels — keeping
    /// `details` and `artifactDetails` for every channel is about 24 MB per
    /// channel, ~6 GB across the net, which is a hard failure well before
    /// speed matters. The Explorer only needs aggregate salience plus each
    /// sample's dominant level, so it asks for neither; template matching
    /// (`detect`) genuinely needs the full arrays and asks for both.
    private struct ChannelDataRetention {
        var perLevelDetails: Bool
        var signedSalience: Bool

        static let full = ChannelDataRetention(perLevelDetails: true, signedSalience: true)
        static let explorer = ChannelDataRetention(perLevelDetails: false, signedSalience: false)
        static let goodness = ChannelDataRetention(perLevelDetails: false, signedSalience: true)
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
        waveletFamily: WaveletReductionFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel,
        effectiveSamplingRate: Double,
        retention: ChannelDataRetention,
        usesGPU: Bool = false,
        progress: ((Int, Int, Int) -> Void)? = nil
    ) -> [ChannelWaveletData] {
        guard !channelIndices.isEmpty else { return [] }

        // The GPU path finishes the per-level work on-device and never brings
        // the bands back, so it can only serve callers that don't need them.
        if usesGPU, !retention.perLevelDetails, !retention.signedSalience,
           let backend = WaveletMetalBackend.shared {
            if let gpuResults = prepareChannelsOnGPU(
                backend: backend,
                signal: signal,
                channelIndices: channelIndices,
                decimation: decimation,
                levelCount: levelCount,
                thresholdScale: thresholdScale,
                waveletFamily: waveletFamily,
                thresholdRule: thresholdRule,
                thresholdModel: thresholdModel,
                effectiveSamplingRate: effectiveSamplingRate,
                retention: retention,
                progress: progress
            ) {
                return gpuResults
            }
            // Falling through to the CPU is the intended behaviour for any GPU
            // hiccup — a scan that quietly takes longer beats one that fails.
        }

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
                    thresholdModel: thresholdModel,
                    effectiveSamplingRate: effectiveSamplingRate,
                    retention: retention
                )
                progress?(offset + 1, channelIndex, channelIndices.count)
                return data
            }
        }

        nonisolated(unsafe) var results = Array<ChannelWaveletData?>(repeating: nil, count: channelIndices.count)
        nonisolated(unsafe) var completedCount = 0
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
                    thresholdModel: thresholdModel,
                    effectiveSamplingRate: effectiveSamplingRate,
                    retention: retention
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

    /// GPU decomposition path. Channels are downsampled and detrended on the
    /// CPU, handed to Metal in batches sized to the device's buffer limit, and
    /// the returned detail bands are folded back through the same
    /// thresholding and accumulation the CPU path uses — so only the
    /// transform differs. Batching keeps peak memory to one batch rather than
    /// the whole net's per-level coefficients.
    ///
    /// Returns nil if the backend can't complete, letting the caller fall back.
    private static func prepareChannelsOnGPU(
        backend: WaveletMetalBackend,
        signal: MFFSignalData,
        channelIndices: [Int],
        decimation: Int,
        levelCount: Int,
        thresholdScale: Double,
        waveletFamily: WaveletReductionFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel,
        effectiveSamplingRate: Double,
        retention: ChannelDataRetention,
        progress: ((Int, Int, Int) -> Void)?
    ) -> [ChannelWaveletData]? {
        let bank = waveletFamily.filterBank
        let lowPass = bank.decompositionLowPass.map(Float.init)
        let highPass = bank.decompositionHighPass.map(Float.init)

        // Prepared up front so every channel in a batch is the same length,
        // which the kernel's channel-major layout requires.
        var prepared: [(channelIndex: Int, samples: [Float], detrended: [Float])] = []
        prepared.reserveCapacity(channelIndices.count)
        for channelIndex in channelIndices {
            guard signal.data.indices.contains(channelIndex) else { continue }
            let samples = downsampleAndDemean(signal.data[channelIndex], by: decimation)
            guard samples.count > 2 else { continue }
            prepared.append((channelIndex, samples, detrendedForTransform(samples)))
        }
        guard let sampleCount = prepared.first?.samples.count,
              prepared.allSatisfy({ $0.samples.count == sampleCount })
        else {
            return nil
        }

        let batchSize = max(backend.maximumBatchChannels(sampleCount: sampleCount, levelCount: levelCount), 1)
        let edgeMarginSamples = edgeMargin(family: waveletFamily, levelCount: levelCount, sampleCount: sampleCount)
        let marginEnd = max(sampleCount - edgeMarginSamples, edgeMarginSamples)
        let windowSamples = max(Int((localThresholdWindowSeconds * effectiveSamplingRate).rounded()), 64)
        let windows = thresholdWindows(sampleCount: sampleCount, windowSamples: windowSamples)
        let delays = levelGroupDelays(family: waveletFamily, levelCount: levelCount)
        let subsampleStride = max(windowSamples / robustStatisticSampleCap, 1)

        var results: [ChannelWaveletData] = []
        results.reserveCapacity(prepared.count)
        var completed = 0

        var batchStart = 0
        while batchStart < prepared.count {
            let batchEnd = min(batchStart + batchSize, prepared.count)
            let batch = Array(prepared[batchStart..<batchEnd])

            // Transform, then leave the bands on-device. The CPU only reads a
            // strided subsample out of them (shared storage, so a direct read
            // rather than a copy) to compute each window's robust threshold —
            // the one genuinely serial step, since it needs a median.
            guard let resident = backend.residentDetails(
                channels: batch.map(\.detrended),
                levelCount: levelCount,
                lowPass: lowPass,
                highPass: highPass
            ) else {
                return nil
            }

            nonisolated(unsafe) var thresholds = [Float](
                repeating: 0,
                count: levelCount * batch.count * windows.count
            )
            let workerCount = waveletWorkerCount(for: batch.count)
            evaConcurrentPerform(iterations: workerCount) { workerIndex in
                var channel = workerIndex
                while channel < batch.count {
                    for level in 0..<levelCount {
                        let slot = (level * batch.count + channel) * windows.count
                        for (windowIndex, window) in windows.enumerated() {
                            let subsample = resident.subsample(
                                level: level,
                                channel: channel,
                                delay: delays[level],
                                from: window.start,
                                to: window.end,
                                stride: subsampleStride
                            )
                            thresholds[slot + windowIndex] = coefficientThreshold(
                                for: subsample,
                                model: thresholdModel,
                                populationCount: window.end - window.start
                            )
                        }
                    }
                    channel += workerCount
                }
            }

            guard let accumulated = backend.accumulate(
                resident,
                request: WaveletMetalBackend.AccumulateRequest(
                    levelDelays: delays,
                    thresholds: thresholds,
                    windowCenters: windows.map(\.center),
                    edgeMarginStart: edgeMarginSamples,
                    edgeMarginEnd: marginEnd,
                    thresholdScale: Float(max(thresholdScale, 0.05)),
                    usesSoftThreshold: thresholdRule == .soft
                )
            ) else {
                return nil
            }

            for (offset, entry) in batch.enumerated() {
                results.append(ChannelWaveletData(
                    channelIndex: entry.channelIndex,
                    samples: entry.samples,
                    // The GPU path never materializes per-level bands on the
                    // host, so it can only serve the Explorer's retention
                    // (which asks for neither) — `prepareChannels` routes the
                    // template-matching paths to the CPU.
                    details: [],
                    artifactDetails: [],
                    signedSalience: [],
                    energySalience: accumulated.energySalience[offset],
                    dominantLevels: accumulated.dominantLevels[offset],
                    totalEnergyByLevel: accumulated.totalEnergyByLevel[offset],
                    artifactEnergyByLevel: accumulated.artifactEnergyByLevel[offset]
                ))
                completed += 1
                progress?(completed, entry.channelIndex, prepared.count)
            }
            batchStart = batchEnd
        }

        return results
    }

    /// Window bounds and centres for the per-level threshold curve, matching
    /// `windowedThreshold`'s own stepping so both backends threshold on the
    /// same windows.
    private static func thresholdWindows(
        sampleCount: Int,
        windowSamples: Int
    ) -> [(start: Int, end: Int, center: Int)] {
        guard sampleCount > 0 else { return [] }
        guard sampleCount > windowSamples else {
            return [(0, sampleCount, (sampleCount - 1) / 2)]
        }
        var windows: [(start: Int, end: Int, center: Int)] = []
        let stride = max(windowSamples / 2, 1)
        var start = 0
        while start < sampleCount {
            let end = min(start + windowSamples, sampleCount)
            windows.append((start, end, (start + end - 1) / 2))
            if end == sampleCount { break }
            start += stride
        }
        return windows
    }

    /// Each level's accumulated group delay — the same cascade
    /// `undecimatedDetails` applies, precomputed so the GPU kernels can index it.
    private static func levelGroupDelays(family: WaveletReductionFamily, levelCount: Int) -> [Int] {
        let bank = family.filterBank
        let highLength = bank.decompositionHighPass.count
        let lowLength = bank.decompositionLowPass.count
        var delays: [Int] = []
        delays.reserveCapacity(levelCount)
        var cumulativeLowPassDelay = 0
        for level in 0..<levelCount {
            let dilation = 1 << level
            delays.append(cumulativeLowPassDelay + (highLength - 1) / 2 * dilation)
            cumulativeLowPassDelay += (lowLength - 1) / 2 * dilation
        }
        return delays
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
        waveletFamily: WaveletReductionFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel,
        effectiveSamplingRate: Double,
        retention: ChannelDataRetention,
        precomputedSamples: [Float]? = nil,
        precomputedDetails: [[Float]]? = nil
    ) -> ChannelWaveletData? {
        guard signal.data.indices.contains(channelIndex) else { return nil }
        let samples = precomputedSamples ?? downsampleAndDemean(signal.data[channelIndex], by: decimation)
        guard samples.count > 2 else { return nil }
        let decomposition = undecimatedDetails(
            samples,
            levelCount: levelCount,
            thresholdScale: thresholdScale,
            waveletFamily: waveletFamily,
            thresholdRule: thresholdRule,
            thresholdModel: thresholdModel,
            effectiveSamplingRate: effectiveSamplingRate,
            precomputedDetails: precomputedDetails
        )
        var signedSalience = retention.signedSalience
            ? [Float](repeating: 0, count: samples.count)
            : []
        var energySalience = [Float](repeating: 0, count: samples.count)
        var dominantLevels = [UInt8](repeating: 0, count: samples.count)
        var dominantMagnitude = [Float](repeating: 0, count: samples.count)
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
                let magnitude = abs(artifact[sample])
                if retention.signedSalience {
                    signedSalience[sample] += artifact[sample]
                }
                energySalience[sample] += magnitude
                if magnitude > dominantMagnitude[sample] {
                    dominantMagnitude[sample] = magnitude
                    dominantLevels[sample] = UInt8(truncatingIfNeeded: level + 1)
                }
            }
        }

        return ChannelWaveletData(
            channelIndex: channelIndex,
            samples: samples,
            details: retention.perLevelDetails ? decomposition.details : [],
            artifactDetails: retention.perLevelDetails ? decomposition.artifactDetails : [],
            signedSalience: signedSalience,
            energySalience: energySalience,
            dominantLevels: dominantLevels,
            totalEnergyByLevel: totalEnergyByLevel,
            artifactEnergyByLevel: artifactEnergyByLevel
        )
    }

    /// Threshold is re-estimated in overlapping windows of this length (see
    /// `windowedCoefficientThreshold`) rather than once for the whole
    /// recording, so a quiet stretch and a noisy stretch each get their own
    /// noise floor instead of sharing one whole-recording robust statistic.
    /// 30s rather than a few seconds: `coefficientThreshold`'s BayesShrink
    /// path estimates both a noise sigma AND an observed-variance "signal"
    /// estimate from the same window, and on a short window (order
    /// hundreds-to-low-thousands of samples) the observed-variance estimate
    /// is itself noisy enough that pure noise can look like "signal" purely
    /// from small-sample variance, driving the threshold down and letting
    /// noise through as false "artifact" in that window. 30s keeps enough
    /// samples per window for that variance estimate to stabilize while
    /// still adapting across a multi-minute recording instead of using one
    /// whole-recording statistic.
    private static let localThresholdWindowSeconds = 30.0

    private static func undecimatedDetails(
        _ samples: [Float],
        levelCount: Int,
        thresholdScale: Double,
        waveletFamily: WaveletReductionFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel,
        effectiveSamplingRate: Double,
        precomputedDetails: [[Float]]? = nil
    ) -> (details: [[Float]], artifactDetails: [[Float]]) {
        guard samples.count > 2, levelCount > 0 else { return ([], []) }

        // The real (undecimated) transform below wraps circularly at its
        // boundaries. Removing the whole-channel linear trend first — never
        // added back, since only the detail bands feed the rest of this
        // pipeline — keeps a slow drift/impedance change from reading as one
        // large spurious discontinuity at the seam. That still leaves a
        // smaller but real effect: filter taps for samples near the end
        // reach around into samples near the start (`(index + k*dilation) %
        // n`), splicing two otherwise-unrelated stretches of noise together —
        // which a wavelet filter reads as more structure than an ordinary
        // interior stretch has, since real interior noise is never that
        // locally self-similar. Padding the signal to fake a smoother seam
        // (tried: mirror reflection) trades this for a *different* artifact —
        // a reflection's mirror point is itself an unnaturally correlated
        // kink that a high-pass filter also responds to. Rather than chase a
        // padding scheme that manufactures no artifact at all, suppress
        // candidate generation in the margin that's actually reachable by
        // the wrap (`edgeMarginSamples` below) — a tiny, known-bounded slice
        // of any real recording, not a detection compromise anywhere else.
        let bank = waveletFamily.filterBank
        let edgeMarginSamples = edgeMargin(
            family: waveletFamily,
            levelCount: levelCount,
            sampleCount: samples.count
        )
        // `precomputedDetails` is the GPU seam: when the Metal backend has
        // already produced this channel's raw detail bands (from the same
        // detrended samples), everything from here on — group-delay
        // realignment, windowed thresholding, edge suppression — is identical
        // either way.
        let rawDetails: [[Float]]
        if let precomputedDetails, precomputedDetails.count == levelCount {
            rawDetails = precomputedDetails
        } else {
            let transform = WaveletTransform(bank: bank)
            rawDetails = transform.forwardSWT(detrendedForTransform(samples).map(Double.init), levels: levelCount)
                .details
                .map { $0.map(Float.init) }
        }
        let windowSamples = max(Int((localThresholdWindowSeconds * effectiveSamplingRate).rounded()), 64)
        var details: [[Float]] = []
        var artifactDetails: [[Float]] = []
        details.reserveCapacity(rawDetails.count)
        artifactDetails.reserveCapacity(rawDetails.count)
        let marginEnd = max(samples.count - edgeMarginSamples, edgeMarginSamples)

        // `swtStep`'s taps run forward from `index` (`index + k*dilation`,
        // never `index - k*dilation`), so `detail[index]` is really centered
        // on an input sample *ahead* of `index`, for a (near-)symmetric
        // filter — a group delay. And since each level decomposes the
        // *previous* level's low-pass output (not the original signal), that
        // delay accumulates across levels via the low-pass chain, mirroring
        // `WaveletTransform.forwardSWT`'s own cascade. Left uncorrected, a
        // feature at true sample T shows up in a deep level's detail band
        // well *before* T — fine for a same-level self-correlation, but
        // breaks anything that compares a fixed input-sample window (an
        // exemplar/template) against this array, like `detectWaveform`'s
        // matching. Shifting each level's detail forward by its own
        // (accumulated) delay re-aligns `detail[index]` with input sample
        // `index`.
        let highLength = bank.decompositionHighPass.count
        let lowLength = bank.decompositionLowPass.count
        var cumulativeLowPassDelay = 0

        for level in rawDetails.indices {
            let dilation = 1 << level
            let delay = cumulativeLowPassDelay + (highLength - 1) / 2 * dilation
            cumulativeLowPassDelay += (lowLength - 1) / 2 * dilation
            let detail = shiftForward(rawDetails[level], by: delay)
            let scale = Float(max(thresholdScale, 0.05))
            let thresholds = windowedCoefficientThreshold(
                for: detail,
                model: thresholdModel,
                windowSamples: windowSamples
            )
            var artifacts = [Float](repeating: 0, count: detail.count)
            for index in detail.indices where index >= edgeMarginSamples && index < marginEnd {
                artifacts[index] = thresholdCoefficient(detail[index], threshold: thresholds[index] * scale, rule: thresholdRule)
            }
            details.append(detail)
            artifactDetails.append(artifacts)
        }

        return (details, artifactDetails)
    }

    /// Samples at each end where the transform's circular boundary makes
    /// coefficients untrustworthy, so no candidate is reported there.
    ///
    /// Covers the deepest level's tap reach plus the group-delay shift
    /// applied in `undecimatedDetails` (that level's accumulated low-pass
    /// delay plus its own high-pass delay), so the shift's zero-filled
    /// head/tail also lands inside the margin. Capped at 5% of the signal
    /// rather than 50%: the margin is sized for a boundary artifact in a long
    /// continuous recording, where it's a sliver of the total, but on a short
    /// snippet (a padded exemplar window for template matching, say) an
    /// uncapped margin would approach half the signal and swallow genuine
    /// interior content.
    static func edgeMargin(family: WaveletReductionFamily, levelCount: Int, sampleCount: Int) -> Int {
        let bank = family.filterBank
        let maxDilation = 1 << max(levelCount - 1, 0)
        let maxFilterLength = max(bank.decompositionLowPass.count, bank.decompositionHighPass.count)
        let maxGroupDelay = (bank.decompositionLowPass.count - 1) / 2 * (maxDilation - 1)
            + (bank.decompositionHighPass.count - 1) / 2 * maxDilation
        return min((maxFilterLength - 1) * maxDilation + maxGroupDelay, sampleCount / 20)
    }

    /// Shifts `values` forward (later) by `delay` samples, zero-filling the
    /// now-empty head — see the group-delay note in `undecimatedDetails`.
    private static func shiftForward(_ values: [Float], by delay: Int) -> [Float] {
        guard delay > 0 else { return values }
        guard delay < values.count else { return [Float](repeating: 0, count: values.count) }
        var shifted = [Float](repeating: 0, count: values.count)
        for index in delay..<values.count {
            shifted[index] = values[index - delay]
        }
        return shifted
    }

    /// The exact input the transform sees, whichever backend runs it — the
    /// GPU path detrends here too before uploading, so both produce detail
    /// bands from identical samples.
    static func detrendedForTransform(_ samples: [Float]) -> [Float] {
        removeLinearTrend(samples)
    }

    /// Least-squares linear fit removed from the whole channel — see the
    /// boundary-wrap note in `undecimatedDetails`.
    private static func removeLinearTrend(_ samples: [Float]) -> [Float] {
        let n = samples.count
        guard n > 2 else { return samples }
        let xMean = Float(n - 1) / 2
        let yMean = samples.reduce(Float(0), +) / Float(n)
        var numerator: Float = 0
        var denominator: Float = 0
        for index in samples.indices {
            let dx = Float(index) - xMean
            numerator += dx * (samples[index] - yMean)
            denominator += dx * dx
        }
        guard denominator > 1e-9 else { return samples }
        let slope = numerator / denominator
        let intercept = yMean - slope * xMean
        return samples.indices.map { samples[$0] - (intercept + slope * Float($0)) }
    }

    /// Per-sample coefficient threshold, re-estimated at the center of
    /// overlapping (50%-stride) windows and linearly interpolated between
    /// centers so the noise floor tracks local signal quality instead of one
    /// whole-recording statistic, without discontinuities at window edges.
    private static func windowedCoefficientThreshold(
        for values: [Float],
        model: WaveletCleaningThresholdModel,
        windowSamples: Int
    ) -> [Float] {
        windowedThreshold(for: values, windowSamples: windowSamples) { coefficientThreshold(for: $0, model: model) }
    }

    /// Re-estimates `statistic` at the center of overlapping (50%-stride)
    /// windows and linearly interpolates between centers, so a per-sample
    /// threshold tracks local signal quality instead of one whole-recording
    /// statistic, without discontinuities at window edges. Shared by the
    /// per-level coefficient threshold and the per-channel burst threshold.
    private static func windowedThreshold(
        for values: [Float],
        windowSamples: Int,
        statistic: ([Float]) -> Float
    ) -> [Float] {
        let n = values.count
        guard n > 0 else { return [] }
        guard n > windowSamples else {
            return [Float](repeating: statistic(values), count: n)
        }

        let stride = max(windowSamples / 2, 1)
        var centers: [Int] = []
        var centerValues: [Float] = []
        var start = 0
        while start < n {
            let end = min(start + windowSamples, n)
            centers.append((start + end - 1) / 2)
            centerValues.append(statistic(Array(values[start..<end])))
            if end == n { break }
            start += stride
        }

        return interpolatedCurve(centerValues, centers: centers, count: n)
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


    /// `populationCount` is the size of the window these values represent,
    /// which is the `N` in the universal threshold's `sqrt(2 ln N)`. It's
    /// separate from `values.count` so a caller holding only a subsample (the
    /// GPU path, which reads a strided sample straight out of device memory)
    /// still gets the threshold the full window would have produced, rather
    /// than a systematically lower one.
    private static func coefficientThreshold(
        for values: [Float],
        model: WaveletCleaningThresholdModel,
        populationCount: Int? = nil
    ) -> Float {
        guard values.count > 2 else { return 0 }
        let sigma = robustSigma(values)
        let universalThreshold: Float
        if sigma > 1e-12 {
            universalThreshold = sigma * Float(sqrt(2 * log(Double(max(populationCount ?? values.count, 2)))))
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
        let stride = max(values.count / robustStatisticSampleCap, 1)
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
        waveletFamily: WaveletReductionFamily,
        thresholdRule: WaveletCleaningThresholdRule,
        thresholdModel: WaveletCleaningThresholdModel,
        samplingRate: Double,
        precomputedDetails: [[Float]]? = nil
    ) -> [Float] {
        guard samples.count > 2 else { return [Float](repeating: 0, count: samples.count) }
        let centered = demean(samples)
        let decomposition = undecimatedDetails(
            centered,
            levelCount: levelCount,
            thresholdScale: thresholdScale,
            waveletFamily: waveletFamily,
            thresholdRule: thresholdRule,
            thresholdModel: thresholdModel,
            effectiveSamplingRate: samplingRate,
            precomputedDetails: precomputedDetails
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

    private struct ChannelCandidateRange {
        var start: Int
        var end: Int
        var peak: Int
        /// Raw salience at the peak, in the channel's own units.
        var peakValue: Float
        /// Sigmas above that channel's local median at the peak. Unlike
        /// `peakValue` this is comparable across channels, so ranking with it
        /// doesn't just surface whichever channels run hottest.
        var peakScore: Float
    }

    private struct MergedArtifactEvent {
        var start: Int
        var end: Int
        var peak: Int
        var peakValue: Float
        var peakScore: Float
        var peakChannelIndex: Int
        var peakLevel: Int
        var contributingChannels: Set<Int>
    }

    private struct ScanPassResult {
        var candidates: [WaveletArtifactCandidate]
        var summary: WaveletArtifactFeatureSummary
        var representativeThreshold: Double
    }

    /// One complete detection pass at a given decimation and depth:
    /// decompose every channel, find each channel's own local bursts, merge
    /// them across channels, and classify. Factored out so the Explorer can
    /// run it twice — once downsampled for the bulk of the recording, once at
    /// full rate for fast transients (see `detectsFastArtifacts`).
    private static func scanPass(
        signal: MFFSignalData,
        channels: [Int],
        configuration: WaveletArtifactExplorerConfiguration,
        decimation: Int,
        levelCount: Int,
        roles: WaveletChannelRoles,
        sampleCount: Int,
        progress: ((Int, Int, Int) -> Void)? = nil
    ) -> ScanPassResult {
        let effectiveRate = signal.samplingRate / Double(decimation)
        let data = prepareChannels(
            signal: signal,
            channelIndices: channels,
            decimation: decimation,
            levelCount: levelCount,
            thresholdScale: configuration.thresholdScale,
            waveletFamily: configuration.waveletFamily,
            thresholdRule: configuration.thresholdRule,
            thresholdModel: configuration.thresholdModel,
            effectiveSamplingRate: effectiveRate,
            retention: .explorer,
            usesGPU: configuration.usesGPU,
            progress: progress
        )
        let summary = featureSummary(from: data, effectiveSamplingRate: effectiveRate)
        let minimumDurationSamples = max(Int((configuration.minimumDurationSeconds * effectiveRate).rounded()), 1)
        let mergeSamples = max(Int((configuration.mergeWindowSeconds * effectiveRate).rounded()), 1)
        let perChannelWindowSamples = max(Int((localThresholdWindowSeconds * effectiveRate).rounded()), 64)

        let perChannelRanges = data.map { channel in
            (
                channel: channel,
                ranges: channelCandidateRanges(
                    for: channel,
                    minimumDurationSamples: minimumDurationSamples,
                    windowSamples: perChannelWindowSamples
                )
            )
        }
        let representativeThreshold = medianPositive(
            data.map { Double(burstStatistics($0.energySalience).threshold) },
            fallback: 0
        )
        let events = mergeChannelCandidates(perChannelRanges, mergeSamples: mergeSamples)
        let candidates = buildExplorerCandidates(
            from: events,
            sampleCount: sampleCount,
            samplingRate: signal.samplingRate,
            decimation: decimation,
            levelCount: levelCount,
            roles: roles
        )

        return ScanPassResult(
            candidates: candidates,
            summary: summary,
            representativeThreshold: representativeThreshold
        )
    }

    /// Depth for the full-rate fast pass: enough levels to reach down to
    /// roughly 20 Hz, which brackets muscle/EMG, and no further — deeper
    /// levels only re-cover ground the primary (downsampled) pass already
    /// handles at a fraction of the cost.
    private static func fastPassLevelCount(samplingRate: Double, sampleCount: Int) -> Int {
        let lowestFrequencyOfInterest = 20.0
        let ideal = Int(ceil(log2(max(samplingRate / (2 * lowestFrequencyOfInterest), 2))))
        return boundedLevelCount(min(max(ideal, 3), 6), sampleCount: sampleCount)
    }

    /// Folds the fast pass's candidates into the primary list. A fast-pass
    /// find that lands on something the primary pass already reported is the
    /// same event seen twice, so the stronger reading wins rather than the
    /// list carrying both.
    private static func mergeCandidateLists(
        _ primary: [WaveletArtifactCandidate],
        _ additional: [WaveletArtifactCandidate],
        samplingRate: Double,
        mergeWindowSeconds: Double
    ) -> [WaveletArtifactCandidate] {
        guard !additional.isEmpty else { return primary }
        guard !primary.isEmpty else { return additional }

        let tolerance = max(mergeWindowSeconds, 0.001)
        var combined = primary
        for candidate in additional {
            let overlapIndex = combined.firstIndex { existing in
                candidate.startTimeSeconds <= existing.endTimeSeconds + tolerance
                    && existing.startTimeSeconds <= candidate.endTimeSeconds + tolerance
            }
            if let overlapIndex {
                if candidate.score > combined[overlapIndex].score {
                    combined[overlapIndex] = candidate
                }
            } else {
                combined.append(candidate)
            }
        }
        return combined
    }

    /// Sorts by anomaly strength, applies the cap, and renumbers — ranks and
    /// ids have to be reassigned after the two passes are combined.
    private static func rankedCandidates(
        _ candidates: [WaveletArtifactCandidate],
        limit: Int
    ) -> [WaveletArtifactCandidate] {
        let sorted = candidates.sorted {
            if $0.score == $1.score {
                return $0.peakSample < $1.peakSample
            }
            return $0.score > $1.score
        }
        .prefix(limit)

        return sorted.enumerated().map { offset, candidate in
            var renumbered = candidate
            renumbered.rank = offset + 1
            renumbered.id = "wavelet-explorer-\(offset + 1)-\(candidate.peakSample)"
            return renumbered
        }
    }

    /// Per-channel burst extraction: a local (windowed) threshold on that
    /// channel's own salience, rather than the whole recording's or every
    /// other channel's. This is what lets a subtle artifact confined to one
    /// or two channels survive instead of being diluted by an averaged,
    /// whole-recording cross-channel projection.
    private static func channelCandidateRanges(
        for channel: ChannelWaveletData,
        minimumDurationSamples: Int,
        windowSamples: Int
    ) -> [ChannelCandidateRange] {
        let values = channel.energySalience
        guard !values.isEmpty else { return [] }
        let model = localNoiseModel(for: values, windowSamples: windowSamples)
        let thresholds = interpolatedCurve(model.thresholds, centers: model.centers, count: values.count)

        var ranges: [ChannelCandidateRange] = []
        var index = 0
        while index < values.count {
            guard values[index] >= thresholds[index] else {
                index += 1
                continue
            }

            let start = index
            var end = index
            var peak = index
            var peakValue = values[index]
            while end + 1 < values.count, values[end + 1] >= thresholds[end + 1] {
                end += 1
                if values[end] > peakValue {
                    peak = end
                    peakValue = values[end]
                }
            }

            if end - start + 1 >= minimumDurationSamples {
                let median = interpolated(model.medians, centers: model.centers, at: peak)
                let sigma = interpolated(model.sigmas, centers: model.centers, at: peak)
                let peakScore = sigma > 1e-9 ? (peakValue - median) / sigma : 0
                ranges.append(ChannelCandidateRange(
                    start: start,
                    end: end,
                    peak: peak,
                    peakValue: peakValue,
                    peakScore: peakScore
                ))
            }
            index = end + 1
        }
        return ranges
    }

    /// Merges per-channel candidate ranges into cross-channel events: ranges
    /// that overlap or fall within `mergeSamples` of the growing group are
    /// combined into one event, so an artifact that shows up slightly offset
    /// across channels still reads as a single occurrence.
    ///
    /// Contributing channels are then counted separately, and more strictly:
    /// only channels whose own range actually reaches the event's peak (again
    /// within `mergeSamples`) count. Proximity-based merging chains — each
    /// absorbed range pushes the group's `end` out, letting the next one in —
    /// so on a many-channel recording a lone real burst would otherwise
    /// accumulate unrelated noise detections from neighbouring channels and
    /// get misread as a widespread (movement) artifact instead of the
    /// channel-local event it is.
    private static func mergeChannelCandidates(
        _ perChannel: [(channel: ChannelWaveletData, ranges: [ChannelCandidateRange])],
        mergeSamples: Int
    ) -> [MergedArtifactEvent] {
        struct Tagged {
            var range: ChannelCandidateRange
            var channelIndex: Int
            var level: Int
        }

        var tagged: [Tagged] = []
        for entry in perChannel {
            for range in entry.ranges {
                tagged.append(Tagged(
                    range: range,
                    channelIndex: entry.channel.channelIndex,
                    level: dominantLevel(in: entry.channel, at: range.peak)
                ))
            }
        }
        guard !tagged.isEmpty else { return [] }
        tagged.sort { $0.range.start < $1.range.start }

        var events: [MergedArtifactEvent] = []
        var groups: [[Tagged]] = []
        for item in tagged {
            if var last = events.last, item.range.start - last.end <= mergeSamples {
                last.end = max(last.end, item.range.end)
                // Representative peak is the most *anomalous* contribution
                // (sigmas above that channel's own local median), not the
                // largest raw one — otherwise a merged event's reported peak
                // channel is just whichever contributing channel runs hottest.
                if item.range.peakScore > last.peakScore {
                    last.peakValue = item.range.peakValue
                    last.peakScore = item.range.peakScore
                    last.peak = item.range.peak
                    last.peakChannelIndex = item.channelIndex
                    last.peakLevel = item.level
                }
                events[events.count - 1] = last
                groups[groups.count - 1].append(item)
            } else {
                events.append(MergedArtifactEvent(
                    start: item.range.start,
                    end: item.range.end,
                    peak: item.range.peak,
                    peakValue: item.range.peakValue,
                    peakScore: item.range.peakScore,
                    peakChannelIndex: item.channelIndex,
                    peakLevel: item.level,
                    contributingChannels: [item.channelIndex]
                ))
                groups.append([item])
            }
        }

        // Second pass: settle which channels actually took part. A channel
        // counts only if its own range both reaches the event's (now final)
        // peak in time AND responded with comparable strength. Time alone is
        // too weak a test — every channel throws the occasional
        // barely-over-threshold noise blip, and on a high-density net some of
        // those land near any given peak by chance, which would turn a lone
        // electrode pop into an apparently widespread (movement) artifact.
        // Requiring a fraction of the peak channel's score keeps genuinely
        // weaker participants in a real widespread event (posterior channels
        // in a blink, say) while dropping noise-level coincidences.
        for index in events.indices {
            let peak = events[index].peak
            let peakScore = events[index].peakScore
            let strengthFloor = peakScore * contributingChannelScoreFraction
            var contributing: Set<Int> = [events[index].peakChannelIndex]
            for item in groups[index] {
                let reachesPeak = item.range.start - mergeSamples <= peak
                    && item.range.end + mergeSamples >= peak
                if reachesPeak, item.range.peakScore >= strengthFloor {
                    contributing.insert(item.channelIndex)
                }
            }
            events[index].contributingChannels = contributing
        }
        return events
    }

    /// A channel must reach this fraction of the event's peak score to count
    /// as contributing — see `mergeChannelCandidates`.
    private static let contributingChannelScoreFraction: Float = 0.35

    private static func dominantLevel(in channel: ChannelWaveletData, at sample: Int) -> Int {
        guard channel.dominantLevels.indices.contains(sample) else { return 1 }
        return max(Int(channel.dominantLevels[sample]), 1)
    }

    /// Classifies a merged event's likely artifact type from which channels
    /// contributed, following the same ocular/muscle/movement topography
    /// heuristics ADJUST/ICLabel use: ocular artifacts are frontal-weighted
    /// and coarse (low-frequency — high level index), muscle is
    /// lateral/temporal-weighted and fine (high-frequency — low level
    /// index), a lone contributing channel is treated as channel-local
    /// (electrode pop/bad contact) rather than a real multi-channel pattern,
    /// and anything broadband/multi-channel that fits neither weighting is
    /// left as movement/cap-shift.
    ///
    /// Internal rather than private so its decision matrix can be tested
    /// directly: driving every branch through `explore` would mean
    /// synthesizing signals that land on exact wavelet levels, which tests
    /// the transform's frequency mapping more than it tests this logic.
    static func classifyArtifactType(
        contributingChannels: Set<Int>,
        peakLevel: Int,
        levelCount: Int,
        roles: WaveletChannelRoles
    ) -> WaveletArtifactType {
        guard contributingChannels.count > 1 else { return .channelLocal }
        guard !roles.ocular.isEmpty || !roles.lateral.isEmpty else { return .unclassified }

        let ocularFraction = roles.ocular.isEmpty ? 0 :
            Double(contributingChannels.intersection(roles.ocular).count) / Double(contributingChannels.count)
        let lateralFraction = roles.lateral.isEmpty ? 0 :
            Double(contributingChannels.intersection(roles.lateral).count) / Double(contributingChannels.count)
        // Coarser (higher-numbered) levels are lower-frequency bands — see
        // `featureSummary`'s `centerFrequencyHz`, which halves per level.
        let isCoarse = peakLevel >= max(levelCount - 2, 1)
        let isFine = peakLevel <= max(levelCount / 3, 1)

        if ocularFraction >= 0.5, isCoarse {
            return .ocular
        }
        if lateralFraction >= 0.4, isFine {
            return .muscle
        }
        return .movement
    }

    private static func buildExplorerCandidates(
        from events: [MergedArtifactEvent],
        sampleCount: Int,
        samplingRate: Double,
        decimation: Int,
        levelCount: Int,
        roles: WaveletChannelRoles
    ) -> [WaveletArtifactCandidate] {
        events.enumerated().map { offset, event in
            let startSample = min(max(event.start * decimation, 0), max(sampleCount - 1, 0))
            let endSample = min(max((event.end + 1) * decimation - 1, startSample), max(sampleCount - 1, 0))
            let peakSample = min(max(event.peak * decimation, startSample), endSample)
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
                score: Double(event.peakScore),
                peakEnergy: Double(event.peakValue),
                channelIndex: event.peakChannelIndex,
                dominantLevel: event.peakLevel,
                contributingChannelCount: event.contributingChannels.count,
                artifactType: classifyArtifactType(
                    contributingChannels: event.contributingChannels,
                    peakLevel: event.peakLevel,
                    levelCount: levelCount,
                    roles: roles
                )
            )
        }
    }

    /// Robust local burst threshold for one window of a channel's salience
    /// trace — the same percentile-based formula the old whole-recording
    /// projection threshold used, just applied per-window via
    /// `windowedThreshold` so it adapts to local noise level instead of one
    /// global statistic.
    /// Robust local burst threshold for one window of a channel's salience
    /// trace. Deliberately NOT a percentile-rank cutoff (e.g. "top 1.5% of
    /// this window") — a fixed local percentile always flags *something* in
    /// every window purely by construction, artifact or not, once you're
    /// evaluating "top X%" against a small local sample instead of the whole
    /// recording. Instead this is a fixed-significance (sigma-scaled)
    /// universal threshold, the same style `coefficientThreshold` already
    /// uses for detail coefficients: median + robust-sigma * sqrt(2 ln N).
    /// That scales with window size the right way — a real outlier has to
    /// clear a noise-calibrated bar, not merely rank near the top of
    /// whatever's in the window.
    /// Robust local statistics for one window of a channel's salience trace.
    /// The threshold is deliberately NOT a percentile-rank cutoff (e.g. "top
    /// 1.5% of this window") — a fixed local percentile always flags
    /// *something* in every window purely by construction, artifact or not,
    /// once you're evaluating "top X%" against a small local sample instead
    /// of the whole recording. It's a fixed-significance (sigma-scaled)
    /// universal threshold, the same style `coefficientThreshold` uses for
    /// detail coefficients: a real outlier has to clear a noise-calibrated
    /// bar, not merely rank near the top of whatever's in the window.
    ///
    /// `median` and `sigma` come back alongside it because the candidate
    /// score is expressed in sigmas above the local median — deriving all
    /// three from the one sort keeps this off the hot path.
    private static func burstStatistics(_ values: [Float]) -> (median: Float, sigma: Float, threshold: Float) {
        let sampled = sampledFiniteValues(values).sorted()
        guard !sampled.isEmpty else { return (0, 0, 0) }
        let medianValue = percentile(sampled, fraction: 0.50)
        let deviations = sampled.map { abs($0 - medianValue) }.sorted()
        let mad = percentile(deviations, fraction: 0.50)
        let sigma = mad / 0.6745
        guard sigma > 1e-9 else {
            return (medianValue, 0, medianValue + 0.0001)
        }
        // `energySalience` is one-sided (sum of |coefficient| across levels,
        // never negative) and right-skewed, not Gaussian — a MAD-based sigma
        // underestimates its upper-tail spread relative to the Gaussian
        // sqrt(2 ln N) formula's assumption, and with hundreds of overlapping
        // windows across many channels the effective number of comparisons is
        // far larger than one window's sample count. The 1.8x margin is an
        // empirical correction for both: tight enough to still catch a
        // genuine local burst, loose enough that per-window/per-channel
        // multiple-comparisons noise stops crossing it by chance.
        let universal = sigma * Float(sqrt(2 * log(Double(max(sampled.count, 2))))) * 1.8
        return (medianValue, sigma, medianValue + universal)
    }

    /// Per-window robust noise statistics for one channel's salience trace,
    /// sampled at window centers. The detection threshold curve and the
    /// per-candidate score both read from this, so the expensive part
    /// (sorting each window) happens once per channel rather than once per
    /// quantity.
    private struct LocalNoiseModel {
        var centers: [Int]
        var medians: [Float]
        var sigmas: [Float]
        var thresholds: [Float]
    }

    private static func localNoiseModel(for values: [Float], windowSamples: Int) -> LocalNoiseModel {
        var model = LocalNoiseModel(centers: [], medians: [], sigmas: [], thresholds: [])
        let n = values.count
        guard n > 0 else { return model }

        func appendWindow(from start: Int, to end: Int) {
            let stats = burstStatistics(Array(values[start..<end]))
            model.centers.append((start + end - 1) / 2)
            model.medians.append(stats.median)
            model.sigmas.append(stats.sigma)
            model.thresholds.append(stats.threshold)
        }

        guard n > windowSamples else {
            appendWindow(from: 0, to: n)
            return model
        }

        let stride = max(windowSamples / 2, 1)
        var start = 0
        while start < n {
            let end = min(start + windowSamples, n)
            appendWindow(from: start, to: end)
            if end == n { break }
            start += stride
        }
        return model
    }

    /// Linearly interpolates a per-window-center quantity at one sample
    /// index, clamping to the nearest center outside the covered span.
    private static func interpolated(_ valuesAtCenters: [Float], centers: [Int], at index: Int) -> Float {
        guard !valuesAtCenters.isEmpty, valuesAtCenters.count == centers.count else { return 0 }
        guard centers.count > 1 else { return valuesAtCenters[0] }
        if index <= centers[0] { return valuesAtCenters[0] }
        if index >= centers[centers.count - 1] { return valuesAtCenters[valuesAtCenters.count - 1] }

        var segment = 0
        while segment < centers.count - 2, index > centers[segment + 1] {
            segment += 1
        }
        let leftCenter = centers[segment]
        let rightCenter = centers[segment + 1]
        let span = Float(rightCenter - leftCenter)
        guard span > 0 else { return valuesAtCenters[segment] }
        let weight = Float(index - leftCenter) / span
        return valuesAtCenters[segment] * (1 - weight) + valuesAtCenters[segment + 1] * weight
    }

    /// Expands a per-window-center quantity into a full per-sample curve.
    private static func interpolatedCurve(_ valuesAtCenters: [Float], centers: [Int], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !valuesAtCenters.isEmpty else { return [Float](repeating: 0, count: count) }
        guard centers.count > 1 else { return [Float](repeating: valuesAtCenters[0], count: count) }

        var result = [Float](repeating: 0, count: count)
        var segment = 0
        for index in 0..<count {
            while segment < centers.count - 2, index > centers[segment + 1] {
                segment += 1
            }
            let leftCenter = centers[segment]
            let rightCenter = centers[segment + 1]
            let leftValue = valuesAtCenters[segment]
            let rightValue = valuesAtCenters[segment + 1]
            if index <= leftCenter {
                result[index] = leftValue
            } else if index >= rightCenter {
                result[index] = rightValue
            } else {
                let span = Float(rightCenter - leftCenter)
                let weight = span > 0 ? Float(index - leftCenter) / span : 0
                result[index] = leftValue * (1 - weight) + rightValue * weight
            }
        }
        return result
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

    /// Robust statistics (median, MAD) are estimated from at most this many
    /// evenly-strided samples. These estimates get recomputed for every
    /// window of every level of every channel, and each one sorts its
    /// sample — at 256 channels this is the single largest cost in the scan
    /// after the transform itself. A median from ~2000 samples carries a
    /// standard error near 3%, far finer than the threshold needs, so the
    /// larger caps were paying an n-log-n price for precision that never
    /// reached the result.
    private static let robustStatisticSampleCap = 2_000

    private static func sampledFiniteValues(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let stride = max(values.count / robustStatisticSampleCap, 1)
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

    /// Anti-aliased decimation, not plain striding. Striding folds everything
    /// above the new Nyquist back into the analysis band, so a fast transient
    /// (muscle/EMG, an electrode pop) doesn't drop out of a downsampled scan —
    /// it reappears at a bogus frequency, which then lands on the wrong
    /// wavelet level and gets classified accordingly. Filtering first means
    /// out-of-band content is genuinely excluded, and the full-rate second
    /// pass (`detectsFastArtifacts`) is what recovers it, at its real
    /// frequency.
    private static func downsampleAndDemean(_ samples: [Float], by decimation: Int) -> [Float] {
        let sanitized = samples.map { $0.isFinite ? $0 : 0 }
        let values = Downsampler.windowedSincDecimated(sanitized, by: max(decimation, 1))
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
}
