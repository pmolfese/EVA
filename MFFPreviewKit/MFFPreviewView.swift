//
//  MFFPreviewView.swift
//  MFFPreviewKit
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The QuickLook preview panel. Three bands, in decreasing order of how fast they
//  can be read: identity and headline numbers, then the type-specific picture,
//  then the details grid and file-manifest chips.
//

import SwiftUI

struct MFFPreviewView: View {
    let summary: MFFQuickLookSummary

    var body: some View {
        ScrollView {
            MFFPreviewContent(summary: summary)
        }
    }
}

/// The panel body without the surrounding scroll view. Split out so it can be
/// laid out and snapshotted directly -- `ImageRenderer` cannot size a
/// `ScrollView`, so rendering `MFFPreviewView` yields a blank image.
struct MFFPreviewContent: View {
    let summary: MFFQuickLookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            identityBand
            tileRow
            Divider()
            typeSpecificSection
            Divider()
            detailGrid
            chips
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Identity

    private var identityBand: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(summary.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Badge(text: summary.fileType.displayName, tint: .accentColor)
                if let version = summary.mffVersion {
                    Badge(text: "MFF v\(version)", tint: .secondary)
                }
                // eva.xml means EVA has processed this package. Worth saying up
                // front rather than as one manifest chip among many.
                if summary.manifest.hasEVAScript {
                    Badge(text: "EVA", tint: .orange)
                }
            }
            Text(identityLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var identityLine: String {
        var parts: [String] = []
        if let recordTime = summary.recordTime {
            parts.append(recordTime.formatted(date: .abbreviated, time: .shortened))
        }
        if let amplifier = summary.amplifier { parts.append(amplifier) }
        if let version = summary.acquisitionVersion { parts.append("Net Station \(version)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tiles

    private var tileRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            Tile(label: "Duration", value: durationText)
            Tile(label: "Channels", value: channelText)
            Tile(label: "Rate", value: rateText)
            Tile(label: headlineCountLabel, value: headlineCountText)
            Tile(label: "Size", value: sizeText)
        }
    }

    private var durationText: String {
        guard let seconds = summary.durationSeconds else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var channelText: String {
        guard let count = summary.channelCount else { return "—" }
        if let pns = summary.pnsChannelCount, pns > 0 { return "\(count) +\(pns)" }
        return "\(count)"
    }

    private var rateText: String {
        guard let rate = summary.samplingRate else { return "—" }
        return "\(Int(rate)) Hz"
    }

    private var headlineCountLabel: String {
        switch summary.fileType {
        case .continuous: return "Events"
        case .segmented: return "Segments"
        case .averaged: return "Conditions"
        case .grandAverage: return "Subjects"
        }
    }

    private var headlineCountText: String {
        switch summary.fileType {
        case .continuous:
            return "\(summary.continuousDetail?.totalEventCount ?? 0)"
        case .segmented:
            guard let detail = summary.segmentedDetail else { return "—" }
            return "\(detail.kept + detail.rejected)"
        case .averaged:
            return "\(summary.averagedDetail?.conditions.count ?? 0)"
        case .grandAverage:
            return "\(summary.averagedDetail?.subjects.count ?? 0)"
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: summary.byteSize, countStyle: .file)
    }

    // MARK: - Type-specific

    @ViewBuilder
    private var typeSpecificSection: some View {
        HStack(alignment: .top, spacing: 20) {
            if !summary.sensors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.layoutName ?? "Sensor layout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    SensorCapView(
                        sensors: summary.sensors,
                        badChannels: summary.badChannels,
                        impedance: summary.impedance
                    )
                    .frame(width: 140, height: 150)

                    if let impedance = summary.impedance {
                        ImpedanceLegend(impedance: impedance)
                    } else {
                        Text("No impedance recorded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !summary.badChannels.isEmpty {
                        Text("\(summary.badChannels.count) flagged in analysis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                switch summary.fileType {
                case .continuous:
                    if let detail = summary.continuousDetail, !detail.tracks.isEmpty {
                        Text("Event timeline").font(.caption).foregroundStyle(.secondary)
                        EventTimelineView(
                            tracks: detail.tracks,
                            duration: summary.durationSeconds ?? 0
                        )
                    } else {
                        Text("No event tracks").font(.caption).foregroundStyle(.secondary)
                    }
                case .segmented:
                    if let detail = summary.segmentedDetail {
                        Text(detail.recordsRejections ? "Segments kept and rejected" : "Segments per condition")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SegmentedBarsView(detail: detail)
                        if !detail.recordsRejections {
                            Text("This package holds only the surviving segments — it records no rejection counts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .averaged, .grandAverage:
                    if let detail = summary.averagedDetail {
                        Text(detail.subjects.count > 1 ? "Contributing trials per cell" : "Contributing trials")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        AveragedGridView(detail: detail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Detail grid

    private var detailGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: 20)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(detailRows, id: \.0) { row in
                HStack {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1)
                }
                .font(.subheadline)
            }
        }
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let subject = summary.subjectID { rows.append(("Subject", subject)) }
        if let session = summary.sessionNumber { rows.append(("Session", session)) }
        rows.append(("Epochs", summary.epochCount == 1 ? "1 continuous" : "\(summary.epochCount)"))
        if let shift = summary.hardwareFilterShiftMicroseconds {
            rows.append(("HW filter shift", "\(shift / 1000) ms"))
        }
        if let trs = summary.trsPerVolume { rows.append(("MRI TRs/volume", "\(trs)")) }
        if let impedance = summary.impedance, let median = impedance.medianKOhm {
            rows.append(("Median impedance", "\(Int(median.rounded())) kΩ"))
        }
        if let detail = summary.segmentedDetail {
            // Only claim a retention figure when the file actually says what was
            // discarded; otherwise it is always a meaningless 100%.
            if detail.recordsRejections {
                rows.append(("Retention", "\(Int((detail.retention * 100).rounded()))%"))
            }
            if let length = detail.epochLengthSeconds {
                rows.append(("Epoch length", String(format: "%.2f s", length)))
            }
            if let baseline = detail.baselineSeconds, baseline > 0 {
                rows.append(("Baseline", "\(Int((baseline * 1000).rounded())) ms"))
            }
        }
        if let detail = summary.averagedDetail, !detail.sourceFiles.isEmpty {
            rows.append(("Source files", "\(detail.sourceFiles.count)"))
        }
        return rows
    }

    // MARK: - Chips

    private var chips: some View {
        FlowLayout(spacing: 6) {
            if summary.manifest.hasMRInfo {
                Chip(text: "MR gradient present", tint: .orange)
            }
            if let impedance = summary.impedance, impedance.poorCount > 0 {
                Chip(
                    text: "\(impedance.poorCount) over \(Int(MFFQuickLookSummary.Impedance.poorKOhm)) kΩ",
                    tint: .red
                )
            }
            if let detail = summary.segmentedDetail {
                ForEach(detail.faultHistogram.sorted(by: { $0.value > $1.value }), id: \.key) { fault in
                    Chip(text: "\(fault.key) \(fault.value)", tint: .red)
                }
            }
            if summary.manifest.hasPNS { Chip(text: "PNS signal", tint: .secondary) }
            if summary.manifest.hasCoordinates { Chip(text: "coordinates.xml", tint: .secondary) }
            if summary.manifest.hasHistory { Chip(text: "history.xml", tint: .secondary) }
            if let detail = summary.continuousDetail, !detail.tracks.isEmpty {
                Chip(
                    text: detail.tracks.count == 1 ? "1 event track" : "\(detail.tracks.count) event tracks",
                    tint: .secondary
                )
            }
        }
    }
}

// MARK: - Pieces

private struct Tile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

/// The cap picture. Positions come straight from `sensorLayout.xml`, so a 32-channel
/// net is visibly sparser than a 128.
private struct SensorCapView: View {
    let sensors: [MFFQuickLookSummary.Sensor]
    let badChannels: Set<Int>
    let impedance: MFFQuickLookSummary.Impedance?

    var body: some View {
        Canvas { context, size in
            let xs = sensors.map(\.x)
            let ys = sensors.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max(),
                  maxX > minX, maxY > minY else { return }

            let inset: CGFloat = 10
            let scale = min(
                (size.width - inset * 2) / (maxX - minX),
                (size.height - inset * 2) / (maxY - minY)
            )
            let originX = (size.width - (maxX - minX) * scale) / 2
            let originY = (size.height - (maxY - minY) * scale) / 2

            let head = CGRect(
                x: originX - 4,
                y: originY - 4,
                width: (maxX - minX) * scale + 8,
                height: (maxY - minY) * scale + 8
            )
            context.stroke(Path(ellipseIn: head), with: .color(.secondary), lineWidth: 1)

            for sensor in sensors {
                // Sensor y is in math coordinates (+y toward the nose, matching
                // SensorLayout in the app); Canvas y grows downward, so invert
                // here or the nose lands at the bottom.
                let point = CGPoint(
                    x: originX + (sensor.x - minX) * scale,
                    y: originY + (maxY - sensor.y) * scale
                )
                let dot = CGRect(x: point.x - 2.4, y: point.y - 2.4, width: 4.8, height: 4.8)
                let isFlagged = badChannels.contains(sensor.number)

                // Fill carries impedance, which is an at-acquisition measure.
                // Analysis-flagged channels are a different thing entirely, so
                // they get a ring rather than competing for the same colour --
                // unless there is no impedance at all, in which case the fill is
                // free to carry the flag.
                // A channel with no measured value takes the default colour
                // rather than a "missing" grey -- an unmeasured electrode is not
                // evidence of a bad one.
                let fill: Color
                if let band = impedance?.band(forChannel: sensor.number) {
                    fill = ImpedancePalette.color(for: band)
                } else if impedance == nil, isFlagged {
                    fill = .red
                } else {
                    fill = .teal
                }
                context.fill(Path(ellipseIn: dot), with: .color(fill))

                // A hairline halo, deliberately quiet: on a heavily edited file
                // most electrodes carry the flag, and a strong ring would bury
                // the impedance colour the cap exists to show.
                if isFlagged, impedance != nil {
                    context.stroke(Path(ellipseIn: dot.insetBy(dx: -1.1, dy: -1.1)),
                                   with: .color(.secondary.opacity(0.55)),
                                   lineWidth: 0.7)
                }
            }
        }
    }
}

enum ImpedancePalette {
    /// A deeper yellow than `Color.yellow`, which is close to invisible on the
    /// light preview background.
    static let caution = Color(red: 0.85, green: 0.62, blue: 0.05)

    static func color(for band: MFFQuickLookSummary.Impedance.Band) -> Color {
        switch band {
        case .ok: return .teal
        case .caution: return caution
        case .poor: return .red
        }
    }
}

private struct ImpedanceLegend: View {
    let impedance: MFFQuickLookSummary.Impedance

    private var caution: Int { Int(MFFQuickLookSummary.Impedance.cautionKOhm) }
    private var poor: Int { Int(MFFQuickLookSummary.Impedance.poorKOhm) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            swatch(.teal, "≤ \(caution) kΩ", impedance.measuredCount - impedance.cautionCount - impedance.poorCount)
            swatch(ImpedancePalette.caution, "\(caution)–\(poor) kΩ", impedance.cautionCount)
            swatch(.red, "> \(poor) kΩ", impedance.poorCount)
        }
    }

    private func swatch(_ color: Color, _ label: String, _ count: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(count)").font(.caption).foregroundStyle(count > 0 ? .primary : .secondary)
        }
        .frame(width: 130)
    }
}

/// One lane per event code, ticks placed by time. Shows at a glance whether a run
/// completed and whether the trial spacing looks sane.
private struct EventTimelineView: View {
    let tracks: [MFFQuickLookSummary.EventTrack]
    let duration: Double

    private var lanes: [(String, [Double], Int)] {
        var result: [(String, [Double], Int)] = []
        for track in tracks {
            for tally in track.codes.sorted(by: { $0.count > $1.count }) {
                result.append((tally.code, tally.times, tally.count))
            }
        }
        return Array(result.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                HStack(spacing: 8) {
                    Text(lane.0)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)
                    Canvas { context, size in
                        guard duration > 0 else { return }
                        for time in lane.1 {
                            // Event clocks can run a few microseconds ahead of
                            // the recording start, so clamp rather than drop --
                            // otherwise the run's first marker vanishes.
                            let x = min(max(size.width * CGFloat(time / duration), 0), size.width - 1.6)
                            let tick = CGRect(x: x, y: 0, width: 1.6, height: size.height)
                            context.fill(Path(roundedRect: tick, cornerRadius: 0.8), with: .color(.purple))
                        }
                    }
                    .frame(height: 11)
                    Text("\(lane.2)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            if tracks.contains(where: \.truncated) {
                Text("timeline truncated")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SegmentedBarsView: View {
    let detail: MFFQuickLookSummary.SegmentedDetail

    private var maxTotal: Int {
        max(detail.conditions.map(\.total).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(detail.conditions) { condition in
                HStack(spacing: 8) {
                    Text(condition.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { proxy in
                        let unit = proxy.size.width / CGFloat(maxTotal)
                        HStack(spacing: 1) {
                            Rectangle()
                                .fill(.teal)
                                .frame(width: unit * CGFloat(condition.kept))
                            if detail.recordsRejections {
                                Rectangle()
                                    .fill(.red)
                                    .frame(width: unit * CGFloat(condition.rejected))
                            }
                            Spacer(minLength: 0)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .frame(height: 13)
                    Text(detail.recordsRejections
                         ? "\(condition.kept) / \(condition.rejected)"
                         : "\(condition.kept)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }
}

/// Condition-by-subject contribution counts. A subject who contributed thin
/// across the board is the thing worth catching before it silently weights a
/// group ERP.
private struct AveragedGridView: View {
    let detail: MFFQuickLookSummary.AveragedDetail

    private var subjectKeys: [String] {
        detail.subjects.isEmpty ? [""] : detail.subjects
    }

    private var maxTrials: Int {
        max(detail.trialsPerCell.values.flatMap(\.values).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(detail.conditions, id: \.self) { condition in
                HStack(spacing: 3) {
                    Text(condition)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                        .lineLimit(1)
                    ForEach(subjectKeys, id: \.self) { subject in
                        let trials = detail.trialsPerCell[condition]?[subject]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(trials == nil
                                  ? Color.secondary.opacity(0.12)
                                  : Color.blue.opacity(0.25 + 0.75 * Double(trials ?? 0) / Double(maxTrials)))
                            .frame(height: 14)
                            .overlay {
                                if subjectKeys.count <= 8, let trials {
                                    Text("\(trials)").font(.system(size: 9))
                                }
                            }
                    }
                }
            }
            if detail.subjects.count > 1 {
                Text("\(detail.subjects.count) subjects")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Wraps chips onto as many rows as the width needs.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
