//
//  FIFPreviewView.swift
//  EVAPreviewKit
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The FIF Quick Look panel, in the three bands the MFF preview established:
//  identity and headline numbers, then the picture, then the details.
//
//  What makes FIF different is that the picture depends on what the file *is*
//  (`FIFDocument.Kind`), and most of the answers are not recordings:
//
//  * recordings get the MFF treatment — sensor cap, event timeline, waveform,
//    and a per-condition butterfly for epoched and averaged files;
//  * a **head model** gets its shells sliced through the middle and drawn as
//    nested contours, sagittal and axial, which shows shape, nesting and mesh
//    density at a glance in a way a table of vertex counts never would;
//  * a **transform** gets its matrix plus the decomposition that makes it
//    readable — how far the head moved, in millimetres, and how far it turned;
//  * a **digitization** gets the point cloud from above and from the side, with
//    the fiducials marked, because the shape of the cloud is the information;
//  * everything else gets an honest structural outline rather than a shrug.
//

import SwiftUI
import simd

struct FIFPreviewView: View {
    let summary: FIFQuickLookSummary

    var body: some View {
        ScrollView { FIFPreviewContent(summary: summary) }
    }
}

/// The body without the scroll view, so `ImageRenderer` can size it for
/// thumbnails (it cannot size a `ScrollView`).
struct FIFPreviewContent: View {
    let summary: FIFQuickLookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identityBand
            tileRow
            Divider()
            picture
            if !summary.warnings.isEmpty {
                Divider()
                warnings
            }
            Divider()
            outlineStrip
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
                FIFBadge(text: summary.kind.displayName, tint: .accentColor)
                if summary.isCompressed { FIFBadge(text: "gzip", tint: .secondary) }
                if let solver = summary.headModel?.solver {
                    FIFBadge(text: solver == "mne" ? "MNE solver" : "OpenMEEG solver", tint: .orange)
                }
            }
            Text(identityLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var identityLine: String {
        var parts = ["FIF"]
        if let recording = summary.recording {
            if let date = recording.measurementDate {
                parts.append(date.formatted(date: .abbreviated, time: .shortened))
            }
            if let subject = recording.subject { parts.append(subject) }
        }
        if let model = summary.headModel { parts.append(model.frameName) }
        if let dig = summary.digitization { parts.append("\(dig.frameName) frame") }
        parts.append(byteText(summary.fileSizeBytes))
        return parts.joined(separator: " · ")
    }

    // MARK: - Tiles

    private var tileRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], alignment: .leading, spacing: 10) {
            if let recording = summary.recording {
                // For a segmented file the concatenated length is an artefact of
                // how EVA lays epochs out; the epoch window is the real number.
                if recording.content == .continuous {
                    FIFTile(label: "Duration", value: durationText(recording.durationSeconds))
                } else {
                    FIFTile(label: "Window", value: String(format: "%.0f ms", recording.traceSeconds * 1000))
                }
                FIFTile(label: "Channels", value: channelText(recording))
                FIFTile(label: "Rate", value: "\(Int(recording.samplingRate.rounded())) Hz")
                switch recording.content {
                case .continuous:
                    // Annotations are read from the whole file; stimulus edges
                    // only from the seconds this preview decoded. Counting them
                    // together would put a window-sized number under a
                    // whole-file label, so the tile reports the honest one.
                    FIFTile(label: recording.isTruncated ? "Annotations" : "Events",
                            value: "\(recording.isTruncated ? recording.markers.filter(\.isAnnotation).count : recording.markers.count)")
                case .epoched:
                    FIFTile(label: "Epochs", value: "\(recording.sampleCount / max(sampleCountPerSegment(recording), 1))")
                case .averaged:
                    FIFTile(label: "Conditions", value: "\(recording.conditions.count)")
                }
            } else if let model = summary.headModel {
                FIFTile(label: "Shells", value: "\(model.shells.count)")
                FIFTile(label: "Vertices", value: "\(model.shells.reduce(0) { $0 + $1.vertexCount })")
                FIFTile(label: "Triangles", value: "\(model.shells.reduce(0) { $0 + $1.triangleCount })")
                FIFTile(label: "Solution", value: model.hasSolution ? "\(model.solutionSize ?? 0)²" : "none")
            } else if let transform = summary.transform {
                FIFTile(label: "From", value: transform.fromFrame)
                FIFTile(label: "To", value: transform.toFrame)
                FIFTile(label: "Translation", value: String(format: "%.1f mm", simd_length(transform.translationMillimetres)))
                FIFTile(label: "Scale", value: String(format: "%.4f", transform.scale))
            } else if let dig = summary.digitization {
                FIFTile(label: "Points", value: "\(dig.points.count)")
                // The kind names are already correctly cased ("EEG", "LPA",
                // "nasion"); capitalizing them turns acronyms into "Eeg".
                ForEach(dig.counts.prefix(3), id: \.kind) { entry in
                    FIFTile(label: entry.kind, value: "\(entry.count)")
                }
            } else {
                FIFTile(label: "Blocks", value: "\(summary.outline.count)")
                FIFTile(label: "Tags", value: "\(summary.tagCount)")
                FIFTile(label: "Size", value: byteText(summary.fileSizeBytes))
            }
        }
    }

    private func sampleCountPerSegment(_ recording: FIFQuickLookSummary.Recording) -> Int {
        Int((recording.traceSeconds * recording.samplingRate).rounded())
    }

    private func channelText(_ recording: FIFQuickLookSummary.Recording) -> String {
        let extra = recording.peripheralChannelCount + recording.stimulusChannelCount
        return extra > 0 ? "\(recording.brainChannelCount) +\(extra)" : "\(recording.brainChannelCount)"
    }

    private func durationText(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - The picture

    @ViewBuilder
    private var picture: some View {
        if let recording = summary.recording {
            FIFRecordingPicture(recording: recording)
        } else if let model = summary.headModel {
            FIFHeadModelPicture(model: model)
        } else if let transform = summary.transform {
            FIFTransformPicture(transform: transform)
        } else if let dig = summary.digitization {
            FIFDigitizationPicture(digitization: dig)
        } else {
            FIFStructureOutline(summary: summary)
        }
    }

    // MARK: - Warnings and outline

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(summary.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var outlineStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            FIFFlowLayout(spacing: 6) {
                ForEach(summary.outline.prefix(10)) { block in
                    FIFChip(text: block.count > 1 ? "\(block.name) ×\(block.count)" : block.name)
                }
            }
            if let name = summary.largestTagName, let bytes = summary.largestTagBytes {
                Text("Largest tag: \(name), \(byteText(Int64(bytes)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Recording picture

private struct FIFRecordingPicture: View {
    let recording: FIFQuickLookSummary.Recording

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            if recording.channels.contains(where: { $0.direction != nil }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Montage").font(.caption).foregroundStyle(.secondary)
                    FIFSensorCapView(channels: recording.channels)
                        .frame(width: 132, height: 142)
                    Text(positionSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                switch recording.content {
                case .continuous:
                    // The preview reads the first seconds of a recording, not
                    // all of it, so the timeline covers what was read and says
                    // so — the tile above already gives the true duration.
                    if !recording.markers.isEmpty {
                        Text(windowLabel(recording))
                            .font(.caption).foregroundStyle(.secondary)
                        FIFEventTimeline(
                            markers: recording.markers.filter { $0.timeSeconds <= recording.traceSeconds },
                            duration: recording.traceSeconds)
                            .frame(height: 26)
                    }
                    Text(recording.isTruncated
                         ? "First \(Int(recording.traceSeconds.rounded())) s of \(Int(recording.durationSeconds.rounded())) s"
                         : "Whole recording")
                        .font(.caption).foregroundStyle(.secondary)
                    FIFWaveformStack(traces: recording.traces, amplitude: recording.amplitudeMicrovolts)
                        .frame(minHeight: 150)
                case .epoched, .averaged:
                    Text(recording.content == .averaged
                         ? "Condition averages, all channels"
                         : "Epochs averaged by condition, all channels")
                        .font(.caption).foregroundStyle(.secondary)
                    FIFButterflyRow(recording: recording)
                        .frame(minHeight: 150)
                }
                if !recording.projectorDescriptions.isEmpty {
                    Text("Projectors: \(recording.projectorDescriptions.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                filterLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func windowLabel(_ recording: FIFQuickLookSummary.Recording) -> String {
        recording.isTruncated
            ? "Events in the first \(Int(recording.traceSeconds.rounded())) s"
            : "Events over \(Int(recording.durationSeconds.rounded())) s"
    }

    private var positionSummary: String {
        let located = recording.channels.filter { $0.direction != nil }.count
        let bad = recording.channels.filter(\.isBad).count
        var parts = ["\(located) positioned"]
        if bad > 0 { parts.append("\(bad) bad") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var filterLine: some View {
        let high = recording.highpassHz.map { String(format: "%.1f", $0) }
        let low = recording.lowpassHz.map { String(format: "%.0f", $0) }
        if high != nil || low != nil {
            Text("Acquisition filters \(high ?? "0")–\(low ?? "∞") Hz")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The montage, projected the way a topographic map is: straight down, with the
/// nose up. Bad channels are hollow.
private struct FIFSensorCapView: View {
    let channels: [FIFQuickLookSummary.Recording.Channel]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().stroke(.secondary.opacity(0.35), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: side * 0.45, y: side * 0.03))
                    path.addLine(to: CGPoint(x: side * 0.5, y: -side * 0.03))
                    path.addLine(to: CGPoint(x: side * 0.55, y: side * 0.03))
                }
                .stroke(.secondary.opacity(0.35), lineWidth: 1)
                ForEach(channels) { channel in
                    if let direction = channel.direction {
                        // Azimuthal-equidistant: radius from the vertical angle,
                        // which keeps low electrodes from piling up at the rim.
                        let radius = acos(max(-1, min(1, direction.z))) / .pi
                        let horizontal = simd_length(SIMD2(direction.x, direction.y))
                        let unit = horizontal > 1e-9
                            ? SIMD2(direction.x / horizontal, direction.y / horizontal)
                            : SIMD2(0.0, 0.0)
                        let x = side * (0.5 + radius * unit.x * 0.92)
                        let y = side * (0.5 - radius * unit.y * 0.92)
                        Circle()
                            .strokeBorder(channel.isBad ? Color.orange : .clear, lineWidth: 1)
                            .background(Circle().fill(channel.isBad ? Color.clear : Color.accentColor.opacity(0.75)))
                            .frame(width: 5, height: 5)
                            .position(x: x, y: y)
                    }
                }
            }
            .frame(width: side, height: side)
        }
    }
}

private struct FIFEventTimeline: View {
    let markers: [FIFQuickLookSummary.Recording.Marker]
    let duration: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.5))
                ForEach(markers) { marker in
                    let x = duration > 0 ? proxy.size.width * marker.timeSeconds / duration : 0
                    Rectangle()
                        .fill(marker.isAnnotation ? Color.orange : Color.accentColor)
                        .frame(width: 1.5)
                        .position(x: x, y: proxy.size.height / 2)
                }
            }
        }
    }
}

/// Stacked single-channel traces, sharing one amplitude scale so the relative
/// sizes are true.
private struct FIFWaveformStack: View {
    let traces: [FIFQuickLookSummary.Recording.Trace]
    let amplitude: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(traces) { trace in
                HStack(spacing: 6) {
                    Text(trace.name)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                        .lineLimit(1)
                    FIFTracePath(values: trace.values, amplitude: amplitude)
                        .stroke(Color.accentColor, lineWidth: 0.8)
                        .frame(height: 16)
                }
            }
            Text(String(format: "full scale ±%.0f µV", amplitude))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// One butterfly per condition, side by side and on a shared scale.
private struct FIFButterflyRow: View {
    let recording: FIFQuickLookSummary.Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(recording.conditionTraces.enumerated().prefix(4)), id: \.offset) { index, traces in
                    VStack(spacing: 3) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.35))
                            // Stimulus onset, wherever tmin puts it.
                            if recording.traceSeconds > 0, recording.traceStartSeconds < 0 {
                                GeometryReader { proxy in
                                    let fraction = -recording.traceStartSeconds / recording.traceSeconds
                                    Rectangle()
                                        .fill(.secondary.opacity(0.5))
                                        .frame(width: 1)
                                        .position(x: proxy.size.width * fraction, y: proxy.size.height / 2)
                                }
                            }
                            ForEach(traces) { trace in
                                FIFTracePath(values: trace.values, amplitude: recording.amplitudeMicrovolts)
                                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 0.6)
                            }
                        }
                        .frame(height: 108)
                        Text(conditionName(index))
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(String(format: "%.0f to %.0f ms · full scale ±%.1f µV",
                        recording.traceStartSeconds * 1000,
                        (recording.traceStartSeconds + recording.traceSeconds) * 1000,
                        recording.amplitudeMicrovolts))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Names come from the trace order, not the alphabetically sorted condition
    /// list — indexing the wrong one silently swaps the labels on the panels.
    private func conditionName(_ index: Int) -> String {
        index < recording.conditionTraceNames.count
            ? recording.conditionTraceNames[index]
            : "condition \(index + 1)"
    }
}

private struct FIFTracePath: Shape {
    let values: [Float]
    let amplitude: Float

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, amplitude > 0 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let y = rect.midY - CGFloat(value / amplitude) * rect.height / 2
            let point = CGPoint(x: rect.minX + CGFloat(index) * step, y: min(max(y, rect.minY), rect.maxY))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

// MARK: - Head model picture

private struct FIFHeadModelPicture: View {
    let model: FIFQuickLookSummary.HeadModel

    private static let tints: [Color] = [.pink, .teal, .indigo, .brown]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    contourPanel(label: "Sagittal", contours: { $0.sagittal })
                    contourPanel(label: "Axial", contours: { $0.axial })
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.shells.enumerated()), id: \.offset) { index, shell in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.tints[index % Self.tints.count])
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(shell.name.prefix(1).uppercased() + shell.name.dropFirst()).font(.callout)
                            Text("σ \(conductivityText(shell.conductivity)) S/m · \(shell.vertexCount) vertices, \(shell.triangleCount) triangles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let approximation = model.approximation {
                    Text(model.hasSolution
                         ? "Solved (\(approximation))\(solutionSizeText)"
                         : "Geometry only (\(approximation))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Geometry only — no BEM solution in this file")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !failures.isEmpty {
                    ForEach(failures) { check in
                        Label("\(check.name): \(check.detail)", systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Label("Closed, nested, outward-oriented", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var failures: [FIFQuickLookSummary.HeadModel.Check] {
        model.checks.filter { $0.severity == "failure" }
    }

    private var solutionSizeText: String {
        guard let bytes = model.solutionBytes else { return "" }
        return " · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    private func conductivityText(_ value: Double) -> String {
        value < 0.01 ? String(format: "%.4f", value) : String(format: "%.2f", value)
    }

    private func contourPanel(label: String,
                              contours: @escaping (FIFQuickLookSummary.HeadModel.Shell) -> [FIFQuickLookSummary.HeadModel.Contour]) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85))
                ForEach(Array(model.shells.enumerated()), id: \.offset) { index, shell in
                    FIFContourShape(contours: contours(shell))
                        .stroke(Self.tints[index % Self.tints.count], lineWidth: 1)
                }
            }
            .frame(width: 136, height: 136)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct FIFContourShape: Shape {
    let contours: [FIFQuickLookSummary.HeadModel.Contour]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = rect.insetBy(dx: 6, dy: 6)
        for segment in contours {
            path.move(to: CGPoint(x: inset.minX + inset.width * segment.from.x,
                                  y: inset.minY + inset.height * segment.from.y))
            path.addLine(to: CGPoint(x: inset.minX + inset.width * segment.to.x,
                                     y: inset.minY + inset.height * segment.to.y))
        }
        return path
    }
}

// MARK: - Transform picture

private struct FIFTransformPicture: View {
    let transform: FIFQuickLookSummary.Transform

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(transform.fromFrame) → \(transform.toFrame)")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(0..<4, id: \.self) { row in
                        GridRow {
                            ForEach(0..<4, id: \.self) { column in
                                Text(cellText(row, column))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(minWidth: 52, alignment: .trailing)
                                    .foregroundStyle(row == 3 ? .secondary : .primary)
                            }
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 8) {
                // The matrix is the file; this is what it means.
                labelled("Translation",
                         String(format: "x %.1f · y %.1f · z %.1f mm",
                                transform.translationMillimetres.x,
                                transform.translationMillimetres.y,
                                transform.translationMillimetres.z))
                labelled("Rotation",
                         String(format: "roll %.1f° · pitch %.1f° · yaw %.1f°",
                                transform.rotationDegrees.x,
                                transform.rotationDegrees.y,
                                transform.rotationDegrees.z))
                labelled("Scale", String(format: "%.5f", transform.scale))
                Text(abs(transform.scale - 1) < 1e-4
                     ? "Rigid — no scaling, as a coregistration should be."
                     : "Scaled: this transform resizes as well as moves, which is what a template fit does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cellText(_ row: Int, _ column: Int) -> String {
        let value = transform.matrix[row][column]
        // The translation column is metres; showing it to 4 decimals is what
        // makes a 3 mm shift look like 0.003 instead of 0.
        return column == 3 && row < 3 ? String(format: "%.4f", value) : String(format: "%.4f", value)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Digitization picture

private struct FIFDigitizationPicture: View {
    let digitization: FIFQuickLookSummary.Digitization

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            projection(label: "From above") { $0.top }
            projection(label: "From the left") { $0.side }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(digitization.counts, id: \.kind) { entry in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.kind == "nasion" || entry.kind == "LPA" || entry.kind == "RPA"
                                  ? Color.orange : Color.accentColor)
                            .frame(width: 6, height: 6)
                        Text("\(entry.count) \(entry.kind)").font(.callout)
                    }
                }
                if let width = digitization.headWidthMillimetres {
                    Text(String(format: "Spans %.0f mm left to right", width))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(digitization.frameName) coordinates")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func projection(label: String,
                            point: @escaping (FIFQuickLookSummary.Digitization.Point) -> SIMD2<Double>) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.4))
                GeometryReader { proxy in
                    ForEach(digitization.points) { entry in
                        let position = point(entry)
                        Circle()
                            .fill(entry.isFiducial ? Color.orange : Color.accentColor.opacity(0.8))
                            .frame(width: entry.isFiducial ? 6 : 4, height: entry.isFiducial ? 6 : 4)
                            .position(x: proxy.size.width * position.x, y: proxy.size.height * position.y)
                    }
                }
            }
            .frame(width: 130, height: 130)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Fallback outline

/// For the FIF documents EVA has no dedicated picture for — forward and inverse
/// operators, source spaces, covariances, ICA decompositions. Saying what is
/// actually in the file beats an apologetic blank panel.
private struct FIFStructureOutline: View {
    let summary: FIFQuickLookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 24) {
                if !summary.values.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                        ForEach(summary.values) { value in
                            GridRow {
                                Text(value.name).font(.caption).foregroundStyle(.secondary)
                                Text(value.value).font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    ForEach(summary.outline.prefix(12)) { block in
                        GridRow {
                            Text(block.name).font(.caption)
                            Text(block.count > 1 ? "×\(block.count)" : "")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var headline: String {
        guard let advice = summary.kind.importAdvice else {
            return "EVA reads this file's structure but has no dedicated view for it yet."
        }
        return "This is \(summary.kind.nounWithArticle). \(advice)"
    }
}

// MARK: - Small components

private struct FIFTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FIFBadge: View {
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

private struct FIFChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.4), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// Wraps chips onto as many lines as they need.
private struct FIFFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
