//
//  ArtifactTemplateDetector.swift
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
//  Interactive exemplar/template matching for user-defined EEG artifacts.
//

import Foundation

struct ArtifactTemplateConfiguration: Sendable {
    var name: String
    var eventCode: String
    var selectedChannelIndices: [Int]
    var comparisonChannelIndices: [Int]
    var exemplarRange: ClosedRange<Int>
    var matchThreshold: Double
    var windowSizeSeconds: Double
    var downsampleRate: Double
    var mergeWindowSeconds: Double
    var polarity: ArtifactTemplatePolarity
    var comparisonScopes: [ArtifactTemplateComparisonScope] = []
    /// When not `.off`, also scans the recording for the scalp topography
    /// (spatial voltage pattern across all electrodes) of the exemplar window.
    var topographyMode: ArtifactTopographyMode = .off
    /// Channels used for the spatial (topography) correlation. When empty, all
    /// channels are used. Callers should pass good channels only (bad channels
    /// excluded) and may further restrict to a cluster/region of interest.
    var topographyChannelIndices: [Int] = []
    /// Cost function for scoring scalp-map similarity. Independent of `polarity`
    /// (which governs the per-channel waveform scan).
    var topographyMetric: ArtifactTopographyMetric = .pearson
    /// Trajectory mode: maximum allowed time shift (seconds) applied to the
    /// reference trajectory when searching for the best-fitting alignment.
    /// Useful for compensating slight beat-to-beat onset jitter. Set to 0 to
    /// disable shifting.
    var trajectoryShiftSeconds: Double = 0.05
    /// Trajectory mode: fractional time-scale variation (0–1). E.g. 0.10
    /// allows the reference trajectory to be stretched or compressed by ±10%,
    /// accommodating heart-rate variation. Set to 0 to disable scaling.
    var trajectoryScaleRange: Double = 0.10
    /// Trajectory mode: when true (default), each frame's spatial-correlation
    /// contribution is weighted by the GFP of the reference map at that time
    /// point. This focuses the score on frames where the artifact has strong
    /// spatial structure (useful for BCG, saccades, muscle bursts). Disable
    /// for sustained/flat artifacts where the "quiet" periods are part of the
    /// signature you want to match.
    var trajectoryGFPWeighted: Bool = true
}

/// How the similarity between two scalp maps is scored during topography
/// matching. The maps are mean-centred and unit-normalised, so the dot product
/// is Pearson's r.
enum ArtifactTopographyMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Pearson correlation coefficient (same-polarity maps).
    case pearson = "Pearson r"
    /// Absolute Pearson — also matches polarity-inverted maps.
    case absolutePearson = "|Pearson r|"
    /// Negative Pearson — matches the inverted map only.
    case negativePearson = "Opposite (−r)"

    var id: String { rawValue }
}

enum ArtifactTemplatePolarity: String, CaseIterable, Identifiable, Codable, Sendable {
    case same = "Same"
    case opposite = "Opposite"
    case either = "Either"

    var id: String { rawValue }
}

/// How the reference scalp map is derived from the highlighted exemplar window.
enum ArtifactTopographyMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off = "Off"
    case middle = "Window Middle"
    case peak = "Window Peak"
    case average = "Window Average"
    /// Scores candidate windows by *mean* spatial correlation across a sequence
    /// of scalp maps spanning the whole exemplar window, with optional time-shift
    /// and time-scale tolerance. Better suited to BCG than single-map modes
    /// because the BCG topography rotates/propagates across the beat.
    case trajectory = "Trajectory"

    var id: String { rawValue }

    /// Whether topography scanning is requested.
    nonisolated var isEnabled: Bool { self != .off }
}

struct ArtifactTemplateDetectionResult: Sendable {
    var selectedEvents: [MFFEvent]
    var comparisonEvents: [MFFEvent]
    var scopeCounts: [ArtifactTemplateScopeCount]
    var singleChannelMatchCounts: [Int: Int]
    var templateAverage: ArtifactTemplateAverage?
    var savedTemplate: SavedArtifactTemplate
    /// Matches found by scalp-topography scanning (empty when topography is off).
    var topographyEvents: [MFFEvent] = []
    /// The reference scalp map and its scanning metrics (nil when off).
    var topographyReference: ArtifactTemplateTopography? = nil

    var additionalComparisonCount: Int {
        max(comparisonEvents.count - selectedEvents.count, 0)
    }
}

/// The reference scalp topography used for spatial matching, plus the result
/// of scanning the recording for it.
/// One display frame sampled from the trajectory reference window.
struct ArtifactTrajectoryFrame: Sendable, Identifiable {
    var id: Int { frameIndex }
    /// Index within the full (decimated) trajectory.
    var frameIndex: Int
    /// Absolute time in the recording (seconds).
    var timeSeconds: Double
    /// Time relative to the start of the exemplar window (seconds).
    var relativeSeconds: Double
    /// Per-channel amplitude values across ALL channels (indexed by channel).
    var channelValues: [Float]
    /// Raw GFP of this frame before spatial normalisation — used to draw the
    /// amplitude bar and to identify the highest-energy frame.
    var gfp: Float
}

struct ArtifactTemplateTopography: Sendable {
    var mode: ArtifactTopographyMode
    /// Absolute sample whose scalp map was used (window centre, peak GFP sample,
    /// or — for `.average` — the window centre as a nominal time reference).
    var referenceSample: Int
    var referenceTimeSeconds: Double
    /// Per-channel µV defining the template scalp map, indexed by channel.
    var channelValues: [Float]
    /// Channels actually used in the spatial correlation.
    var channelIndices: [Int]
    var matchThreshold: Double
    var matchCount: Int
    /// Number of time frames in the full trajectory (nil for single-map modes).
    var trajectoryFrameCount: Int? = nil
    /// Up to ~10 evenly-spaced display frames sampled from the trajectory,
    /// stored with full-channel values so they can be shown as topomaps.
    /// Nil for non-trajectory modes.
    var trajectoryDisplayFrames: [ArtifactTrajectoryFrame]? = nil
}

struct ArtifactTemplateComparisonScope: Sendable {
    var name: String
    var channelIndices: [Int]
}

struct ArtifactTemplateScopeCount: Identifiable, Sendable {
    var name: String
    var channelCount: Int
    var matchCount: Int

    var id: String { "\(name)-\(channelCount)-\(matchCount)" }
}

struct ArtifactTemplateAverage: Sendable {
    var samplingRate: Double
    var windowSizeSeconds: Double
    var eventCount: Int
    var selectedChannelIndices: [Int]
    var allChannelSamples: [[Float]]
    var channelSummaries: [ArtifactTemplateChannelSummary]
}

struct ArtifactTemplateChannelSummary: Identifiable, Sendable {
    var channelIndex: Int
    var peakAbsoluteMicrovolts: Float
    var rmsMicrovolts: Float

    var id: Int { channelIndex }
}

struct SavedArtifactTemplate: Codable, Sendable {
    var schemaVersion: Int
    var name: String
    var eventCode: String
    var createdAt: Date
    var sourceSignalPath: String
    var sourceSamplingRate: Double
    var exemplarStartSeconds: Double
    var exemplarEndSeconds: Double
    var windowSizeSeconds: Double
    var channelScope: String
    var channels: [SavedArtifactTemplateChannel]
    var preprocessing: SavedArtifactTemplatePreprocessing
    var matching: SavedArtifactTemplateMatching
    var exemplarSamples: [[Float]]
    var averageSamples: [[Float]]?
    var averageEventCount: Int
}

struct SavedArtifactTemplateChannel: Codable, Sendable {
    var index: Int
    var label: String
    var peakAbsoluteMicrovolts: Float
    var rmsMicrovolts: Float
}

struct SavedArtifactTemplatePreprocessing: Codable, Sendable {
    var downsampleRate: Double
    var normalization: String
}

struct SavedArtifactTemplateMatching: Codable, Sendable {
    var threshold: Double
    var mergeWindowSeconds: Double
    var polarity: ArtifactTemplatePolarity
}

nonisolated enum ArtifactTemplateDetector {
    /// Reports scan progress as `(samplesCompleted, samplesTotal)`.
    /// Called periodically from a background thread; callers must hop to the
    /// main actor before updating UI state.
    typealias ProgressHandler = @Sendable (Int, Int) -> Void

    static func detect(
        in signal: MFFSignalData,
        configuration: ArtifactTemplateConfiguration,
        progress: ProgressHandler? = nil
    ) -> ArtifactTemplateDetectionResult {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0 else {
            let emptyTemplate = savedTemplate(
                signal: signal,
                configuration: configuration,
                channelIndices: [],
                exemplarSamples: [],
                average: nil
            )
            return ArtifactTemplateDetectionResult(
                selectedEvents: [],
                comparisonEvents: [],
                scopeCounts: [],
                singleChannelMatchCounts: [:],
                templateAverage: nil,
                savedTemplate: emptyTemplate
            )
        }

        let exemplarRange = clamped(configuration.exemplarRange, upperBound: sampleCount - 1)
        let windowSamples = max(Int((configuration.windowSizeSeconds * signal.samplingRate).rounded()), 3)
        let exemplarCenter = (exemplarRange.lowerBound + exemplarRange.upperBound) / 2
        let exemplarStart = min(max(exemplarCenter - windowSamples / 2, 0), max(sampleCount - windowSamples, 0))
        let exemplarEnd = min(exemplarStart + windowSamples, sampleCount)
        let selectedChannels = SignalSelection.validChannels(configuration.selectedChannelIndices, in: signal)
        let comparisonChannels = SignalSelection.validChannels(configuration.comparisonChannelIndices, in: signal)

        // Progress budget: weight phases by approximate cost.
        // Selected scan (heaviest) = 50%, comparison = 25%, topology = 25%.
        // Scopes and single-channel counts share part of the comparison budget.
        let topoEnabled = configuration.topographyMode.isEnabled
        let selectedWeight  = topoEnabled ? 0.50 : 0.60
        let compareWeight   = topoEnabled ? 0.25 : 0.40
        let topoWeight      = topoEnabled ? 0.25 : 0.00

        func phaseProgress(phase offset: Double, weight: Double) -> ProgressHandler? {
            guard let progress else { return nil }
            return { completed, total in
                let fraction = total > 0 ? offset + weight * Double(completed) / Double(total) : offset
                progress(Int(fraction * Double(sampleCount)), sampleCount)
            }
        }

        let selectedEvents = scan(
            signal: signal,
            channelIndices: selectedChannels,
            exemplarStart: exemplarStart,
            exemplarEnd: exemplarEnd,
            configuration: configuration,
            progress: phaseProgress(phase: 0, weight: selectedWeight)
        )
        let average = average(
            signal: signal,
            events: selectedEvents,
            selectedChannelIndices: selectedChannels,
            windowSamples: windowSamples
        )
        let comparisonEvents = scan(
            signal: signal,
            channelIndices: comparisonChannels,
            exemplarStart: exemplarStart,
            exemplarEnd: exemplarEnd,
            configuration: configuration,
            progress: phaseProgress(phase: selectedWeight, weight: compareWeight * 0.5)
        )
        let scopeCounts = configuration.comparisonScopes.map { scope in
            let channels = SignalSelection.validChannels(scope.channelIndices, in: signal)
            let events = scan(
                signal: signal,
                channelIndices: channels,
                exemplarStart: exemplarStart,
                exemplarEnd: exemplarEnd,
                configuration: configuration
            )
            return ArtifactTemplateScopeCount(
                name: scope.name,
                channelCount: channels.count,
                matchCount: events.count
            )
        }
        let singleChannelMatchCounts = singleChannelCounts(
            signal: signal,
            channelIndices: average?.channelSummaries.prefix(8).map(\.channelIndex) ?? [],
            exemplarStart: exemplarStart,
            exemplarEnd: exemplarEnd,
            configuration: configuration
        )
        let exemplarSamples = selectedChannels.map { index in
            Array(signal.data[index][exemplarStart..<exemplarEnd])
        }
        let saved = savedTemplate(
            signal: signal,
            configuration: configuration,
            channelIndices: selectedChannels,
            exemplarSamples: exemplarSamples,
            average: average
        )

        var topographyEvents: [MFFEvent] = []
        var topographyReference: ArtifactTemplateTopography?
        if topoEnabled {
            (topographyEvents, topographyReference) = detectTopography(
                signal: signal,
                channelIndices: topographyChannels(configuration, in: signal),
                exemplarStart: exemplarStart,
                exemplarEnd: exemplarEnd,
                configuration: configuration,
                progress: phaseProgress(phase: selectedWeight + compareWeight, weight: topoWeight)
            )
        }

        return ArtifactTemplateDetectionResult(
            selectedEvents: selectedEvents,
            comparisonEvents: comparisonEvents,
            scopeCounts: scopeCounts,
            singleChannelMatchCounts: singleChannelMatchCounts,
            templateAverage: average,
            savedTemplate: saved,
            topographyEvents: topographyEvents,
            topographyReference: topographyReference
        )
    }

    // MARK: - Topography (scalp-map) matching

    /// Runs only the scalp-topography scan. Used to refresh the topography
    /// result live (e.g. when the user switches reference mode) without redoing
    /// the more expensive per-channel waveform scans.
    static func detectTopography(
        in signal: MFFSignalData,
        configuration: ArtifactTemplateConfiguration,
        progress: ProgressHandler? = nil
    ) -> (events: [MFFEvent], reference: ArtifactTemplateTopography?) {
        guard configuration.topographyMode.isEnabled,
              signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0 else {
            return ([], nil)
        }

        let exemplarRange = clamped(configuration.exemplarRange, upperBound: sampleCount - 1)
        let windowSamples = max(Int((configuration.windowSizeSeconds * signal.samplingRate).rounded()), 3)
        let exemplarCenter = (exemplarRange.lowerBound + exemplarRange.upperBound) / 2
        let exemplarStart = min(max(exemplarCenter - windowSamples / 2, 0), max(sampleCount - windowSamples, 0))
        let exemplarEnd = min(exemplarStart + windowSamples, sampleCount)

        return detectTopography(
            signal: signal,
            channelIndices: topographyChannels(configuration, in: signal),
            exemplarStart: exemplarStart,
            exemplarEnd: exemplarEnd,
            configuration: configuration,
            progress: progress
        )
    }

    /// Resolves which channels the spatial correlation should use: the explicit
    /// `topographyChannelIndices` when provided, otherwise all channels.
    private static func topographyChannels(
        _ configuration: ArtifactTemplateConfiguration,
        in signal: MFFSignalData
    ) -> [Int] {
        let requested = configuration.topographyChannelIndices.isEmpty
            ? Array(signal.data.indices)
            : configuration.topographyChannelIndices
        return SignalSelection.validChannels(requested, in: signal)
    }

    /// Builds the reference scalp map (or trajectory) from the exemplar window
    /// and scans the recording for matching candidates.
    static func detectTopography(
        signal: MFFSignalData,
        channelIndices: [Int],
        exemplarStart: Int,
        exemplarEnd: Int,
        configuration: ArtifactTemplateConfiguration,
        progress: ProgressHandler? = nil
    ) -> ([MFFEvent], ArtifactTemplateTopography?) {
        guard channelIndices.count >= 3,
              exemplarEnd > exemplarStart,
              signal.samplingRate > 0 else {
            return ([], nil)
        }

        if configuration.topographyMode == .trajectory {
            return detectTrajectory(
                signal: signal,
                channelIndices: channelIndices,
                exemplarStart: exemplarStart,
                exemplarEnd: exemplarEnd,
                configuration: configuration,
                progress: progress
            )
        }

        let referenceSample = topographyReferenceSample(
            signal: signal,
            mode: configuration.topographyMode,
            exemplarStart: exemplarStart,
            exemplarEnd: exemplarEnd,
            channelIndices: channelIndices
        )
        let channelValues = topographyVector(
            signal: signal,
            mode: configuration.topographyMode,
            referenceSample: referenceSample,
            exemplarStart: exemplarStart,
            exemplarEnd: exemplarEnd
        )

        // Template restricted to the correlation channels, spatially normalized.
        let templateRaw = channelIndices.map { channelValues[$0] }
        let template = normalizedSpatial(templateRaw)
        guard !template.isEmpty else {
            return ([], ArtifactTemplateTopography(
                mode: configuration.topographyMode,
                referenceSample: referenceSample,
                referenceTimeSeconds: Double(referenceSample) / signal.samplingRate,
                channelValues: channelValues,
                channelIndices: channelIndices,
                matchThreshold: configuration.matchThreshold,
                matchCount: 0
            ))
        }

        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else {
            return ([], nil)
        }
        let decimation = Downsampler.factor(sourceRate: signal.samplingRate, targetRate: configuration.downsampleRate)
        let mergeSamples = max(Int((configuration.mergeWindowSeconds * signal.samplingRate).rounded()), 1)

        // Split the recording into per-core chunks and score in parallel.
        // Each chunk owns an independent window buffer and writes into its own
        // hits array; we merge at the end — no locking needed.
        let coreCount = evaMaxWorkers
        let decimatedTotal = (sampleCount + decimation - 1) / decimation
        let chunkSize = max((decimatedTotal + coreCount - 1) / coreCount, 1)
        let metric = configuration.topographyMetric
        let threshold = configuration.matchThreshold

        var chunkHits = [[(sample: Int, score: Float)]](repeating: [], count: coreCount)
        nonisolated(unsafe) let chunkHitsPtr = UnsafeMutablePointer<[(sample: Int, score: Float)]>.allocate(capacity: coreCount)
        chunkHitsPtr.initialize(from: &chunkHits, count: coreCount)
        let lock = NSLock()
        nonisolated(unsafe) var globalCompleted = 0

        evaConcurrentPerform(iterations: coreCount) { chunkIdx in
            let startD = chunkIdx * chunkSize
            let endD   = min(startD + chunkSize, decimatedTotal)
            guard startD < endD else { return }

            var localHits: [(sample: Int, score: Float)] = []
            var window = [Float](repeating: 0, count: channelIndices.count)

            for dSample in startD..<endD {
                let sample = dSample * decimation
                for (offset, channelIndex) in channelIndices.enumerated() {
                    let channel = signal.data[channelIndex]
                    window[offset] = sample < channel.count ? channel[sample] : 0
                }
                let normalized = normalizedSpatial(window)
                if !normalized.isEmpty {
                    var dot: Float = 0
                    for index in normalized.indices { dot += template[index] * normalized[index] }
                    let score: Float
                    switch metric {
                    case .pearson:         score =  dot
                    case .negativePearson: score = -dot
                    case .absolutePearson: score =  abs(dot)
                    }
                    if Double(score) >= threshold { localHits.append((sample, score)) }
                }
                lock.lock()
                globalCompleted += 1
                let c = min(globalCompleted * decimation, sampleCount)
                lock.unlock()
                progress?(c, sampleCount)
            }
            chunkHitsPtr[chunkIdx] = localHits
        }
        chunkHits = Array(UnsafeBufferPointer(start: chunkHitsPtr, count: coreCount))
        chunkHitsPtr.deinitialize(count: coreCount)
        chunkHitsPtr.deallocate()
        progress?(sampleCount, sampleCount)

        let hits = chunkHits.flatMap { $0 }

        let merged = mergeTopography(hits: hits, mergeSamples: mergeSamples)
        let events = merged.enumerated().map { index, hit -> MFFEvent in
            let time = Double(hit.sample) / signal.samplingRate
            return MFFEvent(
                id: "artifact-topo-\(index)-\(hit.sample)",
                code: configuration.eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: String(format: "Topography %.0f%%", configuration.matchThreshold * 100)
            )
        }

        let reference = ArtifactTemplateTopography(
            mode: configuration.topographyMode,
            referenceSample: referenceSample,
            referenceTimeSeconds: Double(referenceSample) / signal.samplingRate,
            channelValues: channelValues,
            channelIndices: channelIndices,
            matchThreshold: configuration.matchThreshold,
            matchCount: events.count
        )
        return (events, reference)
    }

    // MARK: - Trajectory topography matching

    /// Scores candidate windows by mean spatial Pearson r across a sequence of
    /// scalp maps spanning the exemplar window, with optional time-shift and
    /// time-scale search to handle onset jitter and heart-rate variation.
    private static func detectTrajectory(
        signal: MFFSignalData,
        channelIndices: [Int],
        exemplarStart: Int,
        exemplarEnd: Int,
        configuration: ArtifactTemplateConfiguration,
        progress: ProgressHandler? = nil
    ) -> ([MFFEvent], ArtifactTemplateTopography?) {
        let sr = signal.samplingRate
        guard channelIndices.count >= 3, exemplarEnd > exemplarStart, sr > 0 else { return ([], nil) }
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return ([], nil) }

        let decimation = Downsampler.factor(sourceRate: sr, targetRate: configuration.downsampleRate)
        let totalDecimatedSamples = sampleCount / decimation
        let mergeSamples = max(Int((configuration.mergeWindowSeconds * sr).rounded()), 1)

        // --- Build reference trajectory ---
        // One normalized spatial map per decimated sample across the exemplar window.
        let exemplarStartD = exemplarStart / decimation
        let exemplarEndD   = min(exemplarEnd / decimation, totalDecimatedSamples)
        let trajectoryLength = max(exemplarEndD - exemplarStartD, 2)

        nonisolated(unsafe) var referenceTrajectory = [[Float]]()
        var referenceGFP = [Float]()          // raw GFP per frame, used as scoring weight
        referenceTrajectory.reserveCapacity(trajectoryLength)
        referenceGFP.reserveCapacity(trajectoryLength)
        for t in 0..<trajectoryLength {
            let sample = (exemplarStartD + t) * decimation
            var rawMap = [Float](repeating: 0, count: channelIndices.count)
            for (offset, chIdx) in channelIndices.enumerated() {
                let ch = signal.data[chIdx]
                rawMap[offset] = sample < ch.count ? ch[sample] : 0
            }
            // Compute GFP (std dev across channels) from the raw map before normalizing.
            let mean = rawMap.reduce(Float(0), +) / Float(max(rawMap.count, 1))
            let gfp  = sqrt(rawMap.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
                            / Float(max(rawMap.count, 1)))
            referenceGFP.append(gfp)
            referenceTrajectory.append(normalizedSpatial(rawMap))
        }
        let actualLength = referenceTrajectory.count
        guard actualLength >= 2 else { return ([], nil) }

        // Weights per frame: GFP-proportional (focuses on amplitude peaks) or uniform.
        let uniform = [Float](repeating: 1.0 / Float(actualLength), count: actualLength)
        let gfpSum = referenceGFP.reduce(Float(0), +)
        let refWeights: [Float] = configuration.trajectoryGFPWeighted && gfpSum > 0
            ? referenceGFP.map { $0 / gfpSum }
            : uniform

        // Middle frame for topomap display (all channels, raw values).
        let middleSampleD = exemplarStartD + actualLength / 2
        let middleSample  = middleSampleD * decimation
        var channelValues = [Float](repeating: 0, count: signal.numberOfChannels)
        for chIdx in signal.data.indices {
            let ch = signal.data[chIdx]
            if middleSample < ch.count { channelValues[chIdx] = ch[middleSample] }
        }

        // Sample up to 10 evenly-spaced frames for the display strip.
        // Each frame captures full-channel raw values so it can be shown as a topomap.
        let displayFrameCount = min(actualLength, 10)
        let windowStartTime = Double(exemplarStartD * decimation) / sr
        let displayFrames: [ArtifactTrajectoryFrame] = (0..<displayFrameCount).map { fi in
            let t = fi * (actualLength - 1) / max(displayFrameCount - 1, 1)
            let dSample = exemplarStartD + t
            let sample  = dSample * decimation
            var fullChannelValues = [Float](repeating: 0, count: signal.numberOfChannels)
            for chIdx in signal.data.indices {
                let ch = signal.data[chIdx]
                if sample < ch.count { fullChannelValues[chIdx] = ch[sample] }
            }
            return ArtifactTrajectoryFrame(
                frameIndex: t,
                timeSeconds: Double(sample) / sr,
                relativeSeconds: Double(sample) / sr - windowStartTime,
                channelValues: fullChannelValues,
                gfp: t < referenceGFP.count ? referenceGFP[t] : 0
            )
        }

        // --- Precompute normalized maps for the whole recording ---
        // Memory: totalDecimatedSamples × channelIndices.count × 4 bytes.
        // At a typical downsample rate of 20–30 Hz and 64 channels over 30 min,
        // this is ~(36 000 × 64 × 4) ≈ 9 MB — well within budget.
        nonisolated(unsafe) var allNormalized = [[Float]](repeating: [], count: totalDecimatedSamples)
        for dSample in 0..<totalDecimatedSamples {
            let sample = dSample * decimation
            var rawMap = [Float](repeating: 0, count: channelIndices.count)
            for (offset, chIdx) in channelIndices.enumerated() {
                let ch = signal.data[chIdx]
                rawMap[offset] = sample < ch.count ? ch[sample] : 0
            }
            allNormalized[dSample] = normalizedSpatial(rawMap)
        }

        // --- Build search grid for time-shift and time-scale ---
        let maxShiftD = max(Int((configuration.trajectoryShiftSeconds * sr / Double(decimation)).rounded()), 0)
        let shiftStep = max(maxShiftD / 4, 1)
        let shifts: [Int] = maxShiftD == 0 ? [0] :
            Array(stride(from: -maxShiftD, through: maxShiftD, by: shiftStep))

        let scaleRange = configuration.trajectoryScaleRange
        let scales: [Double] = scaleRange <= 0 ? [1.0] : [
            1.0 - scaleRange, 1.0 - scaleRange * 0.5, 1.0,
            1.0 + scaleRange * 0.5, 1.0 + scaleRange
        ]

        // --- Slide and score (parallel across CPU cores) ---
        let slideStep = max(actualLength / 8, 1)
        let candidateStarts = Array(stride(from: 0, through: totalDecimatedSamples - actualLength, by: slideStep))
        let totalCandidates = max(candidateStarts.count, 1)

        let coreCount = evaMaxWorkers
        let chunkSize = max((totalCandidates + coreCount - 1) / coreCount, 1)

        var chunkHits = [[(sample: Int, score: Float)]](repeating: [], count: coreCount)
        nonisolated(unsafe) let chunkHitsPtr2 = UnsafeMutablePointer<[(sample: Int, score: Float)]>.allocate(capacity: coreCount)
        chunkHitsPtr2.initialize(from: &chunkHits, count: coreCount)
        let metric = configuration.topographyMetric
        let threshold = configuration.matchThreshold
        let lock = NSLock()
        nonisolated(unsafe) var globalCompleted = 0

        evaConcurrentPerform(iterations: coreCount) { chunkIdx in
            let startIdx = chunkIdx * chunkSize
            let endIdx   = min(startIdx + chunkSize, totalCandidates)
            guard startIdx < endIdx else { return }

            var localHits: [(sample: Int, score: Float)] = []

            for localIdx in startIdx..<endIdx {
                let candidateStartD = candidateStarts[localIdx]
                var bestScore: Float = -1

                for shift in shifts {
                    for scale in scales {
                        // GFP-weighted mean spatial r: peak-amplitude reference frames
                        // drive the score; quiet frames at the window edges barely count.
                        var weightedR: Float = 0
                        var usedWeight: Float = 0
                        for t in 0..<actualLength {
                            let mappedT = Int((Double(t) * scale).rounded()) + shift
                            let targetD = candidateStartD + mappedT
                            guard targetD >= 0, targetD < totalDecimatedSamples else { continue }
                            let refMap  = referenceTrajectory[t]
                            let candMap = allNormalized[targetD]
                            guard candMap.count == refMap.count, !candMap.isEmpty else { continue }
                            var dot: Float = 0
                            for i in refMap.indices { dot += refMap[i] * candMap[i] }
                            let r: Float
                            switch metric {
                            case .pearson:         r =  dot
                            case .negativePearson: r = -dot
                            case .absolutePearson: r =  abs(dot)
                            }
                            let w = refWeights[t]
                            weightedR  += r * w
                            usedWeight += w
                        }
                        if usedWeight > 0 {
                            let score = weightedR / usedWeight
                            if score > bestScore { bestScore = score }
                        }
                    }
                }

                if Double(bestScore) >= threshold {
                    let centerSample = (candidateStartD + actualLength / 2) * decimation
                    localHits.append((sample: centerSample, score: bestScore))
                }

                lock.lock()
                globalCompleted += 1
                let c = min(globalCompleted * sampleCount / totalCandidates, sampleCount)
                lock.unlock()
                progress?(c, sampleCount)
            }
            chunkHitsPtr2[chunkIdx] = localHits
        }
        chunkHits = Array(UnsafeBufferPointer(start: chunkHitsPtr2, count: coreCount))
        chunkHitsPtr2.deinitialize(count: coreCount)
        chunkHitsPtr2.deallocate()
        progress?(sampleCount, sampleCount)

        let hits = chunkHits.flatMap { $0 }

        let merged = mergeTopography(hits: hits, mergeSamples: mergeSamples)
        let events = merged.enumerated().map { index, hit -> MFFEvent in
            let time = Double(hit.sample) / sr
            return MFFEvent(
                id: "artifact-trajectory-\(index)-\(hit.sample)",
                code: configuration.eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: String(format: "Trajectory %.0f%%", configuration.matchThreshold * 100)
            )
        }

        let reference = ArtifactTemplateTopography(
            mode: .trajectory,
            referenceSample: middleSample,
            referenceTimeSeconds: Double(middleSample) / sr,
            channelValues: channelValues,
            channelIndices: channelIndices,
            matchThreshold: configuration.matchThreshold,
            matchCount: events.count,
            trajectoryFrameCount: actualLength,
            trajectoryDisplayFrames: displayFrames
        )
        return (events, reference)
    }

    /// The exemplar sample whose scalp map seeds the template. For `.peak` this
    /// is the sample of maximum global field power within the window.
    private static func topographyReferenceSample(
        signal: MFFSignalData,
        mode: ArtifactTopographyMode,
        exemplarStart: Int,
        exemplarEnd: Int,
        channelIndices: [Int]
    ) -> Int {
        let center = (exemplarStart + exemplarEnd) / 2
        guard mode == .peak else { return center }

        var bestSample = center
        var bestGFP: Float = -1
        for sample in exemplarStart..<exemplarEnd {
            let gfp = globalFieldPower(signal: signal, sample: sample, channelIndices: channelIndices)
            if gfp > bestGFP {
                bestGFP = gfp
                bestSample = sample
            }
        }
        return bestSample
    }

    /// Per-channel reference values (indexed by channel) for the whole montage,
    /// so the result can be drawn as a topomap.
    private static func topographyVector(
        signal: MFFSignalData,
        mode: ArtifactTopographyMode,
        referenceSample: Int,
        exemplarStart: Int,
        exemplarEnd: Int
    ) -> [Float] {
        let channelCount = signal.numberOfChannels
        var values = [Float](repeating: 0, count: channelCount)

        if mode == .average {
            let count = max(exemplarEnd - exemplarStart, 1)
            for channelIndex in 0..<channelCount {
                let channel = signal.data[channelIndex]
                guard channel.count >= exemplarEnd else { continue }
                var sum: Float = 0
                for sample in exemplarStart..<exemplarEnd {
                    sum += channel[sample]
                }
                values[channelIndex] = sum / Float(count)
            }
        } else {
            for channelIndex in 0..<channelCount {
                let channel = signal.data[channelIndex]
                guard referenceSample < channel.count else { continue }
                values[channelIndex] = channel[referenceSample]
            }
        }
        return values
    }

    private static func globalFieldPower(
        signal: MFFSignalData,
        sample: Int,
        channelIndices: [Int]
    ) -> Float {
        var values: [Float] = []
        values.reserveCapacity(channelIndices.count)
        for channelIndex in channelIndices {
            let channel = signal.data[channelIndex]
            if sample < channel.count {
                values.append(channel[sample])
            }
        }
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(Float(0), +) / Float(values.count)
        let variance = values.reduce(Float(0)) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Float(values.count)
        return sqrt(variance)
    }

    /// Mean-centres a topography vector across channels and scales to unit norm,
    /// so a dot product between two such vectors is their spatial correlation.
    private static func normalizedSpatial(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let mean = values.reduce(Float(0), +) / Float(values.count)
        var centered = values.map { $0 - mean }
        let norm = sqrt(centered.reduce(Float(0)) { $0 + ($1 * $1) })
        guard norm > 0 else { return [] }
        for index in centered.indices {
            centered[index] /= norm
        }
        return centered
    }

    private static func mergeTopography(
        hits: [(sample: Int, score: Float)],
        mergeSamples: Int
    ) -> [(sample: Int, score: Float)] {
        let sorted = hits.sorted {
            $0.sample == $1.sample ? $0.score > $1.score : $0.sample < $1.sample
        }
        var merged: [(sample: Int, score: Float)] = []
        for hit in sorted {
            guard let last = merged.last else {
                merged.append(hit)
                continue
            }
            if hit.sample - last.sample <= mergeSamples {
                if hit.score > last.score {
                    merged[merged.count - 1] = hit
                }
            } else {
                merged.append(hit)
            }
        }
        return merged
    }

    private static func singleChannelCounts(
        signal: MFFSignalData,
        channelIndices: [Int],
        exemplarStart: Int,
        exemplarEnd: Int,
        configuration: ArtifactTemplateConfiguration
    ) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for channelIndex in Array(Set(channelIndices)).sorted() {
            let events = scan(
                signal: signal,
                channelIndices: [channelIndex],
                exemplarStart: exemplarStart,
                exemplarEnd: exemplarEnd,
                configuration: configuration
            )
            counts[channelIndex] = events.count
        }
        return counts
    }

    private static func scan(
        signal: MFFSignalData,
        channelIndices: [Int],
        exemplarStart: Int,
        exemplarEnd: Int,
        configuration: ArtifactTemplateConfiguration,
        progress: ProgressHandler? = nil
    ) -> [MFFEvent] {
        guard !channelIndices.isEmpty,
              exemplarEnd > exemplarStart,
              let sampleCount = signal.data.first?.count else {
            return []
        }

        let decimation = Downsampler.factor(sourceRate: signal.samplingRate, targetRate: configuration.downsampleRate)
        let downsampledRate = signal.samplingRate / Double(decimation)
        let templateStart = exemplarStart / decimation
        let templateEnd = max(exemplarEnd / decimation, templateStart + 3)
        let templateLength = templateEnd - templateStart
        guard templateLength >= 3 else { return [] }

        let downsampledChannels = channelIndices.map { Downsampler.strided(signal.data[$0], by: decimation) }
        guard let downsampledCount = downsampledChannels.first?.count,
              downsampledCount >= templateLength else {
            return []
        }

        let templatePairs = downsampledChannels.map { channel in
            normalized(Array(channel[templateStart..<min(templateEnd, channel.count)]))
        }
        guard templatePairs.allSatisfy({ $0.normalized.count == templateLength }) else {
            return []
        }

        let templates = templatePairs.map(\.normalized)
        let weights = templatePairs.map { max(rms($0.original), 0.0001) }
        let totalWeight = max(weights.reduce(0, +), 0.0001)
        let candidates = candidateStarts(
            channels: downsampledChannels,
            weights: weights,
            templateLength: templateLength
        )
        let mergeSamples = max(Int((configuration.mergeWindowSeconds * downsampledRate).rounded()), 1)

        var hits: [(start: Int, score: Float)] = []
        let totalCandidates = max(candidates.count, 1)
        let reportEvery = max(totalCandidates / 20, 1)
        for (candidateIdx, start) in candidates.enumerated() where start >= 0 && start + templateLength <= downsampledCount {
            defer {
                if candidateIdx % reportEvery == 0 {
                    progress?(candidateIdx * downsampledCount / totalCandidates * decimation, sampleCount)
                }
            }
            var weightedScore: Float = 0
            for channelOffset in downsampledChannels.indices {
                let channel = downsampledChannels[channelOffset]
                let window = normalized(Array(channel[start..<(start + templateLength)])).normalized
                guard !window.isEmpty else { continue }
                var dot: Float = 0
                for sample in window.indices {
                    dot += templates[channelOffset][sample] * window[sample]
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
                weightedScore += score * weights[channelOffset]
            }

            let score = weightedScore / totalWeight
            if Double(score) >= configuration.matchThreshold {
                hits.append((start, score))
            }
        }

        progress?(sampleCount, sampleCount)
        let merged = SignalSelection.mergeNearbyStarts(hits, mergeSamples: mergeSamples)
        return merged.enumerated().map { index, hit in
            let centerSample = min(max((hit.start + templateLength / 2) * decimation, 0), sampleCount - 1)
            let time = Double(centerSample) / signal.samplingRate
            return MFFEvent(
                id: "artifact-template-\(index)-\(centerSample)",
                code: configuration.eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: String(format: "Template %.0f%%", configuration.matchThreshold * 100)
            )
        }
    }

    private static func candidateStarts(
        channels: [[Float]],
        weights: [Float],
        templateLength: Int
    ) -> [Int] {
        guard let sampleCount = channels.first?.count, sampleCount >= templateLength else { return [] }
        var projection = [Float](repeating: 0, count: sampleCount)
        let totalWeight = max(weights.reduce(0, +), 0.0001)

        for channelOffset in channels.indices {
            let weight = weights[channelOffset] / totalWeight
            let channel = channels[channelOffset]
            for sample in channel.indices {
                projection[sample] += abs(channel[sample]) * weight
            }
        }

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
            candidates.append(min(max(sample - templateLength / 2, 0), sampleCount - templateLength))
            lastAccepted = sample
        }

        if candidates.count < 12 {
            let fallbackStride = max(templateLength / 4, 1)
            candidates = Array(stride(from: 0, through: sampleCount - templateLength, by: fallbackStride))
        }

        return Array(Set(candidates)).sorted()
    }

    private static func average(
        signal: MFFSignalData,
        events: [MFFEvent],
        selectedChannelIndices: [Int],
        windowSamples: Int
    ) -> ArtifactTemplateAverage? {
        guard !events.isEmpty,
              windowSamples > 1,
              let sampleCount = signal.data.first?.count else {
            return nil
        }

        var averages = Array(repeating: [Float](repeating: 0, count: windowSamples), count: signal.numberOfChannels)
        var accepted = 0

        for event in events {
            let center = Int((event.beginTimeSeconds * signal.samplingRate).rounded())
            let start = center - windowSamples / 2
            let end = start + windowSamples
            guard start >= 0, end <= sampleCount else { continue }

            for channelIndex in signal.data.indices {
                let channel = signal.data[channelIndex]
                guard channel.count >= end else { continue }
                for offset in 0..<windowSamples {
                    averages[channelIndex][offset] += channel[start + offset]
                }
            }
            accepted += 1
        }

        guard accepted > 0 else { return nil }
        let divisor = Float(accepted)
        for channelIndex in averages.indices {
            for sample in averages[channelIndex].indices {
                averages[channelIndex][sample] /= divisor
            }
        }

        var summaries: [ArtifactTemplateChannelSummary] = []
        for channelIndex in averages.indices {
            let channelSamples: [Float] = averages[channelIndex]
            let peak = channelSamples.map { abs($0) }.max() ?? 0
            let channelRMS = rms(channelSamples)
            summaries.append(ArtifactTemplateChannelSummary(
                channelIndex: channelIndex,
                peakAbsoluteMicrovolts: peak,
                rmsMicrovolts: channelRMS
            ))
        }
        summaries.sort {
            $0.peakAbsoluteMicrovolts == $1.peakAbsoluteMicrovolts
                ? $0.channelIndex < $1.channelIndex
                : $0.peakAbsoluteMicrovolts > $1.peakAbsoluteMicrovolts
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

    private static func savedTemplate(
        signal: MFFSignalData,
        configuration: ArtifactTemplateConfiguration,
        channelIndices: [Int],
        exemplarSamples: [[Float]],
        average: ArtifactTemplateAverage?
    ) -> SavedArtifactTemplate {
        let startSeconds = Double(configuration.exemplarRange.lowerBound) / max(signal.samplingRate, 1)
        let endSeconds = Double(configuration.exemplarRange.upperBound) / max(signal.samplingRate, 1)
        let summariesByChannel = Dictionary(uniqueKeysWithValues: (average?.channelSummaries ?? []).map { ($0.channelIndex, $0) })
        let channels = channelIndices.enumerated().map { offset, index in
            let samples = offset < exemplarSamples.count ? exemplarSamples[offset] : []
            let summary = summariesByChannel[index]
            return SavedArtifactTemplateChannel(
                index: index,
                label: "Ch \(index + 1)",
                peakAbsoluteMicrovolts: summary?.peakAbsoluteMicrovolts ?? (samples.map(abs).max() ?? 0),
                rmsMicrovolts: summary?.rmsMicrovolts ?? rms(samples)
            )
        }

        return SavedArtifactTemplate(
            schemaVersion: 1,
            name: configuration.name,
            eventCode: configuration.eventCode,
            createdAt: Date(),
            sourceSignalPath: signal.signalURL.path,
            sourceSamplingRate: signal.samplingRate,
            exemplarStartSeconds: startSeconds,
            exemplarEndSeconds: endSeconds,
            windowSizeSeconds: configuration.windowSizeSeconds,
            channelScope: channelIndices.count == signal.numberOfChannels ? "all" : "specific",
            channels: channels,
            preprocessing: SavedArtifactTemplatePreprocessing(
                downsampleRate: configuration.downsampleRate,
                normalization: "per-channel zscore"
            ),
            matching: SavedArtifactTemplateMatching(
                threshold: configuration.matchThreshold,
                mergeWindowSeconds: configuration.mergeWindowSeconds,
                polarity: configuration.polarity
            ),
            exemplarSamples: exemplarSamples,
            averageSamples: selectedAverageSamples(from: average),
            averageEventCount: average?.eventCount ?? 0
        )
    }

    private static func selectedAverageSamples(from average: ArtifactTemplateAverage?) -> [[Float]]? {
        guard let average else { return nil }
        return average.selectedChannelIndices.compactMap { index in
            guard index >= 0, index < average.allChannelSamples.count else { return nil }
            return average.allChannelSamples[index]
        }
    }

    private static func clamped(_ range: ClosedRange<Int>, upperBound: Int) -> ClosedRange<Int> {
        let lower = min(max(range.lowerBound, 0), upperBound)
        let upper = min(max(range.upperBound, lower), upperBound)
        return lower...upper
    }


    private static func normalized(_ samples: [Float]) -> (original: [Float], normalized: [Float]) {
        guard !samples.isEmpty else { return (samples, []) }
        let mean = samples.reduce(Float(0), +) / Float(samples.count)
        var centered = samples.map { $0 - mean }
        let norm = sqrt(centered.reduce(Float(0)) { $0 + ($1 * $1) })
        guard norm > 0 else { return (samples, []) }
        for index in centered.indices {
            centered[index] /= norm
        }
        return (samples, centered)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float(0)) { $0 + ($1 * $1) } / Float(samples.count)
        return sqrt(meanSquare)
    }
}
