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

private enum WaveformTimeMarkers {
    static func drawLocal(
        in context: inout GraphicsContext,
        size: CGSize,
        pxPerSecond: Double,
        contentOffset: CGFloat = 0,
        style: WaveformTimeMarkerStyle
    ) {
        guard pxPerSecond.isFinite, pxPerSecond > 0, size.width > 0, size.height > 0 else { return }

        let firstSecond = max(0, Int(ceil(Double(contentOffset) / pxPerSecond)))
        let lastSecond = Int(floor(Double(contentOffset + size.width) / pxPerSecond))
        guard lastSecond >= firstSecond else { return }

        var path = Path()
        for second in firstSecond...lastSecond {
            let x = CGFloat(Double(second) * pxPerSecond) - contentOffset
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(path, with: .color(color(for: style)), style: stroke(for: style))
    }

    static func drawContent(
        in context: inout GraphicsContext,
        visibleRange: ClosedRange<CGFloat>,
        height: CGFloat,
        pxPerSecond: Double,
        style: WaveformTimeMarkerStyle
    ) {
        guard pxPerSecond.isFinite, pxPerSecond > 0, height > 0 else { return }

        let firstSecond = max(0, Int(ceil(Double(visibleRange.lowerBound) / pxPerSecond)))
        let lastSecond = Int(floor(Double(visibleRange.upperBound) / pxPerSecond))
        guard lastSecond >= firstSecond else { return }

        var path = Path()
        for second in firstSecond...lastSecond {
            let x = CGFloat(Double(second) * pxPerSecond)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: height))
        }
        context.stroke(path, with: .color(color(for: style)), style: stroke(for: style))
    }

    private static func color(for style: WaveformTimeMarkerStyle) -> Color {
        let normalized = style.normalized()
        return Color(
            red: normalized.red,
            green: normalized.green,
            blue: normalized.blue,
            opacity: normalized.alpha
        )
    }

    private static func stroke(for style: WaveformTimeMarkerStyle) -> StrokeStyle {
        let normalized = style.normalized()
        return StrokeStyle(
            lineWidth: CGFloat(normalized.lineWidth),
            dash: normalized.isSolid ? [] : [CGFloat(normalized.dashOn), CGFloat(normalized.dashOff)]
        )
    }
}

nonisolated struct EventTrackEventSignature: Equatable {
    let count: Int
    let firstID: MFFEvent.ID?
    let middleID: MFFEvent.ID?
    let lastID: MFFEvent.ID?
    let firstCode: String?
    let middleCode: String?
    let lastCode: String?
    let firstLabel: String?
    let middleLabel: String?
    let lastLabel: String?
    let firstTime: Double?
    let middleTime: Double?
    let lastTime: Double?
    let firstDuration: Double?
    let middleDuration: Double?
    let lastDuration: Double?
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
        firstCode = events.first?.code
        middleCode = middleIndex.map { events[$0].code }
        lastCode = events.last?.code
        firstLabel = events.first?.label
        middleLabel = middleIndex.flatMap { events[$0].label }
        lastLabel = events.last?.label
        firstTime = events.first?.beginTimeSeconds
        middleTime = middleIndex.map { events[$0].beginTimeSeconds }
        lastTime = events.last?.beginTimeSeconds
        firstDuration = events.first?.durationSeconds
        middleDuration = middleIndex.flatMap { events[$0].durationSeconds }
        lastDuration = events.last?.durationSeconds
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

nonisolated struct EventTrackOverlapCluster: Identifiable {
    let id: String
    let globalX: CGFloat
    let laneY: CGFloat
    let count: Int
    let color: Color
}

private struct EventTrackHoverStack: Identifiable {
    var id: String { markers.map(\.event.id).joined(separator: "|") }
    let location: CGPoint
    let markers: [EventTrackMarker]
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
    let samplingRate: Double
    let amplitudeScale: Double
    let timeScale: Double
    let sampleStride: Int
    let visibleRange: ClosedRange<CGFloat>
    let nominalHeight: CGFloat
    var color: Color = .accentColor
    var usesPixelAdaptiveRendering = true
    var showsTimeMarkers = false
    var timeMarkerStyle = WaveformTimeMarkerStyle.defaultValue

    var body: some View {
        Canvas { context, size in
            let safeSampleStride = max(sampleStride, 1)
            guard samples.count > safeSampleStride else { return }

            let xScale = CGFloat(timeScale)
            let midY = size.height / 2
            let pointsPerMicrovolt = (nominalHeight / 2) / max(amplitudeScale, 1)

            strokeBaseline(in: &context, midY: midY)
            if showsTimeMarkers {
                WaveformTimeMarkers.drawContent(
                    in: &context,
                    visibleRange: visibleRange,
                    height: size.height,
                    pxPerSecond: samplingRate / Double(safeSampleStride) * timeScale,
                    style: timeMarkerStyle
                )
            }

            if usesPixelAdaptiveRendering, xScale < 1 {
                drawPixelAdaptiveTrace(
                    in: &context,
                    size: size,
                    xScale: xScale,
                    sampleStride: safeSampleStride,
                    midY: midY,
                    pointsPerMicrovolt: pointsPerMicrovolt
                )
            } else {
                drawSamplePath(
                    in: &context,
                    xScale: xScale,
                    sampleStride: safeSampleStride,
                    midY: midY,
                    pointsPerMicrovolt: pointsPerMicrovolt
                )
            }
        }
    }

    private func drawSamplePath(
        in context: inout GraphicsContext,
        xScale: CGFloat,
        sampleStride: Int,
        midY: CGFloat,
        pointsPerMicrovolt: CGFloat
    ) {
        let safeXScale = max(xScale, 0.001)
        let lowerVisibleIndex = max(Int(floor(visibleRange.lowerBound / safeXScale)) - 2, 0)
        let upperVisibleIndex = Int(ceil(visibleRange.upperBound / safeXScale)) + 2

        let firstSampleIndex = min(lowerVisibleIndex * sampleStride, samples.count - 1)
        let lastSampleIndex = min(max(upperVisibleIndex * sampleStride, firstSampleIndex + sampleStride), samples.count - 1)
        guard lastSampleIndex > firstSampleIndex else { return }

        var path = Path()
        let firstPlottedIndex = firstSampleIndex / sampleStride
        path.move(
            to: CGPoint(
                x: CGFloat(firstPlottedIndex) * xScale,
                y: yPosition(for: samples[firstSampleIndex], midY: midY, pointsPerMicrovolt: pointsPerMicrovolt)
            )
        )

        for sampleIndex in stride(from: firstSampleIndex + sampleStride, through: lastSampleIndex, by: sampleStride) {
            let plottedIndex = sampleIndex / sampleStride
            path.addLine(
                to: CGPoint(
                    x: CGFloat(plottedIndex) * xScale,
                    y: yPosition(for: samples[sampleIndex], midY: midY, pointsPerMicrovolt: pointsPerMicrovolt)
                )
            )
        }

        context.stroke(path, with: .color(color), lineWidth: 1)
    }

    private func drawPixelAdaptiveTrace(
        in context: inout GraphicsContext,
        size: CGSize,
        xScale: CGFloat,
        sampleStride: Int,
        midY: CGFloat,
        pointsPerMicrovolt: CGFloat
    ) {
        let safeXScale = max(xScale, 0.001)
        let lastPlottedIndex = max((samples.count - 1) / sampleStride, 0)
        let lowerBucket = max(Int(floor(visibleRange.lowerBound)), 0)
        let maxBucket = max(Int(ceil(size.width)) - 1, lowerBucket)
        let upperBucket = min(
            Int(ceil(visibleRange.upperBound)),
            maxBucket
        )
        guard upperBucket >= lowerBucket else { return }

        var envelope = Path()

        for bucketX in lowerBucket...upperBucket {
            let bucketStartX = CGFloat(bucketX)
            let bucketEndX = bucketStartX + 1
            let firstPlottedIndex = min(
                max(Int(floor(bucketStartX / safeXScale)), 0),
                lastPlottedIndex
            )
            let lastInBucket = max(
                firstPlottedIndex,
                Int(ceil(bucketEndX / safeXScale)) - 1
            )
            let lastPlottedInBucket = min(lastInBucket, lastPlottedIndex)

            var minValue = Float.greatestFiniteMagnitude
            var maxValue = -Float.greatestFiniteMagnitude
            var plottedIndex = firstPlottedIndex
            while plottedIndex <= lastPlottedInBucket {
                let sampleIndex = plottedIndex * sampleStride
                let value = samples[sampleIndex]
                if value.isFinite {
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
                plottedIndex += 1
            }

            guard minValue <= maxValue else { continue }

            let x = CGFloat(bucketX) + 0.5
            let minY = yPosition(for: minValue, midY: midY, pointsPerMicrovolt: pointsPerMicrovolt)
            let maxY = yPosition(for: maxValue, midY: midY, pointsPerMicrovolt: pointsPerMicrovolt)
            envelope.move(to: CGPoint(x: x, y: min(minY, maxY)))
            envelope.addLine(to: CGPoint(x: x, y: max(minY, maxY)))
        }

        context.stroke(envelope, with: .color(color), lineWidth: 1)
    }

    private func strokeBaseline(in context: inout GraphicsContext, midY: CGFloat) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: visibleRange.lowerBound, y: midY))
        baseline.addLine(to: CGPoint(x: visibleRange.upperBound, y: midY))
        context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 0.75)
    }

    private func yPosition(for value: Float, midY: CGFloat, pointsPerMicrovolt: CGFloat) -> CGFloat {
        midY - CGFloat(value) * pointsPerMicrovolt
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
    let samplingRate: Double
    let color: Color
    var highlightRelativeSample: Int? = nil
    /// Per-sample grand-average noise amplitude (µV) shaded as a ± band.
    var noiseCurve: [Float]? = nil
    /// Resolves a channel index to its display name, for the hover badge.
    var channelName: ((Int) -> String)? = nil
    /// Called when the user clicks the trace nearest the cursor.
    var onTapChannel: ((Int) -> Void)? = nil

    @State private var hoveredTrace: ButterflyTraceHit?

    var body: some View {
        GeometryReader { proxy in
            plotCanvas
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredTrace = nearestButterflyTrace(
                            at: location, in: proxy.size, data: data,
                            segments: [segment], hiddenChannels: hiddenChannels,
                            amplitudeScale: amplitudeScale,
                            maximumDistance: nil
                        )
                    case .ended:
                        hoveredTrace = nil
                    }
                }
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        guard let onTapChannel,
                              let hit = nearestButterflyTrace(
                                  at: value.location, in: proxy.size, data: data,
                                  segments: [segment], hiddenChannels: hiddenChannels,
                                  amplitudeScale: amplitudeScale,
                                  maximumDistance: nil
                              )
                        else { return }
                        onTapChannel(hit.channel)
                    }
                )
                .overlay(alignment: .topTrailing) {
                    if let hoveredTrace {
                        ButterflyChannelBadge(
                            name: channelName?(hoveredTrace.channel) ?? "Ch \(hoveredTrace.channel + 1)",
                            valueMicrovolts: Double(hoveredTrace.valueMicrovolts),
                            detail: butterflyLatencyText(
                                localSample: hoveredTrace.localSample,
                                stimulusOffsetSamples: segment.stimulusOffsetSamples,
                                samplingRate: samplingRate
                            )
                        )
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private var plotCanvas: some View {
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
    }
}

private struct ButterflyTraceHit {
    let channel: Int
    let localSample: Int
    let valueMicrovolts: Float
}

private func butterflyLatencyText(localSample: Int, stimulusOffsetSamples: Int, samplingRate: Double) -> String? {
    guard samplingRate > 0 else { return nil }
    let seconds = Double(localSample - stimulusOffsetSamples) / samplingRate
    return "Latency \(formatButterflyLatency(seconds))"
}

private func formatButterflyLatency(_ seconds: Double) -> String {
    let magnitude = abs(seconds)
    if magnitude < 1 {
        return String(format: "%.1f ms", seconds * 1_000)
    }
    if magnitude < 60 {
        return String(format: "%.3f s", seconds)
    }
    let sign = seconds < 0 ? "-" : ""
    let positiveSeconds = magnitude
    let minutes = Int(positiveSeconds) / 60
    let remainingSeconds = positiveSeconds.truncatingRemainder(dividingBy: 60)
    return "\(sign)\(minutes):\(String(format: "%06.3f", remainingSeconds))"
}

/// Nearest-trace hit test shared by `ButterflyConditionPlot`/`OverlayButterflyPlot`:
/// at the hovered/tapped x, finds the visible trace whose y is closest and
/// returns the channel plus sampled µV value.
private func nearestButterflyTrace(
    at location: CGPoint, in size: CGSize, data: [[Float]],
    segments: [EpochSegment], hiddenChannels: Set<Int>, amplitudeScale: Double,
    maximumDistance: CGFloat?
) -> ButterflyTraceHit? {
    guard let first = segments.first, first.endSample > first.startSample, size.width > 0 else { return nil }
    let epochLength = first.endSample - first.startSample + 1
    let midY = size.height / 2
    let pointsPerMicrovolt = (size.height * 0.42) / CGFloat(max(amplitudeScale, 1))
    let xScale = size.width / CGFloat(max(epochLength - 1, 1))
    let localSample = min(max(Int((location.x / xScale).rounded()), 0), epochLength - 1)

    var best: (hit: ButterflyTraceHit, distance: CGFloat)?
    for segment in segments {
        let sample = segment.startSample + localSample
        guard sample <= segment.endSample else { continue }
        for channelIndex in data.indices where !hiddenChannels.contains(channelIndex) {
            let channel = data[channelIndex]
            guard sample < channel.count else { continue }
            let value = channel[sample]
            let y: CGFloat = midY - CGFloat(value) * pointsPerMicrovolt
            let distance: CGFloat = abs(y - location.y)
            if best == nil || distance < best!.distance {
                best = (
                    hit: ButterflyTraceHit(channel: channelIndex, localSample: localSample, valueMicrovolts: value),
                    distance: distance
                )
            }
        }
    }
    guard let best else { return nil }
    if let maximumDistance, best.distance > maximumDistance { return nil }
    return best.hit
}

struct ButterflyChannelBadge: View {
    let name: String
    var valueMicrovolts: Double? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(name)
                .font(.caption2.weight(.semibold))
            if let valueMicrovolts {
                Text("\(format(valueMicrovolts)) µV")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .shadow(radius: 2, y: 1)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// Vertical topomap color-scale control (shown while ⌘ is held): µV min/max with
/// an optional symmetry lock, or a Z-score scale of ±N SD about the mean.
struct TopomapScaleControl: View {
    @Binding var mode: EpochingViewModel.TopomapScaleMode
    // µV
    @Binding var symmetric: Bool
    @Binding var minValue: Double
    @Binding var maxValue: Double
    let autoScale: Double
    let onAutoMicrovolts: () -> Void
    // Z-score
    @Binding var sigma: Double
    @Binding var zMean: Double
    @Binding var zSD: Double
    let onAutoZ: () -> Void

    var body: some View {
        let limit = Swift.max(autoScale * 3, 1)
        VStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(EpochingViewModel.TopomapScaleMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)

            if mode == .microvolts {
                Toggle("Symmetric", isOn: $symmetric)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                numField("Max", $maxValue)
                VerticalSlider(value: $maxValue, range: 0...limit)
                if !symmetric {
                    VerticalSlider(value: $minValue, range: -limit...0)
                    numField("Min", $minValue)
                } else {
                    Text("± max").font(.caption2).foregroundStyle(.secondary)
                }
                Button("Auto") { onAutoMicrovolts() }.font(.caption2).buttonStyle(.borderless)
            } else {
                numField("± SD", $sigma)
                numField("Mean", $zMean)
                numField("SD", $zSD)
                Button("Auto") { onAutoZ() }.font(.caption2).buttonStyle(.borderless)
                Text("color = ±SD\nabout the mean")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(8)
        .frame(width: 92)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .help("Adjust the topomap color scale. µV min/max (tighter = more intense) or a Z-score ±SD scale.")
    }

    @ViewBuilder
    private func numField(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .font(.caption2.monospacedDigit())
                .frame(width: 62)
        }
    }
}

/// A Slider rotated to run vertically.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Slider(value: $value, in: range)
            .frame(width: 130)
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: 130)
    }
}

/// Overlays the all-channel butterfly of two or more conditions on shared axes,
/// each condition in its own color — for publication comparison figures.
struct OverlayButterflyPlot: View {
    let data: [[Float]]
    let segments: [EpochSegment]
    let colors: [Color]
    let hiddenChannels: Set<Int>
    let amplitudeScale: Double
    let samplingRate: Double
    var highlightRelativeSample: Int? = nil
    /// Resolves a channel index to its display name, for the hover badge.
    var channelName: ((Int) -> String)? = nil
    /// Called when the user clicks the trace nearest the cursor.
    var onTapChannel: ((Int) -> Void)? = nil
    /// When supplied, dragging in the plot previews a latency cursor locally
    /// and commits the selected relative sample when the drag ends.
    var onScrubRelativeSample: ((Int) -> Void)? = nil

    @State private var hoveredTrace: ButterflyTraceHit?
    @State private var liveScrubRelativeSample: Int?

    var body: some View {
        GeometryReader { proxy in
            plotCanvas
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredTrace = nearestButterflyTrace(
                            at: location, in: proxy.size, data: data,
                            segments: segments, hiddenChannels: hiddenChannels,
                            amplitudeScale: amplitudeScale,
                            maximumDistance: nil
                        )
                    case .ended:
                        hoveredTrace = nil
                    }
                }
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        guard let onTapChannel,
                              let hit = nearestButterflyTrace(
                                  at: value.location, in: proxy.size, data: data,
                                  segments: segments, hiddenChannels: hiddenChannels,
                                  amplitudeScale: amplitudeScale,
                                  maximumDistance: nil
                              )
                        else { return }
                        onTapChannel(hit.channel)
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .local)
                        .onChanged { value in
                            guard onScrubRelativeSample != nil else { return }
                            liveScrubRelativeSample = relativeSample(forX: value.location.x, width: proxy.size.width)
                        }
                        .onEnded { value in
                            guard let onScrubRelativeSample else { return }
                            let sample = relativeSample(forX: value.location.x, width: proxy.size.width)
                            liveScrubRelativeSample = nil
                            onScrubRelativeSample(sample)
                        }
                )
                .overlay(alignment: .topTrailing) {
                    if let hoveredTrace {
                        let firstSegment = segments.first
                        ButterflyChannelBadge(
                            name: channelName?(hoveredTrace.channel) ?? "Ch \(hoveredTrace.channel + 1)",
                            valueMicrovolts: Double(hoveredTrace.valueMicrovolts),
                            detail: firstSegment.flatMap {
                                butterflyLatencyText(
                                    localSample: hoveredTrace.localSample,
                                    stimulusOffsetSamples: $0.stimulusOffsetSamples,
                                    samplingRate: samplingRate
                                )
                            }
                        )
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private var plotCanvas: some View {
        Canvas { context, size in
            guard let first = segments.first, !data.isEmpty else { return }
            let epochLength = first.endSample - first.startSample + 1
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
            context.stroke(stimulus, with: .color(.green.opacity(0.75)), lineWidth: 1)

            if let displaySample = liveScrubRelativeSample ?? highlightRelativeSample {
                let clamped = min(max(displaySample, 0), epochLength - 1)
                let cursorX = CGFloat(clamped) * xScale
                var cursor = Path()
                cursor.move(to: CGPoint(x: cursorX, y: 0))
                cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
                context.stroke(cursor, with: .color(.yellow), lineWidth: 1.5)
            }

            for (index, segment) in segments.enumerated() {
                let color = index < colors.count ? colors[index] : .accentColor
                for channelIndex in data.indices where !hiddenChannels.contains(channelIndex) {
                    let channel = data[channelIndex]
                    guard segment.startSample >= 0, segment.endSample < channel.count else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: midY - CGFloat(channel[segment.startSample]) * pointsPerMicrovolt))
                    for localSample in stride(from: sampleStep, through: epochLength - 1, by: sampleStep) {
                        let sample = segment.startSample + localSample
                        guard sample < channel.count else { break }
                        path.addLine(to: CGPoint(x: CGFloat(localSample) * xScale,
                                                 y: midY - CGFloat(channel[sample]) * pointsPerMicrovolt))
                    }
                    context.stroke(path, with: .color(color.opacity(0.30)), lineWidth: 0.7)
                }
            }
        }
    }

    private func relativeSample(forX x: CGFloat, width: CGFloat) -> Int {
        guard let first = segments.first else { return 0 }
        let epochLength = max(first.endSample - first.startSample + 1, 1)
        guard epochLength > 1, width > 0 else { return 0 }
        let xScale = width / CGFloat(epochLength - 1)
        return min(max(Int((x / xScale).rounded()), 0), epochLength - 1)
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
    var showsTimeMarkers = false
    var timeMarkerStyle = WaveformTimeMarkerStyle.defaultValue
    /// Resolved (possibly user-renamed) channel labels, for the hover tooltip.
    var names: [String] = []

    @State private var hoveredChannel: Int?
    @State private var hoveredSample: Int?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        Canvas { context, size in
            guard signal.samplingRate > 0, eegSamplingRate > 0, sampleStride > 0,
                  size.width > 0 else { return }
            let pxPerSecond = eegSamplingRate / Double(sampleStride) * timeScale
            guard pxPerSecond > 0 else { return }

            if showsTimeMarkers {
                WaveformTimeMarkers.drawLocal(
                    in: &context,
                    size: size,
                    pxPerSecond: pxPerSecond,
                    contentOffset: contentOffset,
                    style: timeMarkerStyle
                )
            }

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
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard let row = rowIndex(atY: location.y),
                      let sampleIdx = sampleIndex(atX: location.x),
                      signal.data.indices.contains(row),
                      signal.data[row].indices.contains(sampleIdx)
                else {
                    hoveredChannel = nil
                    return
                }
                hoveredChannel = row
                hoveredSample = sampleIdx
                hoverLocation = location
            case .ended:
                hoveredChannel = nil
            }
        }
        .overlay(alignment: .topLeading) { hoverTooltip }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private func rowIndex(atY y: CGFloat) -> Int? {
        guard rowHeight > 0 else { return nil }
        let idx = Int(y / rowHeight)
        return (0..<signal.numberOfChannels).contains(idx) ? idx : nil
    }

    private func sampleIndex(atX x: CGFloat) -> Int? {
        guard eegSamplingRate > 0, sampleStride > 0, signal.samplingRate > 0 else { return nil }
        let pxPerSecond = eegSamplingRate / Double(sampleStride) * timeScale
        guard pxPerSecond > 0 else { return nil }
        let t = Double(x + contentOffset) / pxPerSecond
        guard t.isFinite, t >= 0 else { return nil }
        return Int((t * signal.samplingRate).rounded())
    }

    @ViewBuilder
    private var hoverTooltip: some View {
        if let hoveredChannel, let hoveredSample,
           signal.data.indices.contains(hoveredChannel),
           signal.data[hoveredChannel].indices.contains(hoveredSample) {
            let value = signal.data[hoveredChannel][hoveredSample]
            let name = hoveredChannel < names.count ? names[hoveredChannel] : "PNS \(hoveredChannel + 1)"
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption.weight(.semibold))
                Text(String(format: "%.2f", value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .offset(x: min(hoverLocation.x + 12, viewportWidth - 90), y: max(hoverLocation.y - 28, 0))
            .allowsHitTesting(false)
        }
    }
}

struct EventTrackView: View {
    /// Maximum number of vertical lanes events are staggered across, and the
    /// extra height each lane beyond the first adds to the track.
    static let maxLanes = EventTrackConstants.maxLanes
    static let laneSpacing = EventTrackConstants.laneSpacing
    static let denseMarkerThreshold = EventTrackConstants.denseMarkerThreshold
    private static let baseTrackHeight: CGFloat = 64

    let events: [MFFEvent]
    let samplingRate: Double
    let timeScale: Double
    let sampleStride: Int
    /// True horizontal scroll offset of the waveform content, used so event
    /// markers line up with the waveform cursor.
    let contentOffset: CGFloat
    let visibleRange: ClosedRange<CGFloat>
    let viewportWidth: CGFloat
    let isCommandKeyPressed: Bool
    var timeMarkerStyle = WaveformTimeMarkerStyle.defaultValue
    /// Number of distinct source lanes events are staggered into.
    var laneCount: Int = 1
    /// Called when a flag is tapped, with the event and its flag color, so the
    /// parent can highlight the artifact's window in the waveform.
    var onSelectEvent: ((MFFEvent, Color) -> Void)? = nil

    /// Event whose detail popover is currently shown (tap a flag to open).
    @State private var poppedEvent: MFFEvent?
    @State private var hoveredEventStack: EventTrackHoverStack?
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
        let overlapClusters = drawsFlags ? overlapClusters(for: visibleMarkers) : []

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))

            Canvas { context, size in
                guard samplingRate > 0 else { return }
                WaveformTimeMarkers.drawLocal(
                    in: &context,
                    size: size,
                    pxPerSecond: samplingRate / Double(max(sampleStride, 1)) * timeScale,
                    contentOffset: contentOffset,
                    style: timeMarkerStyle
                )

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
                ForEach(overlapClusters) { cluster in
                    overlapBadge(cluster)
                }
            }

            if isCommandKeyPressed, let hoveredEventStack {
                inlineEventStackChooser(hoveredEventStack)
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
        .onChange(of: isCommandKeyPressed) { _, pressed in
            if !pressed {
                hoveredEventStack = nil
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                updateHoveredEventStack(at: location, visibleMarkers: visibleMarkers)
            case .ended:
                break
            }
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

    private func localXPosition(forGlobalX globalX: CGFloat) -> CGFloat {
        globalX - contentOffset
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
        Text(ribbonLabel(for: event))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.15), in: Capsule())
            .foregroundStyle(style.color)
            .help(tooltip(for: event))
            .contentShape(Capsule())
            .onTapGesture {
                poppedEvent = event
                onSelectEvent?(event, style.color)
            }
            .popover(isPresented: isPopped) {
                eventDetailPopover(event, color: style.color)
            }
            .offset(x: min(max(x + 4, 0), max(viewportWidth - 70, 0)), y: style.laneY)
    }

    @ViewBuilder
    private func overlapBadge(_ cluster: EventTrackOverlapCluster) -> some View {
        let x = localXPosition(forGlobalX: cluster.globalX)
        Text("\(cluster.count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(cluster.color, in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.85), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .offset(x: min(max(x + 3, 0), max(viewportWidth - 24, 0)),
                    y: max(cluster.laneY - 6, 0))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func inlineEventStackChooser(_ stack: EventTrackHoverStack) -> some View {
        let offset = inlineChooserOffset(for: stack)
        let width = inlineChooserWidth(for: stack.markers)
        ScrollView(.horizontal, showsIndicators: stack.markers.count > 3) {
            HStack(spacing: 4) {
                ForEach(stack.markers) { marker in
                    Button {
                        poppedEvent = nil
                        hoveredEventStack = nil
                        onSelectEvent?(marker.event, marker.style.color)
                    } label: {
                        Text(ribbonLabel(for: marker.event))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(marker.style.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(marker.style.color.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(tooltip(for: marker.event))
                }
            }
            .padding(4)
        }
        .frame(width: width, height: 30, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .offset(offset)
        .zIndex(30)
    }

    private func ribbonLabel(for event: MFFEvent) -> String {
        if isDefinedArtifactEvent(event), let label = event.label {
            return label
        }
        return event.code
    }

    private func isDefinedArtifactEvent(_ event: MFFEvent) -> Bool {
        event.sourceFile.hasPrefix("Template ")
            || event.sourceFile.hasPrefix("Topography ")
            || event.sourceFile.hasPrefix("Trajectory ")
            || event.sourceFile.hasPrefix("Continuous ")
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

    private func overlapClusters(for markers: [EventTrackMarker]) -> [EventTrackOverlapCluster] {
        let tolerance: CGFloat = 4
        var clusters: [EventTrackOverlapCluster] = []
        let markersBySource = Dictionary(grouping: markers, by: \.style.sourceIndex)

        for sourceMarkers in markersBySource.values {
            let sortedMarkers = sourceMarkers.sorted {
                if $0.globalX == $1.globalX {
                    return $0.event.id < $1.event.id
                }
                return $0.globalX < $1.globalX
            }
            var start = sortedMarkers.startIndex

            while start < sortedMarkers.endIndex {
                var end = sortedMarkers.index(after: start)
                let anchorX = sortedMarkers[start].globalX
                while end < sortedMarkers.endIndex, abs(sortedMarkers[end].globalX - anchorX) <= tolerance {
                    end = sortedMarkers.index(after: end)
                }

                let group = sortedMarkers[start..<end]
                if group.count > 1, let first = group.first {
                    let ids = group.map(\.event.id).joined(separator: "|")
                    clusters.append(EventTrackOverlapCluster(
                        id: ids,
                        globalX: first.globalX,
                        laneY: first.style.laneY,
                        count: group.count,
                        color: first.style.color
                    ))
                }
                start = end
            }
        }
        return clusters.sorted { $0.globalX < $1.globalX }
    }

    private func updateHoveredEventStack(at location: CGPoint, visibleMarkers: [EventTrackMarker]) {
        guard isCommandKeyPressed else {
            hoveredEventStack = nil
            return
        }

        if let hoveredEventStack,
           inlineChooserRect(for: hoveredEventStack).contains(location) {
            return
        }

        let candidates = visibleMarkers.filter { marker in
            markerContains(location, marker: marker)
        }
        guard !candidates.isEmpty else {
            hoveredEventStack = nil
            return
        }

        let sorted = candidates.sorted {
            if $0.event.beginTimeSeconds == $1.event.beginTimeSeconds {
                if $0.event.code == $1.event.code {
                    return $0.event.id < $1.event.id
                }
                return $0.event.code < $1.event.code
            }
            return $0.event.beginTimeSeconds < $1.event.beginTimeSeconds
        }
        let nextID = sorted.map(\.event.id).joined(separator: "|")
        if hoveredEventStack?.id == nextID {
            return
        }
        hoveredEventStack = EventTrackHoverStack(location: chooserAnchor(for: sorted), markers: sorted)
    }

    private func markerContains(_ location: CGPoint, marker: EventTrackMarker) -> Bool {
        let x = localXPosition(for: marker)
        let stemHit = abs(location.x - x) <= 12
        let labelX = min(max(x + 4, 0), max(viewportWidth - 70, 0))
        let labelWidth = min(max(CGFloat(ribbonLabel(for: marker.event).count) * 7 + 18, 40), 170)
        let labelRect = CGRect(x: labelX - 4, y: marker.style.laneY - 3, width: labelWidth + 8, height: 24)
        return stemHit || labelRect.contains(location)
    }

    private func inlineChooserOffset(for stack: EventTrackHoverStack) -> CGSize {
        let width = inlineChooserWidth(for: stack.markers)
        let trackHeight = Self.baseTrackHeight + CGFloat(max(laneCount - 1, 0)) * Self.laneSpacing
        let x = min(max(stack.location.x + 10, 4), max(viewportWidth - width - 4, 4))
        let y = min(max(stack.location.y + 14, 4), max(trackHeight - 34, 4))
        return CGSize(width: x, height: y)
    }

    private func chooserAnchor(for markers: [EventTrackMarker]) -> CGPoint {
        let markerXs = markers.map { localXPosition(for: $0) }
        let anchorX = markerXs.isEmpty
            ? CGFloat(0)
            : markerXs.reduce(CGFloat(0), +) / CGFloat(markerXs.count)
        let anchorY = markers.map(\.style.laneY).min() ?? 0
        return CGPoint(x: anchorX, y: anchorY)
    }

    private func inlineChooserWidth(for markers: [EventTrackMarker]) -> CGFloat {
        let naturalWidth = markers.reduce(CGFloat(8)) { partial, marker in
            partial + inlineChooserLabelWidth(for: marker.event) + 4
        }
        return min(max(naturalWidth, 60), max(viewportWidth - 8, 60))
    }

    private func inlineChooserLabelWidth(for event: MFFEvent) -> CGFloat {
        min(max(CGFloat(ribbonLabel(for: event).count) * 7 + 18, 44), 140)
    }

    private func inlineChooserRect(for stack: EventTrackHoverStack) -> CGRect {
        let offset = inlineChooserOffset(for: stack)
        return CGRect(x: offset.width, y: offset.height, width: inlineChooserWidth(for: stack.markers), height: 30)
            .insetBy(dx: -6, dy: -6)
    }

}
