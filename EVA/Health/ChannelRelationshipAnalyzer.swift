//
//  ChannelRelationshipAnalyzer.swift
//  EVA
//
//  Explainable, review-only channel-pair and recording-reference diagnostics.
//  A bridge is not a bad-channel decision: it is a persistent relationship
//  supported by near-identical waveforms. Neighbor prediction (EVA's
//  RANSAC-style metric) is carried alongside the finding as context, but does
//  not decide it.
//

import Foundation

nonisolated enum ChannelRelationshipKind: String, Codable, Sendable, Equatable {
    case likelyBridge
    case highCorrelation

    var displayName: String {
        switch self {
        case .likelyBridge: return "Likely Bridge"
        case .highCorrelation: return "High Correlation"
        }
    }
}

nonisolated struct ChannelRelationshipFinding: Identifiable, Sendable, Equatable {
    let firstChannel: Int
    let secondChannel: Int
    let kind: ChannelRelationshipKind
    let medianCorrelation: Double
    let medianDifferentialRMSMicrovolts: Double
    let medianNormalizedDifference: Double
    let persistentWindowFraction: Double
    let confidence: Double
    let spatialDistance: Double?
    let firstImpedanceKOhm: Double?
    let secondImpedanceKOhm: Double?
    let firstNeighborPrediction: String?
    let secondNeighborPrediction: String?

    var id: String { "\(firstChannel)-\(secondChannel)-\(kind.rawValue)" }

    func contains(channel: Int) -> Bool {
        firstChannel == channel || secondChannel == channel
    }

    func partner(of channel: Int) -> Int? {
        if firstChannel == channel { return secondChannel }
        if secondChannel == channel { return firstChannel }
        return nil
    }
}

/// The strongest persistent positive relationship evaluated for one channel,
/// retained even when it does not cross a review threshold. This is what lets
/// Channel Health say "analysis completed; nothing was flagged" without
/// confusing that state with "Relationships has not run."
nonisolated struct ChannelRelationshipSummary: Sendable, Equatable {
    let channel: Int
    let partner: Int
    let medianCorrelation: Double
    let medianDifferentialRMSMicrovolts: Double
    let persistentHighCorrelationFraction: Double
    let isFlaggedFinding: Bool
}

nonisolated struct ChannelRelationshipAnalysis: Sendable, Equatable {
    let findings: [ChannelRelationshipFinding]
    let strongestByChannel: [Int: ChannelRelationshipSummary]

    static let empty = ChannelRelationshipAnalysis(findings: [], strongestByChannel: [:])
}

nonisolated struct ChannelRelationshipConfiguration: Sendable, Equatable {
    var targetSamplingRate = 100.0
    var windowSeconds = 2.0
    var maximumWindowCount = 20
    var neighborCandidateCount = 8
    var globalCandidateCountPerChannel = 12
    var globalFingerprintCount = 256
    var globalCandidateCorrelation = 0.95
    var bridgeCorrelation = 0.995
    var highCorrelation = 0.98
    var maximumBridgeDifferenceMicrovolts = 1.0
    var maximumBridgeNormalizedDifference = 0.08
    var minimumPersistentWindowFraction = 0.80
    var minimumUsableRMSMicrovolts = 0.10
    var maximumFindings = 100

    static let defaults = ChannelRelationshipConfiguration()
}

nonisolated enum ChannelRelationshipAnalyzer {
    private struct Pair: Hashable, Comparable, Sendable {
        let first: Int
        let second: Int

        init(_ a: Int, _ b: Int) {
            first = min(a, b)
            second = max(a, b)
        }

        static func < (lhs: Pair, rhs: Pair) -> Bool {
            lhs.first == rhs.first ? lhs.second < rhs.second : lhs.first < rhs.first
        }
    }

    private struct PreparedWindow: Sendable {
        let centered: [Double]
        let rms: Double
    }

    static func analyze(
        signal: MFFSignalData,
        layout: SensorLayout?,
        healthResults: [Int: ChannelHealthResult] = [:],
        configuration: ChannelRelationshipConfiguration = .defaults
    ) -> [ChannelRelationshipFinding] {
        analyzeDetailed(
            signal: signal,
            layout: layout,
            healthResults: healthResults,
            configuration: configuration
        ).findings
    }

    static func analyzeDetailed(
        signal: MFFSignalData,
        layout: SensorLayout?,
        healthResults: [Int: ChannelHealthResult] = [:],
        configuration: ChannelRelationshipConfiguration = .defaults
    ) -> ChannelRelationshipAnalysis {
        let channelCount = min(signal.numberOfChannels, signal.data.count)
        guard channelCount >= 2,
              signal.samplingRate > 0,
              let sampleCount = signal.data.prefix(channelCount).map(\.count).min(),
              sampleCount >= 8 else { return .empty }

        let stride = max(1, Int((signal.samplingRate / max(configuration.targetSamplingRate, 1)).rounded()))
        let rawWindowLength = max(stride * 8, Int((configuration.windowSeconds * signal.samplingRate).rounded()))
        let windowLength = min(rawWindowLength, sampleCount)
        let starts = evenlySpacedStarts(
            sampleCount: sampleCount,
            windowLength: windowLength,
            maximumCount: configuration.maximumWindowCount
        )
        let prepared = (0..<channelCount).map { channel in
            starts.map { start in
                prepareWindow(
                    signal.data[channel],
                    start: start,
                    length: windowLength,
                    stride: stride
                )
            }
        }

        let fingerprints = (0..<channelCount).map { channel in
            fingerprint(signal.data[channel], sampleCount: sampleCount, count: configuration.globalFingerprintCount)
        }
        var candidates = candidatePairs(
            channelCount: channelCount,
            fingerprints: fingerprints,
            layout: layout,
            configuration: configuration
        )
        if channelCount <= 64 {
            for first in 0..<(channelCount - 1) {
                for second in (first + 1)..<channelCount {
                    candidates.insert(Pair(first, second))
                }
            }
        }

        let positions = Dictionary(uniqueKeysWithValues: (layout?.positions ?? []).map { ($0.channelIndex, $0) })
        let impedances = signal.impedancesKOhm
        var findings: [ChannelRelationshipFinding] = []
        var strongestByChannel: [Int: ChannelRelationshipSummary] = [:]
        findings.reserveCapacity(min(candidates.count, configuration.maximumFindings))

        for pair in candidates.sorted() {
            if Task.isCancelled { return .empty }
            let windows = zip(prepared[pair.first], prepared[pair.second])
            var correlations: [Double] = []
            var differences: [Double] = []
            var normalizedDifferences: [Double] = []
            var bridgeWindowCount = 0
            var correlatedWindowCount = 0

            for (first, second) in windows {
                guard first.rms >= configuration.minimumUsableRMSMicrovolts,
                      second.rms >= configuration.minimumUsableRMSMicrovolts,
                      let correlation = correlation(first.centered, second.centered),
                      let differentialRMS = differentialRMS(first.centered, second.centered) else { continue }
                let scale = sqrt((first.rms * first.rms + second.rms * second.rms) / 2)
                let normalized = scale > 1e-12 ? differentialRMS / scale : .infinity
                correlations.append(correlation)
                differences.append(differentialRMS)
                normalizedDifferences.append(normalized)
                if correlation >= configuration.highCorrelation {
                    correlatedWindowCount += 1
                }
                if correlation >= configuration.bridgeCorrelation,
                   differentialRMS <= configuration.maximumBridgeDifferenceMicrovolts,
                   normalized <= configuration.maximumBridgeNormalizedDifference {
                    bridgeWindowCount += 1
                }
            }

            guard !correlations.isEmpty else { continue }
            let medianCorrelation = median(correlations)
            let medianDifference = median(differences)
            let medianNormalized = median(normalizedDifferences)
            let denominator = Double(correlations.count)
            let bridgePersistence = Double(bridgeWindowCount) / denominator
            let correlationPersistence = Double(correlatedWindowCount) / denominator

            let classified: (kind: ChannelRelationshipKind, persistence: Double)?
            if medianCorrelation >= configuration.bridgeCorrelation,
               medianDifference <= configuration.maximumBridgeDifferenceMicrovolts,
               medianNormalized <= configuration.maximumBridgeNormalizedDifference,
               bridgePersistence >= configuration.minimumPersistentWindowFraction {
                classified = (.likelyBridge, bridgePersistence)
            } else if medianCorrelation >= configuration.highCorrelation,
                      correlationPersistence >= configuration.minimumPersistentWindowFraction {
                classified = (.highCorrelation, correlationPersistence)
            } else {
                classified = nil
            }

            let distance = spatialDistance(pair, positions: positions)
            let isFinding = classified != nil
            updateStrongestSummary(
                in: &strongestByChannel,
                channel: pair.first,
                partner: pair.second,
                correlation: medianCorrelation,
                differentialRMS: medianDifference,
                persistence: correlationPersistence,
                isFinding: isFinding
            )
            updateStrongestSummary(
                in: &strongestByChannel,
                channel: pair.second,
                partner: pair.first,
                correlation: medianCorrelation,
                differentialRMS: medianDifference,
                persistence: correlationPersistence,
                isFinding: isFinding
            )

            if let classified {
                let confidence = relationshipConfidence(
                    kind: classified.kind,
                    correlation: medianCorrelation,
                    normalizedDifference: medianNormalized,
                    persistence: classified.persistence,
                    spatialDistance: distance,
                    configuration: configuration
                )
                findings.append(ChannelRelationshipFinding(
                    firstChannel: pair.first,
                    secondChannel: pair.second,
                    kind: classified.kind,
                    medianCorrelation: medianCorrelation,
                    medianDifferentialRMSMicrovolts: medianDifference,
                    medianNormalizedDifference: medianNormalized,
                    persistentWindowFraction: classified.persistence,
                    confidence: confidence,
                    spatialDistance: distance,
                    firstImpedanceKOhm: impedance(at: pair.first, values: impedances),
                    secondImpedanceKOhm: impedance(at: pair.second, values: impedances),
                    firstNeighborPrediction: neighborPrediction(at: pair.first, healthResults: healthResults),
                    secondNeighborPrediction: neighborPrediction(at: pair.second, healthResults: healthResults)
                ))
            }
        }

        let sortedFindings = findings
            .sorted {
                if $0.kind != $1.kind { return $0.kind == .likelyBridge }
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                if $0.firstChannel != $1.firstChannel { return $0.firstChannel < $1.firstChannel }
                return $0.secondChannel < $1.secondChannel
            }
            .prefix(configuration.maximumFindings)
            .map { $0 }
        return ChannelRelationshipAnalysis(
            findings: sortedFindings,
            strongestByChannel: strongestByChannel
        )
    }

    private static func candidatePairs(
        channelCount: Int,
        fingerprints: [[Double]],
        layout: SensorLayout?,
        configuration: ChannelRelationshipConfiguration
    ) -> Set<Pair> {
        var pairs = Set<Pair>()

        var globalMatches = [[(channel: Int, correlation: Double)]](repeating: [], count: channelCount)
        for first in 0..<(channelCount - 1) {
            for second in (first + 1)..<channelCount {
                if let value = correlation(fingerprints[first], fingerprints[second]) {
                    globalMatches[first].append((second, value))
                    globalMatches[second].append((first, value))
                }
            }
        }
        for channel in 0..<channelCount {
            let sorted = globalMatches[channel]
                .sorted(by: { $0.correlation > $1.correlation })
            // Always retain the strongest few so a completed no-finding result
            // can name useful context. Also preserve the original threshold
            // contract: every globally suspicious pair remains a candidate even
            // when it falls outside that per-channel top-N set.
            for match in sorted.prefix(max(configuration.globalCandidateCountPerChannel, 0)) {
                pairs.insert(Pair(channel, match.channel))
            }
            for match in sorted where match.correlation >= configuration.globalCandidateCorrelation {
                pairs.insert(Pair(channel, match.channel))
            }
        }

        let positions = (layout?.positions ?? []).filter { $0.channelIndex >= 0 && $0.channelIndex < channelCount }
        for position in positions {
            let nearest = positions
                .filter { $0.channelIndex != position.channelIndex }
                .map { other in
                    (other.channelIndex, hypot(position.x - other.x, position.y - other.y))
                }
                .sorted { $0.1 < $1.1 }
                .prefix(max(configuration.neighborCandidateCount, 0))
            for (other, _) in nearest {
                pairs.insert(Pair(position.channelIndex, other))
            }
        }
        return pairs
    }

    private static func updateStrongestSummary(
        in summaries: inout [Int: ChannelRelationshipSummary],
        channel: Int,
        partner: Int,
        correlation: Double,
        differentialRMS: Double,
        persistence: Double,
        isFinding: Bool
    ) {
        if let current = summaries[channel], current.medianCorrelation >= correlation {
            return
        }
        summaries[channel] = ChannelRelationshipSummary(
            channel: channel,
            partner: partner,
            medianCorrelation: correlation,
            medianDifferentialRMSMicrovolts: differentialRMS,
            persistentHighCorrelationFraction: persistence,
            isFlaggedFinding: isFinding
        )
    }

    private static func prepareWindow(_ values: [Float], start: Int, length: Int, stride: Int) -> PreparedWindow {
        let end = min(start + length, values.count)
        var samples: [Double] = []
        samples.reserveCapacity(max((end - start) / stride, 0))
        var index = start
        while index < end {
            let value = Double(values[index])
            samples.append(value.isFinite ? value : .nan)
            index += stride
        }
        let finite = samples.filter(\.isFinite)
        let mean = finite.isEmpty ? 0 : finite.reduce(0, +) / Double(finite.count)
        let centered = samples.map { $0.isFinite ? $0 - mean : .nan }
        let squareSum = centered.reduce(0) { $0 + ($1.isFinite ? $1 * $1 : 0) }
        let rms = finite.isEmpty ? 0 : sqrt(squareSum / Double(finite.count))
        return PreparedWindow(centered: centered, rms: rms)
    }

    private static func fingerprint(_ values: [Float], sampleCount: Int, count: Int) -> [Double] {
        let requested = max(8, min(count, sampleCount))
        var samples: [Double] = []
        samples.reserveCapacity(requested)
        for offset in 0..<requested {
            let index = requested == 1 ? 0 : offset * (sampleCount - 1) / (requested - 1)
            let value = Double(values[index])
            samples.append(value.isFinite ? value : .nan)
        }
        let finite = samples.filter(\.isFinite)
        let mean = finite.isEmpty ? 0 : finite.reduce(0, +) / Double(finite.count)
        return samples.map { $0.isFinite ? $0 - mean : .nan }
    }

    private static func evenlySpacedStarts(sampleCount: Int, windowLength: Int, maximumCount: Int) -> [Int] {
        let lastStart = max(sampleCount - windowLength, 0)
        guard lastStart > 0, maximumCount > 1 else { return [0] }
        let count = min(maximumCount, max(1, sampleCount / max(windowLength, 1)))
        guard count > 1 else { return [lastStart / 2] }
        return (0..<count).map { $0 * lastStart / (count - 1) }
    }

    private static func correlation(_ first: [Double], _ second: [Double]) -> Double? {
        let count = min(first.count, second.count)
        guard count >= 3 else { return nil }
        var numerator = 0.0
        var firstSquares = 0.0
        var secondSquares = 0.0
        var finiteCount = 0
        for index in 0..<count {
            let a = first[index]
            let b = second[index]
            guard a.isFinite, b.isFinite else { continue }
            numerator += a * b
            firstSquares += a * a
            secondSquares += b * b
            finiteCount += 1
        }
        guard finiteCount >= 3, firstSquares > 1e-18, secondSquares > 1e-18 else { return nil }
        return numerator / sqrt(firstSquares * secondSquares)
    }

    private static func differentialRMS(_ first: [Double], _ second: [Double]) -> Double? {
        let count = min(first.count, second.count)
        var squareSum = 0.0
        var finiteCount = 0
        for index in 0..<count {
            let a = first[index]
            let b = second[index]
            guard a.isFinite, b.isFinite else { continue }
            let difference = a - b
            squareSum += difference * difference
            finiteCount += 1
        }
        guard finiteCount >= 3 else { return nil }
        return sqrt(squareSum / Double(finiteCount))
    }

    private static func spatialDistance(_ pair: Pair, positions: [Int: SensorPosition]) -> Double? {
        guard let first = positions[pair.first], let second = positions[pair.second] else { return nil }
        return hypot(first.x - second.x, first.y - second.y)
    }

    private static func impedance(at index: Int, values: [Float]?) -> Double? {
        guard let values, values.indices.contains(index) else { return nil }
        let value = Double(values[index])
        return value.isFinite ? value : nil
    }

    private static func neighborPrediction(at index: Int, healthResults: [Int: ChannelHealthResult]) -> String? {
        healthResults[index]?.metrics.first(where: { $0.name == "Neighbor Prediction" }).map {
            "\($0.grade.displayName) · \($0.detail)"
        }
    }

    private static func relationshipConfidence(
        kind: ChannelRelationshipKind,
        correlation: Double,
        normalizedDifference: Double,
        persistence: Double,
        spatialDistance: Double?,
        configuration: ChannelRelationshipConfiguration
    ) -> Double {
        let correlationFloor = kind == .likelyBridge ? configuration.bridgeCorrelation : configuration.highCorrelation
        let correlationScore = min(max((correlation - correlationFloor) / max(1 - correlationFloor, 1e-9), 0), 1)
        let differenceScore = kind == .likelyBridge
            ? min(max(1 - normalizedDifference / configuration.maximumBridgeNormalizedDifference, 0), 1)
            : 0.5
        let proximitySupport = spatialDistance.map { min(max(1 - $0 / 0.8, 0), 1) } ?? 0.5
        return min(max(0.40 * persistence + 0.30 * correlationScore + 0.20 * differenceScore + 0.10 * proximitySupport, 0), 1)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

nonisolated struct ReferenceIntegrityAssessment: Sendable, Equatable {
    let grade: ChannelHealthGrade
    let commonModeRMSMicrovolts: Double
    let medianCommonModeVarianceFraction: Double
    let positiveLoadingFraction: Double
    let medianChannelCorrelation: Double
    let analyzedChannelCount: Int

    var hasFinding: Bool { grade != .good }

    /// User-facing severity for what the calculation actually measures. The
    /// health-grade words implied a diagnosed bad reference; these values only
    /// describe the strength of recording-wide common-mode structure.
    var structureLevel: String {
        switch grade {
        case .good: return "Low"
        case .watch: return "Moderate"
        case .poor: return "High"
        }
    }
}

nonisolated enum ChannelReferenceAnalyzer {
    static func analyze(signal: MFFSignalData, targetSamplingRate: Double = 100, maximumSamples: Int = 10_000) -> ReferenceIntegrityAssessment? {
        let channelCount = min(signal.numberOfChannels, signal.data.count)
        guard channelCount >= 8,
              signal.samplingRate > 0,
              let sampleCount = signal.data.prefix(channelCount).map(\.count).min(),
              sampleCount >= 16 else { return nil }

        let rateStride = max(1, Int((signal.samplingRate / max(targetSamplingRate, 1)).rounded()))
        let countAfterRateLimit = max(1, sampleCount / rateStride)
        let additionalStride = max(1, countAfterRateLimit / max(maximumSamples, 1))
        let stride = rateStride * additionalStride
        let indices = Array(Swift.stride(from: 0, to: sampleCount, by: stride))
        guard indices.count >= 16 else { return nil }

        var centeredChannels = [[Double]]()
        centeredChannels.reserveCapacity(channelCount)
        for channel in signal.data.prefix(channelCount) {
            let samples = indices.map { Double(channel[$0]) }
            let finite = samples.filter { $0.isFinite }
            guard finite.count >= indices.count * 3 / 4 else { continue }
            let mean = finite.reduce(0, +) / Double(finite.count)
            centeredChannels.append(samples.map { $0.isFinite ? $0 - mean : .nan })
        }
        guard centeredChannels.count >= 8 else { return nil }

        var commonSums = [Double](repeating: 0, count: indices.count)
        var commonCounts = [Int](repeating: 0, count: indices.count)
        for channel in centeredChannels {
            for index in channel.indices where channel[index].isFinite {
                commonSums[index] += channel[index]
                commonCounts[index] += 1
            }
        }
        var commonMode = [Double](repeating: .nan, count: indices.count)
        for index in commonMode.indices where commonCounts[index] > 0 {
            commonMode[index] = commonSums[index] / Double(commonCounts[index])
        }
        let commonVariance = variance(commonMode)
        guard commonVariance.isFinite else { return nil }
        let commonRMS = sqrt(max(commonVariance, 0))

        var varianceFractions: [Double] = []
        var correlations: [Double] = []
        var positiveLoadings = 0
        var loadingCount = 0
        for channel in centeredChannels {
            let channelVariance = variance(channel)
            let leaveOneOut = channel.indices.map { index -> Double in
                let channelIsFinite = channel[index].isFinite
                let otherCount = commonCounts[index] - (channelIsFinite ? 1 : 0)
                guard otherCount > 0 else { return .nan }
                let otherSum = commonSums[index] - (channelIsFinite ? channel[index] : 0)
                return otherSum / Double(otherCount)
            }
            let comparisonVariance = variance(leaveOneOut)
            guard channelVariance > 1e-12,
                  comparisonVariance > 1e-12,
                  let covariance = covariance(channel, leaveOneOut),
                  let correlation = correlation(channel, leaveOneOut) else { continue }
            varianceFractions.append(min(max(comparisonVariance / channelVariance, 0), 1))
            correlations.append(correlation)
            let loading = covariance / comparisonVariance
            if loading > 0.20 { positiveLoadings += 1 }
            loadingCount += 1
        }
        guard !varianceFractions.isEmpty, loadingCount > 0 else { return nil }

        let medianFraction = median(varianceFractions)
        let positiveFraction = Double(positiveLoadings) / Double(loadingCount)
        let medianCorrelation = median(correlations)
        let grade: ChannelHealthGrade
        if commonRMS >= 10, medianFraction >= 0.15, positiveFraction >= 0.80, medianCorrelation >= 0.35 {
            grade = .poor
        } else if commonRMS >= 5, medianFraction >= 0.08, positiveFraction >= 0.65, medianCorrelation >= 0.20 {
            grade = .watch
        } else {
            grade = .good
        }

        return ReferenceIntegrityAssessment(
            grade: grade,
            commonModeRMSMicrovolts: commonRMS,
            medianCommonModeVarianceFraction: medianFraction,
            positiveLoadingFraction: positiveFraction,
            medianChannelCorrelation: medianCorrelation,
            analyzedChannelCount: centeredChannels.count
        )
    }

    private static func variance(_ values: [Double]) -> Double {
        let finite = values.filter(\.isFinite)
        guard finite.count >= 2 else { return .nan }
        let mean = finite.reduce(0, +) / Double(finite.count)
        return finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(finite.count)
    }

    private static func covariance(_ first: [Double], _ second: [Double]) -> Double? {
        let count = min(first.count, second.count)
        var sum = 0.0
        var finiteCount = 0
        for index in 0..<count where first[index].isFinite && second[index].isFinite {
            sum += first[index] * second[index]
            finiteCount += 1
        }
        return finiteCount >= 3 ? sum / Double(finiteCount) : nil
    }

    private static func correlation(_ first: [Double], _ second: [Double]) -> Double? {
        guard let covariance = covariance(first, second) else { return nil }
        let firstVariance = variance(first)
        let secondVariance = variance(second)
        guard firstVariance > 1e-18, secondVariance > 1e-18 else { return nil }
        return covariance / sqrt(firstVariance * secondVariance)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
