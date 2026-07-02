//
//  HealthDetailViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Self-contained segment- and channel-health detail / popover / badge views
//  extracted from WaveformView (REFACTOR.md L5). Pure presentation.
//

import SwiftUI

struct SegmentHealthBand: View {
    let result: SegmentHealthResult
    let showsMouseOverHealth: Bool
    @State private var showsDetails = false

    var body: some View {
        Rectangle()
            .fill(result.grade.color.opacity(result.grade.segmentOverlayOpacity))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(result.grade.color.opacity(0.28))
                    .frame(width: result.grade == .good ? 0 : 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                guard showsMouseOverHealth else {
                    showsDetails = false
                    return
                }
                showsDetails = hovering
            }
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                SegmentHealthPopover(result: result)
            }
            .onChange(of: showsMouseOverHealth) { _, isEnabled in
                if !isEnabled {
                    showsDetails = false
                }
            }
            .accessibilityLabel("Segment health \(result.goodPercentage) percent good")
    }
}

struct SegmentHealthDetailsView: View {
    let results: [SegmentHealthResult]
    let isAnalyzing: Bool
    let progress: Double
    let statusMessage: String?
    let onRefresh: () -> Void
    let onSave: () -> Void
    let onJump: (SegmentHealthResult) -> Void
    let onClose: () -> Void

    private var gradeCounts: [(ChannelHealthGrade, Int)] {
        ChannelHealthGrade.allHealthGrades.map { grade in
            (grade, results.filter { $0.grade == grade }.count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Segment Health")
                        .font(.title3.weight(.semibold))
                    Text("\(results.count) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    ForEach(gradeCounts, id: \.0) { grade, count in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(grade.color)
                                .frame(width: 8, height: 8)
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if isAnalyzing {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isAnalyzing)

                Button {
                    onSave()
                } label: {
                    Label("Save Metrics JSON...", systemImage: "square.and.arrow.down")
                }
                .disabled(results.isEmpty || isAnalyzing)

                Button("Close") {
                    onClose()
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(spacing: 0) {
                SegmentHealthTableHeader()

                Divider()

                if results.isEmpty {
                    ContentUnavailableView(
                        "No Segment Health",
                        systemImage: "rectangle.split.3x1",
                        description: Text(isAnalyzing ? "Scoring segments..." : "Refresh to score the current signal.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results) { result in
                                SegmentHealthTableRow(
                                    result: result,
                                    onJump: {
                                        onJump(result)
                                    }
                                )
                                Divider()
                            }
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            }
        }
        .padding(20)
        .frame(minWidth: 880, minHeight: 520)
    }
}

struct SegmentHealthTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Segment")
                .frame(width: 78, alignment: .leading)
            Text("Category")
                .frame(width: 145, alignment: .leading)
            Text("Time")
                .frame(width: 170, alignment: .leading)
            Text("Health")
                .frame(width: 96, alignment: .leading)
            Text("Summary")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Jump")
                .frame(width: 64, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct SegmentHealthTableRow: View {
    let result: SegmentHealthResult
    let onJump: () -> Void
    @State private var showsDetails = false
    @State private var pinsDetails = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(result.segmentIndex + 1)")
                .font(.caption.monospacedDigit())
                .frame(width: 78, alignment: .leading)

            Text(result.category)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 145, alignment: .leading)

            Text(segmentTimeText(result))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)

            HStack(spacing: 6) {
                Circle()
                    .fill(result.grade.color)
                    .frame(width: 9, height: 9)
                Text("\(result.goodPercentage)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(result.grade.color)
            }
            .frame(width: 96, alignment: .leading)

            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onJump()
            } label: {
                Label("Jump", systemImage: "arrow.right.to.line")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Jump to this segment in the waveform viewer")
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHovered || pinsDetails ? result.grade.color.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                showsDetails = true
            } else if !pinsDetails {
                showsDetails = false
            }
        }
        .onTapGesture {
            pinsDetails.toggle()
            showsDetails = pinsDetails
        }
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            SegmentHealthPopover(result: result)
        }
        .onChange(of: showsDetails) { _, isShowing in
            if !isShowing {
                pinsDetails = false
            }
        }
    }

    private func segmentTimeText(_ result: SegmentHealthResult) -> String {
        let start = Self.formatSeconds(result.startTimeSeconds)
        let end = Self.formatSeconds(result.endTimeSeconds)
        return "\(start)-\(end)"
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remaining = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%05.2f", minutes, remaining)
        }
        return String(format: "%.2fs", seconds)
    }
}

struct SegmentHealthPopover: View {
    let result: SegmentHealthResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Segment \(result.segmentIndex + 1)")
                        .font(.headline)
                    Text(result.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(result.goodPercentage)% good")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(result.grade.color)
            }

            HStack(spacing: 8) {
                Text(segmentWindowText(result))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if result.contributingEpochCount > 1 {
                    Text("\(result.contributingEpochCount) epochs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.metrics) { metric in
                    SegmentHealthMetricRow(metric: metric)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func segmentWindowText(_ result: SegmentHealthResult) -> String {
        String(
            format: "%.2fs-%.2fs (%.2fs)",
            result.startTimeSeconds,
            result.endTimeSeconds,
            result.durationSeconds
        )
    }
}

struct SegmentHealthMetricRow: View {
    let metric: SegmentHealthMetric

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(metric.grade.color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(metric.grade.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(metric.grade.color)
                }
                Text(metric.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ChannelHealthBadge: View {
    let result: ChannelHealthResult?
    let isAnalyzing: Bool
    @State private var showsDetails = false
    @State private var pinsDetails = false

    var body: some View {
        Group {
            if let result {
                Circle()
                    .fill(result.grade.color)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                    }
            } else if isAnalyzing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 22, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill((result?.grade.color ?? Color.secondary).opacity(result == nil ? 0.06 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder((result?.grade.color ?? Color.secondary).opacity(result == nil ? 0.20 : 0.35), lineWidth: 0.75)
        )
        .onHover { hovering in
            guard result != nil else { return }
            if hovering {
                showsDetails = true
            } else if !pinsDetails {
                showsDetails = false
            }
        }
        .onTapGesture {
            guard result != nil else { return }
            pinsDetails.toggle()
            showsDetails = pinsDetails
        }
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            if let result {
                ChannelHealthPopover(result: result)
            }
        }
        .onChange(of: showsDetails) { _, isShowing in
            if !isShowing {
                pinsDetails = false
            }
        }
        .accessibilityLabel(result.map { "Channel health \($0.goodPercentage) percent good" } ?? "Channel health pending")
    }
}

private enum ChannelHealthSort: String, CaseIterable, Identifiable {
    case lowestGoodness = "Lowest First"
    case highestGoodness = "Highest First"
    case channel = "Channel"

    var id: String { rawValue }
}

struct ChannelHealthDetailsView: View {
    let results: [ChannelHealthResult]
    let isAnalyzing: Bool
    let progress: Double
    let statusMessage: String?
    let onRefresh: () -> Void
    @Binding var waveletFamily: WaveletCleaningFamily
    @Binding var waveletLevelCount: Int
    @Binding var waveletThresholdModel: WaveletCleaningThresholdModel
    @Binding var waveletThresholdRule: WaveletCleaningThresholdRule
    @Binding var waveletDownsampleRate: Double
    @Binding var waveletCleaningMode: WaveletCleaningMode
    @Binding var waveletIntensity: Double
    let onRunWavelets: () -> Void
    let onClose: () -> Void

    @State private var sort = ChannelHealthSort.lowestGoodness
    @State private var showsWaveletOptions = false

    private var sortedResults: [ChannelHealthResult] {
        switch sort {
        case .lowestGoodness:
            return results.sorted {
                if $0.goodPercentage == $1.goodPercentage {
                    return $0.channelIndex < $1.channelIndex
                }
                return $0.goodPercentage < $1.goodPercentage
            }
        case .highestGoodness:
            return results.sorted {
                if $0.goodPercentage == $1.goodPercentage {
                    return $0.channelIndex < $1.channelIndex
                }
                return $0.goodPercentage > $1.goodPercentage
            }
        case .channel:
            return results.sorted { $0.channelIndex < $1.channelIndex }
        }
    }

    private var gradeCounts: [(ChannelHealthGrade, Int)] {
        ChannelHealthGrade.allHealthGrades.map { grade in
            (grade, results.filter { $0.grade == grade }.count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Channel Goodness")
                        .font(.title3.weight(.semibold))
                    Text("\(results.count) channels scored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Sort", selection: $sort) {
                    ForEach(ChannelHealthSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .labelsHidden()
                .frame(width: 145)

                Button("Refresh", action: onRefresh)
                    .disabled(isAnalyzing)

                Button("Wavelet...") { showsWaveletOptions = true }
                    .disabled(isAnalyzing)
                    .popover(isPresented: $showsWaveletOptions, arrowEdge: .bottom) {
                        WaveletRunPopover(
                            family: $waveletFamily,
                            levelCount: $waveletLevelCount,
                            thresholdModel: $waveletThresholdModel,
                            thresholdRule: $waveletThresholdRule,
                            downsampleRate: $waveletDownsampleRate,
                            cleaningMode: $waveletCleaningMode,
                            intensity: $waveletIntensity,
                            isAnalyzing: isAnalyzing,
                            onRun: {
                                showsWaveletOptions = false
                                onRunWavelets()
                            }
                        )
                    }

                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                ForEach(gradeCounts, id: \.0) { grade, count in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(grade.color)
                            .frame(width: 8, height: 8)
                        Text("\(grade.displayName) \(count)")
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(grade.color.opacity(0.10))
                    )
                }

                Spacer()
            }

            if isAnalyzing {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if sortedResults.isEmpty {
                Spacer()
                Text("No channel goodness metrics yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                        GridRow {
                            Text("Ch")
                            Text("Good")
                            Text("Grade")
                            Text("Summary")
                            Text("Weakest Metrics")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ForEach(sortedResults) { result in
                            GridRow {
                                Text("\(result.channelIndex + 1)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                Text("\(result.goodPercentage)%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(result.grade.color)
                                Text(result.grade.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(result.grade.color)
                                Text(result.summary)
                                    .font(.caption)
                                    .lineLimit(2)
                                Text(weakestMetricText(result))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 760, idealWidth: 880, minHeight: 520, idealHeight: 640)
    }

    private func weakestMetricText(_ result: ChannelHealthResult) -> String {
        result.metrics.prefix(3).map {
            "\($0.name) \(Int(($0.score * 100).rounded()))%"
        }
        .joined(separator: " | ")
    }
}

struct WaveletRunPopover: View {
    @Binding var family: WaveletCleaningFamily
    @Binding var levelCount: Int
    @Binding var thresholdModel: WaveletCleaningThresholdModel
    @Binding var thresholdRule: WaveletCleaningThresholdRule
    @Binding var downsampleRate: Double
    @Binding var cleaningMode: WaveletCleaningMode
    @Binding var intensity: Double
    let isAnalyzing: Bool
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wavelet Channel Burden")
                .font(.headline)
            Text("Scores each channel by its multiscale transient (artifact) burden using an undecimated wavelet decomposition.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Wavelet")
                    Picker("", selection: $family) {
                        ForEach(WaveletCleaningFamily.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                GridRow {
                    Text("Cleaning mode")
                    Picker("", selection: $cleaningMode) {
                        ForEach(WaveletCleaningMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                GridRow {
                    Text("Threshold model")
                    Picker("", selection: $thresholdModel) {
                        ForEach(WaveletCleaningThresholdModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                GridRow {
                    Text("Threshold rule")
                    Picker("", selection: $thresholdRule) {
                        ForEach(WaveletCleaningThresholdRule.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                GridRow {
                    Text("Levels")
                    Stepper("\(levelCount)", value: $levelCount, in: 1...WaveletArtifactAnalyzer.maximumLevelCount)
                        .frame(width: 110)
                }
                GridRow {
                    Text("Intensity")
                    TextField("x", value: $intensity, format: .number.precision(.fractionLength(2)))
                        .frame(width: 80)
                }
                GridRow {
                    Text("Downsample (Hz)")
                    TextField("Hz", value: $downsampleRate, format: .number.precision(.fractionLength(0)))
                        .frame(width: 80)
                }
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Run", action: onRun)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAnalyzing)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct ChannelHealthPopover: View {
    let result: ChannelHealthResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ch \(result.channelIndex + 1)")
                    .font(.headline)
                Spacer()
                Text("\(result.goodPercentage)% good")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(result.grade.color)
            }

            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.metrics) { metric in
                    ChannelHealthMetricRow(metric: metric)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}

struct ChannelHealthMetricRow: View {
    let metric: ChannelHealthMetric

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(metric.grade.color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(metric.grade.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(metric.grade.color)
                }
                Text(metric.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension ChannelHealthGrade {
    static var allHealthGrades: [ChannelHealthGrade] {
        [.good, .watch, .poor]
    }

    var color: Color {
        switch self {
        case .good: return .green
        case .watch: return .yellow
        case .poor: return .red
        }
    }

    var segmentOverlayOpacity: Double {
        switch self {
        case .good: return 0.08
        case .watch: return 0.11
        case .poor: return 0.12
        }
    }
}
