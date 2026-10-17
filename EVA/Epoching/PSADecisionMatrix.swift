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

nonisolated enum PSAChannelMatrixOrder: String, CaseIterable, Identifiable {
    case number = "Channel number"
    case goodness = "Overall goodness"
    var id: String { rawValue }
}

nonisolated enum PSAEpochMatrixOrder: String, CaseIterable, Identifiable {
    case acquisition = "Acquisition"
    case category = "Category"
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
    var summaries: [PSAFastSegmentSummary?]
}

nonisolated struct PSADecisionMatrixPreparation: Sendable {
    var signal: MFFSignalData
    var segments: [EpochSegment]
    var evidence: [[EpochBadChannelDetector.Evidence?]] // epoch, then channel
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
        suggestedRejectedEpochReasons: [Int: [String]] = [:],
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) -> Self {
        var scanRows = [PSAFastScanRow](
            repeating: PSAFastScanRow(
                summaries: [PSAFastSegmentSummary?](repeating: nil, count: signal.numberOfChannels)
            ),
            count: segments.count
        )
        let progressCounter = PSAScanProgressCounter()
        scanRows.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let output = buffer.baseAddress!
            evaConcurrentPerform(iterations: segments.count) { epochIndex in
                let segment = segments[epochIndex]
                let range = segment.startSample..<(segment.endSample + 1)
                var summaries = [PSAFastSegmentSummary?](repeating: nil, count: signal.numberOfChannels)
                for channelIndex in signal.data.indices {
                    summaries[channelIndex] = fastSummary(in: signal.data[channelIndex], range: range)
                }
                (output + epochIndex).pointee = PSAFastScanRow(summaries: summaries)
                progress?(progressCounter.increment(), segments.count)
            }
        }
        let rows = scanRows.map { $0.summaries.map { $0?.evidence } }
        let localScores = scanRows.map { row in
            fastGoodnessScores(summaries: row.summaries, settings: baseSettings)
        }
        var suggestions = Set<PSADecisionCellID>()
        for epochIndex in segments.indices {
            for channelIndex in signal.data.indices {
                if rows[epochIndex][channelIndex]?.exceeds(thresholds) == true {
                    suggestions.insert(.init(channelIndex: channelIndex, epochIndex: epochIndex))
                }
            }
        }
        for (channelIndex, oneBasedEpochs) in detectorSegments {
            for number in oneBasedEpochs where segments.indices.contains(number - 1) {
                suggestions.insert(.init(channelIndex: channelIndex, epochIndex: number - 1))
            }
        }
        let epochGoodnessScores = localScores.map { epoch in
            guard !epoch.isEmpty else { return 100 }
            let total = epoch.reduce(0, +)
            return Int((Double(total) / Double(epoch.count)).rounded())
        }
        let epochSetChannelGoodnessScores = (0..<signal.numberOfChannels).map { channel in
            median(localScores.compactMap { $0.indices.contains(channel) ? Double($0[channel]) : nil }, fallback: 100)
        }
        return Self(
            signal: signal,
            segments: segments,
            evidence: rows,
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

    func resolvedEpochDecision(_ epoch: Int) -> PSAEpochDecision {
        if let explicit = epochOverrides[epoch], explicit != .automatic { return explicit }
        if suggestedRejectedEpochReasons[epoch]?.isEmpty == false { return .reject }
        return Double(epochGoodness(epoch)) < epochRejectionHealthThreshold ? .reject : .keep
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
        let goodness = preparation.epochGoodnessScores.indices.contains(epoch)
            ? preparation.epochGoodnessScores[epoch] : 100
        return Double(goodness) < epochRejectionHealthThreshold ? .reject : .keep
    }

    func materializedResult() -> PSABuildResult? {
        var data = preparation.signal.data
        let cache = SphericalSplineWeightCache()
        for epoch in preparation.segments.indices where epochDecision(epoch) == .keep {
            let segment = preparation.segments[epoch]
            let bad = Set((0..<preparation.signal.numberOfChannels).filter {
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

        var compacted = Array(repeating: [Float](), count: preparation.signal.numberOfChannels)
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
            let stimulusTime = Double(stimulusSample) / preparation.signal.samplingRate
            return MFFEvent(
                id: "psa-reviewed-\(index)",
                code: segment.category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: "PSA Decision Matrix"
            )
        }
        let signal = MFFSignalData(
            signalURL: preparation.signal.signalURL,
            signalType: preparation.signal.signalType,
            numberOfChannels: preparation.signal.numberOfChannels,
            samplingRate: preparation.signal.samplingRate,
            duration: Double(outputStart) / preparation.signal.samplingRate,
            recordingStartTime: preparation.signal.recordingStartTime,
            events: events,
            data: compacted,
            channelNames: preparation.signal.channelNames
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

    private let cellWidth: CGFloat = 28
    private let rowHeight: CGFloat = 24
    private let leftWidth: CGFloat = 164
    private let headerHeight: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader
            controls
            categorySummary
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
            return "Cell score: 60% fast segment health · 25% full Channel Health · 15% epoch health"
        case .fastRecording:
            return "Cell score: 60% fast segment health · 25% fast recording health · 15% epoch health"
        case .segmentMedian:
            return "Cell score: 60% fast segment health · 25% median epoch-set channel health · 15% epoch health"
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
                Text("Drag channel or epoch headers to select ranges.")
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

    private var matrix: some View {
        GeometryReader { _ in
            ScrollView([.horizontal, .vertical]) {
                Canvas { context, _ in drawMatrix(context: &context) }
                    .frame(
                        width: leftWidth + CGFloat(model.orderedEpochs.count) * cellWidth,
                        height: headerHeight + CGFloat(model.orderedChannels.count) * rowHeight
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
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func drawMatrix(context: inout GraphicsContext) {
        let channels = model.orderedChannels
        let epochs = model.orderedEpochs
        context.fill(Path(CGRect(x: 0, y: 0, width: leftWidth, height: headerHeight + CGFloat(channels.count) * rowHeight)),
                     with: .color(.secondary.opacity(0.07)))
        context.draw(Text(model.channelHealthScopeLabel).font(.caption.weight(.semibold)),
                     at: CGPoint(x: 76, y: 16), anchor: .center)
        for (column, epoch) in epochs.enumerated() {
            let x = leftWidth + CGFloat(column) * cellWidth
            let goodness = model.epochGoodness(epoch)
            let category = String(model.preparation.segments[epoch].category.prefix(3))
            context.draw(Text(category).font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: x + cellWidth / 2, y: 15), anchor: .center)
            context.fill(Path(CGRect(x: x + 1, y: 30, width: cellWidth - 2, height: 18)),
                         with: .color(healthColor(goodness).opacity(0.9)))
            if model.resolvedEpochDecision(epoch) == .reject {
                let badge = CGRect(x: x + 1, y: 30, width: cellWidth - 2, height: 18)
                context.fill(Path(badge), with: .color(.black.opacity(0.28)))
                context.draw(Text("×").font(.caption.bold()).foregroundColor(.white),
                             at: CGPoint(x: badge.midX, y: badge.midY), anchor: .center)
            }
            if model.selectedEpochs.contains(epoch) {
                context.stroke(
                    Path(CGRect(x: x + 0.5, y: 0.5, width: cellWidth - 1, height: headerHeight + CGFloat(channels.count) * rowHeight - 1)),
                    with: .color(.accentColor), lineWidth: 2
                )
            }
            context.draw(Text("\(epoch + 1)").font(.system(size: 9, design: .monospaced)),
                         at: CGPoint(x: x + cellWidth / 2, y: 60), anchor: .center)
        }
        for (row, channel) in channels.enumerated() {
            let y = headerHeight + CGFloat(row) * rowHeight
            let name = model.preparation.signal.channelNames?.indices.contains(channel) == true
                ? model.preparation.signal.channelNames?[channel] ?? "Ch \(channel + 1)"
                : "Ch \(channel + 1)"
            let overall = model.displayedChannelGoodness(channel)
            if model.selectedChannels.contains(channel) {
                context.fill(Path(CGRect(x: 0, y: y, width: leftWidth + CGFloat(epochs.count) * cellWidth, height: rowHeight)),
                             with: .color(.accentColor.opacity(0.12)))
            }
            context.draw(Text(name).font(.system(size: 11, design: .monospaced)),
                         at: CGPoint(x: 8, y: y + rowHeight / 2), anchor: .leading)
            context.fill(Path(CGRect(x: 104, y: y + 4, width: 42, height: rowHeight - 8)),
                         with: .color(healthColor(overall)))
            context.draw(Text("\(overall)%").font(.system(size: 9).monospacedDigit()).foregroundColor(.white),
                         at: CGPoint(x: 125, y: y + rowHeight / 2), anchor: .center)
            for (column, epoch) in epochs.enumerated() {
                let id = PSADecisionCellID(channelIndex: channel, epochIndex: epoch)
                let x = leftWidth + CGFloat(column) * cellWidth
                let rect = CGRect(x: x + 1, y: y + 1, width: cellWidth - 2, height: rowHeight - 2)
                let goodness = model.integratedGoodness(channel: channel, epoch: epoch)
                context.fill(Path(rect), with: .color(healthColor(goodness).opacity(0.86)))
                if model.selectedChannels.contains(channel) || model.selectedEpochs.contains(epoch) {
                    context.fill(Path(rect), with: .color(.accentColor.opacity(0.18)))
                }
                if model.cellOverrides[id] != nil {
                    context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.primary), lineWidth: 2)
                }
                if model.selectedCell == id {
                    context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.accentColor), lineWidth: 3)
                }
                if model.resolvedEpochDecision(epoch) == .reject {
                    context.fill(Path(rect), with: .color(.black.opacity(0.18)))
                }
            }
        }
    }

    private func handleMatrixDrag(_ value: DragGesture.Value) {
        let channels = model.orderedChannels
        let epochs = model.orderedEpochs
        if dragMode == nil {
            if value.startLocation.x < leftWidth, value.startLocation.y >= headerHeight {
                let row = Int((value.startLocation.y - headerHeight) / rowHeight)
                guard channels.indices.contains(row) else { return }
                dragMode = .channels(anchorRow: row)
            } else if value.startLocation.y < headerHeight, value.startLocation.x >= leftWidth {
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
                    waveform(id)
                        .frame(height: 110)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
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
        let value = model.preparation.evidence[id.epochIndex][id.channelIndex]
        return VStack(alignment: .leading, spacing: 3) {
            Text("Local evidence").font(.caption.weight(.semibold))
            Text(value.map { String(format: "min %.1f µV · max %.1f µV\nslope %.1f µV/sample · acceleration %.1f", $0.minimumMicrovolts, $0.maximumMicrovolts, $0.maximumSlopeMicrovoltsPerSample, $0.maximumAccelerationMicrovoltsPerSample) } ?? "Unavailable")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func waveform(_ id: PSADecisionCellID) -> some View {
        Canvas { context, size in
            let segment = model.preparation.segments[id.epochIndex]
            let samples = model.preparation.signal.data[id.channelIndex]
            guard samples.indices.contains(segment.startSample), samples.indices.contains(segment.endSample) else { return }
            let values = Array(samples[segment.startSample...segment.endSample])
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let span = max(high - low, 1e-6)
            var path = Path()
            for index in values.indices {
                let point = CGPoint(
                    x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                    y: size.height - CGFloat((values[index] - low) / span) * size.height
                )
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.25)
        }
        .padding(6)
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
