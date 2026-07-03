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

nonisolated struct PSABuildResult {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let message: String

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
    let categoriesBySegmentValue: [String: String]
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

    func buildEpochs() -> PSABuildResult? {
        var epochedData = Array(repeating: [Float](), count: signal.numberOfChannels)
        var epochedEvents: [MFFEvent] = []
        var segments: [EpochSegment] = []
        var skippedOutOfBounds = 0
        var skippedArtifacts = 0
        var skippedTimingMarkers = 0
        var timingAdjusted = 0
        var accepted = 0

        for event in events {
            guard let category = categoriesBySegmentValue[event.code] ?? categoriesBySegmentValue[event.label ?? ""] else { continue }
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
            for channelIndex in signal.data.indices {
                epochedData[channelIndex].append(contentsOf: signal.data[channelIndex][startSample..<endSample])
            }

            let epochStart = accepted * epochLength
            let stimulusSample = epochStart + preSamples
            let stimulusTime = Double(stimulusSample) / signal.samplingRate
            epochedEvents.append(MFFEvent(
                id: "psa-\(accepted)-\(event.id)",
                code: category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: timingMarkerValue.map { "PSA: \(segmentValue) via \($0)" } ?? "PSA: \(segmentValue)"
            ))
            segments.append(EpochSegment(
                startSample: epochStart,
                endSample: epochStart + epochLength - 1,
                stimulusOffsetSamples: preSamples,
                category: category,
                sourceCode: event.code,
                sourceTimeSeconds: anchorTimeSeconds,
                colorIndex: colorIndices[category] ?? 0,
                contributingEpochCount: 1
            ))
            accepted += 1
        }

        guard accepted > 0, let totalSamples = epochedData.first?.count, totalSamples > 0 else { return nil }

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
        return PSABuildResult(signal: epochedSignal, segments: segments, message: message)
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
