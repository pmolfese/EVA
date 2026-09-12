//
//  ABBABandTableView.swift
//  EVA
//

import SwiftUI

struct ABBABandTableView: View {
    let channel: LAVIChannelResult
    @Binding var selection: ABBABand.ID?

    var body: some View {
        Table(channel.bands, selection: $selection) {
            TableColumn("Band") { band in
                Text(band.canonicalName ?? "Unanchored")
            }
            TableColumn("Type") { band in
                Label(
                    band.direction.rawValue.capitalized,
                    systemImage: band.direction == .sustained ? "waveform.path" : "bolt.horizontal"
                )
                .foregroundStyle(band.direction == .sustained ? Color.blue : Color.orange)
            }
            TableColumn("Begin") { band in metric(band.beginFrequencyHz, suffix: " Hz") }
            TableColumn("End") { band in metric(band.endFrequencyHz, suffix: " Hz") }
            TableColumn("Peak") { band in metric(band.peakFrequencyHz, suffix: " Hz") }
            TableColumn("LAVI") { band in metric(band.peakLAVI, digits: 4) }
            TableColumn("Δ median") { band in
                Text(String(format: "%+.4f", band.deviationFromMedian)).monospacedDigit()
            }
            TableColumn("Inference") { band in
                Text(significance(band))
                    .foregroundStyle(band.isSignificant == true ? Color.primary : Color.secondary)
            }
            TableColumn("Margin") { band in
                Text(band.significanceMargin.map { String(format: "%+.4f", $0) } ?? "—")
                    .monospacedDigit()
            }
            TableColumn("Pairs") { band in
                let count = channel.validPairCounts.indices.contains(band.peakIndex)
                    ? channel.validPairCounts[band.peakIndex] : 0
                Text(count.formatted()).monospacedDigit()
            }
        }
        .overlay {
            if channel.bands.isEmpty {
                ContentUnavailableView(
                    "No ABBA regions",
                    systemImage: "waveform.slash",
                    description: Text("The channel has no finite, non-flat LAVI regions to classify.")
                )
            }
        }
    }

    private func metric(_ value: Double, digits: Int = 1, suffix: String = "") -> Text {
        Text(String(format: "%.*f%@", digits, value, suffix)).monospacedDigit()
    }

    private func significance(_ band: ABBABand) -> String {
        switch band.isSignificant {
        case true: return "Significant"
        case false: return "Not significant"
        case nil: return "Not computed"
        }
    }
}

struct LAVIMultiChannelMatrix: View {
    let channels: [LAVIChannelResult]
    let selectedChannelIndex: Int
    let onSelectChannel: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sensor × frequency LAVI")
                .font(.headline)
            Text("Each row is one analyzed channel; frequency increases logarithmically from left to right.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Canvas { context, size in
                guard !channels.isEmpty else { return }
                let rowHeight = size.height / CGFloat(channels.count)
                let columnCount = max(channels.first?.values.count ?? 0, 1)
                let columnWidth = size.width / CGFloat(columnCount)
                for (row, channel) in channels.enumerated() {
                    for column in channel.values.indices {
                        let value = channel.values[column]
                        let color = value.isFinite ? laviColor(value) : Color.gray.opacity(0.25)
                        context.fill(
                            Path(CGRect(
                                x: CGFloat(column) * columnWidth,
                                y: CGFloat(row) * rowHeight,
                                width: ceil(columnWidth + 0.2),
                                height: ceil(rowHeight + 0.2)
                            )),
                            with: .color(color)
                        )
                    }
                    if channel.channelIndex == selectedChannelIndex {
                        context.stroke(
                            Path(CGRect(x: 0, y: CGFloat(row) * rowHeight, width: size.width, height: rowHeight)),
                            with: .color(.primary),
                            lineWidth: 1.5
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard !channels.isEmpty else { return }
                let row = min(max(Int(location.y / max(260 / CGFloat(channels.count), 1)), 0), channels.count - 1)
                onSelectChannel(channels[row].channelIndex)
            }
            .frame(minHeight: 260)
            HStack {
                Text(channels.first?.frequenciesHz.first.map { String(format: "%.2f Hz", $0) } ?? "")
                Spacer()
                Text("LAVI 0")
                LinearGradient(colors: [.indigo.opacity(0.2), .cyan, .yellow], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 100, height: 8)
                Text("1")
                Spacer()
                Text(channels.first?.frequenciesHz.last.map { String(format: "%.2f Hz", $0) } ?? "")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func laviColor(_ value: Double) -> Color {
        let x = min(max(value, 0), 1)
        if x < 0.5 {
            return Color(red: 0.25 - 0.12 * x, green: 0.2 + 1.1 * x, blue: 0.55 + 0.5 * x)
        }
        return Color(red: 0.15 + 1.35 * (x - 0.5), green: 0.75 + 0.35 * (x - 0.5), blue: 0.8 - 1.4 * (x - 0.5))
    }
}

struct LAVISpectrumGallery: View {
    let channels: [LAVIChannelResult]
    @Binding var selectedChannelIndex: Int
    @Binding var selectedBandID: ABBABand.ID?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(channels, id: \.channelIndex) { channel in
                    Button {
                        selectedChannelIndex = channel.channelIndex
                        selectedBandID = channel.bands.first?.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.channelName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            LAVISpectrumView(result: channel, selectedBandID: $selectedBandID, compact: true)
                                .allowsHitTesting(false)
                        }
                        .padding(8)
                        .background(
                            channel.channelIndex == selectedChannelIndex
                                ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ABBADetectionRateSummary: View {
    let channels: [LAVIChannelResult]

    private struct Row: Identifiable {
        var name: String
        var direction: ABBADirection
        var detected: Int
        var significant: Int
        var total: Int
        var id: String { "\(name)-\(direction.rawValue)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detection rate")
                .font(.headline)
            ForEach(rows) { row in
                HStack {
                    Circle().fill(row.direction == .sustained ? Color.blue : Color.orange).frame(width: 7, height: 7)
                    Text(row.name).frame(width: 100, alignment: .leading)
                    ProgressView(value: Double(row.detected), total: Double(max(row.total, 1)))
                    Text("\(row.detected)/\(row.total)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                    Text("\(row.significant) significant")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .trailing)
                }
            }
        }
    }

    private var rows: [Row] {
        let keys = Set(channels.flatMap { channel in
            channel.bands.map { "\($0.canonicalName ?? "Unanchored")|\($0.direction.rawValue)" }
        })
        return keys.sorted().compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let direction = ABBADirection(rawValue: parts[1]) else { return nil }
            let matching = channels.compactMap { channel in
                channel.bands.first { ($0.canonicalName ?? "Unanchored") == parts[0] && $0.direction == direction }
            }
            return Row(
                name: parts[0], direction: direction, detected: matching.count,
                significant: matching.count { $0.isSignificant == true }, total: channels.count
            )
        }
    }
}
