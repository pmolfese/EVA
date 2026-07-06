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
//  UI for "Single Trial Analysis": after a PSA segmentation + average,
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
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension WaveformView {
    func singleTrialAnalysisWorkspace() -> some View {
        singleTrialAnalysisView(isEmbedded: true, onClose: nil)
    }

    func singleTrialAnalysisSheet() -> some View {
        singleTrialAnalysisView(isEmbedded: false, onClose: { singleTrial.showsSheet = false })
    }

    private func singleTrialAnalysisView(isEmbedded: Bool, onClose: (() -> Void)?) -> some View {
        SingleTrialAnalysisSheet(
            viewModel: singleTrial,
            averagedSignal: epoching.epochedSignal,
            averagedSegments: epoching.epochSegments,
            rawSignal: segmentedEpochSignal,
            rawSegments: segmentedEpochSegments,
            categories: overlayAvailableCategories(),
            channelSets: ChannelSetStore.shared.allSets,
            hiddenChannels: channels.hidden,
            amplitudeScale: Binding(
                get: { amplitudeScale },
                set: { amplitudeScale = $0 }
            ),
            averageReference: epoching.averageReference,
            baselineCorrected: epoching.baselineCorrected,
            badChannels: channels.bad,
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
            displayCategory: { [epoching] category in
                epoching.displayCategory(category)
            },
            figureFileName: { title in
                self.figureFileName(title)
            },
            isEmbedded: isEmbedded,
            onClose: onClose
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
    @Binding var amplitudeScale: Double
    let averageReference: Bool
    let baselineCorrected: Bool
    let badChannels: Set<Int>
    let channelName: (Int) -> String
    let categoryColor: (String) -> Color
    let displayCategory: (String) -> String
    let figureFileName: (String) -> String
    let isEmbedded: Bool
    let onClose: (() -> Void)?

    private enum ResultTab: String, CaseIterable, Identifiable {
        case trials = "Per-Trial Values"
        case splits = "Split Comparison"
        case distribution = "Trial Distribution"
        var id: String { rawValue }
    }

    @State private var resultTab = ResultTab.trials
    @State private var trialSortOrder: [KeyPathComparator<SingleTrialAnalyzer.SingleTrialValue>] = [KeyPathComparator(\.trialIndex)]
    private let amplitudeScaleBounds: ClosedRange<Double> = 1...5_000

    private var amplitudeScaleSliderBounds: ClosedRange<Double> {
        log10(amplitudeScaleBounds.lowerBound)...log10(amplitudeScaleBounds.upperBound)
    }

    private var amplitudeScaleSliderBinding: Binding<Double> {
        Binding(
            get: {
                log10(min(max(amplitudeScale, amplitudeScaleBounds.lowerBound), amplitudeScaleBounds.upperBound))
            },
            set: { value in
                amplitudeScale = roundedAmplitudeScale(pow(10, value))
            }
        )
    }

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
                    scaleControls
                    windowPicker
                    singleChannelInspector
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

            if showsFooter {
                Divider()
                footer
            }
        }
        .frame(
            minWidth: isEmbedded ? 0 : 900,
            idealWidth: isEmbedded ? nil : 1020,
            maxWidth: isEmbedded ? .infinity : nil,
            minHeight: isEmbedded ? 0 : 680,
            idealHeight: isEmbedded ? nil : 760,
            maxHeight: isEmbedded ? .infinity : nil
        )
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            ensureSelectedCategoryAvailable()
        }
        .onChange(of: categories) {
            ensureSelectedCategoryAvailable()
        }
    }

    // MARK: - Header / footer

    private var showsFooter: Bool {
        viewModel.result != nil || onClose != nil
    }

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
            if let onClose {
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func ensureSelectedCategoryAvailable() {
        if let selected = viewModel.selectedCategory, categories.contains(selected) {
            return
        }
        viewModel.selectedCategory = categories.first
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

    private var scaleControls: some View {
        HStack(spacing: 8) {
            Text("Trace Scale")
                .font(.caption.weight(.semibold))
                .frame(width: 82, alignment: .leading)
            Slider(value: amplitudeScaleSliderBinding, in: amplitudeScaleSliderBounds)
                .frame(width: 220)
                .help("Lower values make the butterfly and single-channel trial traces taller.")
            Text("±\(formatAmplitudeScale(amplitudeScale)) µV")
                .font(.caption.monospacedDigit())
                .frame(width: 86, alignment: .trailing)
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
                    Toggle("All conditions", isOn: $viewModel.showsAllConditionsInButterfly)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .disabled(averagedSegments.count <= 1)
                        .help("Overlay all available conditions in the butterfly while keeping the selected category for analysis.")
                    Spacer()
                    if viewModel.hasWindow, let start = viewModel.windowStartMs, let end = viewModel.windowEndMs {
                        Text("\(Int(start.rounded())) – \(Int(end.rounded())) ms")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
                let plottedSegments = viewModel.showsAllConditionsInButterfly ? averagedSegments : [segment]
                SingleTrialWindowPicker(
                    data: signal.data,
                    segments: plottedSegments,
                    colors: plottedSegments.map { categoryColor($0.category) },
                    selectionSegment: segment,
                    hiddenChannels: hiddenChannels,
                    amplitudeScale: amplitudeScale,
                    samplingRate: signal.samplingRate,
                    channelName: channelName,
                    windowStartMs: $viewModel.windowStartMs,
                    windowEndMs: $viewModel.windowEndMs,
                    onTapChannel: { channel in
                        viewModel.channelScope = .singleChannel
                        viewModel.selectedChannelIndex = channel
                    }
                )
                .frame(height: 180)
                .contextMenu {
                    trialFigureSaveMenu(
                        title: singleTrialButterflyTitle(segments: plottedSegments),
                        legend: legendItems(for: plottedSegments),
                        size: CGSize(width: 820, height: 300)
                    ) {
                        SingleTrialWindowPicker(
                            data: signal.data,
                            segments: plottedSegments,
                            colors: plottedSegments.map { categoryColor($0.category) },
                            selectionSegment: segment,
                            hiddenChannels: hiddenChannels,
                            amplitudeScale: amplitudeScale,
                            samplingRate: signal.samplingRate,
                            channelName: channelName,
                            windowStartMs: .constant(viewModel.windowStartMs),
                            windowEndMs: .constant(viewModel.windowEndMs),
                            onTapChannel: { _ in }
                        )
                    }
                }
            }
        } else {
            Text("No averaged epoch available for this category yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var singleChannelInspector: some View {
        let selectedChannel = (viewModel.channelScope == .singleChannel) ? viewModel.selectedChannelIndex : nil
        if let averageSignal = averagedSignal,
           let rawSignal,
           let selectedChannel,
           averageSignal.data.indices.contains(selectedChannel),
           rawSignal.data.indices.contains(selectedChannel),
           !averagedSegments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Single-Channel Trial Inspector")
                            .font(.caption.weight(.semibold))
                        Text(channelName(selectedChannel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    FlowLegend(items: singleChannelLegendItems())
                }
                SingleTrialChannelInspectorPlot(
                    averagedSignal: averageSignal,
                    averagedSegments: averagedSegments,
                    rawSignal: rawSignal,
                    rawSegments: rawSegments,
                    channelIndex: selectedChannel,
                    amplitudeScale: amplitudeScale,
                    averageReference: averageReference,
                    baselineCorrected: baselineCorrected,
                    badChannels: badChannels,
                    channelName: channelName,
                    colorForCategory: categoryColor,
                    displayCategory: displayCategory,
                    selectedCategory: viewModel.selectedCategory,
                    windowStartMs: viewModel.windowStartMs,
                    windowEndMs: viewModel.windowEndMs
                )
                .frame(height: 220)
                .contextMenu {
                    trialFigureSaveMenu(
                        title: singleTrialChannelInspectorTitle(channel: selectedChannel),
                        legend: singleChannelLegendItems(),
                        size: CGSize(width: 820, height: 320)
                    ) {
                        SingleTrialChannelInspectorPlot(
                            averagedSignal: averageSignal,
                            averagedSegments: averagedSegments,
                            rawSignal: rawSignal,
                            rawSegments: rawSegments,
                            channelIndex: selectedChannel,
                            amplitudeScale: amplitudeScale,
                            averageReference: averageReference,
                            baselineCorrected: baselineCorrected,
                            badChannels: badChannels,
                            channelName: channelName,
                            colorForCategory: categoryColor,
                            displayCategory: displayCategory,
                            selectedCategory: viewModel.selectedCategory,
                            windowStartMs: viewModel.windowStartMs,
                            windowEndMs: viewModel.windowEndMs
                        )
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Channel Selected",
                systemImage: "waveform.path",
                description: Text("Click a channel in the butterfly trace or choose a single channel above.")
            )
            .frame(height: 130)
        }
    }

    private func singleChannelLegendItems() -> [(String, Color)] {
        legendItems(for: averagedSegments)
    }

    private func legendItems(for segments: [EpochSegment]) -> [(String, Color)] {
        var seen = Set<String>()
        return segments.compactMap { segment in
            guard seen.insert(segment.category).inserted else { return nil }
            return (displayCategory(segment.category), categoryColor(segment.category))
        }
    }

    private func singleTrialButterflyTitle(segments: [EpochSegment]) -> String {
        if viewModel.showsAllConditionsInButterfly || segments.count > 1 {
            return "Single Trial Butterfly"
        }
        if let category = segments.first?.category {
            return "Single Trial Butterfly \(displayCategory(category))"
        }
        return "Single Trial Butterfly"
    }

    private func singleTrialChannelInspectorTitle(channel: Int) -> String {
        "Single Trial Channel Inspector \(channelName(channel))"
    }

    @ViewBuilder
    private func trialFigureSaveMenu<Figure: View>(
        title: String,
        legend: [(String, Color)],
        size: CGSize,
        @ViewBuilder figure: @escaping () -> Figure
    ) -> some View {
        Menu("Save Figure As…") {
            ForEach(FigureFormat.allCases) { format in
                Button(format.label) {
                    FigureExporter.save(
                        FigureCard(title: title, legend: legend, size: size, content: figure),
                        defaultName: figureFileName(title),
                        format: format
                    )
                }
            }
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
        Table(sortedTrials(result), sortOrder: $trialSortOrder) {
            TableColumn("#", value: \.trialIndex) { Text("\($0.trialIndex + 1)") }.width(42)
            TableColumn("Time (s)", value: \.sourceTimeSeconds) { Text(String(format: "%.1f", $0.sourceTimeSeconds)) }.width(70)
            TableColumn("Mean", value: \.meanAmplitude) { Text(String(format: "%.2f", $0.meanAmplitude)) }.width(68)
            TableColumn("Peak@Avg (+/−)", value: \.peakAmplitudeAtAverageLatencyPositive) {
                Text(String(format: "%.2f / %.2f", $0.peakAmplitudeAtAverageLatencyPositive, $0.peakAmplitudeAtAverageLatencyNegative))
            }.width(118)
            TableColumn("Own + @ ms", value: \.peakAmplitudeOwnLatencyPositive) {
                Text(String(format: "%.2f @ %.0f", $0.peakAmplitudeOwnLatencyPositive, $0.peakLatencyOwnPositiveMs))
            }.width(104)
            TableColumn("Own − @ ms", value: \.peakAmplitudeOwnLatencyNegative) {
                Text(String(format: "%.2f @ %.0f", $0.peakAmplitudeOwnLatencyNegative, $0.peakLatencyOwnNegativeMs))
            }.width(104)
            TableColumn("Adaptive (+/−)", value: \.adaptiveMeanAmplitudePositive) {
                Text(String(format: "%.2f / %.2f", $0.adaptiveMeanAmplitudePositive, $0.adaptiveMeanAmplitudeNegative))
            }.width(112)
            TableColumn("P2P", value: \.peakToPeakAmplitude) { Text(String(format: "%.2f", $0.peakToPeakAmplitude)) }.width(64)
            TableColumn("") { row in
                if row.isOutlier {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }.width(24)
        }
        .frame(height: 320)
    }

    private func sortedTrials(_ result: SingleTrialAnalyzer.Result) -> [SingleTrialAnalyzer.SingleTrialValue] {
        guard !trialSortOrder.isEmpty else { return result.trials }
        return result.trials.sorted(using: trialSortOrder)
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

    private func roundedAmplitudeScale(_ value: Double) -> Double {
        let clamped = min(max(value, amplitudeScaleBounds.lowerBound), amplitudeScaleBounds.upperBound)
        if clamped < 100 {
            return clamped.rounded()
        }
        if clamped < 1_000 {
            return (clamped / 10).rounded() * 10
        }
        return (clamped / 100).rounded() * 100
    }

    private func formatAmplitudeScale(_ value: Double) -> String {
        if value < 100 {
            return String(Int(value.rounded()))
        }
        if value < 1_000 {
            return String(Int((value / 10).rounded() * 10))
        }
        return String(Int((value / 100).rounded() * 100))
    }
}

/// Drag-select overlay on a full-channel butterfly trace, matching the look
/// of the existing Butterfly panel (`ButterflyConditionPlot`) but adding a
/// range (not single-point) selection independent from the topomap scrubber.
private struct SingleTrialWindowPicker: View {
    let data: [[Float]]
    let segments: [EpochSegment]
    let colors: [Color]
    let selectionSegment: EpochSegment
    let hiddenChannels: Set<Int>
    let amplitudeScale: Double
    let samplingRate: Double
    let channelName: (Int) -> String
    @Binding var windowStartMs: Double?
    @Binding var windowEndMs: Double?
    let onTapChannel: (Int) -> Void

    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?
    @State private var liveWindowStartMs: Double?
    @State private var liveWindowEndMs: Double?

    private var epochLength: Int {
        max(selectionSegment.endSample - selectionSegment.startSample + 1, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                OverlayButterflyPlot(
                    data: data,
                    segments: segments,
                    colors: colors,
                    hiddenChannels: hiddenChannels,
                    amplitudeScale: amplitudeScale,
                    channelName: channelName,
                    onTapChannel: onTapChannel
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStartX == nil { dragStartX = value.startLocation.x }
                        dragCurrentX = value.location.x
                        updateLiveWindow(width: proxy.size.width)
                    }
                    .onEnded { _ in
                        if let liveWindowStartMs, let liveWindowEndMs {
                            windowStartMs = liveWindowStartMs
                            windowEndMs = liveWindowEndMs
                        }
                        dragStartX = nil
                        dragCurrentX = nil
                        liveWindowStartMs = nil
                        liveWindowEndMs = nil
                    }
            )
        }
    }

    private func selectionRect(in size: CGSize) -> CGRect? {
        let displayStartMs = liveWindowStartMs ?? windowStartMs
        let displayEndMs = liveWindowEndMs ?? windowEndMs
        guard let displayStartMs, let displayEndMs, size.width > 0 else { return nil }
        let startSample = relativeSample(forMs: displayStartMs)
        let endSample = relativeSample(forMs: displayEndMs)
        let xScale = size.width / CGFloat(max(epochLength - 1, 1))
        let x0 = CGFloat(min(startSample, endSample)) * xScale
        let x1 = CGFloat(max(startSample, endSample)) * xScale
        return CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)
    }

    private func relativeSample(forMs ms: Double) -> Int {
        let sample = selectionSegment.stimulusOffsetSamples + Int((ms / 1000.0 * samplingRate).rounded())
        return min(max(sample, 0), epochLength - 1)
    }

    private func msFromRelativeSample(_ relativeSample: Int) -> Double {
        Double(relativeSample - selectionSegment.stimulusOffsetSamples) / samplingRate * 1000.0
    }

    private func updateLiveWindow(width: CGFloat) {
        guard let dragStartX, let dragCurrentX, width > 0 else { return }
        let xScale = width / CGFloat(max(epochLength - 1, 1))
        let startSample = min(max(Int((dragStartX / xScale).rounded()), 0), epochLength - 1)
        let endSample = min(max(Int((dragCurrentX / xScale).rounded()), 0), epochLength - 1)
        liveWindowStartMs = msFromRelativeSample(min(startSample, endSample))
        liveWindowEndMs = msFromRelativeSample(max(startSample, endSample))
    }
}

private struct SingleTrialChannelTraceBundle: Identifiable {
    let category: String
    let segment: EpochSegment
    let length: Int
    let averageTrace: [Float]
    let trialTraces: [[Float]]

    var id: String { category }
}

@MainActor
private final class SingleTrialChannelTraceCache: ObservableObject {
    @Published private(set) var bundles: [SingleTrialChannelTraceBundle] = []
    private var signature: String?

    func prepare(
        averagedSignal: MFFSignalData,
        averagedSegments: [EpochSegment],
        rawSignal: MFFSignalData,
        rawSegments: [EpochSegment],
        channelIndex: Int,
        averageReference: Bool,
        baselineCorrected: Bool,
        badChannels: Set<Int>,
        signature: String
    ) {
        guard self.signature != signature else { return }
        let nextBundles = Self.buildBundles(
            averagedSignal: averagedSignal,
            averagedSegments: averagedSegments,
            rawSignal: rawSignal,
            rawSegments: rawSegments,
            channelIndex: channelIndex,
            averageReference: averageReference,
            baselineCorrected: baselineCorrected,
            badChannels: badChannels
        )
        self.signature = signature
        bundles = nextBundles
    }

    static func buildBundles(
        averagedSignal: MFFSignalData,
        averagedSegments: [EpochSegment],
        rawSignal: MFFSignalData,
        rawSegments: [EpochSegment],
        channelIndex: Int,
        averageReference: Bool,
        baselineCorrected: Bool,
        badChannels: Set<Int>
    ) -> [SingleTrialChannelTraceBundle] {
        guard averagedSignal.data.indices.contains(channelIndex),
              rawSignal.data.indices.contains(channelIndex) else { return [] }
        let rawByCategory = Dictionary(grouping: rawSegments, by: \.category)
        return averagedSegments.compactMap { segment in
            guard segment.startSample >= 0,
                  segment.endSample >= segment.startSample,
                  averagedSignal.data[channelIndex].count > segment.endSample else { return nil }
            let length = segment.endSample - segment.startSample + 1
            guard length > 1 else { return nil }
            let averageTrace = Array(averagedSignal.data[channelIndex][segment.startSample...segment.endSample])
            let trials = rawByCategory[segment.category]?.compactMap { trial -> [Float]? in
                guard trial.endSample - trial.startSample + 1 == length else { return nil }
                return trialTrace(
                    segment: trial,
                    length: length,
                    rawSignal: rawSignal,
                    channelIndex: channelIndex,
                    averageReference: averageReference,
                    baselineCorrected: baselineCorrected,
                    badChannels: badChannels
                )
            } ?? []
            return SingleTrialChannelTraceBundle(
                category: segment.category,
                segment: segment,
                length: length,
                averageTrace: averageTrace,
                trialTraces: trials
            )
        }
    }

    private static func trialTrace(
        segment: EpochSegment,
        length: Int,
        rawSignal: MFFSignalData,
        channelIndex: Int,
        averageReference: Bool,
        baselineCorrected: Bool,
        badChannels: Set<Int>
    ) -> [Float]? {
        guard segment.startSample >= 0,
              rawSignal.data[channelIndex].count > segment.endSample else { return nil }

        let referenceIndices: [Int]
        if averageReference {
            referenceIndices = rawSignal.data.indices.filter {
                !badChannels.contains($0) && rawSignal.data[$0].count > segment.endSample
            }
        } else {
            referenceIndices = []
        }

        var trace = [Float](repeating: 0, count: length)
        for offset in 0..<length {
            let sample = segment.startSample + offset
            var referenceMean = 0.0
            if averageReference {
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

            let value = Double(rawSignal.data[channelIndex][sample]) - referenceMean
            guard value.isFinite else { return nil }
            trace[offset] = Float(value)
        }

        if baselineCorrected {
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
}

private struct SingleTrialInspectorHoverInfo {
    let valueMicrovolts: Double
    let detail: String
}

private struct SingleTrialChannelInspectorPlot: View {
    let averagedSignal: MFFSignalData
    let averagedSegments: [EpochSegment]
    let rawSignal: MFFSignalData
    let rawSegments: [EpochSegment]
    let channelIndex: Int
    let amplitudeScale: Double
    let averageReference: Bool
    let baselineCorrected: Bool
    let badChannels: Set<Int>
    let channelName: (Int) -> String
    let colorForCategory: (String) -> Color
    let displayCategory: (String) -> String
    let selectedCategory: String?
    let windowStartMs: Double?
    let windowEndMs: Double?

    @StateObject private var traceCache = SingleTrialChannelTraceCache()
    @State private var hoverInfo: SingleTrialInspectorHoverInfo?

    private var cacheSignature: String {
        [
            averagedSignal.signalURL.path,
            rawSignal.signalURL.path,
            "\(averagedSignal.samplingRate)",
            "\(rawSignal.samplingRate)",
            "\(channelIndex)",
            "\(averageReference)",
            "\(baselineCorrected)",
            badChannels.sorted().map(String.init).joined(separator: ","),
            segmentSignature(averagedSegments),
            segmentSignature(rawSegments)
        ].joined(separator: "::")
    }

    private func segmentSignature(_ segments: [EpochSegment]) -> String {
        let middle = segments.isEmpty ? nil : segments[segments.count / 2].id
        return [
            "\(segments.count)",
            segments.first?.id ?? "",
            middle ?? "",
            segments.last?.id ?? ""
        ].joined(separator: "|")
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let bundles = preparedBundles()
                guard let first = bundles.first else { return }
                let length = first.length
                guard length > 1 else { return }

                let midY = size.height / 2
                let scale = max(amplitudeScale, 1)
                let sampleStep = max(length / max(Int(size.width), 1), 1)

                drawReferenceLines(first: first.segment, length: length, size: size, midY: midY, in: &context)
                drawWindowSelection(first: first.segment, length: length, size: size, in: &context)

                let orderedBundles = ordered(bundles)
                for bundle in orderedBundles where bundle.length == length {
                    let color = colorForCategory(bundle.category)
                    let isSelected = selectedCategory == nil || bundle.category == selectedCategory
                    for trace in bundle.trialTraces {
                        draw(
                            trace,
                            length: length,
                            sampleStep: sampleStep,
                            size: size,
                            midY: midY,
                            scale: scale,
                            in: &context,
                            color: color,
                            opacity: isSelected ? 0.15 : 0.06,
                            lineWidth: isSelected ? 0.65 : 0.45
                        )
                    }
                }

                for bundle in orderedBundles where bundle.length == length {
                    let color = colorForCategory(bundle.category)
                    let isSelected = selectedCategory == nil || bundle.category == selectedCategory
                    draw(
                        bundle.averageTrace,
                        length: length,
                        sampleStep: sampleStep,
                        size: size,
                        midY: midY,
                        scale: scale,
                        in: &context,
                        color: color,
                        opacity: isSelected ? 0.98 : 0.42,
                        lineWidth: isSelected ? 2.0 : 1.1
                    )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverInfo = nearestHoverInfo(at: location, in: proxy.size)
                case .ended:
                    hoverInfo = nil
                }
            }
            .overlay(alignment: .topTrailing) {
                if let hoverInfo {
                    ButterflyChannelBadge(
                        name: channelName(channelIndex),
                        valueMicrovolts: hoverInfo.valueMicrovolts,
                        detail: hoverInfo.detail
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
        .onAppear { prepareCache() }
        .onChange(of: cacheSignature) { _, _ in
            prepareCache()
        }
    }

    private func prepareCache() {
        traceCache.prepare(
            averagedSignal: averagedSignal,
            averagedSegments: averagedSegments,
            rawSignal: rawSignal,
            rawSegments: rawSegments,
            channelIndex: channelIndex,
            averageReference: averageReference,
            baselineCorrected: baselineCorrected,
            badChannels: badChannels,
            signature: cacheSignature
        )
    }

    private func preparedBundles() -> [SingleTrialChannelTraceBundle] {
        let cached = traceCache.bundles
        if !cached.isEmpty { return cached }
        return SingleTrialChannelTraceCache.buildBundles(
            averagedSignal: averagedSignal,
            averagedSegments: averagedSegments,
            rawSignal: rawSignal,
            rawSegments: rawSegments,
            channelIndex: channelIndex,
            averageReference: averageReference,
            baselineCorrected: baselineCorrected,
            badChannels: badChannels
        )
    }

    private func ordered(_ bundles: [SingleTrialChannelTraceBundle]) -> [SingleTrialChannelTraceBundle] {
        bundles.sorted { lhs, rhs in
            switch (lhs.category == selectedCategory, rhs.category == selectedCategory) {
            case (false, true): return true
            case (true, false): return false
            default: return lhs.category.localizedStandardCompare(rhs.category) == .orderedAscending
            }
        }
    }

    private func drawReferenceLines(
        first: EpochSegment,
        length: Int,
        size: CGSize,
        midY: CGFloat,
        in context: inout GraphicsContext
    ) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: midY))
        baseline.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(baseline, with: .color(.secondary.opacity(0.26)), lineWidth: 0.8)

        let stimulusX = CGFloat(first.stimulusOffsetSamples) / CGFloat(length - 1) * size.width
        var stimulus = Path()
        stimulus.move(to: CGPoint(x: stimulusX, y: 0))
        stimulus.addLine(to: CGPoint(x: stimulusX, y: size.height))
        context.stroke(stimulus, with: .color(.green.opacity(0.58)), lineWidth: 1)
    }

    private func drawWindowSelection(
        first: EpochSegment,
        length: Int,
        size: CGSize,
        in context: inout GraphicsContext
    ) {
        guard let windowStartMs, let windowEndMs, averagedSignal.samplingRate > 0 else { return }
        let start = relativeSample(forMs: windowStartMs, segment: first, length: length)
        let end = relativeSample(forMs: windowEndMs, segment: first, length: length)
        let x0 = CGFloat(min(start, end)) / CGFloat(length - 1) * size.width
        let x1 = CGFloat(max(start, end)) / CGFloat(length - 1) * size.width
        let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)
        context.fill(Path(rect), with: .color(.accentColor.opacity(0.10)))
    }

    private func relativeSample(forMs ms: Double, segment: EpochSegment, length: Int) -> Int {
        let sample = segment.stimulusOffsetSamples + Int((ms / 1000.0 * averagedSignal.samplingRate).rounded())
        return min(max(sample, 0), length - 1)
    }

    private func nearestHoverInfo(at location: CGPoint, in size: CGSize) -> SingleTrialInspectorHoverInfo? {
        let bundles = preparedBundles()
        guard let first = bundles.first, first.length > 1, size.width > 0 else { return nil }
        let length = first.length
        let midY = size.height / 2
        let scale = max(amplitudeScale, 1)
        let xScale = size.width / CGFloat(length - 1)
        let localSample = min(max(Int((location.x / xScale).rounded()), 0), length - 1)
        let timeMs = Double(localSample - first.segment.stimulusOffsetSamples) / averagedSignal.samplingRate * 1000.0

        var best: (value: Double, distance: CGFloat, detail: String)?
        for bundle in ordered(bundles) where bundle.length == length {
            consider(
                trace: bundle.averageTrace,
                localSample: localSample,
                location: location,
                size: size,
                midY: midY,
                scale: scale,
                category: bundle.category,
                source: "Avg",
                timeMs: timeMs,
                best: &best
            )

            guard selectedCategory == nil || bundle.category == selectedCategory else { continue }
            for (trialIndex, trace) in bundle.trialTraces.enumerated() {
                consider(
                    trace: trace,
                    localSample: localSample,
                    location: location,
                    size: size,
                    midY: midY,
                    scale: scale,
                    category: bundle.category,
                    source: "Trial \(trialIndex + 1)",
                    timeMs: timeMs,
                    best: &best
                )
            }
        }

        guard let best, best.distance <= 14 else { return nil }
        return SingleTrialInspectorHoverInfo(valueMicrovolts: best.value, detail: best.detail)
    }

    private func consider(
        trace: [Float],
        localSample: Int,
        location: CGPoint,
        size: CGSize,
        midY: CGFloat,
        scale: Double,
        category: String,
        source: String,
        timeMs: Double,
        best: inout (value: Double, distance: CGFloat, detail: String)?
    ) {
        guard trace.indices.contains(localSample) else { return }
        let value = Double(trace[localSample])
        let y = midY - CGFloat(value / scale) * (size.height / 2) * 0.9
        let distance = abs(y - location.y)
        if best == nil || distance < best!.distance {
            best = (
                value,
                distance,
                "\(source) · \(displayCategory(category)) · \(Int(timeMs.rounded())) ms"
            )
        }
    }

    private func draw(
        _ trace: [Float],
        length: Int,
        sampleStep: Int,
        size: CGSize,
        midY: CGFloat,
        scale: Double,
        in context: inout GraphicsContext,
        color: Color,
        opacity: Double,
        lineWidth: CGFloat
    ) {
        let count = min(trace.count, length)
        guard count > 1 else { return }
        var path = Path()
        var moved = false
        for localSample in stride(from: 0, through: count - 1, by: sampleStep) {
            addPoint(localSample, trace: trace, length: length, size: size, midY: midY, scale: scale, to: &path, moved: &moved)
        }
        if (count - 1) % sampleStep != 0 {
            addPoint(count - 1, trace: trace, length: length, size: size, midY: midY, scale: scale, to: &path, moved: &moved)
        }
        context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)
    }

    private func addPoint(
        _ localSample: Int,
        trace: [Float],
        length: Int,
        size: CGSize,
        midY: CGFloat,
        scale: Double,
        to path: inout Path,
        moved: inout Bool
    ) {
        let x = CGFloat(localSample) / CGFloat(length - 1) * size.width
        let y = midY - CGFloat(Double(trace[localSample]) / scale) * (size.height / 2) * 0.9
        let point = CGPoint(x: x, y: y)
        if moved {
            path.addLine(to: point)
        } else {
            path.move(to: point)
            moved = true
        }
    }
}
