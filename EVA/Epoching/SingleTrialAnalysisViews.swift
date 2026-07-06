//
//  SingleTrialAnalysisViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Sheet UI for "Single Trial Analysis": after a PSA segmentation + average,
//  drag-select a time window on the (still all-channels, butterfly-style)
//  averaged trace, pick a channel or channel-set (ROI), and extract per-trial
//  peak/amplitude measures from the raw pre-average epochs
//  (`segmentedEpochSignal`/`segmentedEpochSegments`) via `SingleTrialAnalyzer`.
//
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

extension WaveformView {
    func singleTrialAnalysisSheet() -> some View {
        SingleTrialAnalysisSheet(
            viewModel: singleTrial,
            averagedSignal: epoching.epochedSignal,
            averagedSegments: epoching.epochSegments,
            rawSignal: segmentedEpochSignal,
            rawSegments: segmentedEpochSegments,
            categories: overlayAvailableCategories(),
            channelSets: ChannelSetStore.shared.allSets,
            hiddenChannels: channels.hidden,
            amplitudeScale: amplitudeScale,
            channelName: { [epoching] index in
                guard let signal = epoching.epochedSignal else { return "Ch \(index + 1)" }
                return self.eegChannelDisplayName(index: index, signal: signal)
            },
            categoryColor: { [epoching] category in
                guard let segment = epoching.epochSegments.first(where: { $0.category == category }) else {
                    return .accentColor
                }
                return self.epochColor(for: segment.colorIndex)
            },
            onClose: { singleTrial.showsSheet = false }
        )
    }
}

struct SingleTrialAnalysisSheet: View {
    @ObservedObject var viewModel: SingleTrialAnalysisViewModel
    let averagedSignal: MFFSignalData?
    let averagedSegments: [EpochSegment]
    let rawSignal: MFFSignalData?
    let rawSegments: [EpochSegment]
    let categories: [String]
    let channelSets: [ChannelSet]
    let hiddenChannels: Set<Int>
    let amplitudeScale: Double
    let channelName: (Int) -> String
    let categoryColor: (String) -> Color
    let onClose: () -> Void

    private enum ResultTab: String, CaseIterable, Identifiable {
        case trials = "Per-Trial Values"
        case splits = "Split Comparison"
        case distribution = "Trial Distribution"
        var id: String { rawValue }
    }

    @State private var resultTab = ResultTab.trials

    private var averagedSegment: EpochSegment? {
        guard let category = viewModel.selectedCategory else { return nil }
        return averagedSegments.first { $0.category == category }
    }

    private var selectedChannelIndices: [Int] {
        switch viewModel.channelScope {
        case .singleChannel:
            guard let index = viewModel.selectedChannelIndex else { return [] }
            return [index]
        case .channelSet:
            guard let id = viewModel.selectedChannelSetID,
                  let set = channelSets.first(where: { $0.id == id }) else { return [] }
            return set.channelIndices
        }
    }

    private var canRun: Bool {
        guard viewModel.hasWindow, averagedSegment != nil, !selectedChannelIndices.isEmpty,
              let category = viewModel.selectedCategory,
              rawSegments.contains(where: { $0.category == category }) else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    selectionControls
                    windowPicker
                    parameterControls
                    runBar

                    if let result = viewModel.result {
                        Divider()
                        resultsSection(result)
                    } else if let statusMessage = viewModel.statusMessage {
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1020, minHeight: 680, idealHeight: 760)
        .onAppear {
            if viewModel.selectedCategory == nil {
                viewModel.selectedCategory = categories.first
            }
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Single Trial Analysis")
                    .font(.title3.weight(.semibold))
                Text("Extract per-trial peak/amplitude values from the segmented epochs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let signal = rawSignal {
                Text("\(rawSegments.count) trials · \(format(signal.samplingRate)) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            if viewModel.result != nil {
                Button("Export Trial Matrix…") { exportTrialMatrix() }
            }
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Selection controls

    private var selectionControls: some View {
        HStack(spacing: 16) {
            Picker("Category", selection: $viewModel.selectedCategory) {
                ForEach(categories, id: \.self) { category in
                    Text(category).tag(String?.some(category))
                }
            }
            .frame(width: 220)

            Picker("Scope", selection: $viewModel.channelScope) {
                ForEach(SingleTrialChannelScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .frame(width: 240)

            if viewModel.channelScope == .singleChannel {
                Picker("Channel", selection: $viewModel.selectedChannelIndex) {
                    Text("—").tag(Int?.none)
                    ForEach(0..<(averagedSignal?.numberOfChannels ?? 0), id: \.self) { index in
                        Text(channelName(index)).tag(Int?.some(index))
                    }
                }
                .frame(width: 200)
            } else {
                Picker("Channel Set", selection: $viewModel.selectedChannelSetID) {
                    Text("—").tag(ChannelSet.ID?.none)
                    ForEach(channelSets) { set in
                        Text(set.name).tag(ChannelSet.ID?.some(set.id))
                    }
                }
                .frame(width: 200)
            }

            Spacer()
        }
    }

    // MARK: - Window picker (drag-select on the butterfly trace)

    @ViewBuilder
    private var windowPicker: some View {
        if let signal = averagedSignal, let segment = averagedSegment {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Drag on the trace to select the analysis window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.hasWindow, let start = viewModel.windowStartMs, let end = viewModel.windowEndMs {
                        Text("\(Int(start.rounded())) – \(Int(end.rounded())) ms")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
                SingleTrialWindowPicker(
                    data: signal.data,
                    segment: segment,
                    hiddenChannels: hiddenChannels,
                    amplitudeScale: amplitudeScale,
                    color: categoryColor(segment.category),
                    samplingRate: signal.samplingRate,
                    windowStartMs: $viewModel.windowStartMs,
                    windowEndMs: $viewModel.windowEndMs
                )
                .frame(height: 180)
            }
        } else {
            Text("No averaged epoch available for this category yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Parameters

    private var parameterControls: some View {
        HStack(spacing: 20) {
            labeledField("Adaptive ± ms", value: $viewModel.adaptiveHalfWidthMs, width: 70)
            labeledStepper("Split groups", value: $viewModel.splitCount, range: 2...8)
            labeledField("Outlier SD", value: $viewModel.outlierThresholdSD, width: 60)
            labeledStepper("Distribution chunks", value: $viewModel.distributionChunkCount, range: 1...12)
        }
    }

    private func labeledField(_ label: String, value: Binding<Double>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    private func labeledStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Stepper("\(value.wrappedValue)", value: value, in: range)
                .frame(width: 130)
        }
    }

    // MARK: - Run

    private var runBar: some View {
        HStack {
            Button("Run Analysis") { runAnalysis() }
                .disabled(!canRun)
                .keyboardShortcut(.defaultAction)
            if !canRun {
                Text("Pick a category, channel/ROI, and drag a window on the trace above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func runAnalysis() {
        guard let category = viewModel.selectedCategory,
              let averageSignal = averagedSignal,
              let averageSegment = averagedSegment,
              let rawSignal,
              !selectedChannelIndices.isEmpty else { return }

        let averageSamples = channelResolvedSamples(
            signal: averageSignal, startSample: averageSegment.startSample,
            endSample: averageSegment.endSample, channels: selectedChannelIndices
        )

        let trials: [SingleTrialAnalyzer.TrialInput] = rawSegments
            .filter { $0.category == category }
            .map { segment in
                SingleTrialAnalyzer.TrialInput(
                    sourceTimeSeconds: segment.sourceTimeSeconds,
                    stimulusOffsetSamples: segment.stimulusOffsetSamples,
                    samples: channelResolvedSamples(
                        signal: rawSignal, startSample: segment.startSample,
                        endSample: segment.endSample, channels: selectedChannelIndices
                    )
                )
            }

        let result = SingleTrialAnalyzer.analyze(
            averageSamples: averageSamples,
            averageStimulusOffsetSamples: averageSegment.stimulusOffsetSamples,
            samplingRate: averageSignal.samplingRate,
            trials: trials,
            windowStartMs: viewModel.windowStartMs ?? 0,
            windowEndMs: viewModel.windowEndMs ?? 0,
            adaptiveHalfWidthMs: viewModel.adaptiveHalfWidthMs,
            splitCount: viewModel.splitCount,
            outlierThresholdSD: viewModel.outlierThresholdSD,
            distributionChunkCount: viewModel.distributionChunkCount
        )

        viewModel.result = result
        viewModel.statusMessage = result == nil ? "Could not compute a result for this window." : nil
    }

    /// Mean across `channels` at each sample in `startSample...endSample`; a
    /// single-element `channels` array is just that channel's raw trace.
    private func channelResolvedSamples(signal: MFFSignalData, startSample: Int, endSample: Int, channels: [Int]) -> [Float] {
        guard endSample >= startSample, startSample >= 0 else { return [] }
        let validChannels = channels.filter { signal.data.indices.contains($0) }
        guard !validChannels.isEmpty else { return [] }
        let length = endSample - startSample + 1
        var result = [Float](repeating: 0, count: length)
        for channel in validChannels {
            let series = signal.data[channel]
            guard endSample < series.count else { continue }
            for i in 0..<length {
                result[i] += series[startSample + i]
            }
        }
        let divisor = Float(validChannels.count)
        for i in 0..<length { result[i] /= divisor }
        return result
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsSection(_ result: SingleTrialAnalyzer.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                if let positive = result.averagePeakLatencyPositiveMs {
                    Text("Avg peak (+): \(Int(positive.rounded())) ms").font(.caption.monospacedDigit())
                }
                if let negative = result.averagePeakLatencyNegativeMs {
                    Text("Avg peak (−): \(Int(negative.rounded())) ms").font(.caption.monospacedDigit())
                }
                Text("\(result.trials.count) trials analyzed").font(.caption).foregroundStyle(.secondary)
                let outliers = result.trials.filter(\.isOutlier).count
                if outliers > 0 {
                    Text("\(outliers) outlier(s) flagged").font(.caption).foregroundStyle(.orange)
                }
            }

            Picker("", selection: $resultTab) {
                ForEach(ResultTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            switch resultTab {
            case .trials: trialsTable(result)
            case .splits: splitsView(result)
            case .distribution: distributionView(result)
            }
        }
    }

    private func trialsTable(_ result: SingleTrialAnalyzer.Result) -> some View {
        Table(result.trials) {
            TableColumn("#") { Text("\($0.trialIndex + 1)") }.width(30)
            TableColumn("Time (s)") { Text(String(format: "%.1f", $0.sourceTimeSeconds)) }.width(60)
            TableColumn("Mean") { Text(String(format: "%.2f", $0.meanAmplitude)) }.width(60)
            TableColumn("Peak@Avg (+/−)") {
                Text(String(format: "%.2f / %.2f", $0.peakAmplitudeAtAverageLatencyPositive, $0.peakAmplitudeAtAverageLatencyNegative))
            }.width(110)
            TableColumn("Peak (own) + @ ms") {
                Text(String(format: "%.2f @ %.0f", $0.peakAmplitudeOwnLatencyPositive, $0.peakLatencyOwnPositiveMs))
            }.width(110)
            TableColumn("Peak (own) − @ ms") {
                Text(String(format: "%.2f @ %.0f", $0.peakAmplitudeOwnLatencyNegative, $0.peakLatencyOwnNegativeMs))
            }.width(110)
            TableColumn("Adaptive (+/−)") {
                Text(String(format: "%.2f / %.2f", $0.adaptiveMeanAmplitudePositive, $0.adaptiveMeanAmplitudeNegative))
            }.width(110)
            TableColumn("P2P") { Text(String(format: "%.2f", $0.peakToPeakAmplitude)) }.width(60)
            TableColumn("") { row in
                if row.isOutlier {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }.width(24)
        }
        .frame(height: 320)
    }

    private func splitsView(_ result: SingleTrialAnalyzer.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(result.splitGroups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.label) — \(group.trialCount) trials")
                        .font(.subheadline.weight(.semibold))
                    ForEach(group.stats.keys.sorted(), id: \.self) { key in
                        if let stat = group.stats[key] {
                            HStack {
                                Text(key).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.2f ± %.2f", stat.mean, stat.sd))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func distributionView(_ result: SingleTrialAnalyzer.Result) -> some View {
        Chart(result.distribution) { chunk in
            BarMark(
                x: .value("Window", chunk.label),
                y: .value("Retained Trials", chunk.retainedTrialCount)
            )
        }
        .frame(height: 220)
    }

    // MARK: - Export

    private func exportTrialMatrix() {
        guard let result = viewModel.result else { return }
        var lines = [
            "Trial\tTimeSeconds\tMean\tPeakAtAvgLatencyPositive\tPeakAtAvgLatencyNegative\t"
                + "PeakOwnLatencyPositive\tPeakLatencyPositiveMs\tPeakOwnLatencyNegative\tPeakLatencyNegativeMs\t"
                + "AdaptiveMeanPositive\tAdaptiveMeanNegative\tPeakToPeak\tOutlier"
        ]
        for trial in result.trials {
            lines.append([
                "\(trial.trialIndex + 1)",
                String(format: "%.3f", trial.sourceTimeSeconds),
                String(format: "%.4f", trial.meanAmplitude),
                String(format: "%.4f", trial.peakAmplitudeAtAverageLatencyPositive),
                String(format: "%.4f", trial.peakAmplitudeAtAverageLatencyNegative),
                String(format: "%.4f", trial.peakAmplitudeOwnLatencyPositive),
                String(format: "%.1f", trial.peakLatencyOwnPositiveMs),
                String(format: "%.4f", trial.peakAmplitudeOwnLatencyNegative),
                String(format: "%.1f", trial.peakLatencyOwnNegativeMs),
                String(format: "%.4f", trial.adaptiveMeanAmplitudePositive),
                String(format: "%.4f", trial.adaptiveMeanAmplitudeNegative),
                String(format: "%.4f", trial.peakToPeakAmplitude),
                trial.isOutlier ? "1" : "0"
            ].joined(separator: "\t"))
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "SingleTrialValues (\(viewModel.selectedCategory ?? "category")).tsv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

/// Drag-select overlay on a full-channel butterfly trace, matching the look
/// of the existing Butterfly panel (`ButterflyConditionPlot`) but adding a
/// range (not single-point) selection independent from the topomap scrubber.
private struct SingleTrialWindowPicker: View {
    let data: [[Float]]
    let segment: EpochSegment
    let hiddenChannels: Set<Int>
    let amplitudeScale: Double
    let color: Color
    let samplingRate: Double
    @Binding var windowStartMs: Double?
    @Binding var windowEndMs: Double?

    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?

    private var epochLength: Int {
        max(segment.endSample - segment.startSample + 1, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ButterflyConditionPlot(
                    data: data,
                    segment: segment,
                    hiddenChannels: hiddenChannels,
                    amplitudeScale: amplitudeScale,
                    color: color
                )
                if let rect = selectionRect(in: proxy.size) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStartX == nil { dragStartX = value.startLocation.x }
                        dragCurrentX = value.location.x
                        updateWindow(width: proxy.size.width)
                    }
                    .onEnded { _ in
                        dragStartX = nil
                        dragCurrentX = nil
                    }
            )
        }
    }

    private func selectionRect(in size: CGSize) -> CGRect? {
        guard let windowStartMs, let windowEndMs, size.width > 0 else { return nil }
        let startSample = relativeSample(forMs: windowStartMs)
        let endSample = relativeSample(forMs: windowEndMs)
        let xScale = size.width / CGFloat(max(epochLength - 1, 1))
        let x0 = CGFloat(min(startSample, endSample)) * xScale
        let x1 = CGFloat(max(startSample, endSample)) * xScale
        return CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)
    }

    private func relativeSample(forMs ms: Double) -> Int {
        let sample = segment.stimulusOffsetSamples + Int((ms / 1000.0 * samplingRate).rounded())
        return min(max(sample, 0), epochLength - 1)
    }

    private func msFromRelativeSample(_ relativeSample: Int) -> Double {
        Double(relativeSample - segment.stimulusOffsetSamples) / samplingRate * 1000.0
    }

    private func updateWindow(width: CGFloat) {
        guard let dragStartX, let dragCurrentX, width > 0 else { return }
        let xScale = width / CGFloat(max(epochLength - 1, 1))
        let startSample = min(max(Int((dragStartX / xScale).rounded()), 0), epochLength - 1)
        let endSample = min(max(Int((dragCurrentX / xScale).rounded()), 0), epochLength - 1)
        windowStartMs = msFromRelativeSample(min(startSample, endSample))
        windowEndMs = msFromRelativeSample(max(startSample, endSample))
    }
}
