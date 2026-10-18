//
//  PSADecisionMatrix.swift
//  EVA
//
//  Fast channel × epoch review before category averaging. Channel Health on
//  the left is recording-wide when available; each cell combines fast local
//  evidence, a channel prior, and aggregate epoch health. Explicit operator
//  decisions always win.
//

import AppKit
import SwiftUI

nonisolated enum PSACellDecision: String, CaseIterable, Sendable {
    case automatic = "Automatic"
    case keep = "Keep"
    case interpolate = "Interpolate"
}

nonisolated enum PSAEpochDecision: String, CaseIterable, Sendable {
    case automatic = "Automatic"
    case keep = "Keep Epoch"
    case reject = "Reject Epoch"
}

nonisolated enum PSAChannelPriorKind: Sendable {
    case segmentMedian
    case fastRecording
    case fullRecording
}

nonisolated struct PSADecisionCellID: Hashable, Sendable {
    var channelIndex: Int
    var epochIndex: Int
}

nonisolated struct PSACategoryEpochSummary: Identifiable, Sendable {
    var category: String
    var kept: Int
    var total: Int
    var id: String { category }
}

nonisolated struct PSARejectionReasonSummary: Identifiable, Sendable {
    var reason: String
    var count: Int
    var id: String { reason }
}

nonisolated enum PSAChannelMatrixOrder: String, CaseIterable, Identifiable {
    case number = "Channel number"
    case goodness = "Overall goodness"
    var id: String { rawValue }
}

nonisolated enum PSAEpochMatrixOrder: String, CaseIterable, Identifiable {
    case acquisition = "Acquisition"
    case category = "Category"
    case goodness = "Epoch goodness"
    var id: String { rawValue }
}

private nonisolated struct PSAFastSegmentSummary: Sendable {
    var evidence: EpochBadChannelDetector.Evidence?
    var finiteFraction: Double
    var rms: Double
    var p95Abs: Double
    var p99Abs: Double
    var maxAbs: Double
    var differenceRMS: Double
    var flatlineFraction: Double
    var clippingFraction: Double
    var excessKurtosis: Double
}

private nonisolated final class PSAScanProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        completed += 1
        return completed
    }
}

private nonisolated struct PSAFastScanRow: Sendable {
    var rawEvidence: [EpochBadChannelDetector.Evidence?]
    var reviewEvidence: [EpochBadChannelDetector.Evidence?]
    var goodnessScores: [Int]
    var referenceChannels: [Int]
}

nonisolated struct PSADecisionMatrixPreparation: Sendable {
    /// The only retained sample buffer. Review-domain samples are produced one
    /// epoch at a time while scanning, then discarded; a selected cell's trace
    /// is reconstructed on demand from this source.
    var sourceSignal: MFFSignalData
    /// Compatibility/readability alias for metadata-only users. This does not
    /// create or retain a second sample buffer.
    var signal: MFFSignalData { sourceSignal }
    var segments: [EpochSegment]
    /// Evidence in the representation the operator reviews (reference and
    /// baseline settings applied).
    var evidence: [[EpochBadChannelDetector.Evidence?]] // epoch, then channel
    /// Pre-reference/pre-baseline evidence retained so correction cannot hide a
    /// DC displacement or allow one bad cell to poison its epoch's reference.
    var rawEvidence: [[EpochBadChannelDetector.Evidence?]]
    /// Channels admitted to each epoch's provisional average reference.
    var referenceChannelsByEpoch: [[Int]]
    var appliesAverageReference: Bool
    var appliesBaselineCorrection: Bool
    /// Geometry-only value computed once, rather than once per epoch decision
    /// (or, historically, once per painted cell).
    var spatialAdjacencyRadius: Double
    /// Abbreviated per-channel/per-epoch health. Unlike the absolute extrema
    /// detector, this uses robust within-epoch cross-channel baselines.
    var localFastGoodnessScores: [[Int]]
    var epochGoodnessScores: [Int]
    /// Aggregate channel quality across only the epochs in this matrix. Used as
    /// an explicitly-labelled fallback when full-recording Channel Health has
    /// not been run; never presented as recording-wide evidence.
    var epochSetChannelGoodnessScores: [Int]
    var detectorSuggestions: Set<PSADecisionCellID>
    var recordingChannelGoodness: [Int: Int]
    var thresholds: EpochBadChannelThresholds
    var electrodePositions: [Int: SIMD3<Double>]
    var globallyBadChannels: Set<Int>
    var suggestedRejectedEpochReasons: [Int: [String]]

    static func make(
        signal: MFFSignalData,
        segments: [EpochSegment],
        thresholds: EpochBadChannelThresholds,
        detectorSegments: [Int: [Int]],
        recordingChannelGoodness: [Int: Int],
        baseSettings: ChannelBaseMetricSettings = .defaults,
        electrodePositions: [Int: SIMD3<Double>],
        globallyBadChannels: Set<Int>,
        averageReference: Bool = false,
        baselineCorrect: Bool = false,
        segmentHealthGoodnessScores: [Int],
        suggestedRejectedEpochReasons: [Int: [String]] = [:],
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) -> Self {
        let emptyEvidence = [EpochBadChannelDetector.Evidence?](
            repeating: nil, count: signal.numberOfChannels
        )
        var scanRows = [PSAFastScanRow](repeating: PSAFastScanRow(
            rawEvidence: emptyEvidence,
            reviewEvidence: emptyEvidence,
            goodnessScores: [Int](repeating: 0, count: signal.numberOfChannels),
            referenceChannels: []
        ), count: segments.count)
        let progressCounter = PSAScanProgressCounter()
        scanRows.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let output = buffer.baseAddress!
            evaConcurrentPerform(iterations: segments.count) { epochIndex in
                let segment = segments[epochIndex]
                let range = segment.startSample..<(segment.endSample + 1)
                var rawSummaries = [PSAFastSegmentSummary?](repeating: nil, count: signal.numberOfChannels)
                for channelIndex in signal.data.indices {
                    rawSummaries[channelIndex] = fastSummary(in: signal.data[channelIndex], range: range)
                }
                let rawScores = fastGoodnessScores(summaries: rawSummaries, settings: baseSettings)
                // This first pass is deliberately conservative. It protects the
                // common average from channels already showing absolute-limit,
                // finite-data, or strongly relative abnormalities.
                let referenceChannels = signal.data.indices.filter { channel in
                    guard !globallyBadChannels.contains(channel),
                          recordingChannelGoodness[channel, default: 100] >= 45,
                          rawSummaries[channel] != nil,
                          rawSummaries[channel]?.finiteFraction == 1,
                          rawSummaries[channel]?.evidence?.exceeds(thresholds) != true else { return false }
                    return rawScores[channel] >= 45
                }
                let mean = averageReference
                    ? referenceMean(signal: signal, range: range, channels: referenceChannels)
                    : nil
                var reviewSummaries = [PSAFastSegmentSummary?](repeating: nil, count: signal.numberOfChannels)
                for channelIndex in signal.data.indices {
                    let samples = reviewedSamples(
                        signal: signal,
                        segment: segment,
                        channel: channelIndex,
                        referenceMean: mean,
                        baselineCorrect: baselineCorrect
                    )
                    reviewSummaries[channelIndex] = fastSummary(
                        in: samples, range: samples.indices
                    )
                }
                let reviewScores = fastGoodnessScores(summaries: reviewSummaries, settings: baseSettings)
                let combinedScores = zip(rawScores, reviewScores).map { min($0.0, $0.1) }
                (output + epochIndex).pointee = PSAFastScanRow(
                    rawEvidence: rawSummaries.map { $0?.evidence },
                    reviewEvidence: reviewSummaries.map { $0?.evidence },
                    goodnessScores: combinedScores,
                    referenceChannels: referenceChannels
                )
                progress?(progressCounter.increment(), segments.count)
            }
        }
        let rows = scanRows.map(\.reviewEvidence)
        let rawRows = scanRows.map(\.rawEvidence)
        let localScores = scanRows.map(\.goodnessScores)
        var suggestions = Set<PSADecisionCellID>()
        for epochIndex in segments.indices {
            for channelIndex in signal.data.indices {
                if globallyBadChannels.contains(channelIndex)
                    || rows[epochIndex][channelIndex]?.exceeds(thresholds) == true
                    || rawRows[epochIndex][channelIndex]?.exceeds(thresholds) == true {
                    suggestions.insert(.init(channelIndex: channelIndex, epochIndex: epochIndex))
                }
            }
        }
        for (channelIndex, oneBasedEpochs) in detectorSegments {
            for number in oneBasedEpochs where segments.indices.contains(number - 1) {
                suggestions.insert(.init(channelIndex: channelIndex, epochIndex: number - 1))
            }
        }
        // Epoch quality comes from EVA's regular Segment Health analysis. The
        // abbreviated scan above exists only to answer the different question
        // "which channel is bad in this epoch?"; averaging those channel scores
        // into a second competing epoch-health metric caused the two workflows
        // to disagree.
        let epochGoodnessScores = segments.indices.map { index in
            segmentHealthGoodnessScores.indices.contains(index)
                ? segmentHealthGoodnessScores[index] : 100
        }
        let epochSetChannelGoodnessScores = (0..<signal.numberOfChannels).map { channel in
            median(localScores.compactMap { $0.indices.contains(channel) ? Double($0[channel]) : nil }, fallback: 100)
        }
        return Self(
            sourceSignal: signal,
            segments: segments,
            evidence: rows,
            rawEvidence: rawRows,
            referenceChannelsByEpoch: scanRows.map(\.referenceChannels),
            appliesAverageReference: averageReference,
            appliesBaselineCorrection: baselineCorrect,
            spatialAdjacencyRadius: psaSpatialAdjacencyRadius(positions: electrodePositions),
            localFastGoodnessScores: localScores,
            epochGoodnessScores: epochGoodnessScores,
            epochSetChannelGoodnessScores: epochSetChannelGoodnessScores,
            detectorSuggestions: suggestions,
            recordingChannelGoodness: recordingChannelGoodness,
            thresholds: thresholds,
            electrodePositions: electrodePositions,
            globallyBadChannels: globallyBadChannels,
            suggestedRejectedEpochReasons: suggestedRejectedEpochReasons
        )
    }

    func matchesCurrentReviewInputs(
        signal: MFFSignalData,
        segments currentSegments: [EpochSegment],
        averageReference: Bool,
        baselineCorrect: Bool,
        globallyBadChannels currentGloballyBad: Set<Int>,
        thresholds currentThresholds: EpochBadChannelThresholds
    ) -> Bool {
        sourceSignal.dataRevision == signal.dataRevision
            && segments.count == currentSegments.count
            && appliesAverageReference == averageReference
            && appliesBaselineCorrection == baselineCorrect
            && globallyBadChannels == currentGloballyBad
            && thresholds == currentThresholds
    }

    private static func referenceMean(
        signal: MFFSignalData, range: Range<Int>, channels: [Int]
    ) -> [Float]? {
        guard !channels.isEmpty, range.count > 0 else { return nil }
        var mean = [Float](repeating: 0, count: range.count)
        for channel in channels where signal.data.indices.contains(channel) {
            let samples = signal.data[channel]
            guard range.upperBound <= samples.count else { continue }
            for (offset, sample) in range.enumerated() { mean[offset] += samples[sample] }
        }
        let divisor = Float(channels.count)
        for index in mean.indices { mean[index] /= divisor }
        return mean
    }

    private static func reviewedSamples(
        signal: MFFSignalData,
        segment: EpochSegment,
        channel: Int,
        referenceMean: [Float]?,
        baselineCorrect: Bool
    ) -> [Float] {
        let range = segment.startSample..<(segment.endSample + 1)
        guard signal.data.indices.contains(channel), range.lowerBound >= 0,
              range.upperBound <= signal.data[channel].count else { return [] }
        let source = signal.data[channel]
        var values = [Float]()
        values.reserveCapacity(range.count)
        for (offset, sample) in range.enumerated() {
            values.append(source[sample] - (referenceMean?[offset] ?? 0))
        }
        if baselineCorrect {
            let count = min(max(segment.stimulusOffsetSamples, 0), values.count)
            if count > 0 {
                let baseline = values[..<count].reduce(0) { $0 + Double($1) } / Double(count)
                if baseline.isFinite {
                    let correction = Float(baseline)
                    for index in values.indices { values[index] -= correction }
                }
            }
        }
        return values
    }

    private static func fastSummary(in channel: [Float], range: Range<Int>) -> PSAFastSegmentSummary? {
        guard range.count > 1, range.lowerBound >= 0, range.upperBound <= channel.count else { return nil }
        var values = [Double]()
        var absValues = [Double]()
        var differences = [Double]()
        values.reserveCapacity(range.count)
        absValues.reserveCapacity(range.count)
        differences.reserveCapacity(range.count - 1)
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var maxSlope = 0.0
        var maxAcceleration = 0.0
        var previousValue: Double?
        var previousSlope: Double?
        var sumSquares = 0.0
        var nonFinite = 0

        for sample in range {
            let value = Double(channel[sample])
            guard value.isFinite else {
                nonFinite += 1
                previousValue = nil
                previousSlope = nil
                continue
            }
            values.append(value)
            absValues.append(abs(value))
            sumSquares += value * value
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            if let previousValue {
                let slope = abs(value - previousValue)
                differences.append(slope)
                maxSlope = max(maxSlope, slope)
                if let previousSlope { maxAcceleration = max(maxAcceleration, abs(slope - previousSlope)) }
                previousSlope = slope
            }
            previousValue = value
        }
        guard !values.isEmpty else {
            return PSAFastSegmentSummary(
                evidence: nil, finiteFraction: 0, rms: 0, p95Abs: 0, p99Abs: 0,
                maxAbs: 0, differenceRMS: 0, flatlineFraction: 1,
                clippingFraction: 0, excessKurtosis: 0
            )
        }
        absValues.sort()
        let p95 = SignalStatistics.percentile(absValues, fraction: 0.95)
        let p99 = SignalStatistics.percentile(absValues, fraction: 0.99)
        let maxAbs = absValues.last ?? 0
        let rms = sqrt(sumSquares / Double(values.count))
        let differenceRMS = differences.isEmpty
            ? 0 : sqrt(differences.reduce(0) { $0 + $1 * $1 } / Double(differences.count))
        let flatlineThreshold = max(p95 * 0.0001, 1e-7)
        let flatlineFraction = differences.isEmpty ? 1
            : Double(differences.filter { $0 <= flatlineThreshold }.count) / Double(differences.count)
        let mean = values.reduce(0, +) / Double(values.count)
        var m2 = 0.0
        var m4 = 0.0
        for value in values {
            let delta = value - mean
            let squared = delta * delta
            m2 += squared
            m4 += squared * squared
        }
        m2 /= Double(values.count)
        m4 /= Double(values.count)
        return PSAFastSegmentSummary(
            evidence: .init(
                minimumMicrovolts: minimum,
                maximumMicrovolts: maximum,
                maximumSlopeMicrovoltsPerSample: maxSlope,
                maximumAccelerationMicrovoltsPerSample: maxAcceleration
            ),
            finiteFraction: Double(values.count) / Double(values.count + nonFinite),
            rms: rms,
            p95Abs: p95,
            p99Abs: p99,
            maxAbs: maxAbs,
            differenceRMS: differenceRMS,
            flatlineFraction: flatlineFraction,
            clippingFraction: HealthScoring.clippingFraction(absValues: absValues, maxAbs: maxAbs),
            excessKurtosis: m2 > 1e-18 ? m4 / (m2 * m2) - 3 : 0
        )
    }

    private static func fastGoodnessScores(
        summaries: [PSAFastSegmentSummary?], settings: ChannelBaseMetricSettings
    ) -> [Int] {
        let valid = summaries.compactMap { $0 }
        let medianP95 = medianDouble(valid.map(\.p95Abs), fallback: 1)
        let medianP99 = medianDouble(valid.map(\.p99Abs), fallback: 1)
        let medianDerivative = medianDouble(
            valid.map { $0.differenceRMS / max($0.rms, 1e-9) }, fallback: 1
        )
        return summaries.map { summary in
            guard let summary else { return 0 }
            var weighted = 0.0
            var weight = 0.0
            func add(_ score: Double, _ metricWeight: Double) {
                weighted += score * metricWeight
                weight += metricWeight
            }
            if settings.finiteEnabled {
                add(HealthScoring.scoreLowerBound(summary.finiteFraction, green: settings.finiteGreen, red: settings.finiteRed), settings.finiteWeight)
            }
            if settings.amplitudeEnabled {
                let score = summary.rms <= 1e-12 || summary.p95Abs <= 1e-12 ? 0
                    : HealthScoring.scoreTwoSidedRatio(summary.p95Abs / medianP95, green: settings.amplitudeGreen, red: settings.amplitudeRed)
                add(score, settings.amplitudeWeight)
            }
            if settings.burstEnabled {
                add(HealthScoring.scoreUpperRatio(summary.maxAbs / max(medianP99, 1e-9), green: settings.burstGreen, red: settings.burstRed), settings.burstWeight)
            }
            if settings.flatlineEnabled {
                add(HealthScoring.scoreUpperFraction(summary.flatlineFraction, green: settings.flatlineGreen, red: settings.flatlineRed), settings.flatlineWeight)
            }
            if settings.clippingEnabled {
                add(HealthScoring.scoreUpperFraction(summary.clippingFraction, green: settings.clippingGreen, red: settings.clippingRed), settings.clippingWeight)
            }
            if settings.fastNoiseEnabled {
                let derivativeRatio = summary.differenceRMS / max(summary.rms, 1e-9)
                add(HealthScoring.scoreUpperRatio(derivativeRatio / max(medianDerivative, 1e-9), green: settings.fastNoiseGreen, red: settings.fastNoiseRed), settings.fastNoiseWeight)
            }
            add(HealthScoring.scoreUpperRatio(max(summary.excessKurtosis, 0), green: 5, red: 20), 1)
            return Int((100 * (weight > 0 ? weighted / weight : 0)).rounded())
        }
    }

    private static func median(_ values: [Double], fallback: Int) -> Int {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return fallback }
        let middle = sorted.count / 2
        let value = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return Int(value.rounded())
    }

    private static func medianDouble(_ values: [Double], fallback: Double) -> Double {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return fallback }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

private nonisolated func psaInterpolationFeasibilityReason(
    bad: Set<Int>,
    channelCount: Int,
    positions: [Int: SIMD3<Double>],
    globallyBad: Set<Int>,
    thresholds: EpochBadChannelThresholds,
    adjacencyRadius: Double
) -> String? {
    guard !bad.isEmpty else { return nil }
    let missingPositions = bad.filter { positions[$0] == nil }
    if !missingPositions.isEmpty {
        return "Missing electrode positions for \(missingPositions.count) interpolation target\(missingPositions.count == 1 ? "" : "s")"
    }
    let donors = (0..<channelCount).filter {
        !bad.contains($0) && !globallyBad.contains($0) && positions[$0] != nil
    }
    if donors.count < 4 { return "Too few positioned donor channels for interpolation" }
    let allowed = thresholds.usesAbsoluteBadChannelCount
        ? thresholds.maxBadChannelCount
        : Int(floor(thresholds.maxBadChannelFraction * Double(channelCount)))
    if bad.count > allowed {
        return "\(bad.count) channels require interpolation; the configured limit is \(allowed)"
    }

    let positioned = bad.compactMap { channel -> (Int, SIMD3<Double>)? in
        positions[channel].map { (channel, $0) }
    }
    guard positioned.count > 1 else { return nil }
    var remaining = Set(positioned.map(\.0))
    var largest = 0
    while let seed = remaining.first {
        remaining.remove(seed)
        var stack = [seed]
        var size = 0
        while let current = stack.popLast() {
            size += 1
            guard let point = positions[current] else { continue }
            let neighbors = remaining.filter { neighbor in
                guard let other = positions[neighbor] else { return false }
                return psaSpatialDistance(point, other) <= adjacencyRadius
            }
            remaining.subtract(neighbors)
            stack.append(contentsOf: neighbors)
        }
        largest = max(largest, size)
    }
    let clusterLimit = max(4, Int(ceil(Double(channelCount) * 0.08)))
    return largest >= clusterLimit
        ? "A contiguous cluster of \(largest) bad channels is too broad for reliable interpolation"
        : nil
}

private nonisolated func psaSpatialAdjacencyRadius(
    positions: [Int: SIMD3<Double>]
) -> Double {
    let allPositions = Array(positions.values)
    let nearestDistances = allPositions.compactMap { point -> Double? in
        allPositions.lazy.map { psaSpatialDistance(point, $0) }
            .filter { $0 > 1e-9 }.min()
    }.sorted()
    return nearestDistances.isEmpty
        ? 0.25 : nearestDistances[nearestDistances.count / 2] * 1.75
}

private nonisolated func psaSpatialDistance(
    _ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>
) -> Double {
    let delta = lhs - rhs
    return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
}

@MainActor
@Observable
final class PSADecisionMatrixModel {
    let preparation: PSADecisionMatrixPreparation
    /// Set when the operator runs full Channel Health from this review. Keeping
    /// it outside `preparation` preserves every explicit matrix decision.
    var recordingChannelGoodnessOverride: [Int: Int]?
    var recordingChannelPriorKindOverride: PSAChannelPriorKind?
    var channelOrder: PSAChannelMatrixOrder = .number
    var epochOrder: PSAEpochMatrixOrder = .acquisition
    var interpolationHealthThreshold = 55.0
    var epochRejectionHealthThreshold: Double
    var cellOverrides: [PSADecisionCellID: PSACellDecision] = [:]
    var epochOverrides: [Int: PSAEpochDecision] = [:]
    /// A manual Good label from regular Segment Health suppresses only the
    /// automatic health-threshold rejection. Artifact rules and interpolation
    /// feasibility remain independent safety decisions.
    var trustedEpochHealth = Set<Int>()
    var selectedCell: PSADecisionCellID?
    var selectedChannels = Set<Int>()
    var selectedEpochs = Set<Int>()
    var suggestedRejectedEpochReasons: [Int: [String]]

    init(preparation: PSADecisionMatrixPreparation) {
        self.preparation = preparation
        suggestedRejectedEpochReasons = preparation.suggestedRejectedEpochReasons
        let threshold = preparation.thresholds
        let tolerated: Int
        if threshold.usesAbsoluteBadChannelCount {
            tolerated = threshold.maxBadChannelCount
        } else {
            let raw = Int((threshold.maxBadChannelFraction * Double(preparation.signal.numberOfChannels)).rounded())
            tolerated = threshold.maxBadChannelFraction > 0 ? max(1, raw) : 0
        }
        let channelCount = max(preparation.signal.numberOfChannels, 1)
        epochRejectionHealthThreshold = max(0, min(100,
            100 * (1 - (Double(tolerated) + 0.5) / Double(channelCount))))
    }

    var orderedChannels: [Int] {
        let indices = Array(0..<preparation.signal.numberOfChannels)
        switch channelOrder {
        case .number: return indices
        case .goodness:
            return indices.sorted {
                let lhs = displayedChannelGoodness($0)
                let rhs = displayedChannelGoodness($1)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
        }
    }

    var orderedEpochs: [Int] {
        switch epochOrder {
        case .acquisition: return Array(preparation.segments.indices)
        case .category:
            return preparation.segments.indices.sorted {
                let lhs = preparation.segments[$0], rhs = preparation.segments[$1]
                let comparison = lhs.category.localizedStandardCompare(rhs.category)
                return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
            }
        case .goodness:
            return preparation.segments.indices.sorted {
                let lhs = epochGoodness($0)
                let rhs = epochGoodness($1)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
        }
    }

    var hasRecordingWideChannelHealth: Bool {
        channelPriorKind != .segmentMedian
    }

    var hasFullRecordingChannelHealth: Bool {
        channelPriorKind == .fullRecording
    }

    var channelPriorKind: PSAChannelPriorKind {
        guard effectiveRecordingChannelGoodness.count >= preparation.signal.numberOfChannels else {
            return .segmentMedian
        }
        return recordingChannelPriorKindOverride ?? .fullRecording
    }

    var channelHealthScopeLabel: String {
        switch channelPriorKind {
        case .fullRecording: return "Overall Channel Health"
        case .fastRecording: return "Fast Recording Health"
        case .segmentMedian: return "Fast Epoch-set Health"
        }
    }

    private var effectiveRecordingChannelGoodness: [Int: Int] {
        recordingChannelGoodnessOverride ?? preparation.recordingChannelGoodness
    }

    func displayedChannelGoodness(_ channel: Int) -> Int {
        if hasRecordingWideChannelHealth,
           let overall = effectiveRecordingChannelGoodness[channel] { return overall }
        return preparation.epochSetChannelGoodnessScores.indices.contains(channel)
            ? preparation.epochSetChannelGoodnessScores[channel] : 100
    }

    func epochGoodness(_ epoch: Int) -> Int {
        preparation.epochGoodnessScores.indices.contains(epoch)
            ? preparation.epochGoodnessScores[epoch]
            : 100
    }

    func localGoodness(channel: Int, epoch: Int) -> Double {
        guard preparation.localFastGoodnessScores.indices.contains(epoch),
              preparation.localFastGoodnessScores[epoch].indices.contains(channel) else { return 100 }
        return Double(preparation.localFastGoodnessScores[epoch][channel])
    }

    /// Cells emphasize transient local evidence while retaining a stable
    /// channel prior and a smaller whole-epoch context contribution.
    func integratedGoodness(channel: Int, epoch: Int) -> Int {
        Int((0.60 * localGoodness(channel: channel, epoch: epoch)
             + 0.25 * Double(displayedChannelGoodness(channel))
             + 0.15 * Double(epochGoodness(epoch))).rounded())
    }

    func adoptRecordingChannelGoodness(
        _ goodness: [Int: Int], kind: PSAChannelPriorKind = .fullRecording
    ) {
        guard goodness.count >= preparation.signal.numberOfChannels else { return }
        recordingChannelGoodnessOverride = goodness
        recordingChannelPriorKindOverride = kind
    }

    func resolvedCellDecision(_ id: PSADecisionCellID) -> PSACellDecision {
        if let explicit = cellOverrides[id], explicit != .automatic { return explicit }
        if preparation.detectorSuggestions.contains(id)
            || Double(integratedGoodness(channel: id.channelIndex, epoch: id.epochIndex)) < interpolationHealthThreshold {
            return .interpolate
        }
        return .keep
    }

    func badChannelCount(epoch: Int) -> Int {
        (0..<preparation.signal.numberOfChannels).filter {
            resolvedCellDecision(.init(channelIndex: $0, epochIndex: epoch)) == .interpolate
        }.count
    }

    func isChannelInterpolatedAcrossAllEpochs(_ channel: Int) -> Bool {
        !preparation.segments.isEmpty && preparation.segments.indices.allSatisfy {
            resolvedCellDecision(.init(channelIndex: channel, epochIndex: $0)) == .interpolate
        }
    }

    func resolvedEpochDecision(_ epoch: Int) -> PSAEpochDecision {
        if let explicit = epochOverrides[epoch], explicit != .automatic { return explicit }
        if suggestedRejectedEpochReasons[epoch]?.isEmpty == false { return .reject }
        if interpolationFeasibilityReason(epoch: epoch) != nil { return .reject }
        if trustedEpochHealth.contains(epoch) { return .keep }
        return Double(epochGoodness(epoch)) < epochRejectionHealthThreshold ? .reject : .keep
    }

    func trustEpochHealth(_ epoch: Int) {
        trustedEpochHealth.insert(epoch)
    }

    func rejectionReasons(for epoch: Int) -> [String] {
        if epochOverrides[epoch] == .keep { return [] }
        if epochOverrides[epoch] == .reject { return ["Manual rejection"] }
        var reasons = suggestedRejectedEpochReasons[epoch, default: []]
            .flatMap { $0.components(separatedBy: " + ") }
        if interpolationFeasibilityReason(epoch: epoch) != nil {
            reasons.append("Interpolation infeasible")
        }
        if !trustedEpochHealth.contains(epoch),
           Double(epochGoodness(epoch)) < epochRejectionHealthThreshold {
            reasons.append("Segment Health")
        }
        return Array(Set(reasons)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var rejectionReasonSummaries: [PSARejectionReasonSummary] {
        var counts: [String: Int] = [:]
        for epoch in preparation.segments.indices where resolvedEpochDecision(epoch) == .reject {
            for reason in rejectionReasons(for: epoch) {
                counts[reason, default: 0] += 1
            }
        }
        return counts.map { .init(reason: $0.key, count: $0.value) }
            .sorted {
                $0.count == $1.count
                    ? $0.reason.localizedStandardCompare($1.reason) == .orderedAscending
                    : $0.count > $1.count
            }
    }

    /// A spatial reconstruction needs positioned donors and becomes unreliable
    /// when the targets form a broad contiguous hole. Manual epoch decisions
    /// remain authoritative, but automatic mode rejects rather than silently
    /// claiming those cells were successfully repaired.
    func interpolationFeasibilityReason(epoch: Int) -> String? {
        let bad = Set((0..<preparation.signal.numberOfChannels).filter {
            resolvedCellDecision(.init(channelIndex: $0, epochIndex: epoch)) == .interpolate
        })
        return psaInterpolationFeasibilityReason(
            bad: bad,
            channelCount: preparation.signal.numberOfChannels,
            positions: preparation.electrodePositions,
            globallyBad: preparation.globallyBadChannels,
            thresholds: preparation.thresholds,
            adjacencyRadius: preparation.spatialAdjacencyRadius
        )
    }

    var keptEpochCount: Int { preparation.segments.indices.filter { resolvedEpochDecision($0) == .keep }.count }
    var rejectedEpochCount: Int { preparation.segments.count - keptEpochCount }

    var categorySummaries: [PSACategoryEpochSummary] {
        let grouped = Dictionary(grouping: preparation.segments.indices) {
            preparation.segments[$0].category
        }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { category in
            let epochs = grouped[category] ?? []
            return PSACategoryEpochSummary(
                category: category,
                kept: epochs.filter { resolvedEpochDecision($0) == .keep }.count,
                total: epochs.count
            )
        }
    }

    func setCellDecision(_ decision: PSACellDecision, for id: PSADecisionCellID) {
        if decision == .automatic { cellOverrides[id] = nil } else { cellOverrides[id] = decision }
    }

    func setEpochDecision(_ decision: PSAEpochDecision, epoch: Int) {
        if decision == .automatic { epochOverrides[epoch] = nil } else { epochOverrides[epoch] = decision }
    }

    func suggestEpochRejection(_ epoch: Int, reason: String) {
        suggestedRejectedEpochReasons[epoch, default: []].append(reason)
    }

    func setChannelDecision(_ decision: PSACellDecision, channels: Set<Int>) {
        for channel in channels {
            for epoch in preparation.segments.indices {
                setCellDecision(decision, for: .init(channelIndex: channel, epochIndex: epoch))
            }
        }
    }

    func setEpochDecision(_ decision: PSAEpochDecision, epochs: Set<Int>) {
        for epoch in epochs { setEpochDecision(decision, epoch: epoch) }
    }

    func selectChannels(_ channels: Set<Int>) {
        selectedChannels = channels
        selectedEpochs.removeAll()
        selectedCell = nil
    }

    func selectEpochs(_ epochs: Set<Int>) {
        selectedEpochs = epochs
        selectedChannels.removeAll()
        selectedCell = nil
    }

    func selectCell(_ cell: PSADecisionCellID) {
        selectedCell = cell
        selectedChannels.removeAll()
        selectedEpochs.removeAll()
    }

    func snapshot() -> PSADecisionMatrixSnapshot {
        .init(
            preparation: preparation,
            channelPriorGoodnessScores: (0..<preparation.signal.numberOfChannels).map(displayedChannelGoodness),
            interpolationHealthThreshold: interpolationHealthThreshold,
            epochRejectionHealthThreshold: epochRejectionHealthThreshold,
            suggestedRejectedEpochs: Set(suggestedRejectedEpochReasons.keys),
            trustedEpochHealth: trustedEpochHealth,
            cellOverrides: cellOverrides,
            epochOverrides: epochOverrides
        )
    }
}

nonisolated struct PSADecisionMatrixSnapshot: Sendable {
    var preparation: PSADecisionMatrixPreparation
    var channelPriorGoodnessScores: [Int]
    var interpolationHealthThreshold: Double
    var epochRejectionHealthThreshold: Double
    var suggestedRejectedEpochs: Set<Int>
    var trustedEpochHealth: Set<Int>
    var cellOverrides: [PSADecisionCellID: PSACellDecision]
    var epochOverrides: [Int: PSAEpochDecision]

    private func integratedGoodness(channel: Int, epoch: Int) -> Int {
        let local = preparation.localFastGoodnessScores.indices.contains(epoch)
            && preparation.localFastGoodnessScores[epoch].indices.contains(channel)
            ? Double(preparation.localFastGoodnessScores[epoch][channel]) : 100
        let channelPrior = channelPriorGoodnessScores.indices.contains(channel)
            ? Double(channelPriorGoodnessScores[channel]) : 100
        let epochGoodness = preparation.epochGoodnessScores.indices.contains(epoch)
            ? Double(preparation.epochGoodnessScores[epoch]) : 100
        return Int((0.60 * local + 0.25 * channelPrior + 0.15 * epochGoodness).rounded())
    }

    private func cellDecision(channel: Int, epoch: Int) -> PSACellDecision {
        let id = PSADecisionCellID(channelIndex: channel, epochIndex: epoch)
        if let explicit = cellOverrides[id], explicit != .automatic { return explicit }
        return preparation.detectorSuggestions.contains(id)
            || Double(integratedGoodness(channel: channel, epoch: epoch)) < interpolationHealthThreshold
            ? .interpolate : .keep
    }

    private func epochDecision(_ epoch: Int) -> PSAEpochDecision {
        if let explicit = epochOverrides[epoch], explicit != .automatic { return explicit }
        if suggestedRejectedEpochs.contains(epoch) { return .reject }
        let bad = Set((0..<preparation.signal.numberOfChannels).filter {
            cellDecision(channel: $0, epoch: epoch) == .interpolate
        })
        if psaInterpolationFeasibilityReason(
            bad: bad,
            channelCount: preparation.signal.numberOfChannels,
            positions: preparation.electrodePositions,
            globallyBad: preparation.globallyBadChannels,
            thresholds: preparation.thresholds,
            adjacencyRadius: preparation.spatialAdjacencyRadius
        ) != nil { return .reject }
        if trustedEpochHealth.contains(epoch) { return .keep }
        let goodness = preparation.epochGoodnessScores.indices.contains(epoch)
            ? preparation.epochGoodnessScores[epoch] : 100
        return Double(goodness) < epochRejectionHealthThreshold ? .reject : .keep
    }

    func materializedResult() -> PSABuildResult? {
        let sourceSignal = preparation.sourceSignal
        var data = sourceSignal.data
        let cache = SphericalSplineWeightCache()
        for epoch in preparation.segments.indices where epochDecision(epoch) == .keep {
            let segment = preparation.segments[epoch]
            let bad = Set((0..<sourceSignal.numberOfChannels).filter {
                cellDecision(channel: $0, epoch: epoch) == .interpolate
            })
            EpochBadChannelDetector.interpolate(
                badChannels: bad,
                in: &data,
                range: segment.startSample..<(segment.endSample + 1),
                positions: preparation.electrodePositions,
                excludingGloballyBad: preparation.globallyBadChannels,
                weightCache: cache
            )
        }

        var compacted = Array(repeating: [Float](), count: sourceSignal.numberOfChannels)
        var keptSegments: [EpochSegment] = []
        var outputStart = 0
        for epoch in preparation.segments.indices where epochDecision(epoch) == .keep {
            let old = preparation.segments[epoch]
            let length = old.endSample - old.startSample + 1
            guard length > 0 else { continue }
            for channel in compacted.indices {
                guard data[channel].indices.contains(old.startSample), data[channel].indices.contains(old.endSample) else { continue }
                compacted[channel].append(contentsOf: data[channel][old.startSample...old.endSample])
            }
            keptSegments.append(EpochSegment(
                startSample: outputStart,
                endSample: outputStart + length - 1,
                stimulusOffsetSamples: old.stimulusOffsetSamples,
                category: old.category,
                sourceCode: old.sourceCode,
                sourceTimeSeconds: old.sourceTimeSeconds,
                colorIndex: old.colorIndex,
                contributingEpochCount: old.contributingEpochCount
            ))
            outputStart += length
        }
        guard !keptSegments.isEmpty, compacted.first?.isEmpty == false else { return nil }
        let events = keptSegments.enumerated().map { index, segment in
            let stimulusSample = segment.startSample + segment.stimulusOffsetSamples
            let stimulusTime = Double(stimulusSample) / sourceSignal.samplingRate
            return MFFEvent(
                id: "psa-reviewed-\(index)",
                code: segment.category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: "PSA Decision Matrix"
            )
        }
        let signal = MFFSignalData(
            signalURL: sourceSignal.signalURL,
            signalType: sourceSignal.signalType,
            numberOfChannels: sourceSignal.numberOfChannels,
            samplingRate: sourceSignal.samplingRate,
            duration: Double(outputStart) / sourceSignal.samplingRate,
            recordingStartTime: sourceSignal.recordingStartTime,
            events: events,
            data: compacted,
            channelNames: sourceSignal.channelNames
        )
        return PSABuildResult(
            signal: signal,
            segments: keptSegments,
            message: "\(keptSegments.count) reviewed epochs"
        )
    }
}

private enum PSAMatrixDragMode {
    case channels(anchorRow: Int)
    case epochs(anchorColumn: Int)
    case cell
}

private enum PSAMatrixViewMode: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case detail = "Detail"
    var id: String { rawValue }
}

private struct PSAOverviewBrush {
    var anchor: CGPoint
    var current: CGPoint

    var rect: CGRect {
        CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }
}

private struct PSAOverviewSelection {
    var channels: [Int]
    var epochs: [Int]
    var rect: CGRect
}

private enum PSAOverviewDragMode {
    case area
    case channels(anchorRow: Int)
    case epochs(anchorColumn: Int)
}

struct PSADecisionMatrixView: View {
    @Bindable var model: PSADecisionMatrixModel
    var isApplying: Bool
    var isRunningFullChannelHealth: Bool
    var allowsFullHealthUpgrade: Bool
    var fallbackMessage: String
    var progress: Double?
    var progressMessage: String?
    var onBack: () -> Void
    var onCancel: () -> Void
    var onRunFullChannelHealth: () -> Void
    var onAverage: () -> Void
    @State private var dragMode: PSAMatrixDragMode?
    @State private var showsSelectionPopover = false
    @State private var matrixScrollOffset = CGPoint.zero
    @State private var matrixViewMode: PSAMatrixViewMode = .overview
    @State private var overviewBrush: PSAOverviewBrush?
    @State private var overviewSelection: PSAOverviewSelection?
    @State private var overviewDragMode: PSAOverviewDragMode?
    @State private var showsOverviewActions = false
    @State private var detailChannels: Set<Int>?
    @State private var detailEpochs: Set<Int>?

    private let cellWidth: CGFloat = 28
    private let rowHeight: CGFloat = 24
    private let leftWidth: CGFloat = 164
    private let headerHeight: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader
            controls
            categorySummary
            rejectionSummary
            if !model.hasRecordingWideChannelHealth {
                HStack(spacing: 12) {
                    Label(
                        fallbackMessage,
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if allowsFullHealthUpgrade {
                        Button("Run Full Channel Health", action: onRunFullChannelHealth)
                            .controlSize(.small)
                            .disabled(isRunningFullChannelHealth || isApplying)
                    }
                }
            }
            Text(cellScoreExplanation)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            matrix
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .popover(isPresented: $showsSelectionPopover, arrowEdge: .trailing) {
                    inspector
                        .frame(width: 340)
                        .padding(12)
                }
            footer
        }
        .padding(20)
        .frame(minWidth: 1120, idealWidth: 1320, minHeight: 680, idealHeight: 820)
    }

    private var cellScoreExplanation: String {
        switch model.channelPriorKind {
        case .fullRecording:
            return "Cell score: 60% channel-in-epoch evidence · 25% full Channel Health · 15% Segment Health"
        case .fastRecording:
            return "Cell score: 60% channel-in-epoch evidence · 25% fast recording health · 15% Segment Health"
        case .segmentMedian:
            return "Cell score: 60% channel-in-epoch evidence · 25% median epoch-set channel health · 15% Segment Health"
        }
    }

    private var stepHeader: some View {
        HStack(spacing: 8) {
            Label("Configure", systemImage: "1.circle.fill").foregroundStyle(.secondary)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            Label("Review decisions", systemImage: "2.circle.fill").fontWeight(.semibold)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            Label("Average", systemImage: "3.circle").foregroundStyle(.secondary)
            Spacer()
            Text("\(model.keptEpochCount) kept · \(model.rejectedEpochCount) rejected")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Picker("Channels", selection: $model.channelOrder) {
                    ForEach(PSAChannelMatrixOrder.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 230)
                Picker("Epochs", selection: $model.epochOrder) {
                    ForEach(PSAEpochMatrixOrder.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 210)
                Spacer()
                Picker("View", selection: $matrixViewMode) {
                    ForEach(PSAMatrixViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                if matrixViewMode == .detail,
                   detailChannels != nil || detailEpochs != nil {
                    Button("Fit All") {
                        detailChannels = nil
                        detailEpochs = nil
                        matrixViewMode = .overview
                    }
                    .controlSize(.small)
                }
                Text(matrixViewMode == .overview
                     ? "Drag an area to zoom or act on it."
                     : "Drag channel or epoch headers to select ranges.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("Interpolate channels below", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(width: 190, alignment: .leading)
                Slider(value: $model.interpolationHealthThreshold, in: 0...100, step: 1).frame(width: 180)
                Text("\(Int(model.interpolationHealthThreshold))%").monospacedDigit().frame(width: 36)
                Divider().frame(height: 20)
                Label("Reject epochs below", systemImage: "xmark.rectangle")
                    .frame(width: 155, alignment: .leading)
                Slider(value: $model.epochRejectionHealthThreshold, in: 0...100, step: 1).frame(width: 180)
                Text("\(Int(model.epochRejectionHealthThreshold))%").monospacedDigit().frame(width: 36)
                Spacer()
            }
        }
        .font(.caption)
    }

    private var categorySummary: some View {
        HStack(spacing: 10) {
            Text("Kept by category")
                .font(.caption.weight(.semibold))
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.categorySummaries) { summary in
                        HStack(spacing: 5) {
                            Text(summary.category.isEmpty ? "Uncategorized" : summary.category)
                                .lineLimit(1)
                            Text("\(summary.kept)/\(summary.total)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(healthColor(summary.total > 0 ? 100 * summary.kept / summary.total : 0).opacity(0.16), in: Capsule())
                        .help("\(summary.kept) of \(summary.total) epochs kept")
                    }
                }
            }
        }
    }

    private var rejectionSummary: some View {
        HStack(spacing: 8) {
            Text("Rejected because")
                .font(.caption.weight(.semibold))
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(model.rejectionReasonSummaries) { summary in
                        Text("\(summary.reason) \(summary.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.14), in: Capsule())
                    }
                }
            }
            Text("Counts can overlap")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .help("One epoch can have more than one rejection reason, so reason counts need not add up to the rejected total.")
    }

    private var matrix: some View {
        Group {
            switch matrixViewMode {
            case .overview:
                overviewMatrix
            case .detail:
                detailMatrix
            }
        }
    }

    private var displayedDetailChannels: [Int] {
        guard let detailChannels else { return model.orderedChannels }
        return model.orderedChannels.filter(detailChannels.contains)
    }

    private var displayedDetailEpochs: [Int] {
        guard let detailEpochs else { return model.orderedEpochs }
        return model.orderedEpochs.filter(detailEpochs.contains)
    }

    private var detailMatrix: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                // Keep this canvas synchronous. Its pinned labels are cheap to
                // draw, and letting an asynchronous frame arrive after the
                // scroll offset changed made the epoch/channel rails visibly
                // lag behind the cells (and occasionally disappear).
                Canvas(opaque: true, rendersAsynchronously: false) { context, _ in
                    drawDetailMatrix(
                        context: &context,
                        channels: displayedDetailChannels,
                        epochs: displayedDetailEpochs,
                        viewportSize: geometry.size
                    )
                }
                    .frame(
                        width: leftWidth + CGFloat(displayedDetailEpochs.count) * cellWidth,
                        height: headerHeight + CGFloat(displayedDetailChannels.count) * rowHeight
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged(handleMatrixDrag)
                            .onEnded { _ in
                                dragMode = nil
                                showsSelectionPopover = model.selectedCell != nil
                                    || !model.selectedChannels.isEmpty
                                    || !model.selectedEpochs.isEmpty
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            fitAllOverview()
                        }
                    )
            }
            .onScrollGeometryChange(for: CGPoint.self) { geometry in
                geometry.contentOffset
            } action: { _, offset in
                matrixScrollOffset = offset
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .help("Double-click the detail background to return to Fit All.")
        }
    }

    private func fitAllOverview() {
        detailChannels = nil
        detailEpochs = nil
        matrixScrollOffset = .zero
        matrixViewMode = .overview
    }

    private let overviewLeftWidth: CGFloat = 74
    private let overviewHeaderHeight: CGFloat = 42

    private var isOverviewAreaDrag: Bool {
        guard let overviewDragMode else { return false }
        if case .area = overviewDragMode { return true }
        return false
    }

    private var overviewMatrix: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas(opaque: true, rendersAsynchronously: true) { context, _ in
                    drawOverviewMatrix(context: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { handleOverviewDrag($0, size: size) }
                        .onEnded { finishOverviewDrag($0, size: size) }
                )

                if let brush = overviewBrush, isOverviewAreaDrag {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.13))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: brush.rect.width, height: brush.rect.height)
                        .offset(x: brush.rect.minX, y: brush.rect.minY)
                        .allowsHitTesting(false)
                } else if let selection = overviewSelection {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: selection.rect.width, height: selection.rect.height)
                        .offset(x: selection.rect.minX, y: selection.rect.minY)
                        .allowsHitTesting(false)
                }

                VStack {
                    Spacer()
                    Text("All \(model.orderedChannels.count) channels × \(model.orderedEpochs.count) epochs · drag the body to select an area")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .popover(isPresented: $showsOverviewActions, arrowEdge: .trailing) {
                overviewActions
                    .frame(width: 310)
                    .padding(12)
            }
            .onChange(of: model.channelOrder) { _, _ in clearOverviewSelection() }
            .onChange(of: model.epochOrder) { _, _ in clearOverviewSelection() }
        }
    }

    private func clearOverviewSelection() {
        overviewBrush = nil
        overviewSelection = nil
        showsOverviewActions = false
    }

    @ViewBuilder
    private var overviewActions: some View {
        if let selection = overviewSelection {
            VStack(alignment: .leading, spacing: 12) {
                Text("Selected area").font(.headline)
                Text("\(selection.channels.count) channel\(selection.channels.count == 1 ? "" : "s") × \(selection.epochs.count) epoch\(selection.epochs.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Zoom to Selection") {
                    detailChannels = Set(selection.channels)
                    detailEpochs = Set(selection.epochs)
                    matrixViewMode = .detail
                    showsOverviewActions = false
                }
                .buttonStyle(.borderedProminent)
                Button("Interpolate Selected Cells") {
                    for channel in selection.channels {
                        for epoch in selection.epochs {
                            model.setCellDecision(
                                .interpolate,
                                for: .init(channelIndex: channel, epochIndex: epoch)
                            )
                        }
                    }
                    showsOverviewActions = false
                }
                Button("Reject Selected Epochs") {
                    model.setEpochDecision(.reject, epochs: Set(selection.epochs))
                    showsOverviewActions = false
                }
                Button("Clear Area") {
                    overviewSelection = nil
                    showsOverviewActions = false
                }
                Text("Use the left or top margin to select entire channels or epochs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func drawOverviewMatrix(context: inout GraphicsContext, size: CGSize) {
        let channels = model.orderedChannels
        let epochs = model.orderedEpochs
        guard !channels.isEmpty, !epochs.isEmpty,
              size.width > overviewLeftWidth, size.height > overviewHeaderHeight else { return }
        let matrixWidth = size.width - overviewLeftWidth
        let matrixHeight = size.height - overviewHeaderHeight
        let cellWidth = matrixWidth / CGFloat(epochs.count)
        let rowHeight = matrixHeight / CGFloat(channels.count)
        let epochDecisions = epochs.map(model.resolvedEpochDecision)
        let background = Color(nsColor: .controlBackgroundColor)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))

        var greenCells = Path()
        var yellowCells = Path()
        var redCells = Path()
        var interpolatedCells = Path()
        var rejectedEpochs = Path()
        var overrides = Path()
        var interpolatedCounts = [Int](repeating: 0, count: channels.count)
        for (row, channel) in channels.enumerated() {
            let y = overviewHeaderHeight + CGFloat(row) * rowHeight
            for (column, epoch) in epochs.enumerated() {
                let x = overviewLeftWidth + CGFloat(column) * cellWidth
                let rect = CGRect(
                    x: x, y: y,
                    width: max(cellWidth + 0.2, 0.7),
                    height: max(rowHeight + 0.2, 0.7)
                )
                let id = PSADecisionCellID(channelIndex: channel, epochIndex: epoch)
                if model.resolvedCellDecision(id) == .interpolate {
                    interpolatedCells.addRect(rect)
                    interpolatedCounts[row] += 1
                } else {
                    switch model.integratedGoodness(channel: channel, epoch: epoch) {
                    case 75...: greenCells.addRect(rect)
                    case 45..<75: yellowCells.addRect(rect)
                    default: redCells.addRect(rect)
                    }
                }
                if model.cellOverrides[id] != nil { overrides.addRect(rect) }
            }
        }
        context.fill(greenCells, with: .color(.green.opacity(0.86)))
        context.fill(yellowCells, with: .color(.yellow.opacity(0.88)))
        context.fill(redCells, with: .color(.red.opacity(0.88)))
        context.fill(interpolatedCells, with: .color(.blue.opacity(0.9)))
        for (column, decision) in epochDecisions.enumerated() where decision == .reject {
            let x = overviewLeftWidth + CGFloat(column) * cellWidth
            rejectedEpochs.addRect(CGRect(
                x: x, y: overviewHeaderHeight,
                width: max(cellWidth, 0.7), height: matrixHeight
            ))
        }
        context.fill(rejectedEpochs, with: .color(.black.opacity(0.18)))
        context.fill(overrides, with: .color(.purple.opacity(0.52)))

        // Marginal health strips make sorted rows and columns legible even
        // when individual overview cells are smaller than a point.
        for (row, channel) in channels.enumerated() {
            let y = overviewHeaderHeight + CGFloat(row) * rowHeight
            let color: Color = interpolatedCounts[row] == epochs.count
                ? .blue : healthColor(model.displayedChannelGoodness(channel))
            context.fill(
                Path(CGRect(x: overviewLeftWidth - 13, y: y, width: 11, height: max(rowHeight, 0.7))),
                with: .color(color)
            )
        }
        for (column, epoch) in epochs.enumerated() {
            let x = overviewLeftWidth + CGFloat(column) * cellWidth
            context.fill(
                Path(CGRect(x: x, y: overviewHeaderHeight - 13, width: max(cellWidth, 0.7), height: 11)),
                with: .color(healthColor(model.epochGoodness(epoch)))
            )
        }

        context.draw(
            Text(model.channelHealthScopeLabel).font(.system(size: 9, weight: .semibold)),
            at: CGPoint(x: (overviewLeftWidth - 13) / 2, y: 11),
            anchor: .center
        )
        context.draw(
            Text("Epoch health").font(.system(size: 9, weight: .semibold)),
            at: CGPoint(x: overviewLeftWidth + matrixWidth / 2, y: 11),
            anchor: .center
        )
        drawOverviewTicks(
            context: &context,
            channels: channels,
            epochs: epochs,
            cellWidth: cellWidth,
            rowHeight: rowHeight
        )
    }

    private func drawOverviewTicks(
        context: inout GraphicsContext,
        channels: [Int],
        epochs: [Int],
        cellWidth: CGFloat,
        rowHeight: CGFloat
    ) {
        let channelStep = max(1, Int(ceil(16 / max(rowHeight, 0.1))))
        for row in stride(from: 0, to: channels.count, by: channelStep) {
            let channel = channels[row]
            context.draw(
                Text(channelName(channel)).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary),
                at: CGPoint(
                    x: overviewLeftWidth - 17,
                    y: overviewHeaderHeight + (CGFloat(row) + 0.5) * rowHeight
                ),
                anchor: .trailing
            )
        }
        let epochStep = max(1, Int(ceil(28 / max(cellWidth, 0.1))))
        for column in stride(from: 0, to: epochs.count, by: epochStep) {
            let epoch = epochs[column]
            context.draw(
                Text("\(epoch + 1)").font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary),
                at: CGPoint(
                    x: overviewLeftWidth + (CGFloat(column) + 0.5) * cellWidth,
                    y: overviewHeaderHeight - 17
                ),
                anchor: .center
            )
        }
    }

    private func handleOverviewDrag(_ value: DragGesture.Value, size: CGSize) {
        let channels = model.orderedChannels
        let epochs = model.orderedEpochs
        guard !channels.isEmpty, !epochs.isEmpty else { return }
        let matrixWidth = max(size.width - overviewLeftWidth, 1)
        let matrixHeight = max(size.height - overviewHeaderHeight, 1)
        let rowHeight = matrixHeight / CGFloat(channels.count)
        let cellWidth = matrixWidth / CGFloat(epochs.count)
        if overviewDragMode == nil {
            if value.startLocation.x < overviewLeftWidth,
               value.startLocation.y >= overviewHeaderHeight {
                let row = overviewRow(at: value.startLocation.y, rowHeight: rowHeight, count: channels.count)
                overviewDragMode = .channels(anchorRow: row)
            } else if value.startLocation.y < overviewHeaderHeight,
                      value.startLocation.x >= overviewLeftWidth {
                let column = overviewColumn(at: value.startLocation.x, cellWidth: cellWidth, count: epochs.count)
                overviewDragMode = .epochs(anchorColumn: column)
            } else if value.startLocation.x >= overviewLeftWidth,
                      value.startLocation.y >= overviewHeaderHeight {
                overviewDragMode = .area
                overviewSelection = nil
                overviewBrush = .init(anchor: value.startLocation, current: value.location)
            }
        }
        switch overviewDragMode {
        case .area:
            overviewBrush?.current = CGPoint(
                x: min(max(value.location.x, overviewLeftWidth), size.width),
                y: min(max(value.location.y, overviewHeaderHeight), size.height)
            )
        case .channels(let anchor):
            let current = overviewRow(at: value.location.y, rowHeight: rowHeight, count: channels.count)
            model.selectChannels(Set(channels[min(anchor, current)...max(anchor, current)]))
        case .epochs(let anchor):
            let current = overviewColumn(at: value.location.x, cellWidth: cellWidth, count: epochs.count)
            model.selectEpochs(Set(epochs[min(anchor, current)...max(anchor, current)]))
        case nil:
            break
        }
    }

    private func finishOverviewDrag(_ value: DragGesture.Value, size: CGSize) {
        defer { overviewDragMode = nil }
        switch overviewDragMode {
        case .area:
            guard let brush = overviewBrush else { return }
            let channels = model.orderedChannels
            let epochs = model.orderedEpochs
            let matrixWidth = max(size.width - overviewLeftWidth, 1)
            let matrixHeight = max(size.height - overviewHeaderHeight, 1)
            let rowHeight = matrixHeight / CGFloat(max(channels.count, 1))
            let cellWidth = matrixWidth / CGFloat(max(epochs.count, 1))
            let rect = brush.rect.intersection(CGRect(
                x: overviewLeftWidth,
                y: overviewHeaderHeight,
                width: matrixWidth,
                height: matrixHeight
            ))
            guard rect.width > 1, rect.height > 1 else {
                overviewBrush = nil
                return
            }
            let firstRow = overviewRow(at: rect.minY, rowHeight: rowHeight, count: channels.count)
            let lastRow = overviewRow(at: rect.maxY, rowHeight: rowHeight, count: channels.count)
            let firstColumn = overviewColumn(at: rect.minX, cellWidth: cellWidth, count: epochs.count)
            let lastColumn = overviewColumn(at: rect.maxX, cellWidth: cellWidth, count: epochs.count)
            overviewSelection = .init(
                channels: Array(channels[min(firstRow, lastRow)...max(firstRow, lastRow)]),
                epochs: Array(epochs[min(firstColumn, lastColumn)...max(firstColumn, lastColumn)]),
                rect: rect
            )
            overviewBrush = nil
            showsOverviewActions = true
        case .channels, .epochs:
            showsSelectionPopover = !model.selectedChannels.isEmpty || !model.selectedEpochs.isEmpty
        case nil:
            break
        }
    }

    private func overviewRow(at y: CGFloat, rowHeight: CGFloat, count: Int) -> Int {
        min(max(Int((y - overviewHeaderHeight) / rowHeight), 0), max(count - 1, 0))
    }

    private func overviewColumn(at x: CGFloat, cellWidth: CGFloat, count: Int) -> Int {
        min(max(Int((x - overviewLeftWidth) / cellWidth), 0), max(count - 1, 0))
    }

    private func drawDetailMatrix(
        context: inout GraphicsContext,
        channels: [Int],
        epochs: [Int],
        viewportSize: CGSize
    ) {
        guard !channels.isEmpty, !epochs.isEmpty else { return }
        let contentBounds = CGRect(
            x: 0, y: 0,
            width: leftWidth + CGFloat(epochs.count) * cellWidth,
            height: headerHeight + CGFloat(channels.count) * rowHeight
        )
        let visible = CGRect(
            origin: CGPoint(
                x: max(matrixScrollOffset.x, 0),
                y: max(matrixScrollOffset.y, 0)
            ),
            size: viewportSize
        ).intersection(contentBounds)
        let firstColumn = max(0, Int(floor((visible.minX - leftWidth) / cellWidth)) - 1)
        let lastColumn = min(epochs.count - 1, Int(ceil((visible.maxX - leftWidth) / cellWidth)) + 1)
        let firstRow = max(0, Int(floor((visible.minY - headerHeight) / rowHeight)) - 1)
        let lastRow = min(channels.count - 1, Int(ceil((visible.maxY - headerHeight) / rowHeight)) + 1)
        let columnRange = firstColumn...max(firstColumn, lastColumn)
        let rowRange = firstRow...max(firstRow, lastRow)
        let epochDecisions = epochs.map(model.resolvedEpochDecision)

        context.fill(Path(visible), with: .color(Color(nsColor: .controlBackgroundColor)))
        var greenCells = Path()
        var yellowCells = Path()
        var redCells = Path()
        var interpolatedCells = Path()
        var selectedCells = Path()
        var rejectedCells = Path()
        var overrideOutlines = Path()
        var selectedOutline = Path()

        for row in rowRange {
            let y = headerHeight + CGFloat(row) * rowHeight
            let channel = channels[row]
            if model.selectedChannels.contains(channel) {
                context.fill(Path(CGRect(x: visible.minX, y: y, width: visible.width, height: rowHeight)),
                             with: .color(.accentColor.opacity(0.12)))
            }
            for column in columnRange {
                let epoch = epochs[column]
                let id = PSADecisionCellID(channelIndex: channel, epochIndex: epoch)
                let x = leftWidth + CGFloat(column) * cellWidth
                let rect = CGRect(x: x + 1, y: y + 1, width: cellWidth - 2, height: rowHeight - 2)
                if model.resolvedCellDecision(id) == .interpolate {
                    interpolatedCells.addRect(rect)
                } else {
                    let goodness = model.integratedGoodness(channel: channel, epoch: epoch)
                    switch goodness {
                    case 75...: greenCells.addRect(rect)
                    case 45..<75: yellowCells.addRect(rect)
                    default: redCells.addRect(rect)
                    }
                }
                if model.selectedChannels.contains(channel) || model.selectedEpochs.contains(epoch) {
                    selectedCells.addRect(rect)
                }
                if model.cellOverrides[id] != nil {
                    overrideOutlines.addRect(rect.insetBy(dx: 1, dy: 1))
                }
                if model.selectedCell == id {
                    selectedOutline.addRect(rect.insetBy(dx: 0.5, dy: 0.5))
                }
                if epochDecisions[column] == .reject {
                    rejectedCells.addRect(rect)
                }
            }
        }
        context.fill(greenCells, with: .color(.green.opacity(0.86)))
        context.fill(yellowCells, with: .color(.yellow.opacity(0.86)))
        context.fill(redCells, with: .color(.red.opacity(0.86)))
        context.fill(interpolatedCells, with: .color(.blue.opacity(0.9)))
        context.fill(selectedCells, with: .color(.accentColor.opacity(0.18)))
        context.fill(rejectedCells, with: .color(.black.opacity(0.18)))
        context.stroke(overrideOutlines, with: .color(.primary), lineWidth: 2)
        context.stroke(selectedOutline, with: .color(.accentColor), lineWidth: 3)

        // Pin epoch identity to the top of the visible viewport.
        let pinnedY = visible.minY
        context.fill(
            Path(CGRect(x: visible.minX, y: pinnedY, width: visible.width, height: headerHeight)),
            with: .color(Color(nsColor: .controlBackgroundColor))
        )
        for column in columnRange {
            let epoch = epochs[column]
            let x = leftWidth + CGFloat(column) * cellWidth
            guard x + cellWidth >= visible.minX + leftWidth else { continue }
            let goodness = model.epochGoodness(epoch)
            let category = String(model.preparation.segments[epoch].category.prefix(3))
            context.draw(Text(category).font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: x + cellWidth / 2, y: pinnedY + 15), anchor: .center)
            let badge = CGRect(x: x + 1, y: pinnedY + 30, width: cellWidth - 2, height: 18)
            context.fill(Path(badge), with: .color(healthColor(goodness).opacity(0.9)))
            if epochDecisions[column] == .reject {
                context.fill(Path(badge), with: .color(.black.opacity(0.28)))
                var icon = context.resolve(Image(systemName: epochArtifactSymbol(epoch)))
                icon.shading = .color(.white)
                context.draw(icon, at: CGPoint(x: badge.midX, y: badge.midY), anchor: .center)
            }
            context.draw(Text("\(epoch + 1)").font(.system(size: 9, design: .monospaced)),
                         at: CGPoint(x: x + cellWidth / 2, y: pinnedY + 60), anchor: .center)
        }

        // Pin channel identity and overall health to the left edge.
        let pinnedX = visible.minX
        context.fill(
            Path(CGRect(x: pinnedX, y: visible.minY, width: leftWidth, height: visible.height)),
            with: .color(Color(nsColor: .controlBackgroundColor))
        )
        for row in rowRange {
            let channel = channels[row]
            let y = headerHeight + CGFloat(row) * rowHeight
            let name = model.preparation.signal.channelNames?.indices.contains(channel) == true
                ? model.preparation.signal.channelNames?[channel] ?? "Ch \(channel + 1)"
                : "Ch \(channel + 1)"
            let overall = model.displayedChannelGoodness(channel)
            let channelColor: Color = model.isChannelInterpolatedAcrossAllEpochs(channel)
                ? .blue : healthColor(overall)
            if model.selectedChannels.contains(channel) {
                context.fill(Path(CGRect(x: pinnedX, y: y, width: leftWidth, height: rowHeight)),
                             with: .color(.accentColor.opacity(0.12)))
            }
            context.draw(Text(name).font(.system(size: 11, design: .monospaced)),
                         at: CGPoint(x: pinnedX + 8, y: y + rowHeight / 2), anchor: .leading)
            context.fill(Path(CGRect(x: pinnedX + 104, y: y + 4, width: 42, height: rowHeight - 8)),
                         with: .color(channelColor))
            context.draw(Text("\(overall)%").font(.system(size: 9).monospacedDigit()).foregroundColor(.white),
                         at: CGPoint(x: pinnedX + 125, y: y + rowHeight / 2), anchor: .center)
        }

        // The upper-left label remains visible at both scroll extremes.
        context.fill(
            Path(CGRect(x: pinnedX, y: pinnedY, width: leftWidth, height: headerHeight)),
            with: .color(Color(nsColor: .controlBackgroundColor))
        )
        context.draw(Text(model.channelHealthScopeLabel).font(.caption.weight(.semibold)),
                     at: CGPoint(x: pinnedX + 76, y: pinnedY + 16), anchor: .center)
    }

    private func epochArtifactSymbol(_ epoch: Int) -> String {
        let reasons = model.suggestedRejectedEpochReasons[epoch, default: []]
            .joined(separator: " ").lowercased()
        if reasons.contains("eye") || reasons.contains("blink") || reasons.contains("ocular") {
            return "eye.fill"
        }
        if reasons.contains("bcg") || reasons.contains("pulse") || reasons.contains("cardiac")
            || reasons.contains("ecg") || reasons.contains("heartbeat") {
            return "waveform.path.ecg"
        }
        if reasons.contains("mri") || reasons.contains("gradient") {
            return "bolt.fill"
        }
        if reasons.contains("timing") || reasons.contains("marker") {
            return "clock.badge.exclamationmark"
        }
        return "xmark"
    }

    private func handleMatrixDrag(_ value: DragGesture.Value) {
        let channels = displayedDetailChannels
        let epochs = displayedDetailEpochs
        let pinnedX = max(matrixScrollOffset.x, 0)
        let pinnedY = max(matrixScrollOffset.y, 0)
        if dragMode == nil {
            if value.startLocation.x < pinnedX + leftWidth,
               value.startLocation.y >= pinnedY + headerHeight {
                let row = Int((value.startLocation.y - headerHeight) / rowHeight)
                guard channels.indices.contains(row) else { return }
                dragMode = .channels(anchorRow: row)
            } else if value.startLocation.y < pinnedY + headerHeight,
                      value.startLocation.x >= pinnedX + leftWidth {
                let column = Int((value.startLocation.x - leftWidth) / cellWidth)
                guard epochs.indices.contains(column) else { return }
                dragMode = .epochs(anchorColumn: column)
            } else if value.startLocation.x >= leftWidth, value.startLocation.y >= headerHeight {
                dragMode = .cell
            } else {
                return
            }
        }
        switch dragMode {
        case .channels(let anchor):
            let current = min(max(Int((value.location.y - headerHeight) / rowHeight), 0), channels.count - 1)
            model.selectChannels(Set(channels[min(anchor, current)...max(anchor, current)]))
        case .epochs(let anchor):
            let current = min(max(Int((value.location.x - leftWidth) / cellWidth), 0), epochs.count - 1)
            model.selectEpochs(Set(epochs[min(anchor, current)...max(anchor, current)]))
        case .cell:
            let column = Int((value.location.x - leftWidth) / cellWidth)
            let row = Int((value.location.y - headerHeight) / rowHeight)
            guard channels.indices.contains(row), epochs.indices.contains(column) else { return }
            model.selectCell(.init(channelIndex: channels[row], epochIndex: epochs[column]))
        case nil:
            break
        }
    }

    private var inspector: some View {
        GroupBox("Selection details") {
            if !model.selectedChannels.isEmpty {
                channelSelectionInspector
            } else if !model.selectedEpochs.isEmpty {
                epochSelectionInspector
            } else if let id = model.selectedCell {
                VStack(alignment: .leading, spacing: 12) {
                    let segment = model.preparation.segments[id.epochIndex]
                    Text("Channel \(id.channelIndex + 1) · Epoch \(id.epochIndex + 1)").font(.headline)
                    Text("\(segment.category) · local \(Int(model.localGoodness(channel: id.channelIndex, epoch: id.epochIndex)))% · channel prior \(model.displayedChannelGoodness(id.channelIndex))% · epoch \(model.epochGoodness(id.epochIndex))% · integrated \(model.integratedGoodness(channel: id.channelIndex, epoch: id.epochIndex))%")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reasons = model.suggestedRejectedEpochReasons[id.epochIndex], !reasons.isEmpty {
                        Label(reasons.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let reason = model.interpolationFeasibilityReason(epoch: id.epochIndex) {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    evidenceText(id)
                    Picker("Cell decision", selection: Binding(
                        get: { model.cellOverrides[id] ?? .automatic },
                        set: { model.setCellDecision($0, for: id) }
                    )) {
                        ForEach(PSACellDecision.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Epoch decision", selection: Binding(
                        get: { model.epochOverrides[id.epochIndex] ?? .automatic },
                        set: { model.setEpochDecision($0, epoch: id.epochIndex) }
                    )) {
                        ForEach(PSAEpochDecision.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                    HStack {
                        Button("Keep channel") {
                            model.setChannelDecision(.keep, channels: [id.channelIndex])
                        }
                        Button("Reject channel") {
                            model.setChannelDecision(.interpolate, channels: [id.channelIndex])
                        }
                    }
                    .controlSize(.small)
                    Text("Explicit decisions override both sliders.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var channelSelectionInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.selectedChannels.count) channel\(model.selectedChannels.count == 1 ? "" : "s") selected")
                .font(.headline)
            Text(model.selectedChannels.sorted().map { channelName($0) }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(4)
            Text("Rejecting a channel here means interpolating it within every kept epoch; it does not change recording-wide Channel Health.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reject Selected Channels (Interpolate)") {
                model.setChannelDecision(.interpolate, channels: model.selectedChannels)
            }
            .buttonStyle(.borderedProminent)
            Button("Keep Selected Channels") {
                model.setChannelDecision(.keep, channels: model.selectedChannels)
            }
            Button("Return Selected to Automatic") {
                model.setChannelDecision(.automatic, channels: model.selectedChannels)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var epochSelectionInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.selectedEpochs.count) epoch\(model.selectedEpochs.count == 1 ? "" : "s") selected")
                .font(.headline)
            Text(model.selectedEpochs.sorted().map { "#\($0 + 1) \(model.preparation.segments[$0].category)" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(5)
            let reasons = Set(model.selectedEpochs.flatMap { model.suggestedRejectedEpochReasons[$0] ?? [] })
            if !reasons.isEmpty {
                Label(reasons.sorted().joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            let interpolationWarnings = Set(model.selectedEpochs.compactMap {
                model.interpolationFeasibilityReason(epoch: $0)
            })
            if !interpolationWarnings.isEmpty {
                Label(interpolationWarnings.sorted().joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("Reject Selected Epochs") {
                model.setEpochDecision(.reject, epochs: model.selectedEpochs)
            }
            .buttonStyle(.borderedProminent)
            Button("Keep Selected Epochs") {
                model.setEpochDecision(.keep, epochs: model.selectedEpochs)
            }
            Button("Return Selected to Automatic") {
                model.setEpochDecision(.automatic, epochs: model.selectedEpochs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func channelName(_ channel: Int) -> String {
        model.preparation.signal.channelNames?.indices.contains(channel) == true
            ? model.preparation.signal.channelNames?[channel] ?? "Ch \(channel + 1)"
            : "Ch \(channel + 1)"
    }

    private func evidenceText(_ id: PSADecisionCellID) -> some View {
        let reviewed = model.preparation.evidence[id.epochIndex][id.channelIndex]
        let raw = model.preparation.rawEvidence[id.epochIndex][id.channelIndex]
        return VStack(alignment: .leading, spacing: 3) {
            Text("Review evidence").font(.caption.weight(.semibold))
            Text(reviewed.map { String(format: "min %.1f µV · max %.1f µV\nslope %.1f µV/sample · acceleration %.1f", $0.minimumMicrovolts, $0.maximumMicrovolts, $0.maximumSlopeMicrovoltsPerSample, $0.maximumAccelerationMicrovoltsPerSample) } ?? "Unavailable")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("Before reference/baseline").font(.caption.weight(.semibold))
            Text(raw.map { String(format: "min %.1f µV · max %.1f µV\nslope %.1f µV/sample · acceleration %.1f", $0.minimumMicrovolts, $0.maximumMicrovolts, $0.maximumSlopeMicrovoltsPerSample, $0.maximumAccelerationMicrovoltsPerSample) } ?? "Unavailable")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back", action: onBack).disabled(isApplying)
            Spacer()
            if isApplying || isRunningFullChannelHealth {
                if let progress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(progressMessage ?? (isRunningFullChannelHealth ? "Running full Channel Health…" : "Applying decisions and averaging…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", action: onCancel).disabled(isApplying)
            Button("Average \(model.keptEpochCount) Epochs", action: onAverage)
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || isRunningFullChannelHealth || model.keptEpochCount == 0)
        }
    }

    private func healthColor(_ goodness: Int) -> Color {
        switch goodness {
        case 75...: return .green
        case 45..<75: return .yellow
        default: return .red
        }
    }
}
