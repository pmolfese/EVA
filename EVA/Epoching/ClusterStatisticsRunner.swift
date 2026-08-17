//
//  ClusterStatisticsRunner.swift
//  EVA
//
//  Prepares EVA's retained pre-average epochs for cluster permutation testing.
//  Average reference and baseline correction are applied per trial here because
//  those linear operations are applied only after averaging in the PSA path.
//

import Foundation

nonisolated enum ClusterStatisticKind: String, CaseIterable, Identifiable, Sendable {
    case t = "Two-condition t"
    case f = "Multi-condition F"

    var id: String { rawValue }
}

nonisolated struct ClusterStatisticsJob: Sendable {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let statistic: ClusterStatisticKind
    let conditionNames: [String]
    let sensorLayout: SensorLayout?
    let badChannels: Set<Int>
    let averageReference: Bool
    let baselineCorrected: Bool
    let windowStartMs: Double
    let windowEndMs: Double
    let sampleStride: Int
    let permutationCount: Int
    let clusterThreshold: Double
    let seed: UInt64
}

nonisolated struct ClusterStatisticsAnalysis: Sendable {
    let statistic: ClusterStatisticKind
    let conditionNames: [String]
    let conditionCounts: [Int]
    let numeratorDegreesOfFreedom: Int?
    let denominatorDegreesOfFreedom: Int?
    let channelCount: Int
    let sampleCount: Int
    let observedStatistics: [Double]
    let clusters: [ClusterPermutationAnalyzer.Cluster]
    let permutationCount: Int
    let clusterThreshold: Double
}

nonisolated struct ClusterStatisticsOutput: Sendable {
    /// Identifies the raw signal used to compute the result so stale results
    /// can be discarded after a file or preprocessing change.
    let dataRevision: UUID
    let analysis: ClusterStatisticsAnalysis
    /// Local analysis channel index -> original signal channel index.
    let channelIndices: [Int]
    /// Analysis sample index -> samples relative to each epoch's stimulus.
    let relativeSampleOffsets: [Int]
    let samplingRate: Double
    /// Corrected cluster id -> category -> across-trial ROI waveform summary.
    let clusterWaveforms: [Int: [String: ClusterWaveformSummary]]
    let usedSpatialAdjacency: Bool
}

nonisolated struct ClusterWaveformSummary: Sendable, Equatable {
    let mean: [Double]
    /// Standard error across trials after averaging each trial over the
    /// cluster's participating sensors.
    let standardError: [Double]
}

nonisolated struct ClusterStatisticsRunResponse: Sendable {
    let output: ClusterStatisticsOutput?
    let errorMessage: String?

    static let cancelled = ClusterStatisticsRunResponse(output: nil, errorMessage: nil)
}

nonisolated enum ClusterStatisticsRunner {
    static func run(
        job: ClusterStatisticsJob,
        progress: AsyncStream<SingleTrialRunProgress>.Continuation
    ) -> ClusterStatisticsRunResponse {
        do {
            progress.yield(.init(fraction: 0.02, title: "Cluster Statistics", detail: "Preparing single trials…"))
            let prepared = try prepare(job: job)
            if Task.isCancelled { return .cancelled }
            progress.yield(.init(
                fraction: 0.10,
                title: "Cluster Statistics",
                detail: "Permuting condition labels on \(min(evaMaxWorkers, job.permutationCount)) CPU workers…"
            ))
            let progressHandler: @Sendable (Double) -> Void = { fraction in
                progress.yield(.init(
                    fraction: 0.10 + 0.88 * fraction,
                    title: "Cluster Statistics",
                    detail: "Permutation \(max(Int((fraction * Double(job.permutationCount)).rounded()), 1)) of \(job.permutationCount) · \(min(evaMaxWorkers, job.permutationCount)) workers"
                ))
            }
            let analysis: ClusterStatisticsAnalysis
            switch job.statistic {
            case .t:
                guard prepared.conditions.count == 2 else { throw PreparationError.missingConditions }
                let result = try ClusterPermutationAnalyzer.analyze(
                    input: .init(
                        conditionA: .init(name: prepared.conditions[0].name, trials: prepared.conditions[0].trials),
                        conditionB: .init(name: prepared.conditions[1].name, trials: prepared.conditions[1].trials),
                        channelCount: prepared.channelIndices.count,
                        sampleCount: prepared.relativeSampleOffsets.count,
                        spatialAdjacency: prepared.spatialAdjacency
                    ),
                    configuration: .init(
                        permutationCount: job.permutationCount,
                        clusterThreshold: job.clusterThreshold,
                        seed: job.seed
                    ),
                    progress: progressHandler
                )
                guard let result else { return .cancelled }
                analysis = ClusterStatisticsAnalysis(
                    statistic: .t,
                    conditionNames: [result.conditionA, result.conditionB],
                    conditionCounts: [result.conditionACount, result.conditionBCount],
                    numeratorDegreesOfFreedom: nil,
                    denominatorDegreesOfFreedom: result.conditionACount + result.conditionBCount - 2,
                    channelCount: result.channelCount,
                    sampleCount: result.sampleCount,
                    observedStatistics: result.observedStatistics,
                    clusters: result.clusters,
                    permutationCount: result.configuration.permutationCount,
                    clusterThreshold: result.configuration.clusterThreshold
                )
            case .f:
                let result = try ClusterPermutationFAnalyzer.analyze(
                    input: .init(
                        conditions: prepared.conditions.map { .init(name: $0.name, trials: $0.trials) },
                        channelCount: prepared.channelIndices.count,
                        sampleCount: prepared.relativeSampleOffsets.count,
                        spatialAdjacency: prepared.spatialAdjacency
                    ),
                    configuration: .init(
                        permutationCount: job.permutationCount,
                        clusterThreshold: job.clusterThreshold,
                        seed: job.seed
                    ),
                    progress: progressHandler
                )
                guard let result else { return .cancelled }
                analysis = ClusterStatisticsAnalysis(
                    statistic: .f,
                    conditionNames: result.conditionNames,
                    conditionCounts: result.conditionCounts,
                    numeratorDegreesOfFreedom: result.numeratorDegreesOfFreedom,
                    denominatorDegreesOfFreedom: result.denominatorDegreesOfFreedom,
                    channelCount: result.channelCount,
                    sampleCount: result.sampleCount,
                    observedStatistics: result.observedStatistics,
                    clusters: result.clusters,
                    permutationCount: result.configuration.permutationCount,
                    clusterThreshold: result.configuration.clusterThreshold
                )
            }
            progress.yield(.init(fraction: 0.99, title: "Cluster Statistics", detail: "Summarizing condition means…"))
            let clusterWaveforms = waveformSummaries(analysis: analysis, conditions: prepared.conditions)
            progress.yield(.init(fraction: 1, title: "Cluster Statistics", detail: "Ready to inspect."))
            return ClusterStatisticsRunResponse(
                output: ClusterStatisticsOutput(
                    dataRevision: job.signal.dataRevision,
                    analysis: analysis,
                    channelIndices: prepared.channelIndices,
                    relativeSampleOffsets: prepared.relativeSampleOffsets,
                    samplingRate: job.signal.samplingRate,
                    clusterWaveforms: clusterWaveforms,
                    usedSpatialAdjacency: prepared.usedSpatialAdjacency
                ),
                errorMessage: nil
            )
        } catch let error as PreparationError {
            return ClusterStatisticsRunResponse(output: nil, errorMessage: error.message)
        } catch let error as ClusterPermutationAnalyzer.AnalysisError {
            return ClusterStatisticsRunResponse(output: nil, errorMessage: message(for: error))
        } catch let error as ClusterPermutationFAnalyzer.AnalysisError {
            return ClusterStatisticsRunResponse(output: nil, errorMessage: message(for: error))
        } catch {
            return ClusterStatisticsRunResponse(output: nil, errorMessage: "Cluster statistics could not be computed.")
        }
    }

    private struct PreparedData {
        let conditions: [PreparedCondition]
        let channelIndices: [Int]
        let relativeSampleOffsets: [Int]
        let spatialAdjacency: [[Int]]
        let usedSpatialAdjacency: Bool
    }

    private struct PreparedCondition {
        let name: String
        let trials: [[Double]]
    }

    private enum PreparationError: Error {
        case invalidWindow
        case windowOutsideEpochs(Double, Double)
        case missingConditions
        case overlappingConditions
        case insufficientTrials(String, Int)
        case noChannels

        var message: String {
            switch self {
            case .invalidWindow:
                return "Choose a valid time window with at least two samples."
            case .windowOutsideEpochs(let startMs, let endMs):
                return "The selected window is outside the common retained-trial interval (\(formatMilliseconds(startMs)) to \(formatMilliseconds(endMs)) ms)."
            case .missingConditions:
                return "Choose the required number of distinct categories containing retained single trials."
            case .overlappingConditions:
                return "These categories share source trials. Choose mutually exclusive categories; overlapping category groups cannot be label-permuted as independent observations."
            case .insufficientTrials(let category, let count):
                return "\(category) has \(count) usable trial\(count == 1 ? "" : "s"); at least two are required."
            case .noChannels:
                return "No good EEG channels with usable samples are available."
            }
        }
    }

    private static func prepare(job: ClusterStatisticsJob) throws -> PreparedData {
        guard job.signal.samplingRate > 0,
              job.permutationCount > 0,
              job.clusterThreshold > 0,
              job.windowEndMs > job.windowStartMs else { throw PreparationError.invalidWindow }

        let requiredConditionCount = job.statistic == .t ? 2 : 3
        let conditionNames = job.conditionNames.reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        guard conditionNames.count >= requiredConditionCount,
              job.statistic != .t || conditionNames.count == 2 else {
            throw PreparationError.missingConditions
        }
        let segmentsByCondition = conditionNames.map { name in
            (name, job.segments.filter { $0.category == name })
        }
        guard segmentsByCondition.allSatisfy({ !$0.1.isEmpty }) else { throw PreparationError.missingConditions }

        // PSA category groups deliberately duplicate a source event into every
        // category it belongs to. Such a trial cannot occur in more than one
        // cell of an independent label-permutation design.
        var seenSourceTrials = Set<Int64>()
        for (_, segments) in segmentsByCondition {
            let keys = Set(segments.map(sourceTrialKey))
            guard seenSourceTrials.isDisjoint(with: keys) else { throw PreparationError.overlappingConditions }
            seenSourceTrials.formUnion(keys)
        }

        let rate = job.signal.samplingRate
        let startRelative = Int((job.windowStartMs * rate / 1_000).rounded())
        let endRelative = Int((job.windowEndMs * rate / 1_000).rounded())
        guard endRelative > startRelative else { throw PreparationError.invalidWindow }
        let selectedSegments = segmentsByCondition.flatMap { $0.1 }
        guard let availableSamples = commonRelativeSampleWindow(segments: selectedSegments),
              startRelative >= availableSamples.lowerBound,
              endRelative <= availableSamples.upperBound else {
            let available = commonWindowMilliseconds(segments: selectedSegments, samplingRate: rate)
            throw PreparationError.windowOutsideEpochs(
                available?.lowerBound ?? 0,
                available?.upperBound ?? 0
            )
        }
        let sampleStride = max(job.sampleStride, 1)
        let relativeOffsets = Array(Swift.stride(from: startRelative, through: endRelative, by: sampleStride))
        guard relativeOffsets.count > 1 else { throw PreparationError.invalidWindow }

        let layoutChannels = Set(job.sensorLayout?.positions.map(\.channelIndex) ?? [])
        let candidateChannels = layoutChannels.isEmpty
            ? Array(job.signal.data.indices)
            : job.signal.data.indices.filter { layoutChannels.contains($0) }
        let channels = candidateChannels.filter { !job.badChannels.contains($0) }
        guard !channels.isEmpty else { throw PreparationError.noChannels }

        let adjacency = spatialAdjacency(channelIndices: channels, layout: job.sensorLayout)
        let featureCount = channels.count * relativeOffsets.count
        let referenceChannels = job.signal.data.indices.filter { !job.badChannels.contains($0) }

        func preparedTrials(_ segments: [EpochSegment]) -> [[Double]] {
            var trials: [[Double]] = []
            trials.reserveCapacity(segments.count)
            for segment in segments {
                if Task.isCancelled { break }
                guard let trial = prepareTrial(
                    segment: segment,
                    signal: job.signal,
                    channelIndices: channels,
                    referenceChannels: referenceChannels,
                    relativeSampleOffsets: relativeOffsets,
                    averageReference: job.averageReference,
                    baselineCorrected: job.baselineCorrected
                ), trial.count == featureCount else { continue }
                trials.append(trial)
            }
            return trials
        }

        let preparedConditions = try segmentsByCondition.map { name, segments -> PreparedCondition in
            let trials = preparedTrials(segments)
            guard trials.count >= 2 else { throw PreparationError.insufficientTrials(name, trials.count) }
            return PreparedCondition(name: name, trials: trials)
        }
        return PreparedData(
            conditions: preparedConditions,
            channelIndices: channels,
            relativeSampleOffsets: relativeOffsets,
            spatialAdjacency: adjacency,
            usedSpatialAdjacency: adjacency.contains { !$0.isEmpty }
        )
    }

    private static func prepareTrial(
        segment: EpochSegment,
        signal: MFFSignalData,
        channelIndices: [Int],
        referenceChannels: [Int],
        relativeSampleOffsets: [Int],
        averageReference: Bool,
        baselineCorrected: Bool
    ) -> [Double]? {
        let length = segment.endSample - segment.startSample + 1
        guard length > 1, segment.startSample >= 0,
              channelIndices.allSatisfy({ signal.data[$0].count > segment.endSample }) else { return nil }

        let validReferenceChannels = averageReference
            ? referenceChannels.filter { signal.data[$0].count > segment.endSample }
            : []
        func referenceMean(at sample: Int) -> Double {
            guard averageReference, !validReferenceChannels.isEmpty else { return 0 }
            var sum = 0.0
            var count = 0
            for channel in validReferenceChannels {
                let value = Double(signal.data[channel][sample])
                guard value.isFinite else { continue }
                sum += value
                count += 1
            }
            return count > 0 ? sum / Double(count) : 0
        }

        var baselines = [Double](repeating: 0, count: channelIndices.count)
        if baselineCorrected {
            let baselineCount = min(max(segment.stimulusOffsetSamples, 0), length)
            if baselineCount > 0 {
                for offset in 0..<baselineCount {
                    let sample = segment.startSample + offset
                    let reference = referenceMean(at: sample)
                    for (localChannel, channel) in channelIndices.enumerated() {
                        baselines[localChannel] += Double(signal.data[channel][sample]) - reference
                    }
                }
                for channel in baselines.indices { baselines[channel] /= Double(baselineCount) }
            }
        }

        var trial = [Double](repeating: 0, count: channelIndices.count * relativeSampleOffsets.count)
        for (localSample, relativeOffset) in relativeSampleOffsets.enumerated() {
            let epochOffset = segment.stimulusOffsetSamples + relativeOffset
            guard epochOffset >= 0, epochOffset < length else { return nil }
            let sample = segment.startSample + epochOffset
            let reference = referenceMean(at: sample)
            for (localChannel, channel) in channelIndices.enumerated() {
                let value = Double(signal.data[channel][sample]) - reference - baselines[localChannel]
                guard value.isFinite else { return nil }
                trial[localChannel * relativeSampleOffsets.count + localSample] = value
            }
        }
        return trial
    }

    private static func sourceTrialKey(_ segment: EpochSegment) -> Int64 {
        Int64((segment.sourceTimeSeconds * 1_000_000).rounded())
    }

    /// Largest stimulus-relative interval represented by every supplied epoch.
    /// Cluster tests require the same channel × time features for every trial,
    /// unlike scalar measurements, which can safely clip each trial separately.
    static func commonWindowMilliseconds(
        segments: [EpochSegment],
        samplingRate: Double
    ) -> ClosedRange<Double>? {
        guard samplingRate > 0,
              let samples = commonRelativeSampleWindow(segments: segments) else { return nil }
        return (Double(samples.lowerBound) / samplingRate * 1_000)...(Double(samples.upperBound) / samplingRate * 1_000)
    }

    private static func commonRelativeSampleWindow(segments: [EpochSegment]) -> ClosedRange<Int>? {
        guard !segments.isEmpty else { return nil }
        var lowerBound = Int.min
        var upperBound = Int.max
        for segment in segments {
            let length = segment.endSample - segment.startSample + 1
            guard length > 1, segment.stimulusOffsetSamples >= 0,
                  segment.stimulusOffsetSamples < length else { return nil }
            lowerBound = max(lowerBound, -segment.stimulusOffsetSamples)
            upperBound = min(upperBound, length - 1 - segment.stimulusOffsetSamples)
        }
        guard lowerBound < upperBound else { return nil }
        return lowerBound...upperBound
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }

    private static func waveformSummaries(
        analysis: ClusterStatisticsAnalysis,
        conditions: [PreparedCondition]
    ) -> [Int: [String: ClusterWaveformSummary]] {
        var summaries: [Int: [String: ClusterWaveformSummary]] = [:]
        // The UI's most permissive corrected threshold is .10; waveform
        // summaries for clusters that can never be displayed would only retain
        // potentially large arrays of redundant means and SEMs.
        for cluster in analysis.clusters where cluster.pValue <= 0.10 {
            var byCondition: [String: ClusterWaveformSummary] = [:]
            for condition in conditions {
                byCondition[condition.name] = waveformSummary(
                    trials: condition.trials,
                    channelIndices: cluster.channelIndices,
                    sampleCount: analysis.sampleCount
                )
            }
            summaries[cluster.id] = byCondition
        }
        return summaries
    }

    static func waveformSummary(
        trials: [[Double]],
        channelIndices: [Int],
        sampleCount: Int
    ) -> ClusterWaveformSummary {
        guard trials.count > 0, !channelIndices.isEmpty, sampleCount > 0 else {
            return ClusterWaveformSummary(
                mean: [Double](repeating: 0, count: max(sampleCount, 0)),
                standardError: [Double](repeating: 0, count: max(sampleCount, 0))
            )
        }

        var means = [Double](repeating: 0, count: sampleCount)
        var standardErrors = [Double](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            var runningMean = 0.0
            var sumSquaredDeviations = 0.0
            var count = 0
            for trial in trials {
                var sensorSum = 0.0
                var sensorCount = 0
                for channel in channelIndices {
                    let feature = channel * sampleCount + sample
                    guard trial.indices.contains(feature) else { continue }
                    sensorSum += trial[feature]
                    sensorCount += 1
                }
                guard sensorCount > 0 else { continue }
                let trialMean = sensorSum / Double(sensorCount)
                count += 1
                let delta = trialMean - runningMean
                runningMean += delta / Double(count)
                sumSquaredDeviations += delta * (trialMean - runningMean)
            }
            means[sample] = runningMean
            if count > 1 {
                let sampleVariance = sumSquaredDeviations / Double(count - 1)
                standardErrors[sample] = sqrt(max(sampleVariance, 0) / Double(count))
            }
        }
        return ClusterWaveformSummary(mean: means, standardError: standardErrors)
    }

    /// Symmetric four-nearest-neighbor graph in EVA's normalized 2D sensor
    /// projection. This gives imported montages the same spatial-clustering
    /// capability as MFF layouts without requiring format-specific templates.
    private static func spatialAdjacency(channelIndices: [Int], layout: SensorLayout?) -> [[Int]] {
        guard let layout else { return Array(repeating: [], count: channelIndices.count) }
        let positions = Dictionary(uniqueKeysWithValues: layout.positions.map { ($0.channelIndex, $0) })
        var adjacency = Array(repeating: Set<Int>(), count: channelIndices.count)
        for (local, channel) in channelIndices.enumerated() {
            guard let position = positions[channel] else { continue }
            let nearest = channelIndices.enumerated().compactMap { otherLocal, otherChannel -> (Int, Double)? in
                guard otherLocal != local, let other = positions[otherChannel] else { return nil }
                let dx = position.x - other.x
                let dy = position.y - other.y
                return (otherLocal, dx * dx + dy * dy)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(4)
            for (neighbor, _) in nearest {
                adjacency[local].insert(neighbor)
                adjacency[neighbor].insert(local)
            }
        }
        return adjacency.map { $0.sorted() }
    }

    private static func message(for error: ClusterPermutationAnalyzer.AnalysisError) -> String {
        switch error {
        case .invalidDimensions: return "The retained trial matrices do not have compatible dimensions."
        case .insufficientTrials: return "Each condition needs at least two usable trials."
        case .invalidConfiguration: return "Choose a positive cluster threshold and permutation count."
        }
    }

    private static func message(for error: ClusterPermutationFAnalyzer.AnalysisError) -> String {
        switch error {
        case .invalidDimensions: return "The retained trial matrices do not have compatible dimensions."
        case .insufficientConditions: return "Choose at least three conditions for the omnibus F-test."
        case .insufficientTrials: return "Each condition needs at least two usable trials."
        case .invalidConfiguration: return "Choose a positive F-cluster threshold and permutation count."
        }
    }
}
