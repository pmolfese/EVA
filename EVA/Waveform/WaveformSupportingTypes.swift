//
//  WaveformSupportingTypes.swift
//  EVA
//
//  Supporting value types, enums, and small views extracted from WaveformView.swift
//  during the L5 view-decomposition refactor. These are internal (same-module) so
//  WaveformView continues to see them unchanged.
//

import SwiftUI
import AppKit


/// Which channels the scalp-topography correlation uses. Bad channels are always
/// excluded.
enum ArtifactTopographyChannelScope: CaseIterable, Hashable, Identifiable {
    case allGood
    case topN
    case channelSet

    var id: Self { self }

    var label: String {
        switch self {
        case .allGood:     return "All good channels"
        case .topN:        return "Top N by amplitude"
        case .channelSet:  return "Channel set"
        }
    }
}

enum ArtifactDefinitionPanel: String, CaseIterable, Identifiable {
    case waveforms = "Waveforms"
    case topography = "Topography"

    var id: String { rawValue }
}

enum ArtifactDefinitionResultSource: Equatable {
    case waveform
    case topography

    var displayName: String {
        switch self {
        case .waveform: return "Waveform"
        case .topography: return "Topography"
        }
    }

    var confirmationName: String {
        switch self {
        case .waveform: return "Waveform"
        case .topography: return "Topography"
        }
    }

    var systemImage: String {
        switch self {
        case .waveform: return "waveform.path"
        case .topography: return "circle.grid.3x3.fill"
        }
    }
}

enum WaveletExplorerChannelScope: String, CaseIterable, Identifiable {
    case visibleGood = "Visible Good"
    case allGood = "All Good"
    case all = "All Channels"
    case ocular = "Ocular"

    var id: String { rawValue }
}

enum FilterLineNoiseMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case notch = "IIR Notch"
    case adaptiveCleanLine = "CleanLine"

    var id: String { rawValue }
}

struct WaveletArtifactExplorerLogLine: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
}

/// A PNS channel synthesized from one or more ICA components.
struct SyntheticPNSChannel: Identifiable {
    let id = UUID()
    /// Display name — defaults to "ICA" + sorted component numbers, e.g. "ICA13".
    var name: String
    /// Time course at `samplingRate` (sum of selected component activations, linearly
    /// upsampled from the ICA analysis rate to the EEG sampling rate).
    let samples: [Float]
    let samplingRate: Double
    /// The ICA component indices (0-based) that were summed to produce this channel.
    let sourceComponents: [Int]
}

/// Snapshot of the artifact-template controls that affect a full scan. Topography
/// mode/scope are excluded because they refresh live without a rescan.
struct ArtifactScanSignature: Equatable {
    var eventCode: String
    var clickedChannel: Int?
    var channelScope: ArtifactTemplateChannelScope
    var customChannels: String
    var threshold: Double
    var windowSeconds: Double
    var downsampleRate: Double
    var mergeWindowSeconds: Double
    var waveformStretchRange: Double
    var polarity: ArtifactTemplatePolarity
    var range: ClosedRange<Int>?
}

/// A toolbar button face that draws its own fixed-size rounded-rect chrome so
/// that every control — whether a plain Button or a Menu — renders at an
/// identical size regardless of how the system button/menu styles add padding.
struct ToolbarIcon: View {
    let name: String
    var label: String? = nil
    var isActive: Bool = false
    var inactiveForeground: Color = .primary

    private let size = CGSize(width: 77, height: 58)
    private var hasLabel: Bool {
        label?.isEmpty == false
    }

    var body: some View {
        VStack(spacing: hasLabel ? 3 : 0) {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: hasLabel ? 24 : 33, height: hasLabel ? 24 : 33)
                .foregroundStyle(isActive ? Color.white : inactiveForeground)

            if let label, !label.isEmpty {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? Color.white : inactiveForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: size.width - 10, height: 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive
                      ? Color.accentColor
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}


struct ICADebugSignalStats {
    let channelCount: Int
    let sampleCount: Int
    let sampledValueCount: Int
    let mean: Double
    let rms: Double
    let p50Abs: Double
    let p95Abs: Double
    let p99Abs: Double
    let maxAbs: Double
    let maxAbsChannel: Int?

    var summary: String {
        let channelText = maxAbsChannel.map { "Ch \($0 + 1)" } ?? "n/a"
        return [
            "\(channelCount) ch",
            "\(sampleCount) samples",
            "sampled \(sampledValueCount)",
            "mean \(Self.format(mean))",
            "RMS \(Self.format(rms))",
            "p50|x| \(Self.format(p50Abs))",
            "p95|x| \(Self.format(p95Abs))",
            "p99|x| \(Self.format(p99Abs))",
            "max|x| \(Self.format(maxAbs)) (\(channelText))"
        ].joined(separator: "; ")
    }

    static func make(signal: MFFSignalData, sampleRange: ClosedRange<Int>? = nil) -> Self {
        let channelCount = signal.data.count
        let sampleCount = signal.data.first?.count ?? 0
        guard channelCount > 0, sampleCount > 0 else {
            return ICADebugSignalStats(
                channelCount: channelCount,
                sampleCount: sampleCount,
                sampledValueCount: 0,
                mean: 0,
                rms: 0,
                p50Abs: 0,
                p95Abs: 0,
                p99Abs: 0,
                maxAbs: 0,
                maxAbsChannel: nil
            )
        }

        let range = sampleRange ?? 0...(sampleCount - 1)
        let lower = min(max(range.lowerBound, 0), sampleCount - 1)
        let upper = min(max(range.upperBound, lower), sampleCount - 1)
        let rangeCount = upper - lower + 1
        let sampleBudget = 200_000
        let sampleStride = max((rangeCount * max(channelCount, 1)) / sampleBudget, 1)

        var sampledAbsValues: [Double] = []
        sampledAbsValues.reserveCapacity(min(sampleBudget, rangeCount * channelCount / sampleStride + channelCount))
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        var maxAbs = 0.0
        var maxAbsChannel: Int?

        for channelIndex in signal.data.indices {
            let channel = signal.data[channelIndex]
            guard !channel.isEmpty else { continue }
            let channelUpper = min(upper, channel.count - 1)
            guard channelUpper >= lower else { continue }

            for sample in stride(from: lower, through: channelUpper, by: sampleStride) {
                let value = Double(channel[sample])
                guard value.isFinite else { continue }
                let absValue = abs(value)
                sampledAbsValues.append(absValue)
                sum += value
                sumSquares += value * value
                count += 1

                if absValue > maxAbs {
                    maxAbs = absValue
                    maxAbsChannel = channelIndex
                }
            }
        }

        guard count > 0 else {
            return ICADebugSignalStats(
                channelCount: channelCount,
                sampleCount: sampleCount,
                sampledValueCount: 0,
                mean: 0,
                rms: 0,
                p50Abs: 0,
                p95Abs: 0,
                p99Abs: 0,
                maxAbs: 0,
                maxAbsChannel: nil
            )
        }

        sampledAbsValues.sort()
        return ICADebugSignalStats(
            channelCount: channelCount,
            sampleCount: sampleCount,
            sampledValueCount: count,
            mean: sum / Double(count),
            rms: sqrt(sumSquares / Double(count)),
            p50Abs: SignalStatistics.percentile(sampledAbsValues, fraction: 0.50),
            p95Abs: SignalStatistics.percentile(sampledAbsValues, fraction: 0.95),
            p99Abs: SignalStatistics.percentile(sampledAbsValues, fraction: 0.99),
            maxAbs: maxAbs,
            maxAbsChannel: maxAbsChannel
        )
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "nan" }
        if abs(value) >= 100 {
            return String(format: "%.1f uV", value)
        }
        if abs(value) >= 10 {
            return String(format: "%.2f uV", value)
        }
        return String(format: "%.3f uV", value)
    }
}

struct HorizontalViewport: Equatable {
    let offsetX: CGFloat
    let width: CGFloat
}

struct WaveformDisplayedEventsCache {
    struct Key: Equatable {
        let signalURLPath: String
        let signalType: String
        let signalEvents: EventTrackEventSignature
        let userMarkers: [WaveformUserMarkerSignature]
        let artifactEvents: EventTrackEventSignature
        let definedArtifacts: [WaveformDefinedArtifactSignature]
        let epochSegments: WaveformEpochSegmentSignature
        let includeContinuousOverlays: Bool
        let includeArtifactOverlays: Bool
        let mapContinuousOverlaysIntoEpochs: Bool

        static let empty = Key(
            signalURLPath: "",
            signalType: "",
            signalEvents: .empty,
            userMarkers: [],
            artifactEvents: .empty,
            definedArtifacts: [],
            epochSegments: .empty,
            includeContinuousOverlays: false,
            includeArtifactOverlays: false,
            mapContinuousOverlaysIntoEpochs: false
        )
    }

    let key: Key
    let events: [MFFEvent]

    static let empty = WaveformDisplayedEventsCache(key: .empty, events: [])
}

struct WaveformUserMarkerSignature: Equatable {
    let idHash: Int
    let timeSeconds: Double
    let note: String
}

struct WaveformDefinedArtifactSignature: Equatable {
    let id: UUID
    let events: EventTrackEventSignature
}

struct WaveformEpochSegmentSignature: Equatable {
    let count: Int
    let firstID: EpochSegment.ID?
    let middleID: EpochSegment.ID?
    let lastID: EpochSegment.ID?

    static let empty = WaveformEpochSegmentSignature(segments: [])

    init(segments: [EpochSegment]) {
        count = segments.count
        let middleIndex = segments.isEmpty ? nil : segments.index(segments.startIndex, offsetBy: segments.count / 2)
        firstID = segments.first?.id
        middleID = middleIndex.map { segments[$0].id }
        lastID = segments.last?.id
    }
}

struct EventSummary: Identifiable {
    let code: String
    let count: Int
    var detail: String? = nil
    var searchText: String = ""
    var searchFields: [PSAEventSearchField: String] = [:]
    var id: String { code }
}

enum PSAEventSearchField: String, CaseIterable {
    case code = "Code"
    case label = "Label"
    case description = "Description"
    case cell = "Cell"
    case source = "Source"

    init?(alias: String) {
        switch alias
            .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
            .lowercased() {
        case "code", "codes":
            self = .code
        case "label", "labels":
            self = .label
        case "description", "descriptions", "desc":
            self = .description
        case "cell", "cells":
            self = .cell
        case "source", "sources", "file", "files":
            self = .source
        default:
            return nil
        }
    }
}

struct PSAEventSearchFilter {
    let field: PSAEventSearchField?
    let value: String
}

struct EpochCategorySummary: Identifiable {
    let category: String
    let count: Int
    let color: Color

    var id: String { category }
}

struct AveragedTopomapSample: Identifiable {
    let category: String
    let sample: Int
    let latencySeconds: Double
    let colorIndex: Int

    var id: String { "\(category)-\(sample)" }
}

nonisolated struct PSAExclusionSummary: Sendable, Equatable {
    var candidateEvents = 0
    var acceptedEpochs = 0
    var outputSegments = 0
    var skippedArtifacts = 0
    var skippedTimingMarkers = 0
    var skippedOutOfBounds = 0
    var timingAdjusted = 0
    var rejectedForTooManyBadChannels = 0
    var badChannelCount = 0

    var excludedEpochs: Int {
        skippedArtifacts + skippedTimingMarkers + skippedOutOfBounds + rejectedForTooManyBadChannels
    }

    var hasExclusions: Bool {
        excludedEpochs > 0
    }
}

nonisolated struct PSABuildResult {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let message: String
    /// Channel index → number of epochs that flagged it bad, when per-epoch
    /// bad-channel interpolation was enabled. Empty when the feature was off.
    var epochBadChannelCounts: [Int: Int] = [:]
    /// Epoch count the above counts are a fraction of (== accepted epochs).
    var totalEpochsEvaluated: Int = 0
    /// Epochs dropped entirely for exceeding the bad-channel-fraction limit.
    /// NOTE: these three fields describe the RAW (pre-average) build only —
    /// `average()`/`postProcessed()` below construct fresh `PSABuildResult`s
    /// that don't carry them forward. Callers that need this after averaging
    /// must capture it from the raw `buildEpochs()` result directly (see
    /// `applyPSA(to:)`), not from `finalResult`.
    var rejectedForTooManyBadChannels: Int = 0
    var exclusionSummary = PSAExclusionSummary()

    /// Averages each category's epochs. Runs off the main thread.
    func average(colorIndices: [String: Int]) -> PSABuildResult? {
        guard signal.samplingRate > 0, !segments.isEmpty,
              let firstSegment = segments.first else { return nil }
        let epochLength = firstSegment.endSample - firstSegment.startSample + 1
        guard epochLength > 0 else { return nil }

        let groupedSegments = Dictionary(grouping: segments, by: \.category)
        let orderedCategories = groupedSegments.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        var averagedData = Array(repeating: [Float](), count: signal.numberOfChannels)
        var averagedEvents: [MFFEvent] = []
        var averagedSegments: [EpochSegment] = []
        var outputStartSample = 0

        for category in orderedCategories {
            guard let segs = groupedSegments[category]?.sorted(by: { $0.startSample < $1.startSample }),
                  let representative = segs.first else { continue }
            let minChannelLength = signal.data.map(\.count).min() ?? 0
            let validSegs = segs.filter {
                $0.endSample - $0.startSample + 1 == epochLength
                    && $0.startSample >= 0
                    && $0.endSample < minChannelLength
            }
            guard !validSegs.isEmpty else { continue }

            for channelIndex in signal.data.indices {
                var accumulator = [Double](repeating: 0, count: epochLength)
                let channel = signal.data[channelIndex]
                for seg in validSegs {
                    for offset in 0..<epochLength {
                        accumulator[offset] += Double(channel[seg.startSample + offset])
                    }
                }
                let divisor = Double(validSegs.count)
                averagedData[channelIndex].append(contentsOf: accumulator.map { Float($0 / divisor) })
            }

            let stimulusSample = outputStartSample + representative.stimulusOffsetSamples
            let stimulusTime = Double(stimulusSample) / signal.samplingRate
            averagedEvents.append(MFFEvent(
                id: "psa-average-\(category)-\(outputStartSample)",
                code: category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: "PSA Average"
            ))
            averagedSegments.append(EpochSegment(
                startSample: outputStartSample,
                endSample: outputStartSample + epochLength - 1,
                stimulusOffsetSamples: representative.stimulusOffsetSamples,
                category: category,
                sourceCode: category,
                sourceTimeSeconds: representative.sourceTimeSeconds,
                colorIndex: colorIndices[category] ?? 0,
                contributingEpochCount: validSegs.reduce(0) { $0 + $1.contributingEpochCount }
            ))
            outputStartSample += epochLength
        }

        guard let totalSamples = averagedData.first?.count, totalSamples > 0 else { return nil }
        let averaged = MFFSignalData(
            signalURL: signal.signalURL,
            signalType: signal.signalType,
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: Double(totalSamples) / signal.samplingRate,
            recordingStartTime: signal.recordingStartTime,
            events: averagedEvents,
            data: averagedData,
            channelNames: signal.channelNames
        )
        let categoryCount = orderedCategories.count
        let totalEpochs = averagedSegments.reduce(0) { $0 + $1.contributingEpochCount }
        let msg = "\(categoryCount) categor\(categoryCount == 1 ? "y" : "ies"), \(totalEpochs) epochs averaged"
        return PSABuildResult(signal: averaged, segments: averagedSegments, message: msg)
    }

    /// Applies average-reference and/or baseline correction. Runs off the main thread.
    func postProcessed(averageReference: Bool, baselineCorrect: Bool, badChannels: Set<Int>) -> PSABuildResult {
        var output = self
        if averageReference { output = output.withAverageReference(excluding: badChannels) }
        if baselineCorrect { output = output.withBaselineCorrection() }
        return output
    }

    private func withAverageReference(excluding bad: Set<Int>) -> PSABuildResult {
        let referencedData = EEGSignalFilter.averageReferenced(signal.data, excluding: bad)
        let s = MFFSignalData(signalURL: signal.signalURL, signalType: signal.signalType,
                              numberOfChannels: signal.numberOfChannels, samplingRate: signal.samplingRate,
                              duration: signal.duration, recordingStartTime: signal.recordingStartTime,
                              events: signal.events, data: referencedData, channelNames: signal.channelNames)
        return PSABuildResult(signal: s, segments: segments, message: message)
    }

    private func withBaselineCorrection() -> PSABuildResult {
        var data = signal.data
        for segment in segments {
            let preCount = segment.stimulusOffsetSamples
            guard preCount > 0 else { continue }
            let preStart = segment.startSample
            let preEnd = preStart + preCount
            for channel in data.indices {
                guard preEnd <= data[channel].count, segment.endSample < data[channel].count else { continue }
                var sum = 0.0
                for sample in preStart..<preEnd { sum += Double(data[channel][sample]) }
                let baseline = Float(sum / Double(preCount))
                guard baseline.isFinite else { continue }
                for sample in segment.startSample...segment.endSample {
                    data[channel][sample] -= baseline
                }
            }
        }
        let s = MFFSignalData(signalURL: signal.signalURL, signalType: signal.signalType,
                              numberOfChannels: signal.numberOfChannels, samplingRate: signal.samplingRate,
                              duration: signal.duration, recordingStartTime: signal.recordingStartTime,
                              events: signal.events, data: data, channelNames: signal.channelNames)
        return PSABuildResult(signal: s, segments: segments, message: message)
    }
}

/// Captures all inputs needed to build PSA epochs off the main thread.
nonisolated struct PSABuildJob: Sendable {
    let signal: MFFSignalData
    let events: [MFFEvent]
    /// Segment value (code/label) → categories that value's epochs are filed
    /// under. Usually one entry (the code's own category); a code that also
    /// belongs to a pooled group carries a second entry for the group's
    /// category, producing a duplicate epoch tagged with each category.
    let categoriesBySegmentValue: [String: [String]]
    let timingMarkersBySegmentValue: [String: String]
    let timingEventsBySegmentValue: [String: [MFFEvent]]
    let artifactEventsForRejection: [MFFEvent]
    let preSamples: Int
    let epochLength: Int
    let psaOffset: Double
    let sampleCount: Int
    let colorIndices: [String: Int]
    let skipIfContainsArtifact: Bool
    let artifactRejectionLabel: String
    let timingTolerance: Double
    /// Per-epoch bad-channel detection + interpolation (distinct from the
    /// whole-recording `channels.bad` set below, which is still excluded from
    /// being used as an interpolation source either way).
    let interpolatesBadChannelsPerEpoch: Bool
    let epochBadChannelThresholds: EpochBadChannelThresholds
    let electrodePositions: [Int: SIMD3<Double>]
    let globallyBadChannels: Set<Int>

    /// One accepted (event, category) pairing, cheap to compute — everything
    /// EXCEPT the per-channel sample extraction and (optional) per-epoch
    /// bad-channel interpolation, which is the expensive, fully-independent
    /// part done in parallel below.
    private struct AcceptedEpochJob: Sendable {
        let startSample: Int
        let category: String
        let sourceEventID: String
        let sourceCode: String
        let anchorTimeSeconds: Double
        let segmentValue: String
        let timingMarkerValue: String?
    }

    /// Builds epochs. `progress` (if given) is called after each epoch's slice
    /// finishes processing — `(completed, total)` — so the caller can report a
    /// percentage/count instead of an indeterminate spinner. May be called from
    /// a background thread/task; hop to the main actor inside the closure if
    /// updating UI state directly.
    func buildEpochs(progress: (@Sendable (Int, Int) -> Void)? = nil) async -> PSABuildResult? {
        // PASS 1 (sequential, cheap): decide which (event, category) pairs are
        // accepted and their final order — identical logic/skip-counting to
        // before, just without touching channel data yet.
        var jobs: [AcceptedEpochJob] = []
        var skippedOutOfBounds = 0
        var skippedArtifacts = 0
        var skippedTimingMarkers = 0
        var timingAdjusted = 0

        for event in events {
            guard let categories = categoriesBySegmentValue[event.code] ?? categoriesBySegmentValue[event.label ?? ""],
                  !categories.isEmpty else { continue }
            let segmentValue: String = categoriesBySegmentValue[event.code] != nil ? event.code : (event.label ?? event.code)
            let anchorTimeSeconds: Double
            let timingMarkerValue = timingMarkersBySegmentValue[event.code] ?? timingMarkersBySegmentValue[event.label ?? ""]
            if let timingMarkerValue {
                let candidates = timingEventsBySegmentValue[timingMarkerValue] ?? []
                guard let timingEvent = nearestEvent(to: event, in: candidates) else {
                    skippedTimingMarkers += 1
                    continue
                }
                anchorTimeSeconds = timingEvent.beginTimeSeconds
                timingAdjusted += 1
            } else {
                anchorTimeSeconds = event.beginTimeSeconds + psaOffset
            }
            let correctedSample = Int((anchorTimeSeconds * signal.samplingRate).rounded())
            let startSample = correctedSample - preSamples
            let endSample = startSample + epochLength

            guard startSample >= 0, endSample <= sampleCount else {
                skippedOutOfBounds += 1
                continue
            }
            if skipIfContainsArtifact, !artifactEventsForRejection.isEmpty {
                let startSeconds = Double(startSample) / signal.samplingRate
                let endSeconds = Double(endSample) / signal.samplingRate
                if artifactEventsForRejection.contains(where: { $0.beginTimeSeconds >= startSeconds && $0.beginTimeSeconds <= endSeconds }) {
                    skippedArtifacts += 1
                    continue
                }
            }

            guard signal.data.indices.allSatisfy({ signal.data[$0].count >= endSample }) else { continue }

            // One event can feed multiple categories (its own + any pooled
            // group it belongs to) — one job per category, duplicating the epoch.
            for category in categories {
                jobs.append(AcceptedEpochJob(
                    startSample: startSample,
                    category: category,
                    sourceEventID: event.id,
                    sourceCode: event.code,
                    anchorTimeSeconds: anchorTimeSeconds,
                    segmentValue: segmentValue,
                    timingMarkerValue: timingMarkerValue
                ))
            }
        }

        guard !jobs.isEmpty else { return nil }

        // PASS 2 (parallel): each job independently extracts its own channel
        // slice and, if enabled, runs per-epoch bad-channel detection +
        // spherical-spline interpolation — the expensive, fully-independent
        // part (this is what got slower with interpolation on; it's also
        // exactly what parallelizes cleanly, since no job touches another
        // job's data). Indexed by the job's PASS-1 position so PASS 3 can
        // reassemble in the original, deterministic order regardless of which
        // task happens to finish first.
        var slices = [[[Float]]?](repeating: nil, count: jobs.count)
        var jobBadChannels = [Set<Int>?](repeating: nil, count: jobs.count)
        let total = jobs.count
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0
        nonisolated(unsafe) var rejectedForTooManyBadChannels = 0
        let maxBadChannelsPerEpoch = epochBadChannelThresholds.usesAbsoluteBadChannelCount
            ? epochBadChannelThresholds.maxBadChannelCount
            : Int((epochBadChannelThresholds.maxBadChannelFraction * Double(signal.numberOfChannels)).rounded())
        // Shared across all workers: identical (target, good-set) pairs recur
        // across most epochs (a bad channel tends to stay bad trial after
        // trial), so caching turns a repeated O(n³) spline solve into an O(1)
        // lookup for every epoch after the first that sees a given combination.
        let weightCache = SphericalSplineWeightCache()
        slices.withUnsafeMutableBufferPointer { out in
            jobBadChannels.withUnsafeMutableBufferPointer { badOut in
                // Each iteration writes a distinct index; bounded to
                // evaMaxWorkers so a large epoch count can't spawn one task
                // per epoch and oversubscribe the machine (this was an
                // unbounded `withTaskGroup` fan-out before — the reported
                // "computer locked up" cause).
                nonisolated(unsafe) let out = out
                nonisolated(unsafe) let badOut = badOut
                evaConcurrentPerform(iterations: jobs.count) { jobIndex in
                    let job = jobs[jobIndex]
                    let jobEndSample = job.startSample + epochLength
                    var slice = signal.data.map { Array($0[job.startSample..<jobEndSample]) }
                    if interpolatesBadChannelsPerEpoch {
                        let range = 0..<epochLength
                        let epochBadChannels = EpochBadChannelDetector.detectBadChannels(
                            in: slice,
                            range: range,
                            thresholds: epochBadChannelThresholds,
                            excluding: globallyBadChannels
                        )
                        // Recorded even for a rejected epoch — a channel bad
                        // enough to help reject the epoch is still a
                        // legitimate "bad in this trial" data point for the
                        // escalate-to-globally-bad decision below.
                        badOut[jobIndex] = epochBadChannels
                        if epochBadChannels.count > maxBadChannelsPerEpoch {
                            // Too messy to trust — reject the whole epoch
                            // instead of interpolating. Skipping the spline
                            // fit here is also the point: it's the expensive
                            // step, and it'd be thrown away regardless.
                            progressLock.lock()
                            rejectedForTooManyBadChannels += 1
                            completed += 1
                            let done = completed
                            progressLock.unlock()
                            progress?(done, total)
                            return
                        }
                        EpochBadChannelDetector.interpolate(
                            badChannels: epochBadChannels,
                            in: &slice,
                            range: range,
                            positions: electrodePositions,
                            excludingGloballyBad: globallyBadChannels,
                            weightCache: weightCache
                        )
                    }
                    out[jobIndex] = slice
                    progressLock.lock()
                    completed += 1
                    let done = completed
                    progressLock.unlock()
                    progress?(done, total)
                }
            }
        }

        // Aggregate how many epochs flagged each channel bad, for reporting
        // and for the caller's "escalate to globally bad" decision. Rejected
        // epochs (too messy) don't contribute — they were never interpolated.
        var epochBadChannelCounts: [Int: Int] = [:]
        if interpolatesBadChannelsPerEpoch {
            for badSet in jobBadChannels {
                guard let badSet else { continue }
                for channel in badSet {
                    epochBadChannelCounts[channel, default: 0] += 1
                }
            }
        }

        // PASS 3 (sequential, cheap concatenation): reassemble in job order.
        var epochedData = Array(repeating: [Float](), count: signal.numberOfChannels)
        var epochedEvents: [MFFEvent] = []
        var segments: [EpochSegment] = []

        for (jobIndex, job) in jobs.enumerated() {
            guard let slice = slices[jobIndex] else { continue }
            for channelIndex in epochedData.indices {
                epochedData[channelIndex].append(contentsOf: slice[channelIndex])
            }

            let epochStart = jobIndex * epochLength
            let stimulusSample = epochStart + preSamples
            let stimulusTime = Double(stimulusSample) / signal.samplingRate
            epochedEvents.append(MFFEvent(
                id: "psa-\(jobIndex)-\(job.sourceEventID)",
                code: job.category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: job.timingMarkerValue.map { "PSA: \(job.segmentValue) via \($0)" } ?? "PSA: \(job.segmentValue)"
            ))
            segments.append(EpochSegment(
                startSample: epochStart,
                endSample: epochStart + epochLength - 1,
                stimulusOffsetSamples: preSamples,
                category: job.category,
                sourceCode: job.sourceCode,
                sourceTimeSeconds: job.anchorTimeSeconds,
                colorIndex: colorIndices[job.category] ?? 0,
                contributingEpochCount: 1
            ))
        }

        let accepted = segments.count
        guard let totalSamples = epochedData.first?.count, totalSamples > 0 else { return nil }

        let epochedSignal = MFFSignalData(
            signalURL: signal.signalURL,
            signalType: "\(signal.signalType) Epochs",
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: Double(totalSamples) / signal.samplingRate,
            recordingStartTime: signal.recordingStartTime,
            events: epochedEvents,
            data: epochedData,
            channelNames: signal.channelNames
        )
        var message = "\(accepted) epochs"
        if skippedArtifacts > 0 { message += ", \(skippedArtifacts) skipped for \(artifactRejectionLabel)" }
        if timingAdjusted > 0 { message += ", \(timingAdjusted) timing adjusted" }
        if skippedTimingMarkers > 0 { message += ", \(skippedTimingMarkers) missing timing marker" }
        if skippedOutOfBounds > 0 { message += ", \(skippedOutOfBounds) out of bounds" }
        if interpolatesBadChannelsPerEpoch {
            message += ", \(epochBadChannelCounts.count) channel\(epochBadChannelCounts.count == 1 ? "" : "s") bad in at least one epoch"
            if rejectedForTooManyBadChannels > 0 {
                message += ", \(rejectedForTooManyBadChannels) epoch\(rejectedForTooManyBadChannels == 1 ? "" : "s") rejected for too many bad channels"
            }
        }
        return PSABuildResult(
            signal: epochedSignal,
            segments: segments,
            message: message,
            epochBadChannelCounts: epochBadChannelCounts,
            totalEpochsEvaluated: jobs.count,
            rejectedForTooManyBadChannels: rejectedForTooManyBadChannels,
            exclusionSummary: PSAExclusionSummary(
                candidateEvents: events.count,
                acceptedEpochs: accepted,
                outputSegments: segments.count,
                skippedArtifacts: skippedArtifacts,
                skippedTimingMarkers: skippedTimingMarkers,
                skippedOutOfBounds: skippedOutOfBounds,
                timingAdjusted: timingAdjusted,
                rejectedForTooManyBadChannels: rejectedForTooManyBadChannels,
                badChannelCount: epochBadChannelCounts.count
            )
        )
    }

    private func nearestEvent(to event: MFFEvent, in candidates: [MFFEvent]) -> MFFEvent? {
        let within = timingTolerance > 0
            ? candidates.filter { abs($0.beginTimeSeconds - event.beginTimeSeconds) <= timingTolerance }
            : candidates
        return within.min { lhs, rhs in
            let ld = abs(lhs.beginTimeSeconds - event.beginTimeSeconds)
            let rd = abs(rhs.beginTimeSeconds - event.beginTimeSeconds)
            return ld == rd ? lhs.beginTimeSeconds < rhs.beginTimeSeconds : ld < rd
        }
    }
}

struct MFFExportSnapshot: Sendable {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let kind: MFFExportKind
}

enum MFFSplitSelection {
    case left
    case right
    case both
}

struct MFFSplitOutput: Sendable {
    let segment: MFFSignalSplitSegment
    let url: URL
}

func normalizedMFFPackageURL(_ url: URL) -> URL {
    url.pathExtension.lowercased() == "mff" ? url : url.appendingPathExtension("mff")
}

struct WaveformRightClickMonitor: NSViewRepresentable {
    var onRightClick: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRightClick: onRightClick)
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        context.coordinator.view = view
        context.coordinator.installIfNeeded()
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        context.coordinator.onRightClick = onRightClick
        context.coordinator.view = nsView
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class MonitorView: NSView {
        override var isFlipped: Bool { true }
    }

    final class Coordinator {
        weak var view: NSView?
        var onRightClick: (CGPoint) -> Void
        private var monitor: Any?

        init(onRightClick: @escaping (CGPoint) -> Void) {
            self.onRightClick = onRightClick
        }

        deinit {
            uninstall()
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                guard let self = self,
                      let view = self.view,
                      event.window === view.window else {
                    return event
                }
                let point = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(point) {
                    self.onRightClick(point)
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

struct ICAProgressUpdate: Sendable {
    var fraction: Double
    var message: String
}

/// Progress update from `PSABuildJob.buildEpochs(progress:)` — how many of the
/// job's epochs have finished their (parallel) per-channel slice/interpolation.
struct EpochBuildProgress: Sendable {
    var completed: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}


enum ArtifactTemplateChannelScope: String, CaseIterable, Identifiable {
    case clickedChannel = "Clicked Channel"
    case ocularChannels = "Ocular Channels"
    case visibleChannels = "Visible Channels"
    case allChannels = "All Channels"
    case specificChannels = "Specific Channels"

    var id: String { rawValue }
}

enum ArtifactDetectionMethod: String, CaseIterable, Identifiable {
    case threshold = "Threshold"
    case template = "Template"
    case ica = "ICA"

    var id: String { rawValue }

    /// Methods the user can pick directly. `.template` is entered implicitly by
    /// drawing a selection and defining a template, so it is not offered here.
    static var selectableCases: [ArtifactDetectionMethod] { [.threshold, .ica] }
}

enum PSASegmentField: String, CaseIterable, Identifiable {
    case code = "Code"
    case label = "Label"
    case artifact = "Artifacts"

    var id: String { rawValue }
}



enum BCGDetectionMethod: String, CaseIterable, Identifiable {
    case periodicity    = "periodicity"
    case spatialPCA     = "spatialPCA"
    case cardiacPowerMap = "cardiacPowerMap"
    case virtualECGPCA  = "virtualECGPCA"
    case panTompkinsProxy = "panTompkinsProxy"
    case qrsLocking     = "qrsLocking"

    var id: String { rawValue }

    var tabLabel: String {
        switch self {
        case .periodicity:      return "Periodicity"
        case .spatialPCA:       return "Spatial PCA"
        case .cardiacPowerMap:  return "Power Map"
        case .virtualECGPCA:    return "Virtual ECG"
        case .panTompkinsProxy: return "Pan-Tompkins"
        case .qrsLocking:       return "QRS Lock"
        }
    }

    var summary: String {
        switch self {
        case .periodicity:
            return "Bandpass the EEG to the cardiac band, compute the Global Field Power, and find peaks. Exploits the fact that BCG repeats at a stable heart rate — no exemplar needed."
        case .spatialPCA:
            return "Derive the dominant spatial map of BCG from a highlighted exemplar window (or the first 30 s), project the full recording onto it, and detect peaks. Works even when beat morphology varies."
        case .cardiacPowerMap:
            return "Identify which channels carry the most cardiac-band energy, compute a power-weighted time series, and detect peaks. Good when BCG is focal to a subset of electrodes."
        case .virtualECGPCA:
            return "Collapse the BCG-channel group to a single \u{201C}virtual ECG\u{201D} by taking the first principal component across those channels, then run Pan-Tompkins QRS detection on it. Averages out channel-specific noise — generalizes FMRIB/OBS's best-channel step to a channel group. Select a BCG channel set below."
        case .panTompkinsProxy:
            return "Run the Pan-Tompkins QRS backbone (bandpass → derivative → squaring → moving-window integration → adaptive thresholding) directly on the BCG-channel group. The high-amplitude proxy deflection has a sharp transient the QRS detector locks onto. Select a BCG channel set below."
        case .qrsLocking:
            return "Offset each detected R-wave by a fixed mechanical delay. Requires ECG / QRS detection to be active. The lag from QRS to BCG onset is typically 200–400 ms — adjust to align peaks."
        }
    }
}
