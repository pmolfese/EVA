//
//  ClusterStatisticsRunner.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
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

/// How observations in different conditions are matched into a unit for
/// within-subject designs. Reported back to the UI because the two are not
/// equally defensible and the user must see which one applied.
nonisolated enum ClusterPairingMode: Sendable, Equatable {
    /// One observation per subject per condition, matched by subject id. This
    /// is the statistically meaningful pairing and is available whenever the
    /// epochs came from a grand average over combined recordings.
    case subject
    /// Nth retained trial of one condition matched to the Nth of the other, in
    /// acquisition order. Only defensible when the paradigm genuinely pairs
    /// trials — alternating or yoked presentation — and misleading otherwise.
    case trialOrder

    var label: String {
        switch self {
        case .subject: return "Paired by subject"
        case .trialOrder: return "Paired by trial order"
        }
    }

    var caution: String? {
        switch self {
        case .subject:
            return nil
        case .trialOrder:
            return "Trials are matched by acquisition order because these epochs carry no subject identity. This is only meaningful if your paradigm pairs trials by position; otherwise use the independent design."
        }
    }
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
    let threshold: ClusterFormingThreshold
    let inference: ClusterInferenceMode
    let tfce: TFCEParameters
    let adjacency: ClusterAdjacencyConfiguration
    let repeatedMeasures: Bool
    let seed: UInt64
}

nonisolated struct ClusterStatisticsAnalysis: Sendable {
    let statistic: ClusterStatisticKind
    let conditionNames: [String]
    let conditionCounts: [Int]
    let repeatedMeasures: Bool
    let pairingMode: ClusterPairingMode?
    let unitCount: Int?
    let numeratorDegreesOfFreedom: Int?
    let denominatorDegreesOfFreedom: Int?
    let channelCount: Int
    let sampleCount: Int
    let observedStatistics: [Double]
    let observedTFCEScores: [Double]?
    let pointPValues: [Double]?
    let clusters: [SpatiotemporalCluster]
    let permutationCount: Int
    let inference: ClusterInferenceMode
    let tfce: TFCEParameters
    /// The statistic value clusters were formed at, after resolving a
    /// probability threshold. Nil under TFCE.
    let resolvedThreshold: Double?
    let thresholdSpecification: ClusterFormingThreshold
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
    let adjacencySummary: ClusterAdjacencySummary
    let adjacencyConfiguration: ClusterAdjacencyConfiguration
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
            let workerText = "\(min(evaMaxWorkers, job.permutationCount)) CPU workers"
            progress.yield(.init(
                fraction: 0.10,
                title: "Cluster Statistics",
                detail: job.inference == .tfce
                    ? "Integrating cluster extent on \(workerText)…"
                    : "Permuting condition labels on \(workerText)…"
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
                        spatialAdjacency: prepared.spatialAdjacency,
                        design: job.repeatedMeasures ? .repeatedMeasures : .independent
                    ),
                    configuration: .init(
                        permutationCount: job.permutationCount,
                        threshold: job.threshold,
                        inference: job.inference,
                        tfce: job.tfce,
                        seed: job.seed
                    ),
                    progress: progressHandler
                )
                guard let result else { return .cancelled }
                analysis = ClusterStatisticsAnalysis(
                    statistic: .t,
                    conditionNames: [result.conditionA, result.conditionB],
                    conditionCounts: [result.conditionACount, result.conditionBCount],
                    repeatedMeasures: result.design == .repeatedMeasures,
                    pairingMode: result.design == .repeatedMeasures ? prepared.pairingMode : nil,
                    unitCount: result.pairCount,
                    numeratorDegreesOfFreedom: nil,
                    denominatorDegreesOfFreedom: Int(result.degreesOfFreedom),
                    channelCount: result.channelCount,
                    sampleCount: result.sampleCount,
                    observedStatistics: result.observedStatistics,
                    observedTFCEScores: result.observedTFCEScores,
                    pointPValues: result.pointPValues,
                    clusters: result.clusters,
                    permutationCount: result.configuration.permutationCount,
                    inference: result.configuration.inference,
                    tfce: result.configuration.tfce,
                    resolvedThreshold: result.resolvedThreshold,
                    thresholdSpecification: result.configuration.threshold
                )
            case .f:
                let result = try ClusterPermutationFAnalyzer.analyze(
                    input: .init(
                        conditions: prepared.conditions.map { .init(name: $0.name, trials: $0.trials) },
                        channelCount: prepared.channelIndices.count,
                        sampleCount: prepared.relativeSampleOffsets.count,
                        spatialAdjacency: prepared.spatialAdjacency,
                        design: job.repeatedMeasures ? .repeatedMeasures : .independent
                    ),
                    configuration: .init(
                        permutationCount: job.permutationCount,
                        threshold: job.threshold,
                        inference: job.inference,
                        tfce: job.tfce,
                        seed: job.seed
                    ),
                    progress: progressHandler
                )
                guard let result else { return .cancelled }
                analysis = ClusterStatisticsAnalysis(
                    statistic: .f,
                    conditionNames: result.conditionNames,
                    conditionCounts: result.conditionCounts,
                    repeatedMeasures: result.design == .repeatedMeasures,
                    pairingMode: result.design == .repeatedMeasures ? prepared.pairingMode : nil,
                    unitCount: result.unitCount,
                    numeratorDegreesOfFreedom: result.numeratorDegreesOfFreedom,
                    denominatorDegreesOfFreedom: result.denominatorDegreesOfFreedom,
                    channelCount: result.channelCount,
                    sampleCount: result.sampleCount,
                    observedStatistics: result.observedStatistics,
                    observedTFCEScores: result.observedTFCEScores,
                    pointPValues: result.pointPValues,
                    clusters: result.clusters,
                    permutationCount: result.configuration.permutationCount,
                    inference: result.configuration.inference,
                    tfce: result.configuration.tfce,
                    resolvedThreshold: result.resolvedThreshold,
                    thresholdSpecification: result.configuration.threshold
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
                    adjacencySummary: ClusterSpatialAdjacency.summarize(prepared.spatialAdjacency),
                    adjacencyConfiguration: job.adjacency
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

    // MARK: - Preparation

    private struct PreparedData {
        let conditions: [PreparedCondition]
        let channelIndices: [Int]
        let relativeSampleOffsets: [Int]
        let spatialAdjacency: [[Int]]
        let pairingMode: ClusterPairingMode?
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
        case invalidAdjacency
        case noSharedSubjects(Int)
        case unbalancedPairing

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
            case .invalidAdjacency:
                return "Choose a valid sensor neighborhood: a positive distance, or between 1 and 32 nearest neighbors."
            case .noSharedSubjects(let count):
                return "A within-subject design needs at least two subjects present in every selected condition; only \(count) qualify."
            case .unbalancedPairing:
                return "A within-subject design needs the same number of matched units in every condition."
            }
        }
    }

    private static func prepare(job: ClusterStatisticsJob) throws -> PreparedData {
        guard job.signal.samplingRate > 0,
              job.permutationCount > 0,
              job.windowEndMs > job.windowStartMs else { throw PreparationError.invalidWindow }
        guard job.adjacency.isValid else { throw PreparationError.invalidAdjacency }

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
        // cell of a label-permutation design, paired or not.
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

        let adjacency = ClusterSpatialAdjacency.build(
            channelIndices: channels,
            layout: job.sensorLayout,
            configuration: job.adjacency
        )
        let featureCount = channels.count * relativeOffsets.count
        let referenceChannels = job.signal.data.indices.filter { !job.badChannels.contains($0) }

        func trial(for segment: EpochSegment) -> [Double]? {
            guard let values = prepareTrial(
                segment: segment,
                signal: job.signal,
                channelIndices: channels,
                referenceChannels: referenceChannels,
                relativeSampleOffsets: relativeOffsets,
                averageReference: job.averageReference,
                baselineCorrected: job.baselineCorrected
            ), values.count == featureCount else { return nil }
            return values
        }

        let preparedConditions: [PreparedCondition]
        let pairingMode: ClusterPairingMode?
        if job.repeatedMeasures {
            let paired = try pairedConditions(
                segmentsByCondition: segmentsByCondition,
                featureCount: featureCount,
                trial: trial
            )
            preparedConditions = paired.conditions
            pairingMode = paired.mode
        } else {
            preparedConditions = try segmentsByCondition.map { name, segments -> PreparedCondition in
                var trials: [[Double]] = []
                trials.reserveCapacity(segments.count)
                for segment in segments {
                    if Task.isCancelled { break }
                    if let values = trial(for: segment) { trials.append(values) }
                }
                guard trials.count >= 2 else { throw PreparationError.insufficientTrials(name, trials.count) }
                return PreparedCondition(name: name, trials: trials)
            }
            pairingMode = nil
        }

        return PreparedData(
            conditions: preparedConditions,
            channelIndices: channels,
            relativeSampleOffsets: relativeOffsets,
            spatialAdjacency: adjacency,
            pairingMode: pairingMode
        )
    }

    /// Builds matched units for a within-subject design.
    ///
    /// Subject identity is used whenever every selected segment carries one —
    /// the case for grand averages over combined recordings — and each subject
    /// contributes the mean of its trials in a condition, which is the standard
    /// within-subject aggregation. Failing that, trials are matched by
    /// acquisition order, which the caller surfaces as a caution.
    private static func pairedConditions(
        segmentsByCondition: [(String, [EpochSegment])],
        featureCount: Int,
        trial: (EpochSegment) -> [Double]?
    ) throws -> (conditions: [PreparedCondition], mode: ClusterPairingMode) {
        let allSegments = segmentsByCondition.flatMap { $0.1 }
        let hasSubjects = !allSegments.isEmpty && allSegments.allSatisfy { ($0.subject?.isEmpty == false) }

        if hasSubjects {
            // subject -> condition index -> accumulated trials
            var perCondition: [[String: [[Double]]]] = Array(
                repeating: [:],
                count: segmentsByCondition.count
            )
            for (index, entry) in segmentsByCondition.enumerated() {
                for segment in entry.1 {
                    if Task.isCancelled { break }
                    guard let subject = segment.subject, let values = trial(segment) else { continue }
                    perCondition[index][subject, default: []].append(values)
                }
            }
            let shared = perCondition
                .map { Set($0.keys) }
                .reduce(into: Set<String>?.none) { result, keys in
                    result = result.map { $0.intersection(keys) } ?? keys
                } ?? []
            let units = shared.sorted()
            guard units.count >= 2 else { throw PreparationError.noSharedSubjects(units.count) }

            let conditions = segmentsByCondition.enumerated().map { index, entry in
                PreparedCondition(
                    name: entry.0,
                    trials: units.map { subject in
                        mean(of: perCondition[index][subject] ?? [], featureCount: featureCount)
                    }
                )
            }
            return (conditions, .subject)
        }

        // Acquisition-order matching. Truncating to the shortest condition is
        // the only way to keep units aligned; the UI reports the discard.
        var ordered: [(String, [[Double]])] = []
        for (name, segments) in segmentsByCondition {
            var trials: [[Double]] = []
            for segment in segments.sorted(by: { $0.sourceTimeSeconds < $1.sourceTimeSeconds }) {
                if Task.isCancelled { break }
                if let values = trial(segment) { trials.append(values) }
            }
            ordered.append((name, trials))
        }
        guard let unitCount = ordered.map({ $0.1.count }).min(), unitCount >= 2 else {
            let smallest = ordered.min { $0.1.count < $1.1.count }
            throw PreparationError.insufficientTrials(smallest?.0 ?? "A condition", smallest?.1.count ?? 0)
        }
        let conditions = ordered.map { PreparedCondition(name: $0.0, trials: Array($0.1.prefix(unitCount))) }
        guard Set(conditions.map { $0.trials.count }).count == 1 else {
            throw PreparationError.unbalancedPairing
        }
        return (conditions, .trialOrder)
    }

    private static func mean(of trials: [[Double]], featureCount: Int) -> [Double] {
        guard !trials.isEmpty else { return [Double](repeating: 0, count: featureCount) }
        var sums = [Double](repeating: 0, count: featureCount)
        for values in trials {
            ClusterPermutationAnalyzer.add(values, to: &sums)
        }
        let count = Double(trials.count)
        for index in sums.indices { sums[index] /= count }
        return sums
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

    private static func message(for error: ClusterPermutationAnalyzer.AnalysisError) -> String {
        switch error {
        case .invalidDimensions: return "The retained trial matrices do not have compatible dimensions."
        case .insufficientTrials: return "Each condition needs at least two usable trials."
        case .invalidConfiguration: return "Choose a positive cluster threshold and permutation count."
        case .unbalancedPairs: return "A paired design needs the same number of matched units in both conditions."
        }
    }

    private static func message(for error: ClusterPermutationFAnalyzer.AnalysisError) -> String {
        switch error {
        case .invalidDimensions: return "The retained trial matrices do not have compatible dimensions."
        case .insufficientConditions: return "Choose at least three conditions for the omnibus F-test."
        case .insufficientTrials: return "Each condition needs at least two usable trials."
        case .invalidConfiguration: return "Choose a positive F-cluster threshold and permutation count."
        case .unbalancedUnits: return "A repeated-measures design needs the same number of matched units in every condition."
        }
    }
}
