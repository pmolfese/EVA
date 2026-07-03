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
    private func channelInspectorIndices(for selection: ChannelInspectorSelection, signal: MFFSignalData) -> [Int] {
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
                            colorFor: { epochColor(for: $0) }
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
                        colorFor: { epochColor(for: $0) }
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(minHeight: 260)
                }
            }
        }
        .frame(width: 760, height: 480)
    }

    @ViewBuilder
    private func channelInspectorChannelMenu(signal: MFFSignalData) -> some View {
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
    private func channelInspectorGroupMenu() -> some View {
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
}

/// Overlays one trace per selected category for the chosen channel/Channel-Set.
/// When the selection is a Channel Set and `showsMembers` is on, each member
/// channel is drawn faintly behind the averaged trace (same category color,
/// lower opacity) so the spread across the group is visible.
private struct ChannelInspectorPlot: View {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let indices: [Int]
    let showsMembers: Bool
    let colorFor: (Int) -> Color

    var body: some View {
        GeometryReader { proxy in
            let scale = amplitudeScale
            Canvas { context, size in
                let midY = size.height / 2
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: size.width, y: midY)) },
                    with: .color(.secondary.opacity(0.25)), lineWidth: 1
                )

                for segment in segments {
                    let color = colorFor(segment.colorIndex)
                    let length = max(segment.endSample - segment.startSample + 1, 1)

                    if showsMembers, indices.count > 1 {
                        for index in indices {
                            guard signal.data.indices.contains(index),
                                  signal.data[index].count >= segment.endSample + 1 else { continue }
                            let trace = Array(signal.data[index][segment.startSample...segment.endSample])
                            draw(trace, length: length, size: size, midY: midY, scale: scale,
                                 in: &context, color: color, opacity: 0.18, lineWidth: 1)
                        }
                    }

                    let averaged = average(indices: indices, segment: segment)
                    draw(averaged, length: length, size: size, midY: midY, scale: scale,
                         in: &context, color: color, opacity: 0.95, lineWidth: 1.6)

                    // Stimulus marker.
                    if length > 1 {
                        let x = CGFloat(segment.stimulusOffsetSamples) / CGFloat(length - 1) * size.width
                        context.stroke(
                            Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                            with: .color(.green.opacity(0.5)), lineWidth: 1
                        )
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
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

    private var amplitudeScale: Double {
        let allValues = segments.flatMap { segment -> [Float] in
            average(indices: indices, segment: segment)
        }
        let maxAbs = allValues.map { abs($0) }.max() ?? 1
        return Double(maxAbs) > 0 ? Double(maxAbs) : 1
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
