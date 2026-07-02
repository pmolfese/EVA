//
//  WaveformPlotViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Self-contained rendering views extracted from WaveformView (REFACTOR.md L5):
//  the waveform / butterfly / overlaid-category / topography-trajectory / ICA
//  time-course / physio / event-track plots. Pure presentation — each takes its
//  data via properties and holds no WaveformView state.
//

import SwiftUI

struct EventMarkerStyle {
    let color: Color
    /// Vertical offset of this event's label (and stem top) — its source lane.
    let laneY: CGFloat
    let sourceIndex: Int
}

nonisolated enum EventTrackConstants {
    static let maxLanes = 3
    static let laneSpacing: CGFloat = 18
    static let denseMarkerThreshold = 180
}

nonisolated struct EventTrackEventSignature: Equatable {
    let count: Int
    let firstID: MFFEvent.ID?
    let middleID: MFFEvent.ID?
    let lastID: MFFEvent.ID?
    let firstTime: Double?
    let middleTime: Double?
    let lastTime: Double?
    let firstSource: String?
    let middleSource: String?
    let lastSource: String?

    static let empty = EventTrackEventSignature(events: [])

    init(events: [MFFEvent]) {
        count = events.count
        let middleIndex = events.isEmpty ? nil : events.index(events.startIndex, offsetBy: events.count / 2)
        firstID = events.first?.id
        middleID = middleIndex.map { events[$0].id }
        lastID = events.last?.id
        firstTime = events.first?.beginTimeSeconds
        middleTime = middleIndex.map { events[$0].beginTimeSeconds }
        lastTime = events.last?.beginTimeSeconds
        firstSource = events.first?.sourceFile
        middleSource = middleIndex.map { events[$0].sourceFile }
        lastSource = events.last?.sourceFile
    }
}

nonisolated struct EventTrackSourceSummary: Equatable {
    let signature: EventTrackEventSignature
    let sourceCount: Int

    static let empty = EventTrackSourceSummary(events: [])

    init(events: [MFFEvent], signature: EventTrackEventSignature = EventTrackEventSignature(events: [])) {
        let resolvedSignature = signature.count == events.count ? signature : EventTrackEventSignature(events: events)
        self.signature = resolvedSignature
        self.sourceCount = Set(events.map(\.sourceFile)).count
    }
}

nonisolated struct EventTrackMarker: Identifiable {
    var id: MFFEvent.ID { event.id }
    let event: MFFEvent
    let globalX: CGFloat
    let style: EventMarkerStyle
}

nonisolated struct EventTrackIndex {
    struct Key: Equatable {
        let events: EventTrackEventSignature
        let samplingRate: Double
        let timeScale: Double
        let sampleStride: Int
        let laneCount: Int

        static let empty = Key(
            events: .empty,
            samplingRate: 0,
            timeScale: 0,
            sampleStride: 1,
            laneCount: 1
        )
    }

    static let empty = EventTrackIndex(key: .empty, markers: [])

    let key: Key
    let markers: [EventTrackMarker]

    init(
        events: [MFFEvent],
        samplingRate: Double,
        timeScale: Double,
        sampleStride: Int,
        laneCount: Int,
        signature: EventTrackEventSignature = EventTrackEventSignature(events: [])
    ) {
        let resolvedSignature = signature.count == events.count ? signature : EventTrackEventSignature(events: events)
        let key = Key(
            events: resolvedSignature,
            samplingRate: samplingRate,
            timeScale: timeScale,
            sampleStride: max(sampleStride, 1),
            laneCount: max(laneCount, 1)
        )

        guard samplingRate > 0, timeScale > 0 else {
            self.init(key: key, markers: [])
            return
        }

        let sources = Array(Set(events.map(\.sourceFile))).sorted()
        let sourceIndices = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
        let palette: [Color] = [.orange, .blue, .green, .red, .pink, .teal, .indigo, .brown]
        let markers = events.map { event in
            let sourceIndex = sourceIndices[event.sourceFile] ?? 0
            let plottedIndex = event.beginTimeSeconds * samplingRate / Double(key.sampleStride)
            let lane = sourceIndex % key.laneCount
            let style = EventMarkerStyle(
                color: palette[sourceIndex % palette.count],
                laneY: 4 + CGFloat(lane) * EventTrackConstants.laneSpacing,
                sourceIndex: sourceIndex
            )
            return EventTrackMarker(
                event: event,
                globalX: CGFloat(plottedIndex) * CGFloat(timeScale),
                style: style
            )
        }
        .sorted {
            if $0.globalX == $1.globalX {
                return $0.event.id < $1.event.id
            }
            return $0.globalX < $1.globalX
        }

        self.init(key: key, markers: markers)
    }

    private init(key: Key, markers: [EventTrackMarker]) {
        self.key = key
        self.markers = markers
    }

    func visibleMarkers(in visibleRange: ClosedRange<CGFloat>) -> [EventTrackMarker] {
        guard !markers.isEmpty else { return [] }
        let lower = lowerBound(for: visibleRange.lowerBound)
        let upper = upperBound(for: visibleRange.upperBound)
        guard lower < upper else { return [] }
        return Array(markers[lower..<upper])
    }

    private func lowerBound(for x: CGFloat) -> Int {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if markers[mid].globalX < x {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func upperBound(for x: CGFloat) -> Int {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if markers[mid].globalX <= x {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

private struct DenseMarkerPixel: Hashable {
    let sourceIndex: Int
    let x: Int
}

struct WaveformPlot: View {
    let samples: [Float]
    let amplitudeScale: Double
    let timeScale: Double
    let sampleStride: Int
    let visibleRange: ClosedRange<CGFloat>
    let nominalHeight: CGFloat
    var color: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard samples.count > sampleStride else { return }

            let xScale = CGFloat(timeScale)
            let lowerVisibleIndex = max(Int(floor(visibleRange.lowerBound / max(xScale, 0.001))) - 2, 0)
            let upperVisibleIndex = Int(ceil(visibleRange.upperBound / max(xScale, 0.001))) + 2

            let firstSampleIndex = min(lowerVisibleIndex * sampleStride, samples.count - 1)
            let lastSampleIndex = min(max(upperVisibleIndex * sampleStride, firstSampleIndex + sampleStride), samples.count - 1)
            guard lastSampleIndex > firstSampleIndex else { return }

            let midY = size.height / 2
            let pointsPerMicrovolt = (nominalHeight / 2) / max(amplitudeScale, 1)

            var path = Path()
            let firstPlottedIndex = firstSampleIndex / sampleStride
            path.move(
                to: CGPoint(
                    x: CGFloat(firstPlottedIndex) * xScale,
                    y: midY - CGFloat(samples[firstSampleIndex]) * pointsPerMicrovolt
                )
            )

            for sampleIndex in stride(from: firstSampleIndex + sampleStride, through: lastSampleIndex, by: sampleStride) {
                let plottedIndex = sampleIndex / sampleStride
                path.addLine(
                    to: CGPoint(
                        x: CGFloat(plottedIndex) * xScale,
                        y: midY - CGFloat(samples[sampleIndex]) * pointsPerMicrovolt
                    )
                )
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: visibleRange.lowerBound, y: midY))
            baseline.addLine(to: CGPoint(x: visibleRange.upperBound, y: midY))

            context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 0.75)
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

/// One channel with every category average overlaid (each in its category color),
/// aligned on the epoch latency axis.
struct OverlaidCategoryChannelPlot: View {
    let data: [[Float]]
    let channelIndex: Int
    let segments: [EpochSegment]
    let colors: [Color]
    let amplitudeScale: Double
    var highlightRelativeSample: Int? = nil

    var body: some View {
        Canvas { context, size in
            guard channelIndex < data.count, let first = segments.first else { return }
            let channel = data[channelIndex]

            let epochLength = max(first.endSample - first.startSample + 1, 1)
            guard epochLength > 1 else { return }

            let midY = size.height / 2
            let pointsPerMicrovolt = (size.height * 0.42) / max(amplitudeScale, 1)
            let xScale = size.width / CGFloat(max(epochLength - 1, 1))
            let sampleStep = max(epochLength / max(Int(size.width), 1), 1)

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.28)), lineWidth: 0.75)

            let stimulusX = CGFloat(first.stimulusOffsetSamples) * xScale
            var stimulus = Path()
            stimulus.move(to: CGPoint(x: stimulusX, y: 0))
            stimulus.addLine(to: CGPoint(x: stimulusX, y: size.height))
            context.stroke(stimulus, with: .color(.green.opacity(0.7)), lineWidth: 1)

            if let highlightRelativeSample {
                let clamped = min(max(highlightRelativeSample, 0), epochLength - 1)
                let cursorX = CGFloat(clamped) * xScale
                var cursor = Path()
                cursor.move(to: CGPoint(x: cursorX, y: 0))
                cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
                context.stroke(cursor, with: .color(.yellow), lineWidth: 1.5)
            }

            for (index, segment) in segments.enumerated() {
                guard segment.startSample >= 0, segment.endSample < channel.count else { continue }
                let color = index < colors.count ? colors[index] : .accentColor

                var path = Path()
                path.move(
                    to: CGPoint(
                        x: 0,
                        y: midY - CGFloat(channel[segment.startSample]) * pointsPerMicrovolt
                    )
                )
                for localSample in stride(from: sampleStep, through: epochLength - 1, by: sampleStep) {
                    let sample = segment.startSample + localSample
                    guard sample < channel.count else { break }
                    path.addLine(
                        to: CGPoint(
                            x: CGFloat(localSample) * xScale,
                            y: midY - CGFloat(channel[sample]) * pointsPerMicrovolt
                        )
                    )
                }
                context.stroke(path, with: .color(color), lineWidth: 1.1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

/// Compact wrapping legend of colored category labels.
struct FlowLegend: View {
    let items: [(String, Color)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            legendRow
            ScrollView(.horizontal, showsIndicators: false) { legendRow }
        }
    }

    private var legendRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.1)
                        .frame(width: 9, height: 9)
                    Text(item.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct ButterflyConditionPlot: View {
    let data: [[Float]]
    let segment: EpochSegment
    let hiddenChannels: Set<Int>
    let amplitudeScale: Double
    let color: Color
    var highlightRelativeSample: Int? = nil
    /// Per-sample grand-average noise amplitude (µV) shaded as a ± band.
    var noiseCurve: [Float]? = nil

    var body: some View {
        Canvas { context, size in
            guard segment.startSample >= 0,
                  segment.endSample >= segment.startSample,
                  !data.isEmpty else { return }

            let epochLength = segment.endSample - segment.startSample + 1
            guard epochLength > 1 else { return }

            let midY = size.height / 2
            let pointsPerMicrovolt = (size.height * 0.42) / max(amplitudeScale, 1)
            let xScale = size.width / CGFloat(max(epochLength - 1, 1))
            let sampleStep = max(epochLength / max(Int(size.width), 1), 1)

            // Shaded ± noise band (drawn first, under the traces).
            if let noiseCurve, noiseCurve.count >= epochLength {
                var upper = Path()
                var lower = [CGPoint]()
                for localSample in stride(from: 0, through: epochLength - 1, by: sampleStep) {
                    let x = CGFloat(localSample) * xScale
                    let n = CGFloat(noiseCurve[localSample]) * pointsPerMicrovolt
                    let top = CGPoint(x: x, y: midY - n)
                    if localSample == 0 { upper.move(to: top) } else { upper.addLine(to: top) }
                    lower.append(CGPoint(x: x, y: midY + n))
                }
                for point in lower.reversed() { upper.addLine(to: point) }
                upper.closeSubpath()
                context.fill(upper, with: .color(color.opacity(0.12)))
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.28)), lineWidth: 0.75)

            let stimulusX = CGFloat(segment.stimulusOffsetSamples) * xScale
            var stimulus = Path()
            stimulus.move(to: CGPoint(x: stimulusX, y: 0))
            stimulus.addLine(to: CGPoint(x: stimulusX, y: size.height))
            context.stroke(stimulus, with: .color(.green.opacity(0.75)), lineWidth: 1)

            // Shared topography cursor.
            if let highlightRelativeSample {
                let clamped = min(max(highlightRelativeSample, 0), epochLength - 1)
                let cursorX = CGFloat(clamped) * xScale
                var cursor = Path()
                cursor.move(to: CGPoint(x: cursorX, y: 0))
                cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
                context.stroke(cursor, with: .color(.yellow), lineWidth: 1.5)
            }

            for channelIndex in data.indices where !hiddenChannels.contains(channelIndex) {
                let channel = data[channelIndex]
                guard segment.endSample < channel.count else { continue }

                var path = Path()
                path.move(
                    to: CGPoint(
                        x: 0,
                        y: midY - CGFloat(channel[segment.startSample]) * pointsPerMicrovolt
                    )
                )

                for localSample in stride(from: sampleStep, through: epochLength - 1, by: sampleStep) {
                    let sample = segment.startSample + localSample
                    path.addLine(
                        to: CGPoint(
                            x: CGFloat(localSample) * xScale,
                            y: midY - CGFloat(channel[sample]) * pointsPerMicrovolt
                        )
                    )
                }

                context.stroke(path, with: .color(color.opacity(0.22)), lineWidth: 0.7)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

struct ArtifactTemplateAveragePlot: View {
    let average: ArtifactTemplateAverage
    let primaryChannel: Int?
    let highlightedChannels: Set<Int>
    var fixedScaleMicrovolts: Float? = nil
    var maximumBackgroundChannels: Int = .max
    var usesAmplitudeWeightedOpacity = false

    var body: some View {
        Canvas { context, size in
            guard let sampleCount = average.allChannelSamples.first?.count, sampleCount > 1 else { return }

            let midY = size.height / 2
            let maxAbs = max(fixedScaleMicrovolts ?? average.allChannelSamples.flatMap { $0.map(abs) }.max() ?? 1, 1)
            let yScale = (size.height * 0.42) / CGFloat(maxAbs)
            let xScale = size.width / CGFloat(sampleCount - 1)
            let peakByChannel = Dictionary(uniqueKeysWithValues: average.channelSummaries.map {
                ($0.channelIndex, $0.peakAbsoluteMicrovolts)
            })
            let strongestBackgroundChannels = Set(
                average.channelSummaries
                    .map(\.channelIndex)
                    .filter { primaryChannel != $0 && !highlightedChannels.contains($0) }
                    .prefix(maximumBackgroundChannels)
            )

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.28)), lineWidth: 0.75)

            for channelIndex in average.allChannelSamples.indices {
                let samples = average.allChannelSamples[channelIndex]
                guard samples.count == sampleCount else { continue }

                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * yScale))
                let sampleStep = max(sampleCount / max(Int(size.width), 1), 1)
                for sample in stride(from: sampleStep, through: sampleCount - 1, by: sampleStep) {
                    path.addLine(
                        to: CGPoint(
                            x: CGFloat(sample) * xScale,
                            y: midY - CGFloat(samples[sample]) * yScale
                        )
                    )
                }

                let isPrimary = primaryChannel == channelIndex
                let isHighlighted = highlightedChannels.contains(channelIndex)
                if !isPrimary,
                   !isHighlighted,
                   maximumBackgroundChannels != .max,
                   !strongestBackgroundChannels.contains(channelIndex) {
                    continue
                }

                let strokeColor: Color
                let lineWidth: CGFloat
                if isPrimary {
                    strokeColor = .blue
                    lineWidth = 1.75
                } else if isHighlighted {
                    strokeColor = .accentColor
                    lineWidth = 1.35
                } else {
                    let opacity: Double
                    if usesAmplitudeWeightedOpacity {
                        let relativePeak = Double(max(peakByChannel[channelIndex] ?? 0, 0) / maxAbs)
                        opacity = min(max(0.06 + relativePeak * 0.18, 0.06), 0.24)
                    } else {
                        opacity = 0.22
                    }
                    strokeColor = .secondary.opacity(opacity)
                    lineWidth = 0.65
                }
                context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

struct ICATimeCoursePreview: View {
    let samples: [Double]
    let visibleRange: ClosedRange<Int>?
    @State private var isExpanded = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        ICATimeCoursePlot(samples: samples, visibleRange: visibleRange)
            .frame(height: 64)
            .contentShape(Rectangle())
            .onHover { isHovering in
                hoverTask?.cancel()
                if isHovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            isExpanded = true
                        }
                    }
                } else {
                    isExpanded = false
                }
            }
            .onDisappear {
                hoverTask?.cancel()
            }
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Component Time Course")
                        .font(.headline)
                    ICATimeCoursePlot(samples: samples, visibleRange: visibleRange)
                        .frame(width: 720, height: 260)
                }
                .padding(14)
            }
            .help("Hover for 2 seconds to expand the component time course.")
    }
}

struct ICATimeCoursePlot: View {
    let samples: [Double]
    let visibleRange: ClosedRange<Int>?

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1,
                  let range = clippedRange(visibleRange, count: samples.count),
                  range.upperBound > range.lowerBound else { return }

            let midY = size.height / 2
            let scale = robustScale(samples, in: range)
            let yScale = (size.height * 0.42) / CGFloat(scale.amplitude)
            let binCount = max(Int(size.width.rounded(.down)), 2)
            let visibleCount = range.upperBound - range.lowerBound + 1

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.75)

            var trace = Path()
            var didStartTrace = false

            for bin in 0..<binCount {
                let start = range.lowerBound + bin * visibleCount / binCount
                let end = max(start + 1, range.lowerBound + (bin + 1) * visibleCount / binCount)
                let boundedEnd = min(end, samples.count)
                var sum = 0.0
                var count = 0

                for index in start..<boundedEnd {
                    let value = samples[index]
                    guard value.isFinite else { continue }
                    sum += clamp(value - scale.center, to: -scale.amplitude...scale.amplitude)
                    count += 1
                }

                guard count > 0 else { continue }

                let x = CGFloat(bin) / CGFloat(max(binCount - 1, 1)) * size.width
                let meanY = midY - CGFloat(sum / Double(count)) * yScale
                if didStartTrace {
                    trace.addLine(to: CGPoint(x: x, y: meanY))
                } else {
                    trace.move(to: CGPoint(x: x, y: meanY))
                    didStartTrace = true
                }
            }

            context.stroke(trace, with: .color(.accentColor), lineWidth: 1.2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private func clippedRange(_ range: ClosedRange<Int>?, count: Int) -> ClosedRange<Int>? {
        guard count > 1 else { return nil }
        let fallback = 0...(count - 1)
        guard let range else { return fallback }
        let lower = min(max(range.lowerBound, 0), count - 1)
        let upper = min(max(range.upperBound, lower), count - 1)
        return lower...upper
    }

    private func robustScale(_ values: [Double], in range: ClosedRange<Int>) -> (center: Double, amplitude: Double) {
        guard !values.isEmpty, range.upperBound >= range.lowerBound else {
            return (0, 1)
        }

        let visibleCount = range.upperBound - range.lowerBound + 1
        let edgeTrim = min(visibleCount / 100, 100)
        let lowerBound = min(range.lowerBound + edgeTrim, values.count - 1)
        let upperBound = min(max(range.upperBound - edgeTrim + 1, lowerBound + 1), values.count)
        let scaleStride = max((upperBound - lowerBound) / 5_000, 1)
        var scaledValues: [Double] = []
        scaledValues.reserveCapacity((upperBound - lowerBound) / scaleStride + 1)

        for index in stride(from: lowerBound, to: upperBound, by: scaleStride) {
            let value = values[index]
            if value.isFinite {
                scaledValues.append(value)
            }
        }

        guard scaledValues.count > 1 else {
            let fallback = values.first(where: { $0.isFinite }) ?? 0
            return (fallback, 1)
        }

        scaledValues.sort()
        let low = SignalStatistics.percentile(scaledValues, fraction: 0.02)
        let high = SignalStatistics.percentile(scaledValues, fraction: 0.98)
        let center = SignalStatistics.percentile(scaledValues, fraction: 0.50)
        let amplitude = max(abs(high - center), abs(low - center), 1e-9)
        return (center, amplitude)
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Pinned physio (PNS) trace pane, sharing the EEG time axis. Mirrors
/// `EventTrackView`: it is offset-driven (not its own scroll view) so it stays
/// fixed while the EEG channels scroll vertically and aligns horizontally with
/// the waveform cursor.
struct PhysioTrackView: View {
    let signal: MFFSignalData
    let ranges: [ClosedRange<Float>]
    let scaleFactors: [Int: Double]
    let maxScaledChannels: Set<Int>
    let flippedPolarity: Set<Int>
    let rowHeight: CGFloat
    let eegSamplingRate: Double
    let sampleStride: Int
    let timeScale: Double
    let contentOffset: CGFloat
    let viewportWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            guard signal.samplingRate > 0, eegSamplingRate > 0, sampleStride > 0,
                  size.width > 0 else { return }
            let pxPerSecond = eegSamplingRate / Double(sampleStride) * timeScale
            guard pxPerSecond > 0 else { return }

            let pnsSR = signal.samplingRate
            let tStart = max(0, Double(contentOffset) / pxPerSecond)
            let tEnd = Double(contentOffset + size.width) / pxPerSecond

            for (c, channel) in signal.data.enumerated() {
                let rowTop = CGFloat(c) * rowHeight
                let midY = rowTop + rowHeight / 2
                let usable = rowHeight - 8

                // Row baseline.
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: rowTop + rowHeight - 2))
                baseline.addLine(to: CGPoint(x: size.width, y: rowTop + rowHeight - 2))
                context.stroke(baseline, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

                guard !channel.isEmpty else { continue }
                let startSample = max(0, Int(tStart * pnsSR))
                let endSample = min(channel.count - 1, Int(tEnd * pnsSR) + 1)
                guard endSample > startSample else { continue }

                let maxScaled = maxScaledChannels.contains(c)
                let fallbackRange = c < ranges.count
                    ? ranges[c]
                    : (channel.min() ?? -1)...(channel.max() ?? 1)
                let range: ClosedRange<Float>
                if maxScaled {
                    let scanStep = max(1, (endSample - startSample) / 5_000)
                    var lo = Float.greatestFiniteMagnitude
                    var hi = -Float.greatestFiniteMagnitude
                    var k = startSample
                    while k <= endSample {
                        let value = channel[k]
                        if value.isFinite {
                            lo = min(lo, value)
                            hi = max(hi, value)
                        }
                        k += scanStep
                    }
                    range = lo < hi ? lo...hi : fallbackRange
                } else {
                    range = fallbackRange
                }

                let span = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
                let center = (range.lowerBound + range.upperBound) / 2
                let scaleFactor = maxScaled
                    ? CGFloat(1)
                    : CGFloat(min(max(scaleFactors[c] ?? 1, 1), 64))
                let polarity: CGFloat = flippedPolarity.contains(c) ? -1 : 1
                let yScale = usable / CGFloat(span) * scaleFactor
                let minY = rowTop + 4
                let maxY = rowTop + rowHeight - 4
                // Decimate to ~1 point per pixel.
                let step = max(1, (endSample - startSample) / max(1, Int(size.width)))

                var path = Path()
                var started = false
                var j = startSample
                while j <= endSample {
                    let x = CGFloat(Double(j) / pnsSR * pxPerSecond) - contentOffset
                    let centered = CGFloat(channel[j] - center) * polarity
                    let rawY = midY - centered * yScale
                    let y = min(max(rawY, minY), maxY)
                    if started {
                        path.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        path.move(to: CGPoint(x: x, y: y))
                        started = true
                    }
                    j += step
                }
                context.stroke(path, with: .color(.pink), lineWidth: 1)
            }
        }
        .frame(height: CGFloat(signal.numberOfChannels) * rowHeight)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}

struct EventTrackView: View {
    /// Maximum number of vertical lanes events are staggered across, and the
    /// extra height each lane beyond the first adds to the track.
    static let maxLanes = EventTrackConstants.maxLanes
    static let laneSpacing = EventTrackConstants.laneSpacing
    static let denseMarkerThreshold = EventTrackConstants.denseMarkerThreshold

    let events: [MFFEvent]
    let samplingRate: Double
    let timeScale: Double
    let sampleStride: Int
    /// True horizontal scroll offset of the waveform content, used so event
    /// markers line up with the waveform cursor.
    let contentOffset: CGFloat
    let visibleRange: ClosedRange<CGFloat>
    let viewportWidth: CGFloat
    /// Number of distinct source lanes events are staggered into.
    var laneCount: Int = 1

    /// Event whose detail popover is currently shown (tap a flag to open).
    @State private var poppedEvent: MFFEvent?
    @State private var eventIndex = EventTrackIndex.empty

    var body: some View {
        let signature = EventTrackEventSignature(events: events)
        let key = EventTrackIndex.Key(
            events: signature,
            samplingRate: samplingRate,
            timeScale: timeScale,
            sampleStride: max(sampleStride, 1),
            laneCount: max(laneCount, 1)
        )
        let index = eventIndex.key == key
            ? eventIndex
            : EventTrackIndex(
                events: events,
                samplingRate: samplingRate,
                timeScale: timeScale,
                sampleStride: sampleStride,
                laneCount: laneCount,
                signature: signature
            )
        let visibleMarkers = index.visibleMarkers(in: visibleRange)
        let drawsFlags = Self.drawsEventFlags(visibleMarkerCount: visibleMarkers.count)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))

            Canvas { context, size in
                guard samplingRate > 0 else { return }
                let baselineY = size.height - 16
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: baselineY))
                baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
                context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 1)

                if drawsFlags {
                    drawIndividualMarkers(visibleMarkers, in: &context, baselineY: baselineY)
                } else {
                    drawDenseMarkers(visibleMarkers, in: &context, baselineY: baselineY)
                }
            }

            if drawsFlags {
                ForEach(visibleMarkers) { marker in
                    eventFlag(marker)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .onAppear {
            updateEventIndexIfNeeded(key: key, signature: signature)
        }
        .onChange(of: key) { _, newKey in
            updateEventIndexIfNeeded(key: newKey, signature: signature)
        }
    }

    nonisolated static func drawsEventFlags(visibleMarkerCount: Int) -> Bool {
        visibleMarkerCount <= EventTrackConstants.denseMarkerThreshold
    }

    private func updateEventIndexIfNeeded(key: EventTrackIndex.Key, signature: EventTrackEventSignature) {
        guard eventIndex.key != key else { return }
        eventIndex = EventTrackIndex(
            events: events,
            samplingRate: samplingRate,
            timeScale: timeScale,
            sampleStride: sampleStride,
            laneCount: laneCount,
            signature: signature
        )
    }

    private func localXPosition(for marker: EventTrackMarker) -> CGFloat {
        // Position relative to the true scroll offset (not the buffered
        // culling range) so markers align with the waveform cursor.
        marker.globalX - contentOffset
    }

    private func drawIndividualMarkers(
        _ markers: [EventTrackMarker],
        in context: inout GraphicsContext,
        baselineY: CGFloat
    ) {
        for marker in markers {
            let x = localXPosition(for: marker)
            var path = Path()
            // Stem starts at this source's lane (just below its label).
            path.move(to: CGPoint(x: x, y: marker.style.laneY + 4))
            path.addLine(to: CGPoint(x: x, y: baselineY))
            context.stroke(path, with: .color(marker.style.color), lineWidth: 1)
        }
    }

    private func drawDenseMarkers(
        _ markers: [EventTrackMarker],
        in context: inout GraphicsContext,
        baselineY: CGFloat
    ) {
        var pathsBySource: [Int: Path] = [:]
        var stylesBySource: [Int: EventMarkerStyle] = [:]
        var drawnPixels = Set<DenseMarkerPixel>()

        for marker in markers {
            let x = localXPosition(for: marker)
            guard x >= 0, x <= viewportWidth else { continue }
            let roundedX = Int(x.rounded())
            let pixel = DenseMarkerPixel(sourceIndex: marker.style.sourceIndex, x: roundedX)
            guard drawnPixels.insert(pixel).inserted else { continue }

            stylesBySource[marker.style.sourceIndex] = marker.style
            var path = pathsBySource[marker.style.sourceIndex] ?? Path()
            let drawX = CGFloat(roundedX)
            path.move(to: CGPoint(x: drawX, y: marker.style.laneY + 6))
            path.addLine(to: CGPoint(x: drawX, y: baselineY))
            pathsBySource[marker.style.sourceIndex] = path
        }

        for sourceIndex in pathsBySource.keys.sorted() {
            guard let path = pathsBySource[sourceIndex],
                  let style = stylesBySource[sourceIndex] else { continue }
            context.stroke(path, with: .color(style.color.opacity(0.75)), lineWidth: 1)
        }
    }

    /// A single tappable event flag (code capsule) positioned in its lane.
    @ViewBuilder
    private func eventFlag(_ marker: EventTrackMarker) -> some View {
        let event = marker.event
        let x = localXPosition(for: marker)
        let style = marker.style
        let isPopped = Binding(
            get: { poppedEvent == event },
            set: { if !$0 { poppedEvent = nil } }
        )
        Text(event.code)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.15), in: Capsule())
            .foregroundStyle(style.color)
            .help(tooltip(for: event))
            .contentShape(Capsule())
            .onTapGesture { poppedEvent = event }
            .popover(isPresented: isPopped) {
                eventDetailPopover(event, color: style.color)
            }
            .offset(x: min(max(x + 4, 0), max(viewportWidth - 70, 0)), y: style.laneY)
    }

    /// Tap-to-open detail popover listing every populated field of the event.
    @ViewBuilder
    private func eventDetailPopover(_ event: MFFEvent, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.code)
                .font(.headline)
                .foregroundStyle(color)
            Divider()
            eventDetailRow("Label", event.label)
            eventDetailRow("Description", event.eventDescription)
            eventDetailRow("Cell", event.cell)
            eventDetailRow("Onset", String(format: "%.3f s", event.beginTimeSeconds))
            if let duration = event.durationSeconds {
                eventDetailRow("Duration", duration >= 1
                    ? String(format: "%.3f s", duration)
                    : String(format: "%.0f ms", duration * 1000))
            }
            eventDetailRow("Source", event.sourceFile)
        }
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
    }

    @ViewBuilder
    private func eventDetailRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Multi-line hover tooltip listing every populated field of the event.
    private func tooltip(for event: MFFEvent) -> String {
        var lines: [String] = ["Code: \(event.code)"]
        if let label = event.label { lines.append("Label: \(label)") }
        if let description = event.eventDescription { lines.append("Description: \(description)") }
        if let cell = event.cell { lines.append("Cell: \(cell)") }
        lines.append(String(format: "Onset: %.3f s", event.beginTimeSeconds))
        if let duration = event.durationSeconds {
            lines.append(duration >= 1
                ? String(format: "Duration: %.3f s", duration)
                : String(format: "Duration: %.0f ms", duration * 1000))
        }
        lines.append("Source: \(event.sourceFile)")
        return lines.joined(separator: "\n")
    }
}
