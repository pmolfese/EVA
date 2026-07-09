//
//  ChannelInspectorViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Single-channel (or Channel-Set average) inspector: opened by clicking a
//  channel on a topomap or picking one from the dropdown. Mirrors the
//  butterfly panel's multi-condition overlay, but for one trace (or a
//  Channel-Set average + faint member traces) instead of all channels.
//  This is an extension of WaveformView, following the L5 file-split pattern.
//

import SwiftUI

/// What the Channel Inspector is currently showing: a single EEG channel, or
/// a named `ChannelSet` (averaged across its member channels).
enum ChannelInspectorSelection: Equatable {
    case channel(Int)
    case channelSet(ChannelSet)
}

extension WaveformView {
    func openChannelInspector(channel index: Int) {
        channelInspectorSelection = .channel(index)
        showsChannelInspector = true
    }

    func channelInspectorTitle(for selection: ChannelInspectorSelection, signal: MFFSignalData) -> String {
        switch selection {
        case .channel(let index):
            return eegChannelDisplayName(index: index, signal: signal)
        case .channelSet(let set):
            return "\(set.name) (\(set.channelIndices.count) channels, averaged)"
        }
    }

    /// Member channel indices for the selection, clamped to the signal's channel count.
    func channelInspectorIndices(for selection: ChannelInspectorSelection, signal: MFFSignalData) -> [Int] {
        switch selection {
        case .channel(let index):
            return signal.data.indices.contains(index) ? [index] : []
        case .channelSet(let set):
            return set.channelIndices.filter { signal.data.indices.contains($0) }
        }
    }

    /// The averaged trace (single channel = itself) for one segment.
    private func channelInspectorTrace(indices: [Int], segment: EpochSegment, signal: MFFSignalData) -> [Float] {
        guard !indices.isEmpty else { return [] }
        let length = max(segment.endSample - segment.startSample + 1, 0)
        guard length > 0 else { return [] }
        var sum = [Float](repeating: 0, count: length)
        for index in indices {
            let row = signal.data[index]
            guard row.count >= segment.endSample + 1 else { continue }
            for i in 0..<length {
                sum[i] += row[segment.startSample + i]
            }
        }
        let n = Float(indices.count)
        return sum.map { $0 / n }
    }

    @ViewBuilder
    func channelInspectorSheet(for signal: MFFSignalData) -> some View {
        let selection = channelInspectorSelection
        let indices = channelInspectorIndices(for: selection, signal: signal)
        let segments = epoching.isAveraged ? selectedOverlaySegments() : []
        let standardErrorBands = channelInspectorShowsStandardError
            ? channelInspectorStandardErrorBands(for: segments, selection: selection, signal: signal)
            : [:]

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Channel Inspector")
                        .font(.title3.weight(.semibold))
                    Text(channelInspectorTitle(for: selection, signal: signal))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !segments.isEmpty {
                    figureSaveMenu(
                        title: channelInspectorTitle(for: selection, signal: signal),
                        legend: overlayLegendItems(),
                        size: CGSize(width: 720, height: 320)
                    ) {
                        ChannelInspectorPlot(
                            signal: signal,
                            segments: segments,
                            indices: indices,
                            showsMembers: channelInspectorOverlayEnabled,
                            amplitudeScale: amplitudeScale,
                            colorFor: { epochColor(for: $0) },
                            standardErrorBands: standardErrorBands
                        )
                        .frame(width: 720, height: 320)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                channelInspectorChannelMenu(signal: signal)
                channelInspectorGroupMenu()
                Button {
                    showsChannelInspector = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if indices.isEmpty {
                ContentUnavailableView(
                    "No Channel Selected",
                    systemImage: "waveform.path",
                    description: Text("Pick a channel or Channel Set above, or click a point on a topomap.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                ContentUnavailableView(
                    "No Averages",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Create PSA averages to see overlaid category traces here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        overlayConditionsMenu()
                        if case .channelSet = selection {
                            Toggle("Show member channels", isOn: $channelInspectorOverlayEnabled)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                                .help("Overlay each member channel faintly behind the Channel Set average.")
                        }
                        Spacer()
                        FlowLegend(items: overlayLegendItems())
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    ChannelInspectorPlot(
                        signal: signal,
                        segments: segments,
                        indices: indices,
                        showsMembers: channelInspectorOverlayEnabled,
                        amplitudeScale: amplitudeScale,
                        colorFor: { epochColor(for: $0) },
                        channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                        standardErrorBands: standardErrorBands
                    )
                    .contextMenu {
                        channelInspectorDisplayMenuItems(selection: selection, signal: signal, segments: segments)
                        Divider()
                        figureSaveMenu(
                            title: channelInspectorTitle(for: selection, signal: signal),
                            legend: overlayLegendItems(),
                            size: CGSize(width: 720, height: 320)
                        ) {
                            ChannelInspectorPlot(
                                signal: signal,
                                segments: segments,
                                indices: indices,
                                showsMembers: channelInspectorOverlayEnabled,
                        amplitudeScale: amplitudeScale,
                        colorFor: { epochColor(for: $0) },
                        channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                        standardErrorBands: standardErrorBands
                    )
                            .frame(width: 720, height: 320)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(minHeight: 260)
                }
            }
        }
        .frame(width: 760, height: 480)
    }

    @ViewBuilder
    func channelInspectorChannelMenu(signal: MFFSignalData) -> some View {
        Menu {
            ForEach(signal.data.indices, id: \.self) { index in
                Button(eegChannelDisplayName(index: index, signal: signal)) {
                    channelInspectorSelection = .channel(index)
                }
            }
        } label: {
            Label("Channel", systemImage: "list.bullet")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    func channelInspectorGroupMenu() -> some View {
        let sets = ChannelSetStore.shared.allSets
        Menu {
            if sets.isEmpty {
                Text("No Channel Sets defined")
            } else {
                ForEach(sets) { set in
                    Button("\(set.name) (\(set.channelIndices.count))") {
                        channelInspectorSelection = .channelSet(set)
                    }
                }
            }
        } label: {
            Label("Channel Group", systemImage: "square.stack.3d.up")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(sets.isEmpty)
    }

    @ViewBuilder
    func channelInspectorDisplayMenuItems(
        selection: ChannelInspectorSelection,
        signal: MFFSignalData,
        segments: [EpochSegment]
    ) -> some View {
        if case .channelSet = selection {
            Toggle("Show faint member lines", isOn: $channelInspectorOverlayEnabled)
        }

        let canShowStandardError = channelInspectorCanShowStandardError(
            selection: selection,
            signal: signal,
            segments: segments
        )
        Toggle("Show standard error", isOn: $channelInspectorShowsStandardError)
            .disabled(!canShowStandardError)

        if !canShowStandardError {
            Text("Standard error unavailable")
        }
    }

    func channelInspectorCanShowStandardError(
        selection: ChannelInspectorSelection,
        signal: MFFSignalData,
        segments: [EpochSegment]
    ) -> Bool {
        let indices = channelInspectorIndices(for: selection, signal: signal)
        return channelInspectorHasTrialStandardError(for: segments) || indices.count > 1
    }

    func channelInspectorStandardErrorBands(
        for segments: [EpochSegment],
        selection: ChannelInspectorSelection,
        signal: MFFSignalData
    ) -> [String: ChannelInspectorStandardErrorBand] {
        let indices = channelInspectorIndices(for: selection, signal: signal)
        guard !segments.isEmpty, !indices.isEmpty else { return [:] }

        var bands = channelInspectorTrialStandardErrorBands(for: segments, indices: indices)
        let channelBands = channelInspectorChannelStandardErrorBands(for: segments, indices: indices, signal: signal)
        for segment in segments where bands[segment.id] == nil {
            if let band = channelBands[segment.id] {
                bands[segment.id] = band
            }
        }
        return bands
    }

    private func channelInspectorHasTrialStandardError(for segments: [EpochSegment]) -> Bool {
        guard let rawSignal = segmentedEpochSignal,
              rawSignal.numberOfChannels > 0,
              !segmentedEpochSegments.isEmpty,
              !segments.isEmpty else { return false }
        let categories = Set(segments.map(\.category))
        var counts = [String: Int]()
        for segment in segmentedEpochSegments where categories.contains(segment.category) {
            guard segment.endSample > segment.startSample else { continue }
            counts[segment.category, default: 0] += 1
            if counts[segment.category, default: 0] > 1 { return true }
        }
        return false
    }

    private func channelInspectorTrialStandardErrorBands(
        for segments: [EpochSegment],
        indices: [Int]
    ) -> [String: ChannelInspectorStandardErrorBand] {
        guard let rawSignal = segmentedEpochSignal,
              !segmentedEpochSegments.isEmpty else { return [:] }
        let validIndices = indices.filter { rawSignal.data.indices.contains($0) }
        guard !validIndices.isEmpty else { return [:] }

        let rawSegmentsByCategory = Dictionary(grouping: segmentedEpochSegments, by: \.category)
        var bands = [String: ChannelInspectorStandardErrorBand]()

        for segment in segments {
            let length = max(segment.endSample - segment.startSample + 1, 0)
            guard length > 1,
                  let rawSegments = rawSegmentsByCategory[segment.category] else { continue }

            var sums = [Double](repeating: 0, count: length)
            var sumSquares = [Double](repeating: 0, count: length)
            var counts = [Int](repeating: 0, count: length)

            for rawSegment in rawSegments {
                guard rawSegment.endSample - rawSegment.startSample + 1 == length,
                      let trace = channelInspectorTrialTrace(
                        rawSignal: rawSignal,
                        segment: rawSegment,
                        indices: validIndices,
                        length: length
                      ) else { continue }

                for offset in 0..<length {
                    let value = Double(trace[offset])
                    guard value.isFinite else { continue }
                    sums[offset] += value
                    sumSquares[offset] += value * value
                    counts[offset] += 1
                }
            }

            let contributingTraceCount = counts.max() ?? 0
            guard contributingTraceCount > 1 else { continue }
            bands[segment.id] = ChannelInspectorStandardErrorBand(
                standardErrors: channelInspectorStandardErrors(sums: sums, sumSquares: sumSquares, counts: counts),
                contributingTraceCount: contributingTraceCount,
                source: .trials
            )
        }

        return bands
    }

    private func channelInspectorTrialTrace(
        rawSignal: MFFSignalData,
        segment: EpochSegment,
        indices: [Int],
        length: Int
    ) -> [Float]? {
        guard length > 1, segment.startSample >= 0 else { return nil }
        let endSample = segment.startSample + length - 1
        let selectedIndices = indices.filter {
            rawSignal.data.indices.contains($0) && rawSignal.data[$0].count > endSample
        }
        guard !selectedIndices.isEmpty else { return nil }

        let referenceIndices: [Int]
        if epoching.averageReference {
            referenceIndices = rawSignal.data.indices.filter {
                !channels.bad.contains($0) && rawSignal.data[$0].count > endSample
            }
        } else {
            referenceIndices = []
        }

        var trace = [Float](repeating: 0, count: length)
        for offset in 0..<length {
            let sample = segment.startSample + offset
            var referenceMean = 0.0
            if epoching.averageReference {
                var referenceSum = 0.0
                var referenceCount = 0
                for index in referenceIndices {
                    let value = Double(rawSignal.data[index][sample])
                    guard value.isFinite else { continue }
                    referenceSum += value
                    referenceCount += 1
                }
                if referenceCount > 0 {
                    referenceMean = referenceSum / Double(referenceCount)
                }
            }

            var selectedSum = 0.0
            var selectedCount = 0
            for index in selectedIndices {
                let value = Double(rawSignal.data[index][sample]) - referenceMean
                guard value.isFinite else { continue }
                selectedSum += value
                selectedCount += 1
            }
            guard selectedCount > 0 else { return nil }
            trace[offset] = Float(selectedSum / Double(selectedCount))
        }

        if epoching.baselineCorrected {
            let baselineCount = min(max(segment.stimulusOffsetSamples, 0), length)
            if baselineCount > 0 {
                var baselineSum = 0.0
                var baselineN = 0
                for offset in 0..<baselineCount {
                    let value = Double(trace[offset])
                    guard value.isFinite else { continue }
                    baselineSum += value
                    baselineN += 1
                }
                if baselineN > 0 {
                    let baseline = Float(baselineSum / Double(baselineN))
                    for offset in trace.indices {
                        trace[offset] -= baseline
                    }
                }
            }
        }

        return trace
    }

    private func channelInspectorChannelStandardErrorBands(
        for segments: [EpochSegment],
        indices: [Int],
        signal: MFFSignalData
    ) -> [String: ChannelInspectorStandardErrorBand] {
        let validIndices = indices.filter { signal.data.indices.contains($0) }
        guard validIndices.count > 1 else { return [:] }

        var bands = [String: ChannelInspectorStandardErrorBand]()
        for segment in segments {
            let length = max(segment.endSample - segment.startSample + 1, 0)
            guard length > 1 else { continue }

            var sums = [Double](repeating: 0, count: length)
            var sumSquares = [Double](repeating: 0, count: length)
            var counts = [Int](repeating: 0, count: length)

            for index in validIndices {
                guard signal.data[index].count > segment.endSample else { continue }
                for offset in 0..<length {
                    let value = Double(signal.data[index][segment.startSample + offset])
                    guard value.isFinite else { continue }
                    sums[offset] += value
                    sumSquares[offset] += value * value
                    counts[offset] += 1
                }
            }

            let contributingTraceCount = counts.max() ?? 0
            guard contributingTraceCount > 1 else { continue }
            bands[segment.id] = ChannelInspectorStandardErrorBand(
                standardErrors: channelInspectorStandardErrors(sums: sums, sumSquares: sumSquares, counts: counts),
                contributingTraceCount: contributingTraceCount,
                source: .channels
            )
        }
        return bands
    }

    private func channelInspectorStandardErrors(
        sums: [Double],
        sumSquares: [Double],
        counts: [Int]
    ) -> [Float] {
        sums.indices.map { index in
            let count = counts[index]
            guard count > 1 else { return 0 }
            let n = Double(count)
            let numerator = max(sumSquares[index] - (sums[index] * sums[index] / n), 0)
            let variance = numerator / (n - 1)
            return Float((variance / n).squareRoot())
        }
    }
}

struct ChannelInspectorStandardErrorBand {
    enum Source {
        case trials
        case channels

        var label: String {
            switch self {
            case .trials: return "trial SEM"
            case .channels: return "channel SEM"
            }
        }
    }

    let standardErrors: [Float]
    let contributingTraceCount: Int
    let source: Source
}

/// Overlays one trace per selected category for the chosen channel/Channel-Set.
/// When the selection is a Channel Set and `showsMembers` is on, each member
/// channel is drawn faintly behind the averaged trace (same category color,
/// lower opacity) so the spread across the group is visible.
struct ChannelInspectorPlot: View {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let indices: [Int]
    let showsMembers: Bool
    let amplitudeScale: Double
    let colorFor: (Int) -> Color
    var channelName: ((Int) -> String)? = nil
    var highlightRelativeSample: Int? = nil
    var onScrubRelativeSample: ((Int) -> Void)? = nil
    var standardErrorBands: [String: ChannelInspectorStandardErrorBand] = [:]

    @State private var hoverInfo: ChannelInspectorHoverInfo?
    @State private var liveScrubRelativeSample: Int?

    var body: some View {
        GeometryReader { proxy in
            let scale = max(amplitudeScale, 1)
            Canvas { context, size in
                let midY = size.height / 2
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: size.width, y: midY)) },
                    with: .color(.secondary.opacity(0.25)), lineWidth: 1
                )

                if let first = segments.first {
                    let length = max(first.endSample - first.startSample + 1, 1)
                    if length > 1 {
                        let x = CGFloat(first.stimulusOffsetSamples) / CGFloat(length - 1) * size.width
                        context.stroke(
                            Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                            with: .color(.green.opacity(0.5)), lineWidth: 1
                        )
                    }
                }

                for segment in segments {
                    let color = colorFor(segment.colorIndex)
                    let length = max(segment.endSample - segment.startSample + 1, 1)
                    let averaged = average(indices: indices, segment: segment)

                    if let band = standardErrorBands[segment.id] {
                        drawStandardErrorBand(
                            center: averaged,
                            standardError: band.standardErrors,
                            length: length,
                            size: size,
                            midY: midY,
                            scale: scale,
                            in: &context,
                            color: color
                        )
                    }

                    if showsMembers, indices.count > 1 {
                        for index in indices {
                            guard signal.data.indices.contains(index),
                                  signal.data[index].count >= segment.endSample + 1 else { continue }
                            let trace = Array(signal.data[index][segment.startSample...segment.endSample])
                            draw(trace, length: length, size: size, midY: midY, scale: scale,
                                 in: &context, color: color, opacity: 0.18, lineWidth: 1)
                        }
                    }

                    draw(averaged, length: length, size: size, midY: midY, scale: scale,
                         in: &context, color: color, opacity: 0.95, lineWidth: 1.6)
                }

                if let first = segments.first, let highlightRelativeSample = liveScrubRelativeSample ?? highlightRelativeSample {
                    let length = max(first.endSample - first.startSample + 1, 1)
                    if length > 1 {
                        let clamped = min(max(highlightRelativeSample, 0), length - 1)
                        let x = CGFloat(clamped) / CGFloat(length - 1) * size.width
                        context.stroke(
                            Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                            with: .color(.yellow), lineWidth: 2
                        )
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverInfo = nearestHoverInfo(at: location, in: proxy.size)
                case .ended:
                    hoverInfo = nil
                }
            }
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
                if let hoverInfo {
                    ButterflyChannelBadge(
                        name: hoverInfo.channelLabel,
                        valueMicrovolts: hoverInfo.valueMicrovolts,
                        detail: hoverInfo.detail
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private struct ChannelInspectorHoverInfo {
        let channelLabel: String
        let valueMicrovolts: Double
        let detail: String
    }

    private func nearestHoverInfo(at location: CGPoint, in size: CGSize) -> ChannelInspectorHoverInfo? {
        guard let first = segments.first, first.endSample > first.startSample, size.width > 0 else { return nil }
        let length = first.endSample - first.startSample + 1
        let midY = size.height / 2
        let scale = max(amplitudeScale, 1)
        let xScale = size.width / CGFloat(length - 1)
        let localSample = min(max(Int((location.x / xScale).rounded()), 0), length - 1)
        let timeMs = signal.samplingRate > 0
            ? Double(localSample - first.stimulusOffsetSamples) / signal.samplingRate * 1_000
            : 0

        var best: (value: Double, distance: CGFloat, label: String, detail: String)?
        for segment in segments {
            let length = max(segment.endSample - segment.startSample + 1, 1)
            guard length > 1, localSample < length else { continue }
            let averageTrace = average(indices: indices, segment: segment)
            consider(
                trace: averageTrace,
                localSample: localSample,
                location: location,
                size: size,
                midY: midY,
                scale: scale,
                label: averageTraceLabel(),
                detail: "\(segment.category) · Avg · \(Int(timeMs.rounded())) ms",
                best: &best
            )

            guard showsMembers, indices.count > 1 else { continue }
            for index in indices {
                guard signal.data.indices.contains(index),
                      signal.data[index].count >= segment.endSample + 1 else { continue }
                let trace = Array(signal.data[index][segment.startSample...segment.endSample])
                consider(
                    trace: trace,
                    localSample: localSample,
                    location: location,
                    size: size,
                    midY: midY,
                    scale: scale,
                    label: displayName(for: index),
                    detail: "\(segment.category) · Member · \(Int(timeMs.rounded())) ms",
                    best: &best
                )
            }
        }

        guard let best else { return nil }
        return ChannelInspectorHoverInfo(
            channelLabel: best.label,
            valueMicrovolts: best.value,
            detail: best.detail
        )
    }

    private func relativeSample(forX x: CGFloat, width: CGFloat) -> Int {
        guard let first = segments.first else { return 0 }
        let length = max(first.endSample - first.startSample + 1, 1)
        guard length > 1, width > 0 else { return 0 }
        let xScale = width / CGFloat(length - 1)
        return min(max(Int((x / xScale).rounded()), 0), length - 1)
    }

    private func consider(
        trace: [Float],
        localSample: Int,
        location: CGPoint,
        size: CGSize,
        midY: CGFloat,
        scale: Double,
        label: String,
        detail: String,
        best: inout (value: Double, distance: CGFloat, label: String, detail: String)?
    ) {
        guard trace.indices.contains(localSample) else { return }
        let value = Double(trace[localSample])
        let y = midY - CGFloat(value / scale) * (size.height / 2) * 0.9
        let distance = abs(y - location.y)
        if best == nil || distance < best!.distance {
            best = (value: value, distance: distance, label: label, detail: detail)
        }
    }

    private func averageTraceLabel() -> String {
        if indices.count == 1, let index = indices.first {
            return displayName(for: index)
        }
        return "\(indices.count) ch avg"
    }

    private func displayName(for index: Int) -> String {
        channelName?(index) ?? "Ch \(index + 1)"
    }

    private func average(indices: [Int], segment: EpochSegment) -> [Float] {
        let length = max(segment.endSample - segment.startSample + 1, 0)
        guard length > 0, !indices.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: length)
        var n: Float = 0
        for index in indices {
            guard signal.data.indices.contains(index), signal.data[index].count >= segment.endSample + 1 else { continue }
            let row = signal.data[index]
            for i in 0..<length { sum[i] += row[segment.startSample + i] }
            n += 1
        }
        guard n > 0 else { return [] }
        return sum.map { $0 / n }
    }

    private func drawStandardErrorBand(
        center: [Float],
        standardError: [Float],
        length: Int,
        size: CGSize,
        midY: CGFloat,
        scale: Double,
        in context: inout GraphicsContext,
        color: Color
    ) {
        let count = min(center.count, standardError.count, length)
        guard count > 1, length > 1 else { return }

        var path = Path()
        for i in 0..<count {
            let sem = Double(standardError[i]).isFinite ? Double(standardError[i]) : 0
            let value = Double(center[i]) + sem
            let x = CGFloat(i) / CGFloat(length - 1) * size.width
            let y = midY - CGFloat(value / scale) * (size.height / 2) * 0.9
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        for i in stride(from: count - 1, through: 0, by: -1) {
            let sem = Double(standardError[i]).isFinite ? Double(standardError[i]) : 0
            let value = Double(center[i]) - sem
            let x = CGFloat(i) / CGFloat(length - 1) * size.width
            let y = midY - CGFloat(value / scale) * (size.height / 2) * 0.9
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()

        context.fill(path, with: .color(color.opacity(0.14)))
        context.stroke(path, with: .color(color.opacity(0.28)), lineWidth: 0.75)
    }

    private func draw(
        _ trace: [Float], length: Int, size: CGSize, midY: CGFloat, scale: Double,
        in context: inout GraphicsContext, color: Color, opacity: Double, lineWidth: CGFloat
    ) {
        guard trace.count > 1 else { return }
        var path = Path()
        for (i, value) in trace.enumerated() {
            let x = CGFloat(i) / CGFloat(length - 1) * size.width
            let y = midY - CGFloat(Double(value) / scale) * (size.height / 2) * 0.9
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)
    }
}
