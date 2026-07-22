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
    @Bindable var viewModel: SingleTrialAnalysisViewModel
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
    @State private var woodySortOrder: [KeyPathComparator<WoodyAlignmentAnalyzer.TrialShift>] = [KeyPathComparator(\.trialIndex)]
    @State private var rideSortOrder: [KeyPathComparator<RIDEAnalyzer.TrialLatency>] = [KeyPathComparator(\.trialIndex)]
    @State private var latencyAnalysisTask: Task<Void, Never>?
    @State private var woodyAlignedPreview: SingleTrialAlignedButterflyPreview?
    @State private var rideAlignedPreview: SingleTrialAlignedButterflyPreview?
    private let amplitudeScaleBounds: ClosedRange<Double> = 1...5_000
    private let singleTrialPlotHeight: CGFloat = 220

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
        guard averagedSegment != nil, !selectedChannelIndices.isEmpty,
              let category = viewModel.selectedCategory,
              rawSegments.contains(where: { $0.category == category }) else { return false }
        if viewModel.analysisMode == .ride {
            let windows = activeRIDEComponentWindows
            return !windows.isEmpty && windows.allSatisfy { $0.endMs > $0.startMs }
        }
        guard viewModel.hasWindow else { return false }
        return true
    }

    private var activeRIDEComponentWindows: [RIDEComponentWindowSelection] {
        var windows: [RIDEComponentWindowSelection] = []
        if viewModel.rideIncludesStimulusComponent {
            windows.append(RIDEComponentWindowSelection(
                component: .stimulus,
                startMs: viewModel.rideStimulusWindowStartMs,
                endMs: viewModel.rideStimulusWindowEndMs
            ))
        }
        if viewModel.rideIncludesCentralComponent {
            windows.append(RIDEComponentWindowSelection(
                component: .central,
                startMs: viewModel.rideCentralWindowStartMs,
                endMs: viewModel.rideCentralWindowEndMs
            ))
        }
        if viewModel.rideIncludesResponseComponent {
            windows.append(RIDEComponentWindowSelection(
                component: .response,
                startMs: viewModel.rideResponseWindowStartMs,
                endMs: viewModel.rideResponseWindowEndMs
            ))
        }
        return windows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeControls
                    selectionControls
                    scaleControls
                    trialInspectorRow
                    parameterControls
                    runBar

                    if viewModel.analysisMode == .measurements, let result = viewModel.result {
                        Divider()
                        resultsSection(result)
                    } else if viewModel.analysisMode == .woody, let result = currentWoodyResult {
                        Divider()
                        woodyResultsSection(result)
                    } else if viewModel.analysisMode == .ride, let result = currentRIDEResult {
                        Divider()
                        rideResultsSection(result)
                    } else if viewModel.analysisMode == .cwtRidge, let result = currentCWTResult {
                        Divider()
                        cwtResultsSection(result)
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
        .task(id: viewModel.isWoodyAlignmentAnimating) {
            await runWoodyAlignmentAnimationIfNeeded()
        }
        .task(id: viewModel.isRIDEAlignmentAnimating) {
            await runRIDEAlignmentAnimationIfNeeded()
        }
        .onDisappear {
            latencyAnalysisTask?.cancel()
            latencyAnalysisTask = nil
            viewModel.isRunning = false
            viewModel.runProgress = nil
            viewModel.isWoodyAlignmentAnimating = false
            viewModel.isRIDEAlignmentAnimating = false
        }
    }

    // MARK: - Header / footer

    private var showsFooter: Bool {
        viewModel.result != nil || viewModel.woodyResult != nil || viewModel.rideResult != nil || onClose != nil
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Single Trial Analysis")
                    .font(.title3.weight(.semibold))
                Text("Measure trial values or estimate latency shifts with Woody alignment")
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
            if viewModel.woodyResult != nil {
                Button("Export Woody Shifts…") { exportWoodyShifts() }
            }
            if viewModel.rideResult != nil {
                Button("Export RIDE Latencies…") { exportRIDELatencies() }
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

    private var modeControls: some View {
        Picker("Analysis Mode", selection: $viewModel.analysisMode) {
            ForEach(SingleTrialAnalysisMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
    }

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

    private var trialInspectorRow: some View {
        GeometryReader { proxy in
            if proxy.size.width < 840 {
                VStack(alignment: .leading, spacing: 12) {
                    windowPicker
                    singleChannelInspector
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    windowPicker
                        .frame(width: proxy.size.width * 0.5 - 7)
                    singleChannelInspector
                        .frame(width: proxy.size.width * 0.5 - 7)
                }
            }
        }
        .frame(height: 290)
    }

    @ViewBuilder
    private var windowPicker: some View {
        if let signal = averagedSignal, let segment = averagedSegment {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Drag on the trace to select the analysis window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Show all conditions", isOn: $viewModel.showsAllConditionsInButterfly)
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
                let isRIDEWindowMode = viewModel.analysisMode == .ride
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
                    componentWindows: isRIDEWindowMode ? activeRIDEComponentWindows : [],
                    colorForComponent: color(forRIDEComponent:),
                    onComponentWindowChange: { component, startMs, endMs in
                        setRIDEComponentWindow(component, startMs: startMs, endMs: endMs)
                    },
                    onTapChannel: { channel in
                        viewModel.channelScope = .singleChannel
                        viewModel.selectedChannelIndex = channel
                    }
                )
                .frame(height: singleTrialPlotHeight)
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
                            componentWindows: isRIDEWindowMode ? activeRIDEComponentWindows : [],
                            colorForComponent: color(forRIDEComponent:),
                            onComponentWindowChange: { _, _, _ in },
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
                    alignmentInspectorControls
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
                    windowEndMs: viewModel.windowEndMs,
                    woodyLatencyShiftSamples: currentWoodyLatencyShiftSamples,
                    showsWoodyAlignedOverlay: viewModel.showsWoodyAlignedOverlay,
                    woodyAlignmentProgress: viewModel.woodyAlignmentAnimationProgress,
                    rideLatencyShiftSamples: currentRIDELatencyShiftSamples,
                    showsRIDEAlignedOverlay: viewModel.showsRIDEAlignedOverlay,
                    rideAlignmentProgress: viewModel.rideAlignmentAnimationProgress
                )
                .frame(height: singleTrialPlotHeight)
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
                            windowEndMs: viewModel.windowEndMs,
                            woodyLatencyShiftSamples: currentWoodyLatencyShiftSamples,
                            showsWoodyAlignedOverlay: viewModel.showsWoodyAlignedOverlay,
                            woodyAlignmentProgress: viewModel.woodyAlignmentAnimationProgress,
                            rideLatencyShiftSamples: currentRIDELatencyShiftSamples,
                            showsRIDEAlignedOverlay: viewModel.showsRIDEAlignedOverlay,
                            rideAlignmentProgress: viewModel.rideAlignmentAnimationProgress
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

    @ViewBuilder
    private var alignmentInspectorControls: some View {
        switch viewModel.analysisMode {
        case .measurements:
            EmptyView()
        case .cwtRidge:
            EmptyView()
        case .woody:
            if hasCurrentWoodyAlignment {
                woodyInspectorControls
            }
        case .ride:
            if hasCurrentRIDEAlignment {
                rideInspectorControls
            }
        }
    }

    private var woodyInspectorControls: some View {
        HStack(spacing: 8) {
            Toggle("Woody overlay", isOn: $viewModel.showsWoodyAlignedOverlay)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Overlay dashed traces that slide horizontally by each trial's Woody latency shift. Original waveforms remain solid.")
            Slider(value: $viewModel.woodyAlignmentAnimationProgress, in: 0...1)
                .frame(width: 90)
                .disabled(!viewModel.showsWoodyAlignedOverlay)
                .help("Preview the alignment from original positions at 0 to fully shifted positions at 1.")
            Button(viewModel.isWoodyAlignmentAnimating ? "Stop" : "Animate") {
                toggleWoodyAlignmentAnimation()
            }
            .font(.caption)
            .disabled(!viewModel.showsWoodyAlignedOverlay)
            .help("Animate the dashed Woody overlay moving from original to aligned positions.")
            Toggle("Loop", isOn: $viewModel.loopsWoodyAlignmentAnimation)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(!viewModel.showsWoodyAlignedOverlay)
                .help("Restart the alignment animation automatically after it reaches the shifted waveforms.")
            Button("Reset") {
                resetWoodyAlignmentDisplay()
            }
            .font(.caption)
            .help("Clear the current Woody alignment display and restore trial measurements to the original waveforms.")
        }
    }

    private var rideInspectorControls: some View {
        HStack(spacing: 8) {
            Toggle("RIDE overlay", isOn: $viewModel.showsRIDEAlignedOverlay)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Overlay dashed trial traces sliding into their RIDE component-locked frame. S remains stimulus-locked; C uses each trial's estimated central latency.")
            Slider(value: $viewModel.rideAlignmentAnimationProgress, in: 0...1)
                .frame(width: 90)
                .disabled(!viewModel.showsRIDEAlignedOverlay)
                .help("Preview RIDE component locking from original positions at 0 to fully C- or R-aligned positions at 1.")
            Button(viewModel.isRIDEAlignmentAnimating ? "Stop" : "Animate") {
                toggleRIDEAlignmentAnimation()
            }
            .font(.caption)
            .disabled(!viewModel.showsRIDEAlignedOverlay)
            .help("Animate the dashed overlay moving toward the component-locked RIDE frame.")
            Toggle("Loop", isOn: $viewModel.loopsRIDEAlignmentAnimation)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(!viewModel.showsRIDEAlignedOverlay)
            Button("Reset") {
                resetRIDEAlignmentDisplay()
            }
            .font(.caption)
            .help("Clear the current RIDE display.")
        }
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

    private var currentWoodyLatencyShiftSamples: [Int]? {
        guard (viewModel.analysisMode == .woody || viewModel.woodyResult != nil),
              hasCurrentWoodyAlignment,
              let category = viewModel.selectedCategory,
              let result = viewModel.woodyResultsByCategory[category],
              result.shifts.count == rawSegments.filter({ $0.category == category }).count else {
            return nil
        }
        return result.shifts.map(\.latencyShiftSamples)
    }

    private var hasCurrentRIDEAlignment: Bool {
        currentRIDEResult != nil
            && viewModel.rideResultChannelIndices == selectedChannelIndices
    }

    private var currentRIDELatencyShiftSamples: [Int]? {
        guard viewModel.analysisMode == .ride,
              hasCurrentRIDEAlignment,
              let category = viewModel.selectedCategory,
              let result = viewModel.rideResultsByCategory[category],
              result.trialLatencies.count == rawSegments.filter({ $0.category == category }).count else {
            return nil
        }
        let central = result.trialLatencies.compactMap(\.centralLatencyShiftSamples)
        if central.count == result.trialLatencies.count { return central }
        let response = result.trialLatencies.compactMap(\.responseLatencySamples)
        return response.count == result.trialLatencies.count ? response : nil
    }

    private func toggleWoodyAlignmentAnimation() {
        if viewModel.isWoodyAlignmentAnimating {
            viewModel.isWoodyAlignmentAnimating = false
        } else {
            viewModel.woodyAlignmentAnimationProgress = 0
            viewModel.isWoodyAlignmentAnimating = true
        }
    }

    private func resetWoodyAlignmentDisplay() {
        viewModel.woodyResult = nil
        viewModel.woodyResultCategory = nil
        viewModel.woodyResultChannelIndices = []
        viewModel.woodyResultsByCategory = [:]
        woodyAlignedPreview = nil
        viewModel.usesWoodyAlignedTrialsForMeasurements = false
        viewModel.showsWoodyAlignedOverlay = true
        viewModel.woodyAlignmentAnimationProgress = 1
        viewModel.isWoodyAlignmentAnimating = false
        viewModel.statusMessage = nil
    }

    private func toggleRIDEAlignmentAnimation() {
        if viewModel.isRIDEAlignmentAnimating {
            viewModel.isRIDEAlignmentAnimating = false
        } else {
            viewModel.rideAlignmentAnimationProgress = 0
            viewModel.isRIDEAlignmentAnimating = true
        }
    }

    private func resetRIDEAlignmentDisplay() {
        viewModel.rideResult = nil
        viewModel.rideResultCategory = nil
        viewModel.rideResultChannelIndices = []
        viewModel.rideResultsByCategory = [:]
        rideAlignedPreview = nil
        viewModel.showsRIDEAlignedOverlay = true
        viewModel.rideAlignmentAnimationProgress = 1
        viewModel.isRIDEAlignmentAnimating = false
        viewModel.statusMessage = nil
    }

    @MainActor
    private func runWoodyAlignmentAnimationIfNeeded() async {
        guard viewModel.isWoodyAlignmentAnimating else { return }
        while viewModel.isWoodyAlignmentAnimating && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(60))
            guard viewModel.isWoodyAlignmentAnimating && !Task.isCancelled else { break }
            let next = viewModel.woodyAlignmentAnimationProgress + 0.05
            if next >= 1 {
                if viewModel.loopsWoodyAlignmentAnimation {
                    viewModel.woodyAlignmentAnimationProgress = 0
                } else {
                    viewModel.woodyAlignmentAnimationProgress = 1
                    viewModel.isWoodyAlignmentAnimating = false
                }
            } else {
                viewModel.woodyAlignmentAnimationProgress = next
            }
        }
    }

    @MainActor
    private func runRIDEAlignmentAnimationIfNeeded() async {
        guard viewModel.isRIDEAlignmentAnimating else { return }
        while viewModel.isRIDEAlignmentAnimating && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(60))
            guard viewModel.isRIDEAlignmentAnimating && !Task.isCancelled else { break }
            let next = viewModel.rideAlignmentAnimationProgress + 0.05
            if next >= 1 {
                if viewModel.loopsRIDEAlignmentAnimation {
                    viewModel.rideAlignmentAnimationProgress = 0
                } else {
                    viewModel.rideAlignmentAnimationProgress = 1
                    viewModel.isRIDEAlignmentAnimating = false
                }
            } else {
                viewModel.rideAlignmentAnimationProgress = next
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            switch viewModel.analysisMode {
            case .measurements:
                HStack(spacing: 20) {
                    labeledField("Adaptive ± ms", value: $viewModel.adaptiveHalfWidthMs, width: 70)
                    labeledStepper("Split groups", value: $viewModel.splitCount, range: 2...8)
                    labeledField("Outlier SD", value: $viewModel.outlierThresholdSD, width: 60)
                    labeledStepper("Distribution chunks", value: $viewModel.distributionChunkCount, range: 1...12)
                    Toggle("Use Woody-aligned trials", isOn: $viewModel.usesWoodyAlignedTrialsForMeasurements)
                        .toggleStyle(.checkbox)
                        .disabled(!hasCurrentWoodyAlignment)
                        .help("Run the measurement table on the most recent Woody-aligned traces for this selection.")
                }
            case .woody:
                HStack(spacing: 20) {
                    Toggle("All categories", isOn: $viewModel.woodyRunsAllCategories)
                        .toggleStyle(.checkbox)
                        .help("Run Woody separately for every available category using the highlighted time window. The selected category still controls the trial table.")
                    Picker("Align", selection: $viewModel.woodyAlignmentMode) {
                        ForEach(WoodyAlignmentAnalyzer.AlignmentMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .frame(width: 190)
                    .help("Correlation aligns the selected window's shape. Peak aligns each trial's selected-window peak to the template peak. Matched Wavelet cross-correlates each trial against a clean wavelet fitted to the window's dominant deflection.")
                    if viewModel.woodyAlignmentMode == .peak || viewModel.woodyAlignmentMode == .matchedWavelet {
                        Picker("Peak", selection: $viewModel.woodyPeakPolarity) {
                            ForEach(WoodyAlignmentAnalyzer.PeakPolarity.allCases) { polarity in
                                Text(polarity.rawValue).tag(polarity)
                            }
                        }
                        .frame(width: 150)
                        .help(viewModel.woodyAlignmentMode == .matchedWavelet
                            ? "Which deflection the matched wavelet is fitted to inside the highlighted window."
                            : "Peak polarity to search inside the highlighted window.")
                    }
                    Toggle("Wavelet denoise", isOn: $viewModel.woodyAppliesDenoising)
                        .toggleStyle(.checkbox)
                        .help("Apply wavelet shrinkage denoising to each trial before alignment. Raises single-trial SNR so latency estimates are less biased by noise.")
                    labeledField(
                        "Max lag ± ms",
                        value: $viewModel.woodyMaxLagMs,
                        width: 70,
                        help: "Largest positive or negative latency shift Woody may test for each trial. Larger values can recover more jitter but can also align to the wrong feature."
                    )
                    labeledStepper(
                        "Iterations",
                        value: $viewModel.woodyMaxIterations,
                        range: 1...30,
                        help: "Maximum number of template/refit passes. More iterations give the template more chances to stabilize, but usually only help until shifts stop changing."
                    )
                    labeledStepper(
                        "Tolerance samples",
                        value: $viewModel.woodyConvergenceToleranceSamples,
                        range: 0...20,
                        help: "Allowed per-trial shift change before the run counts as still moving. Zero requires exact stability; higher values stop sooner."
                    )
                }
                Text("The highlighted window restricts what Woody can align. Positive shifts mean a trial was estimated later than the evolving template and shifted earlier before averaging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .cwtRidge:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Toggle("All categories", isOn: $viewModel.cwtRunsAllCategories)
                            .toggleStyle(.checkbox)
                            .help("Run CWT Ridge separately for every available category using the highlighted window.")
                        Toggle("Wavelet denoise", isOn: $viewModel.cwtAppliesDenoising)
                            .toggleStyle(.checkbox)
                            .help("Apply wavelet shrinkage denoising to each trial before ridge detection and alignment.")
                        Picker("Peaks", selection: $viewModel.cwtPeakSource) {
                            ForEach(CWTRidgePipeline.PeakSource.allCases) { source in
                                Text(source.rawValue).tag(source)
                            }
                        }
                        .frame(width: 200)
                        .help("Detect the peaks that drive alignment from each single trial (max flexibility, noisier) or from the condition average (stabler).")
                        Picker("Engine", selection: $viewModel.cwtEngine) {
                            ForEach(NonlinearAligner.Engine.allCases) { engine in
                                Text(engine.rawValue).tag(engine)
                            }
                        }
                        .frame(width: 210)
                        .help("DTW warps each trial onto the template (multi-component, monotone). Curve Registration warps detected peaks onto template peaks. Maximum Likelihood is a MAP rigid shift with a smoothness prior.")
                    }
                    HStack(spacing: 16) {
                        Picker("Wavelet", selection: $viewModel.cwtWavelet) {
                            ForEach(WaveletTransforms.CWTWavelet.allCases) { wavelet in
                                Text(wavelet.rawValue).tag(wavelet)
                            }
                        }
                        .frame(width: 210)
                        .help("Mother wavelet for the continuous transform. Ricker (Mexican hat) is broad and robust; Morlet is more oscillatory.")
                        Picker("Polarity", selection: $viewModel.cwtRidgePolarity) {
                            ForEach(CWTRidgeDetector.Polarity.allCases) { polarity in
                                Text(polarity.rawValue).tag(polarity)
                            }
                        }
                        .frame(width: 150)
                        .help("Restrict detected peaks to positive, negative, or either polarity.")
                        labeledField("Min SNR", value: $viewModel.cwtMinSNR, width: 60,
                                     help: "A ridge's peak strength must exceed this multiple of the estimated noise level to count as a peak.")
                        labeledField("Min scale", value: $viewModel.cwtMinScale, width: 64,
                                     help: "Smallest wavelet scale (samples). Lower detects narrower peaks.")
                        labeledField("Max scale", value: $viewModel.cwtMaxScale, width: 64,
                                     help: "Largest wavelet scale (samples). Higher detects broader components.")
                    }
                    HStack(spacing: 16) {
                        labeledField("Max shift ± ms", value: $viewModel.cwtMaxShiftMs, width: 78,
                                     help: "Largest latency shift the DTW / maximum-likelihood engines may apply per trial.")
                        labeledStepper("DTW band", value: $viewModel.cwtSakoeChibaBand, range: 2...200,
                                       help: "Sakoe-Chiba band half-width (samples): how far the DTW warp may drift from the diagonal.")
                        labeledField("Prior σ ms", value: $viewModel.cwtPriorSigmaMs, width: 72,
                                     help: "Standard deviation of the Gaussian shift prior used by the maximum-likelihood engine. Smaller keeps shifts near zero.")
                        Toggle("Functional PCA", isOn: $viewModel.cwtComputesFunctionalPCA)
                            .toggleStyle(.checkbox)
                            .help("After alignment, decompose the aligned trials into amplitude modes (functional PCA) to summarize residual variability.")
                    }
                    Text("The highlighted window restricts where peaks are detected. Denoising → CWT ridge peaks → non-linear alignment. Net shift is each trial's dominant-deflection latency relative to the template.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ride:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        Toggle("All categories", isOn: $viewModel.rideRunsAllCategories)
                            .toggleStyle(.checkbox)
                            .help("Run RIDE separately for every available category using the selected channel/ROI and component windows.")
                        Toggle("Wavelet denoise", isOn: $viewModel.rideAppliesDenoising)
                            .toggleStyle(.checkbox)
                            .help("Apply wavelet shrinkage denoising to each trial before RIDE decomposition.")
                        Toggle("S", isOn: $viewModel.rideIncludesStimulusComponent)
                            .toggleStyle(.checkbox)
                            .help("Include the stimulus-locked S component.")
                        Toggle("C", isOn: $viewModel.rideIncludesCentralComponent)
                            .toggleStyle(.checkbox)
                            .help("Include the latency-variable central C component.")
                        Toggle("R", isOn: $viewModel.rideIncludesResponseComponent)
                            .toggleStyle(.checkbox)
                            .help("Include the response-locked R component.")
                        Picker("C search", selection: $viewModel.rideCentralLatencySearchMode) {
                            ForEach(RIDEAnalyzer.CentralLatencySearchMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .frame(width: 180)
                        .disabled(!viewModel.rideIncludesCentralComponent || viewModel.rideCentralLatencySource != .estimated)
                        .help("Most probable prefers a nearby plausible correlation peak; Largest peak chooses the strongest peak in the search range.")
                        labeledField("C max lag ± ms", value: $viewModel.rideCentralMaxLagMs, width: 74)
                        labeledStepper("Iterations", value: $viewModel.rideMaxIterations, range: 1...30)
                        labeledStepper("Tolerance samples", value: $viewModel.rideConvergenceToleranceSamples, range: 0...20)
                    }
                    HStack(spacing: 14) {
                        if viewModel.rideIncludesStimulusComponent {
                            latencySourcePicker("S latency", selection: $viewModel.rideStimulusLatencySource, sources: [.stimulusLocked, .fixed])
                            if viewModel.rideStimulusLatencySource == .fixed {
                                labeledField("S fixed ms", value: $viewModel.rideFixedStimulusLatencyMs, width: 72)
                            }
                        }
                        if viewModel.rideIncludesCentralComponent {
                            latencySourcePicker("C latency", selection: $viewModel.rideCentralLatencySource, sources: [.estimated, .stimulusLocked, .fixed])
                            if viewModel.rideCentralLatencySource == .fixed {
                                labeledField("C fixed ms", value: $viewModel.rideFixedCentralLatencyMs, width: 72)
                            }
                        }
                        if viewModel.rideIncludesResponseComponent {
                            latencySourcePicker("R latency", selection: $viewModel.rideResponseLatencySource, sources: [.fixed, .stimulusLocked])
                            if viewModel.rideResponseLatencySource == .fixed || viewModel.rideResponseLatencySource == .estimated {
                                labeledField("R latency ms", value: $viewModel.rideDefaultResponseLatencyMs, width: 78)
                            }
                        }
                    }
                    Text("Drag each labeled component window on the butterfly trace. C estimation uses its own window; S and R windows define the component ranges used during decomposition.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func latencySourcePicker(
        _ label: String,
        selection: Binding<RIDEAnalyzer.LatencySource>,
        sources: [RIDEAnalyzer.LatencySource]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(sources) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
        .help("\(label) source for RIDE component locking.")
    }

    private func labeledField(_ label: String, value: Binding<Double>, width: CGFloat, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
        .help(help ?? label)
    }

    private func labeledStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Stepper("\(value.wrappedValue)", value: value, in: range)
                .frame(width: 130)
        }
        .help(help ?? label)
    }

    // MARK: - Run

    private var runBar: some View {
        HStack(spacing: 12) {
            Button(runButtonTitle) { runCurrentMode() }
                .disabled(!canRun || viewModel.isRunning)
                .keyboardShortcut(.defaultAction)
            if let progress = viewModel.runProgress, viewModel.isRunning {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: min(max(progress.fraction, 0), 1))
                        .frame(width: 210)
                    HStack(spacing: 4) {
                        Text(progress.title)
                            .fontWeight(.semibold)
                        Text(progress.detail)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(progress.title). \(progress.detail)")
            }
            if !canRun {
                Text("Pick a category, channel/ROI, and drag a window on the trace above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var runButtonTitle: String {
        switch viewModel.analysisMode {
        case .measurements: "Run Analysis"
        case .woody: "Run Woody Alignment"
        case .ride: "Run RIDE"
        case .cwtRidge: "Run CWT Ridge"
        }
    }

    private func runCurrentMode() {
        switch viewModel.analysisMode {
        case .measurements:
            runAnalysis()
        case .woody:
            runWoodyAlignment()
        case .ride:
            runRIDE()
        case .cwtRidge:
            runCWTRidge()
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

        let trials = measurementTrials(category: category, rawSignal: rawSignal)

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

    private func runWoodyAlignment() {
        guard let category = viewModel.selectedCategory,
              let rawSignal,
              !selectedChannelIndices.isEmpty else { return }

        latencyAnalysisTask?.cancel()
        viewModel.isRunning = true
        viewModel.runProgress = SingleTrialRunProgress(
            fraction: 0,
            title: "Woody",
            detail: "Preparing selected trials..."
        )
        viewModel.statusMessage = nil
        woodyAlignedPreview = nil

        let job = SingleTrialWoodyRunJob(
            rawSignal: rawSignal,
            rawSegments: rawSegments,
            averagedSegments: averagedSegments,
            categories: analysisCategories(runAll: viewModel.woodyRunsAllCategories),
            selectedCategory: category,
            selectedChannelIndices: selectedChannelIndices,
            averageReference: averageReference,
            baselineCorrected: baselineCorrected,
            badChannels: badChannels,
            windowStartMs: viewModel.windowStartMs ?? 0,
            windowEndMs: viewModel.windowEndMs ?? 0,
            maxLagMs: viewModel.woodyMaxLagMs,
            maxIterations: viewModel.woodyMaxIterations,
            convergenceToleranceSamples: viewModel.woodyConvergenceToleranceSamples,
            alignmentMode: viewModel.woodyAlignmentMode,
            peakPolarity: viewModel.woodyPeakPolarity,
            appliesDenoising: viewModel.woodyAppliesDenoising
        )

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: SingleTrialRunProgress) in
            viewModel.runProgress = update
        }

        latencyAnalysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                await SingleTrialLatencyRunner.runWoody(job: job, progress: progressContinuation)
            }
            let output = await worker.value
            await ProgressBridge.finishAndWait(progressContinuation, task: progressTask)
            guard !Task.isCancelled else { return }

            let result = output.resultsByCategory[category]
            viewModel.woodyResult = result
            viewModel.woodyResultCategory = category
            viewModel.woodyResultChannelIndices = selectedChannelIndices
            viewModel.woodyResultsByCategory = output.resultsByCategory
            woodyAlignedPreview = output.alignedButterflyPreview
        viewModel.showsWoodyAlignedOverlay = result != nil
        viewModel.woodyAlignmentAnimationProgress = 1
        viewModel.isWoodyAlignmentAnimating = false
        viewModel.isRIDEAlignmentAnimating = false
        viewModel.statusMessage = output.resultsByCategory.isEmpty ? "Could not compute Woody alignment for this window." : nil
            viewModel.runProgress = nil
            viewModel.isRunning = false
            latencyAnalysisTask = nil
        }
    }

    private func runRIDE() {
        guard let category = viewModel.selectedCategory,
              let rawSignal,
              !selectedChannelIndices.isEmpty else { return }

        latencyAnalysisTask?.cancel()
        viewModel.isRunning = true
        viewModel.runProgress = SingleTrialRunProgress(
            fraction: 0,
            title: "RIDE",
            detail: "Preparing selected trials..."
        )
        viewModel.statusMessage = nil
        rideAlignedPreview = nil

        let job = SingleTrialRIDERunJob(
            rawSignal: rawSignal,
            rawSegments: rawSegments,
            averagedSegments: averagedSegments,
            categories: analysisCategories(runAll: viewModel.rideRunsAllCategories),
            selectedCategory: category,
            selectedChannelIndices: selectedChannelIndices,
            averageReference: averageReference,
            baselineCorrected: baselineCorrected,
            badChannels: badChannels,
            configuration: rideConfiguration(),
            appliesDenoising: viewModel.rideAppliesDenoising
        )

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: SingleTrialRunProgress) in
            viewModel.runProgress = update
        }

        latencyAnalysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                await SingleTrialLatencyRunner.runRIDE(job: job, progress: progressContinuation)
            }
            let output = await worker.value
            await ProgressBridge.finishAndWait(progressContinuation, task: progressTask)
            guard !Task.isCancelled else { return }

            let result = output.resultsByCategory[category]
            viewModel.rideResult = result
            viewModel.rideResultCategory = category
        viewModel.rideResultChannelIndices = selectedChannelIndices
        viewModel.rideResultsByCategory = output.resultsByCategory
        rideAlignedPreview = output.alignedButterflyPreview
        viewModel.showsRIDEAlignedOverlay = result != nil
        viewModel.rideAlignmentAnimationProgress = 1
        viewModel.isRIDEAlignmentAnimating = false
        viewModel.isWoodyAlignmentAnimating = false
        viewModel.statusMessage = output.resultsByCategory.isEmpty ? "Could not compute RIDE decomposition for this window and component set." : nil
            viewModel.runProgress = nil
            viewModel.isRunning = false
            latencyAnalysisTask = nil
        }
    }

    private func runCWTRidge() {
        guard let category = viewModel.selectedCategory,
              let rawSignal,
              !selectedChannelIndices.isEmpty else { return }

        latencyAnalysisTask?.cancel()
        viewModel.isRunning = true
        viewModel.runProgress = SingleTrialRunProgress(
            fraction: 0,
            title: "CWT Ridge",
            detail: "Preparing selected trials..."
        )
        viewModel.statusMessage = nil

        let job = SingleTrialCWTRunJob(
            rawSignal: rawSignal,
            rawSegments: rawSegments,
            categories: analysisCategories(runAll: viewModel.cwtRunsAllCategories),
            selectedChannelIndices: selectedChannelIndices,
            samplingRate: rawSignal.samplingRate,
            configuration: cwtConfiguration(samplingRate: rawSignal.samplingRate)
        )

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: SingleTrialRunProgress) in
            viewModel.runProgress = update
        }

        latencyAnalysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                await SingleTrialLatencyRunner.runCWT(job: job, progress: progressContinuation)
            }
            let output = await worker.value
            await ProgressBridge.finishAndWait(progressContinuation, task: progressTask)
            guard !Task.isCancelled else { return }

            let result = output.resultsByCategory[category]
            viewModel.cwtResult = result
            viewModel.cwtResultCategory = category
            viewModel.cwtResultChannelIndices = selectedChannelIndices
            viewModel.cwtResultsByCategory = output.resultsByCategory
            viewModel.statusMessage = output.resultsByCategory.isEmpty
                ? "Could not compute CWT Ridge alignment for this window and settings."
                : nil
            viewModel.runProgress = nil
            viewModel.isRunning = false
            latencyAnalysisTask = nil
        }
    }

    private func cwtConfiguration(samplingRate: Double) -> CWTRidgePipeline.Configuration {
        var config = CWTRidgePipeline.Configuration()
        config.appliesDenoising = viewModel.cwtAppliesDenoising
        config.peakSource = viewModel.cwtPeakSource
        config.engine = viewModel.cwtEngine
        config.windowStartMs = viewModel.windowStartMs
        config.windowEndMs = viewModel.windowEndMs
        config.sakoeChibaBand = max(2, viewModel.cwtSakoeChibaBand)
        config.maxShiftSamples = max(1, Int((viewModel.cwtMaxShiftMs / 1000.0 * samplingRate).rounded()))
        config.priorSigmaSamples = max(1, viewModel.cwtPriorSigmaMs / 1000.0 * samplingRate)
        config.computesFunctionalPCA = viewModel.cwtComputesFunctionalPCA
        config.ridge.wavelet = viewModel.cwtWavelet
        config.ridge.polarity = viewModel.cwtRidgePolarity
        config.ridge.minSNR = viewModel.cwtMinSNR
        config.ridge.minScale = viewModel.cwtMinScale
        config.ridge.maxScale = viewModel.cwtMaxScale
        return config
    }

    private func analysisCategories(runAll: Bool) -> [String] {
        if runAll {
            return categories.filter { category in
                rawSegments.contains(where: { $0.category == category })
                    && averagedSegments.contains(where: { $0.category == category })
            }
        }
        return viewModel.selectedCategory.map { [$0] } ?? []
    }

    private func woodyResult(category: String, rawSignal: MFFSignalData) -> WoodyAlignmentAnalyzer.Result? {
        WoodyAlignmentAnalyzer.align(
            trials: woodyTrials(category: category, rawSignal: rawSignal),
            samplingRate: rawSignal.samplingRate,
            windowStartMs: viewModel.windowStartMs ?? 0,
            windowEndMs: viewModel.windowEndMs ?? 0,
            maxLagMs: viewModel.woodyMaxLagMs,
            maxIterations: viewModel.woodyMaxIterations,
            convergenceToleranceSamples: viewModel.woodyConvergenceToleranceSamples,
            alignmentMode: viewModel.woodyAlignmentMode,
            peakPolarity: viewModel.woodyPeakPolarity
        )
    }

    private func rideResult(category: String, rawSignal: MFFSignalData) -> RIDEAnalyzer.Result? {
        RIDEAnalyzer.decompose(
            trials: rideTrials(category: category, rawSignal: rawSignal),
            samplingRate: rawSignal.samplingRate,
            configuration: rideConfiguration()
        )
    }

    private func rideConfiguration() -> RIDEAnalyzer.Configuration {
        RIDEAnalyzer.Configuration(
            includesStimulusComponent: viewModel.rideIncludesStimulusComponent,
            includesCentralComponent: viewModel.rideIncludesCentralComponent,
            includesResponseComponent: viewModel.rideIncludesResponseComponent,
            stimulusWindow: RIDEAnalyzer.ComponentWindow(
                startMs: viewModel.rideStimulusWindowStartMs,
                endMs: viewModel.rideStimulusWindowEndMs
            ),
            centralWindow: RIDEAnalyzer.ComponentWindow(
                startMs: viewModel.rideCentralWindowStartMs,
                endMs: viewModel.rideCentralWindowEndMs
            ),
            responseWindow: RIDEAnalyzer.ComponentWindow(
                startMs: viewModel.rideResponseWindowStartMs,
                endMs: viewModel.rideResponseWindowEndMs
            ),
            stimulusLatencySource: viewModel.rideStimulusLatencySource,
            centralLatencySource: viewModel.rideCentralLatencySource,
            responseLatencySource: viewModel.rideResponseLatencySource,
            centralMaxLagMs: viewModel.rideCentralMaxLagMs,
            fixedStimulusLatencyMs: viewModel.rideFixedStimulusLatencyMs,
            fixedCentralLatencyMs: viewModel.rideFixedCentralLatencyMs,
            defaultResponseLatencyMs: viewModel.rideDefaultResponseLatencyMs,
            centralLatencySearchMode: viewModel.rideCentralLatencySearchMode,
            maxIterations: viewModel.rideMaxIterations,
            convergenceToleranceSamples: viewModel.rideConvergenceToleranceSamples
        )
    }

    private func measurementTrials(category: String, rawSignal: MFFSignalData) -> [SingleTrialAnalyzer.TrialInput] {
        let segments = rawSegments.filter { $0.category == category }
        let aligned = (viewModel.usesWoodyAlignedTrialsForMeasurements
                       && hasCurrentWoodyAlignment
                       && currentWoodyResult?.alignedTrials.count == segments.count)
            ? currentWoodyResult?.alignedTrials
            : nil
        return segments.enumerated().map { index, segment in
            SingleTrialAnalyzer.TrialInput(
                sourceTimeSeconds: segment.sourceTimeSeconds,
                stimulusOffsetSamples: segment.stimulusOffsetSamples,
                samples: aligned?[index] ?? channelResolvedSamples(
                    signal: rawSignal,
                    startSample: segment.startSample,
                    endSample: segment.endSample,
                    channels: selectedChannelIndices
                )
            )
        }
    }

    private func woodyTrials(category: String, rawSignal: MFFSignalData) -> [WoodyAlignmentAnalyzer.TrialInput] {
        rawSegments
            .filter { $0.category == category }
            .map { segment in
                WoodyAlignmentAnalyzer.TrialInput(
                    sourceTimeSeconds: segment.sourceTimeSeconds,
                    stimulusOffsetSamples: segment.stimulusOffsetSamples,
                    samples: channelResolvedSamples(
                        signal: rawSignal,
                        startSample: segment.startSample,
                        endSample: segment.endSample,
                        channels: selectedChannelIndices
                    )
                )
            }
    }

    private func rideTrials(category: String, rawSignal: MFFSignalData) -> [RIDEAnalyzer.TrialInput] {
        rawSegments
            .filter { $0.category == category }
            .map { segment in
                RIDEAnalyzer.TrialInput(
                    sourceTimeSeconds: segment.sourceTimeSeconds,
                    stimulusOffsetSamples: segment.stimulusOffsetSamples,
                    responseLatencyMs: viewModel.rideIncludesResponseComponent ? viewModel.rideDefaultResponseLatencyMs : nil,
                    samples: channelResolvedSamples(
                        signal: rawSignal,
                        startSample: segment.startSample,
                        endSample: segment.endSample,
                        channels: selectedChannelIndices
                    )
                )
            }
    }

    private var hasCurrentWoodyAlignment: Bool {
        currentWoodyResult != nil
            && viewModel.woodyResultChannelIndices == selectedChannelIndices
    }

    private var currentWoodyResult: WoodyAlignmentAnalyzer.Result? {
        guard let category = viewModel.selectedCategory else { return viewModel.woodyResult }
        return viewModel.woodyResultsByCategory[category] ?? viewModel.woodyResult
    }

    private var currentRIDEResult: RIDEAnalyzer.Result? {
        guard let category = viewModel.selectedCategory else { return viewModel.rideResult }
        return viewModel.rideResultsByCategory[category] ?? viewModel.rideResult
    }

    private var currentCWTResult: CWTRidgePipeline.Result? {
        guard let category = viewModel.selectedCategory else { return viewModel.cwtResult }
        return viewModel.cwtResultsByCategory[category] ?? viewModel.cwtResult
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

    @ViewBuilder
    private func woodyResultsSection(_ result: WoodyAlignmentAnalyzer.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Text("\(result.shifts.count) trials aligned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.converged ? "Converged" : "Reached iteration limit")
                    .font(.caption)
                    .foregroundStyle(result.converged ? Color.secondary : Color.orange)
                if let last = result.iterations.last {
                    Text("Mean r: \(String(format: "%.3f", last.meanCorrelation))")
                        .font(.caption.monospacedDigit())
                    Text("Iterations: \(last.iteration)")
                        .font(.caption.monospacedDigit())
                }
            }

            labeledChart("Original vs Woody-Aligned Averages") {
                alignedAverageAndButterflyRow(
                    alignedAverages: viewModel.woodyResultsByCategory.mapValues(\.alignedAverage),
                    alignedLabel: "Woody",
                    alignedButterfly: woodyAlignedPreview
                )
            }
            .frame(height: 220)

            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 18) {
                    woodyShiftTable(result)
                        .frame(width: proxy.size.width * 0.5)
                        .frame(minHeight: 260)
                    woodyIterationView(result)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(minHeight: 280)
        }
    }

    // MARK: - CWT Ridge results

    @ViewBuilder
    private func cwtResultsSection(_ result: CWTRidgePipeline.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Text("\(result.trials.count) trials aligned")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Engine: \(result.engine.rawValue)")
                    .font(.caption.monospacedDigit())
                Text("Peaks: \(result.peakSource.rawValue)")
                    .font(.caption)
                if result.denoised {
                    Text("Denoised").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(result.templatePeaks.count) template peak(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            labeledChart("Original vs CWT-Aligned Average") {
                cwtAverageChart(result)
            }
            .frame(height: 220)

            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 18) {
                    cwtPeaksTable(result)
                        .frame(width: proxy.size.width * 0.46)
                        .frame(minHeight: 240)
                    VStack(alignment: .leading, spacing: 12) {
                        cwtTrialShiftTable(result)
                        if let fpca = result.functionalPCA {
                            cwtFunctionalPCAView(fpca)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(minHeight: 280)
        }
    }

    private func cwtAverageChart(_ result: CWTRidgePipeline.Result) -> some View {
        Chart {
            ForEach(Array(result.unalignedAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Original")
                )
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(Array(result.alignedAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "CWT-aligned")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            ForEach(result.templatePeaks) { peak in
                RuleMark(x: .value("Sample", peak.sampleIndex))
                    .foregroundStyle(.orange.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartLegend(position: .bottom)
    }

    private func cwtPeaksTable(_ result: CWTRidgePipeline.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Template peaks").font(.caption.weight(.semibold))
            Table(result.templatePeaks) {
                TableColumn("Latency (ms)") { peak in
                    Text(peak.latencyMs.map { String(format: "%.0f", $0) } ?? "—")
                }.width(88)
                TableColumn("Width (smp)") { peak in
                    Text(String(format: "%.1f", peak.widthSamples))
                }.width(84)
                TableColumn("Pol") { peak in
                    Text(peak.polaritySign >= 0 ? "+" : "−")
                }.width(40)
                TableColumn("Amp") { peak in
                    Text(String(format: "%.2f", peak.amplitude))
                }.width(70)
                TableColumn("SNR") { peak in
                    Text(String(format: "%.1f", peak.snr))
                }.width(58)
            }
            .frame(minHeight: 200)
        }
    }

    private func cwtTrialShiftTable(_ result: CWTRidgePipeline.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per-trial shifts").font(.caption.weight(.semibold))
            Table(result.trials) {
                TableColumn("#") { Text("\($0.trialIndex + 1)") }.width(42)
                TableColumn("Time (s)") { Text(String(format: "%.1f", $0.sourceTimeSeconds)) }.width(72)
                TableColumn("Net shift (ms)") { Text(String(format: "%.1f", $0.netShiftMs)) }.width(104)
                TableColumn("r") { Text(String(format: "%.3f", $0.correlation)) }.width(60)
                TableColumn("Peaks") { Text("\($0.detectedPeaks.count)") }.width(56)
            }
            .frame(minHeight: 200)
        }
    }

    private func cwtFunctionalPCAView(_ fpca: NonlinearAligner.FunctionalPCA) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Functional PCA — variance explained")
                .font(.caption.weight(.semibold))
            ForEach(Array(fpca.explainedVariance.enumerated()), id: \.offset) { index, fraction in
                HStack(spacing: 8) {
                    Text("PC\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .leading)
                    ProgressView(value: min(max(fraction, 0), 1))
                        .frame(width: 140)
                    Text(String(format: "%.1f%%", fraction * 100))
                        .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func woodyAverageChart(_ result: WoodyAlignmentAnalyzer.Result) -> some View {
        Chart {
            ForEach(Array(result.unalignedAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Original")
                )
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(Array(result.alignedAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Woody-aligned")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
            }
        }
        .chartLegend(position: .bottom)
    }

    private func woodyShiftTable(_ result: WoodyAlignmentAnalyzer.Result) -> some View {
        Table(sortedWoodyShifts(result), sortOrder: $woodySortOrder) {
            TableColumn("#", value: \.trialIndex) { Text("\($0.trialIndex + 1)") }.width(42)
            TableColumn("Time (s)", value: \.sourceTimeSeconds) { Text(String(format: "%.1f", $0.sourceTimeSeconds)) }.width(74)
            TableColumn("Shift (ms)", value: \.latencyShiftMs) { Text(String(format: "%.1f", $0.latencyShiftMs)) }.width(86)
            TableColumn("Shift (samples)", value: \.latencyShiftSamples) { Text("\($0.latencyShiftSamples)") }.width(108)
            TableColumn("r", value: \.correlation) { Text(String(format: "%.3f", $0.correlation)) }.width(64)
        }
    }

    private func sortedWoodyShifts(_ result: WoodyAlignmentAnalyzer.Result) -> [WoodyAlignmentAnalyzer.TrialShift] {
        guard !woodySortOrder.isEmpty else { return result.shifts }
        return result.shifts.sorted(using: woodySortOrder)
    }

    private func woodyIterationView(_ result: WoodyAlignmentAnalyzer.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Woody Convergence")
                .font(.caption.weight(.semibold))
            ForEach(result.iterations) { iteration in
                HStack {
                    Text("\(iteration.iteration)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 24, alignment: .trailing)
                    Text("\(iteration.changedTrialCount) changed")
                        .font(.caption)
                    Spacer()
                    Text("Δ \(iteration.maxShiftChangeSamples)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func rideResultsSection(_ result: RIDEAnalyzer.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Text("\(result.trialLatencies.count) trials decomposed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Components: \(result.components.map { $0.component.label }.joined(separator: " + "))")
                    .font(.caption.monospacedDigit())
                if viewModel.rideIncludesCentralComponent {
                    Text(result.converged ? "Converged" : "Reached iteration limit")
                        .font(.caption)
                        .foregroundStyle(result.converged ? Color.secondary : Color.orange)
                    if let last = result.iterations.last {
                        Text("Mean C r: \(String(format: "%.3f", last.meanCentralCorrelation))")
                            .font(.caption.monospacedDigit())
                        Text("Stable: \(Int((last.unchangedCentralLatencyFraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            Text("S is stimulus-locked at 0 ms for every trial; C and optional R are the components with trial-specific latency estimates.")
                .font(.caption)
                .foregroundStyle(.secondary)

            labeledChart("Original vs RIDE-Aligned Averages") {
                alignedAverageAndButterflyRow(
                    alignedAverages: rideAlignedAveragesByCategory(),
                    alignedLabel: "RIDE",
                    alignedButterfly: rideAlignedPreview
                )
            }
            .frame(height: 220)

            labeledChart("RIDE Components, Reconstruction, and Residual") {
                rideMergedDiagnosticChart(result)
            }
            .frame(height: 190)

            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 18) {
                    rideLatencyTable(result)
                        .frame(width: proxy.size.width * 0.5)
                        .frame(minHeight: 260)
                    rideIterationView(result)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(minHeight: 280)
        }
    }

    private func labeledChart<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .clipped()
        }
        .clipped()
    }

    private func alignedAverageAndButterflyRow(
        alignedAverages: [String: [Float]],
        alignedLabel: String,
        alignedButterfly: SingleTrialAlignedButterflyPreview?
    ) -> some View {
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 14) {
                alignedCategoryAverageChart(alignedAverages: alignedAverages, alignedLabel: alignedLabel)
                    .frame(width: proxy.size.width * 0.5 - 7)
                    .clipped()
                alignedButterflyChart(preview: alignedButterfly, alignedLabel: alignedLabel)
                    .frame(width: proxy.size.width * 0.5 - 7)
                    .clipped()
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func alignedButterflyChart(preview: SingleTrialAlignedButterflyPreview?, alignedLabel: String) -> some View {
        if let preview {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(alignedLabel)-Aligned Butterfly")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                OverlayButterflyPlot(
                    data: preview.signal.data,
                    segments: preview.segments,
                    colors: preview.segments.map { categoryColor($0.category) },
                    hiddenChannels: hiddenChannels,
                    amplitudeScale: amplitudeScale,
                    samplingRate: preview.signal.samplingRate,
                    channelName: channelName
                )
                .clipped()
            }
        } else {
            ContentUnavailableView("No aligned butterfly", systemImage: "waveform.path.ecg")
        }
    }

    private func alignedCategoryAverageChart(alignedAverages: [String: [Float]], alignedLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                lineLegendItem(label: "Original", color: .secondary, style: StrokeStyle(lineWidth: 1.4))
                lineLegendItem(label: alignedLabel, color: .secondary, style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                Spacer()
            }
            .padding(.leading, 2)

            Chart {
                ForEach(alignedComparisonCategories(alignedAverages: alignedAverages), id: \.self) { category in
                    if let original = originalAverage(category: category) {
                        ForEach(Array(original.enumerated()), id: \.offset) { index, value in
                            LineMark(
                                x: .value("Sample", index),
                                y: .value("Amplitude", Double(value)),
                                series: .value("Trace", "\(displayCategory(category)) original")
                            )
                            .foregroundStyle(categoryColor(category))
                            .lineStyle(StrokeStyle(lineWidth: category == viewModel.selectedCategory ? 1.6 : 1.0))
                        }
                    }
                    if let aligned = alignedAverages[category] {
                        ForEach(Array(aligned.enumerated()), id: \.offset) { index, value in
                            LineMark(
                                x: .value("Sample", index),
                                y: .value("Amplitude", Double(value)),
                                series: .value("Trace", "\(displayCategory(category)) \(alignedLabel)")
                            )
                            .foregroundStyle(categoryColor(category))
                            .lineStyle(StrokeStyle(lineWidth: category == viewModel.selectedCategory ? 1.8 : 1.2, dash: [4, 3]))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: -amplitudeScale...amplitudeScale)
        }
        .clipped()
    }

    private func lineLegendItem(label: String, color: Color, style: StrokeStyle) -> some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(color), style: style)
            }
            .frame(width: 24, height: 10)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func alignedComparisonCategories(alignedAverages: [String: [Float]]) -> [String] {
        let categorySet = Set(alignedAverages.keys)
        let ordered = categories.filter { categorySet.contains($0) }
        return ordered.isEmpty ? viewModel.selectedCategory.map { [$0] } ?? [] : ordered
    }

    private func originalAverage(category: String) -> [Float]? {
        guard let averageSignal = averagedSignal,
              let segment = averagedSegments.first(where: { $0.category == category }) else { return nil }
        let samples = channelResolvedSamples(
            signal: averageSignal,
            startSample: segment.startSample,
            endSample: segment.endSample,
            channels: selectedChannelIndices
        )
        return samples.isEmpty ? nil : samples
    }

    private func setRIDEComponentWindow(_ component: RIDEAnalyzer.Component, startMs: Double, endMs: Double) {
        let orderedStart = min(startMs, endMs)
        let orderedEnd = max(startMs, endMs)
        switch component {
        case .stimulus:
            viewModel.rideStimulusWindowStartMs = orderedStart
            viewModel.rideStimulusWindowEndMs = orderedEnd
        case .central:
            viewModel.rideCentralWindowStartMs = orderedStart
            viewModel.rideCentralWindowEndMs = orderedEnd
            viewModel.windowStartMs = orderedStart
            viewModel.windowEndMs = orderedEnd
        case .response:
            viewModel.rideResponseWindowStartMs = orderedStart
            viewModel.rideResponseWindowEndMs = orderedEnd
        }
    }

    private func rideAlignedAveragesByCategory() -> [String: [Float]] {
        viewModel.rideResultsByCategory.compactMapValues { result in
            result.centralAlignedAverage ?? result.responseAlignedAverage ?? result.reconstructionAverage
        }
    }

    private func rideAlignedAverageChart(_ result: RIDEAnalyzer.Result) -> some View {
        Chart {
            ForEach(Array(result.erpAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Original ERP")
                )
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            if let centralAlignedAverage = result.centralAlignedAverage {
                ForEach(Array(centralAlignedAverage.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Amplitude", Double(value)),
                        series: .value("Trace", "C-aligned average")
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
            }
            if let responseAlignedAverage = result.responseAlignedAverage {
                ForEach(Array(responseAlignedAverage.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Amplitude", Double(value)),
                        series: .value("Trace", "R-aligned average")
                    )
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
            }
        }
        .chartLegend(position: .bottom)
        .chartYScale(domain: -amplitudeScale...amplitudeScale)
    }

    private func rideMergedDiagnosticChart(_ result: RIDEAnalyzer.Result) -> some View {
        Chart {
            ForEach(Array(result.erpAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Original ERP")
                )
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.0))
            }
            if let centralAlignedAverage = result.centralAlignedAverage {
                ForEach(Array(centralAlignedAverage.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Amplitude", Double(value)),
                        series: .value("Trace", "C-aligned")
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
            }
            if let responseAlignedAverage = result.responseAlignedAverage {
                ForEach(Array(responseAlignedAverage.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Amplitude", Double(value)),
                        series: .value("Trace", "R-aligned")
                    )
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
            }
            ForEach(result.components) { component in
                ForEach(Array(component.stimulusLockedAverage.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Amplitude", Double(value)),
                        series: .value("Trace", "\(component.component.label) component")
                    )
                    .foregroundStyle(color(forRIDEComponent: component.component).opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                }
            }
            ForEach(Array(result.reconstructionAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Reconstruction")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
            }
            ForEach(Array(result.residualAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Residual")
                )
                .foregroundStyle(.red.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
            }
        }
        .chartLegend(position: .bottom)
        .chartYScale(domain: -amplitudeScale...amplitudeScale)
    }

    private func rideComponentChart(_ result: RIDEAnalyzer.Result) -> some View {
        Chart {
            ForEach(result.components) { component in
                ForEach(Array(component.stimulusLockedAverage.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Amplitude", Double(value)),
                        series: .value("Trace", component.component.label)
                    )
                    .foregroundStyle(color(forRIDEComponent: component.component))
                    .lineStyle(StrokeStyle(lineWidth: 1.7))
                }
            }
        }
        .chartLegend(position: .bottom)
        .chartYScale(domain: -amplitudeScale...amplitudeScale)
    }

    private func rideReconstructionChart(_ result: RIDEAnalyzer.Result) -> some View {
        Chart {
            ForEach(Array(result.erpAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Original ERP")
                )
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.0))
            }
            ForEach(Array(result.reconstructionAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Reconstruction")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(Array(result.residualAverage.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Amplitude", Double(value)),
                    series: .value("Trace", "Residual")
                )
                .foregroundStyle(.red.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [4, 3]))
            }
        }
        .chartLegend(position: .bottom)
        .chartYScale(domain: -amplitudeScale...amplitudeScale)
    }

    private func color(forRIDEComponent component: RIDEAnalyzer.Component) -> Color {
        switch component {
        case .stimulus: .blue
        case .central: .green
        case .response: .purple
        }
    }

    private func rideLatencyTable(_ result: RIDEAnalyzer.Result) -> some View {
        Table(sortedRIDELatencies(result), sortOrder: $rideSortOrder) {
            TableColumn("#", value: \.trialIndex) { Text("\($0.trialIndex + 1)") }.width(42)
            TableColumn("Time (s)", value: \.sourceTimeSeconds) { Text(String(format: "%.1f", $0.sourceTimeSeconds)) }.width(74)
            TableColumn("S lock (ms)") { _ in
                Text(viewModel.rideIncludesStimulusComponent ? "0.0" : "—")
            }.width(86)
            TableColumn("S lock (samples)") { _ in
                Text(viewModel.rideIncludesStimulusComponent ? "0" : "—")
            }.width(110)
            TableColumn("C shift (ms)") { row in
                Text(row.centralLatencyShiftMs.map { String(format: "%.1f", $0) } ?? "—")
            }.width(94)
            TableColumn("C shift (samples)") { row in
                Text(row.centralLatencyShiftSamples.map(String.init) ?? "—")
            }.width(116)
            TableColumn("C r") { row in
                Text(row.centralCorrelation.map { String(format: "%.3f", $0) } ?? "—")
            }.width(64)
            TableColumn("R latency (ms)") { row in
                Text(row.responseLatencyMs.map { String(format: "%.1f", $0) } ?? "—")
            }.width(104)
        }
    }

    private func sortedRIDELatencies(_ result: RIDEAnalyzer.Result) -> [RIDEAnalyzer.TrialLatency] {
        guard !rideSortOrder.isEmpty else { return result.trialLatencies }
        return result.trialLatencies.sorted(using: rideSortOrder)
    }

    private func rideIterationView(_ result: RIDEAnalyzer.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RIDE C Convergence")
                .font(.caption.weight(.semibold))
            if result.iterations.isEmpty {
                Text("No C latency iteration was needed for this component set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.iterations) { iteration in
                    HStack {
                        Text("\(iteration.iteration)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 24, alignment: .trailing)
                        Text("\(iteration.changedCentralLatencyCount) changed")
                            .font(.caption)
                        Text("\(Int((iteration.unchangedCentralLatencyFraction * 100).rounded()))% stable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Δ \(iteration.maxCentralLatencyChangeSamples)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("r+ \(iteration.improvedCentralCorrelationCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
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

    private func exportWoodyShifts() {
        guard let result = viewModel.woodyResult else { return }
        var lines = ["Trial\tTimeSeconds\tLatencyShiftMs\tLatencyShiftSamples\tCorrelation"]
        for row in result.shifts {
            lines.append([
                "\(row.trialIndex + 1)",
                String(format: "%.3f", row.sourceTimeSeconds),
                String(format: "%.4f", row.latencyShiftMs),
                "\(row.latencyShiftSamples)",
                String(format: "%.6f", row.correlation)
            ].joined(separator: "\t"))
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "WoodyShifts (\(viewModel.selectedCategory ?? "category")).tsv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func exportRIDELatencies() {
        guard let result = viewModel.rideResult else { return }
        var lines = ["Trial\tTimeSeconds\tStimulusLockMs\tStimulusLockSamples\tCentralShiftMs\tCentralShiftSamples\tCentralCorrelation\tResponseLatencyMs\tResponseLatencySamples"]
        for row in result.trialLatencies {
            let trialNumber = String(row.trialIndex + 1)
            let timeSeconds = String(format: "%.3f", row.sourceTimeSeconds)
            let stimulusLockMs = viewModel.rideIncludesStimulusComponent ? "0.0000" : ""
            let stimulusLockSamples = viewModel.rideIncludesStimulusComponent ? "0" : ""
            let centralShiftMs = row.centralLatencyShiftMs.map { String(format: "%.4f", $0) } ?? ""
            let centralShiftSamples = row.centralLatencyShiftSamples.map(String.init) ?? ""
            let centralCorrelation = row.centralCorrelation.map { String(format: "%.6f", $0) } ?? ""
            let responseLatencyMs = row.responseLatencyMs.map { String(format: "%.4f", $0) } ?? ""
            let responseLatencySamples = row.responseLatencySamples.map(String.init) ?? ""
            lines.append([
                trialNumber,
                timeSeconds,
                stimulusLockMs,
                stimulusLockSamples,
                centralShiftMs,
                centralShiftSamples,
                centralCorrelation,
                responseLatencyMs,
                responseLatencySamples
            ].joined(separator: "\t"))
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "RIDELatencies (\(viewModel.selectedCategory ?? "category")).tsv"
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
    let componentWindows: [RIDEComponentWindowSelection]
    let colorForComponent: (RIDEAnalyzer.Component) -> Color
    let onComponentWindowChange: (RIDEAnalyzer.Component, Double, Double) -> Void
    let onTapChannel: (Int) -> Void

    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?
    @State private var liveWindowStartMs: Double?
    @State private var liveWindowEndMs: Double?
    @State private var componentDrag: ComponentWindowDrag?

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
                    samplingRate: samplingRate,
                    channelName: channelName,
                    onTapChannel: onTapChannel
                )
                if componentWindows.isEmpty, let rect = selectionRect(in: proxy.size) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
                ForEach(componentWindows) { window in
                    if let rect = componentSelectionRect(window, in: proxy.size) {
                        let color = colorForComponent(window.component)
                        Rectangle()
                            .fill(color.opacity(0.14))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                        Path { path in
                            path.move(to: CGPoint(x: rect.minX, y: 0))
                            path.addLine(to: CGPoint(x: rect.minX, y: proxy.size.height))
                            path.move(to: CGPoint(x: rect.maxX, y: 0))
                            path.addLine(to: CGPoint(x: rect.maxX, y: proxy.size.height))
                        }
                        .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .allowsHitTesting(false)
                        Text(window.component.label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                            .offset(x: min(max(rect.midX - 10, 0), max(proxy.size.width - 24, 0)), y: 4)
                            .allowsHitTesting(false)
                        Text(timeLabel(window.startMs))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(color)
                            .padding(.horizontal, 3)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                            .offset(x: min(max(rect.minX + 2, 0), max(proxy.size.width - 44, 0)), y: max(proxy.size.height - 18, 0))
                            .allowsHitTesting(false)
                        Text(timeLabel(window.endMs))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(color)
                            .padding(.horizontal, 3)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                            .offset(x: min(max(rect.maxX - 42, 0), max(proxy.size.width - 44, 0)), y: max(proxy.size.height - 18, 0))
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        if componentWindows.isEmpty {
                            if dragStartX == nil { dragStartX = value.startLocation.x }
                            dragCurrentX = value.location.x
                            updateLiveWindow(width: proxy.size.width)
                        } else {
                            updateComponentWindowDrag(value: value, width: proxy.size.width)
                        }
                    }
                    .onEnded { _ in
                        if componentWindows.isEmpty {
                            if let liveWindowStartMs, let liveWindowEndMs {
                                windowStartMs = liveWindowStartMs
                                windowEndMs = liveWindowEndMs
                            }
                            dragStartX = nil
                            dragCurrentX = nil
                            liveWindowStartMs = nil
                            liveWindowEndMs = nil
                        }
                        componentDrag = nil
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

    private func componentSelectionRect(_ window: RIDEComponentWindowSelection, in size: CGSize) -> CGRect? {
        guard size.width > 0 else { return nil }
        let startSample = relativeSample(forMs: window.startMs)
        let endSample = relativeSample(forMs: window.endMs)
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

    private func timeLabel(_ milliseconds: Double) -> String {
        "\(Int(milliseconds.rounded())) ms"
    }

    private func updateComponentWindowDrag(value: DragGesture.Value, width: CGFloat) {
        guard width > 0 else { return }
        if componentDrag == nil {
            componentDrag = dragTarget(at: value.startLocation.x, width: width)
        }
        guard let drag = componentDrag else { return }
        let xScale = width / CGFloat(max(epochLength - 1, 1))
        let deltaSamples = Int(((value.location.x - value.startLocation.x) / xScale).rounded())
        let minWidthSamples = max(Int((20.0 / 1000.0 * samplingRate).rounded()), 1)
        let epochMaxSample = epochLength - 1
        let originalStart = relativeSample(forMs: drag.startMs)
        let originalEnd = relativeSample(forMs: drag.endMs)

        let next: (start: Int, end: Int)
        switch drag.mode {
        case .move:
            let widthSamples = max(originalEnd - originalStart, minWidthSamples)
            var start = originalStart + deltaSamples
            start = min(max(start, 0), max(epochMaxSample - widthSamples, 0))
            next = (start, min(start + widthSamples, epochMaxSample))
        case .resizeStart:
            let end = originalEnd
            let start = min(max(originalStart + deltaSamples, 0), max(end - minWidthSamples, 0))
            next = (start, end)
        case .resizeEnd:
            let start = originalStart
            let end = max(min(originalEnd + deltaSamples, epochMaxSample), min(start + minWidthSamples, epochMaxSample))
            next = (start, end)
        }
        onComponentWindowChange(
            drag.component,
            msFromRelativeSample(next.start),
            msFromRelativeSample(next.end)
        )
    }

    private func dragTarget(at x: CGFloat, width: CGFloat) -> ComponentWindowDrag? {
        let edgeSlop: CGFloat = 8
        let candidates = componentWindows.compactMap { window -> (window: RIDEComponentWindowSelection, rect: CGRect)? in
            componentSelectionRect(window, in: CGSize(width: width, height: 1)).map { (window, $0) }
        }
        let edgeHit = candidates.first { _, rect in abs(x - rect.minX) <= edgeSlop || abs(x - rect.maxX) <= edgeSlop }
        if let edgeHit {
            let mode: ComponentWindowDrag.Mode = abs(x - edgeHit.rect.minX) <= abs(x - edgeHit.rect.maxX) ? .resizeStart : .resizeEnd
            return ComponentWindowDrag(component: edgeHit.window.component, startMs: edgeHit.window.startMs, endMs: edgeHit.window.endMs, mode: mode)
        }
        if let bodyHit = candidates.first(where: { $0.rect.contains(CGPoint(x: x, y: 0.5)) }) {
            return ComponentWindowDrag(component: bodyHit.window.component, startMs: bodyHit.window.startMs, endMs: bodyHit.window.endMs, mode: .move)
        }
        return nil
    }
}

private struct RIDEComponentWindowSelection: Identifiable, Sendable {
    var component: RIDEAnalyzer.Component
    var startMs: Double
    var endMs: Double

    var id: RIDEAnalyzer.Component { component }
}

private struct ComponentWindowDrag {
    enum Mode {
        case move
        case resizeStart
        case resizeEnd
    }

    var component: RIDEAnalyzer.Component
    var startMs: Double
    var endMs: Double
    var mode: Mode
}

private struct SingleTrialChannelTraceBundle: Identifiable {
    let category: String
    let segment: EpochSegment
    let length: Int
    let averageTrace: [Float]
    let trialTraces: [[Float]]

    var id: String { category }
}

private struct SingleTrialAlignedButterflyPreview: Sendable {
    let signal: MFFSignalData
    let segments: [EpochSegment]
}

private struct SingleTrialWoodyRunJob: Sendable {
    var rawSignal: MFFSignalData
    var rawSegments: [EpochSegment]
    var averagedSegments: [EpochSegment]
    var categories: [String]
    var selectedCategory: String
    var selectedChannelIndices: [Int]
    var averageReference: Bool
    var baselineCorrected: Bool
    var badChannels: Set<Int>
    var windowStartMs: Double
    var windowEndMs: Double
    var maxLagMs: Double
    var maxIterations: Int
    var convergenceToleranceSamples: Int
    var alignmentMode: WoodyAlignmentAnalyzer.AlignmentMode
    var peakPolarity: WoodyAlignmentAnalyzer.PeakPolarity
    var appliesDenoising: Bool
}

private struct SingleTrialRIDERunJob: Sendable {
    var rawSignal: MFFSignalData
    var rawSegments: [EpochSegment]
    var averagedSegments: [EpochSegment]
    var categories: [String]
    var selectedCategory: String
    var selectedChannelIndices: [Int]
    var averageReference: Bool
    var baselineCorrected: Bool
    var badChannels: Set<Int>
    var configuration: RIDEAnalyzer.Configuration
    var appliesDenoising: Bool
}

private struct SingleTrialCWTRunJob: Sendable {
    var rawSignal: MFFSignalData
    var rawSegments: [EpochSegment]
    var categories: [String]
    var selectedChannelIndices: [Int]
    var samplingRate: Double
    var configuration: CWTRidgePipeline.Configuration
}

private struct SingleTrialCWTRunOutput: Sendable {
    var resultsByCategory: [String: CWTRidgePipeline.Result]
}

private struct SingleTrialWoodyRunOutput: Sendable {
    var resultsByCategory: [String: WoodyAlignmentAnalyzer.Result]
    var alignedButterflyPreview: SingleTrialAlignedButterflyPreview?
}

private struct SingleTrialRIDERunOutput: Sendable {
    var resultsByCategory: [String: RIDEAnalyzer.Result]
    var alignedButterflyPreview: SingleTrialAlignedButterflyPreview?
}

private struct SingleTrialWoodyCategoryOutput: Sendable {
    var category: String
    var result: WoodyAlignmentAnalyzer.Result?
}

private struct SingleTrialRIDECategoryOutput: Sendable {
    var category: String
    var result: RIDEAnalyzer.Result?
}

private nonisolated enum SingleTrialLatencyRunner {
    static func runWoody(
        job: SingleTrialWoodyRunJob,
        progress: AsyncStream<SingleTrialRunProgress>.Continuation
    ) async -> SingleTrialWoodyRunOutput {
        let output = await runByCategory(
            categories: job.categories,
            modeTitle: "Woody",
            preparationDetail: "Preparing category waveforms...",
            progress: progress
        ) { category in
            let trials = woodyTrials(category: category, job: job)
            let result = WoodyAlignmentAnalyzer.align(
                trials: trials,
                samplingRate: job.rawSignal.samplingRate,
                windowStartMs: job.windowStartMs,
                windowEndMs: job.windowEndMs,
                maxLagMs: job.maxLagMs,
                maxIterations: job.maxIterations,
                convergenceToleranceSamples: job.convergenceToleranceSamples,
                alignmentMode: job.alignmentMode,
                peakPolarity: job.peakPolarity
            )
            return SingleTrialWoodyCategoryOutput(category: category, result: result)
        }
        progress.yield(SingleTrialRunProgress(
            fraction: 0.92,
            title: "Woody",
            detail: "Building all-channel aligned butterfly..."
        ))
        let preview = await alignedButterflyPreview(
            rawSignal: job.rawSignal,
            rawSegments: job.rawSegments,
            averagedSegments: job.averagedSegments,
            orderedCategories: job.categories,
            shiftsByCategory: output.resultsByCategory.mapValues { $0.shifts.map(\.latencyShiftSamples) },
            averageReference: job.averageReference,
            baselineCorrected: job.baselineCorrected,
            badChannels: job.badChannels
        )
        progress.yield(SingleTrialRunProgress(fraction: 1, title: "Woody", detail: "Ready to plot."))
        return SingleTrialWoodyRunOutput(
            resultsByCategory: output.resultsByCategory,
            alignedButterflyPreview: preview
        )
    }

    static func runRIDE(
        job: SingleTrialRIDERunJob,
        progress: AsyncStream<SingleTrialRunProgress>.Continuation
    ) async -> SingleTrialRIDERunOutput {
        let output = await runByCategory(
            categories: job.categories,
            modeTitle: "RIDE",
            preparationDetail: "Preparing category waveforms...",
            progress: progress
        ) { category in
            let trials = rideTrials(category: category, job: job)
            let result = RIDEAnalyzer.decompose(
                trials: trials,
                samplingRate: job.rawSignal.samplingRate,
                configuration: job.configuration
            )
            return SingleTrialRIDECategoryOutput(category: category, result: result)
        }
        progress.yield(SingleTrialRunProgress(
            fraction: 0.92,
            title: "RIDE",
            detail: "Building all-channel aligned butterfly..."
        ))
        let shiftsByCategory = output.resultsByCategory.compactMapValues { result -> [Int]? in
            let central = result.trialLatencies.compactMap(\.centralLatencyShiftSamples)
            if central.count == result.trialLatencies.count { return central }
            let response = result.trialLatencies.compactMap(\.responseLatencySamples)
            return response.count == result.trialLatencies.count ? response : nil
        }
        let preview = await alignedButterflyPreview(
            rawSignal: job.rawSignal,
            rawSegments: job.rawSegments,
            averagedSegments: job.averagedSegments,
            orderedCategories: job.categories,
            shiftsByCategory: shiftsByCategory,
            averageReference: job.averageReference,
            baselineCorrected: job.baselineCorrected,
            badChannels: job.badChannels
        )
        progress.yield(SingleTrialRunProgress(fraction: 1, title: "RIDE", detail: "Ready to plot."))
        return SingleTrialRIDERunOutput(
            resultsByCategory: output.resultsByCategory,
            alignedButterflyPreview: preview
        )
    }

    static func runCWT(
        job: SingleTrialCWTRunJob,
        progress: AsyncStream<SingleTrialRunProgress>.Continuation
    ) async -> SingleTrialCWTRunOutput {
        guard !job.categories.isEmpty else { return SingleTrialCWTRunOutput(resultsByCategory: [:]) }
        progress.yield(SingleTrialRunProgress(fraction: 0.03, title: "CWT Ridge", detail: "Preparing category waveforms..."))

        var outputs: [(category: String, result: CWTRidgePipeline.Result?)] = []
        outputs.reserveCapacity(job.categories.count)

        await withTaskGroup(of: (String, CWTRidgePipeline.Result?).self) { group in
            for category in job.categories {
                group.addTask {
                    let trials = cwtTrials(category: category, job: job)
                    let result = CWTRidgePipeline.run(
                        trials: trials,
                        samplingRate: job.samplingRate,
                        configuration: job.configuration
                    )
                    return (category, result)
                }
            }
            var completed = 0
            for await (category, result) in group {
                completed += 1
                progress.yield(SingleTrialRunProgress(
                    fraction: 0.05 + 0.9 * Double(completed) / Double(job.categories.count),
                    title: "CWT Ridge \(completed)/\(job.categories.count)",
                    detail: "Finished \(category)"
                ))
                outputs.append((category, result))
            }
        }

        progress.yield(SingleTrialRunProgress(fraction: 1, title: "CWT Ridge", detail: "Ready to plot."))
        return SingleTrialCWTRunOutput(
            resultsByCategory: Dictionary(uniqueKeysWithValues: outputs.compactMap { output in
                output.result.map { (output.category, $0) }
            })
        )
    }

    private static func cwtTrials(category: String, job: SingleTrialCWTRunJob) -> [CWTRidgePipeline.TrialInput] {
        job.rawSegments
            .filter { $0.category == category }
            .map { segment in
                CWTRidgePipeline.TrialInput(
                    sourceTimeSeconds: segment.sourceTimeSeconds,
                    stimulusOffsetSamples: segment.stimulusOffsetSamples,
                    samples: channelResolvedSamples(
                        signal: job.rawSignal,
                        startSample: segment.startSample,
                        endSample: segment.endSample,
                        channels: job.selectedChannelIndices
                    )
                )
            }
    }

    private static func runByCategory(
        categories: [String],
        modeTitle: String,
        preparationDetail: String,
        progress: AsyncStream<SingleTrialRunProgress>.Continuation,
        computeWoody: @escaping @Sendable (String) -> SingleTrialWoodyCategoryOutput
    ) async -> SingleTrialWoodyRunOutput {
        guard !categories.isEmpty else { return SingleTrialWoodyRunOutput(resultsByCategory: [:], alignedButterflyPreview: nil) }
        progress.yield(SingleTrialRunProgress(fraction: 0.03, title: modeTitle, detail: preparationDetail))
        var outputs: [SingleTrialWoodyCategoryOutput] = []
        outputs.reserveCapacity(categories.count)

        await withTaskGroup(of: SingleTrialWoodyCategoryOutput.self) { group in
            for category in categories {
                group.addTask {
                    computeWoody(category)
                }
            }
            var completed = 0
            for await output in group {
                completed += 1
                progress.yield(SingleTrialRunProgress(
                    fraction: 0.05 + 0.85 * Double(completed) / Double(categories.count),
                    title: "\(modeTitle) \(completed)/\(categories.count)",
                    detail: "Finished \(output.category)"
                ))
                outputs.append(output)
            }
        }

        return SingleTrialWoodyRunOutput(
            resultsByCategory: Dictionary(uniqueKeysWithValues: outputs.compactMap { output in
                output.result.map { (output.category, $0) }
            }),
            alignedButterflyPreview: nil
        )
    }

    private static func runByCategory(
        categories: [String],
        modeTitle: String,
        preparationDetail: String,
        progress: AsyncStream<SingleTrialRunProgress>.Continuation,
        computeRIDE: @escaping @Sendable (String) -> SingleTrialRIDECategoryOutput
    ) async -> SingleTrialRIDERunOutput {
        guard !categories.isEmpty else { return SingleTrialRIDERunOutput(resultsByCategory: [:], alignedButterflyPreview: nil) }
        progress.yield(SingleTrialRunProgress(fraction: 0.03, title: modeTitle, detail: preparationDetail))
        var outputs: [SingleTrialRIDECategoryOutput] = []
        outputs.reserveCapacity(categories.count)

        await withTaskGroup(of: SingleTrialRIDECategoryOutput.self) { group in
            for category in categories {
                group.addTask {
                    computeRIDE(category)
                }
            }
            var completed = 0
            for await output in group {
                completed += 1
                progress.yield(SingleTrialRunProgress(
                    fraction: 0.05 + 0.85 * Double(completed) / Double(categories.count),
                    title: "\(modeTitle) \(completed)/\(categories.count)",
                    detail: "Finished \(output.category)"
                ))
                outputs.append(output)
            }
        }

        return SingleTrialRIDERunOutput(
            resultsByCategory: Dictionary(uniqueKeysWithValues: outputs.compactMap { output in
                output.result.map { (output.category, $0) }
            }),
            alignedButterflyPreview: nil
        )
    }

    private static func woodyTrials(category: String, job: SingleTrialWoodyRunJob) -> [WoodyAlignmentAnalyzer.TrialInput] {
        job.rawSegments
            .filter { $0.category == category }
            .map { segment in
                let raw = channelResolvedSamples(
                    signal: job.rawSignal,
                    startSample: segment.startSample,
                    endSample: segment.endSample,
                    channels: job.selectedChannelIndices
                )
                return WoodyAlignmentAnalyzer.TrialInput(
                    sourceTimeSeconds: segment.sourceTimeSeconds,
                    stimulusOffsetSamples: segment.stimulusOffsetSamples,
                    samples: job.appliesDenoising ? WaveletDenoiser.denoise(raw) : raw
                )
            }
    }

    private static func rideTrials(category: String, job: SingleTrialRIDERunJob) -> [RIDEAnalyzer.TrialInput] {
        job.rawSegments
            .filter { $0.category == category }
            .map { segment in
                let raw = channelResolvedSamples(
                    signal: job.rawSignal,
                    startSample: segment.startSample,
                    endSample: segment.endSample,
                    channels: job.selectedChannelIndices
                )
                return RIDEAnalyzer.TrialInput(
                    sourceTimeSeconds: segment.sourceTimeSeconds,
                    stimulusOffsetSamples: segment.stimulusOffsetSamples,
                    responseLatencyMs: job.configuration.includesResponseComponent ? job.configuration.defaultResponseLatencyMs : nil,
                    samples: job.appliesDenoising ? WaveletDenoiser.denoise(raw) : raw
                )
            }
    }

    private static func channelResolvedSamples(
        signal: MFFSignalData,
        startSample: Int,
        endSample: Int,
        channels: [Int]
    ) -> [Float] {
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
        for i in result.indices { result[i] /= divisor }
        return result
    }

    private static func alignedButterflyPreview(
        rawSignal: MFFSignalData,
        rawSegments: [EpochSegment],
        averagedSegments: [EpochSegment],
        orderedCategories: [String],
        shiftsByCategory: [String: [Int]],
        averageReference: Bool,
        baselineCorrected: Bool,
        badChannels: Set<Int>
    ) async -> SingleTrialAlignedButterflyPreview? {
        guard rawSignal.samplingRate > 0 else { return nil }
        var outputData = Array(repeating: [Float](), count: rawSignal.numberOfChannels)
        var outputSegments: [EpochSegment] = []
        var cursor = 0
        let rawSegmentsByCategory = Dictionary(grouping: rawSegments, by: \.category)
        var averageSegmentsByCategory: [String: EpochSegment] = [:]
        for segment in averagedSegments where averageSegmentsByCategory[segment.category] == nil {
            averageSegmentsByCategory[segment.category] = segment
        }
        let previewRawLengths = orderedCategories.compactMap { category -> Int? in
            guard let segment = averageSegmentsByCategory[category] else { return nil }
            return segment.endSample - segment.startSample + 1
        }
        let previewStride = max(previewRawLengths.map(displayStride(forEpochLength:)).max() ?? 1, 1)
        let previewSamplingRate = rawSignal.samplingRate / Double(previewStride)

        for category in orderedCategories {
            guard let shifts = shiftsByCategory[category],
                  let averageSegment = averageSegmentsByCategory[category],
                  let trials = rawSegmentsByCategory[category] else { continue }
            let rawLength = averageSegment.endSample - averageSegment.startSample + 1
            let length = displayLength(rawLength: rawLength, displayStride: previewStride)
            guard length > 1, trials.count == shifts.count else { continue }
            guard let averagedChannels = await alignedAverageAllChannels(
                trials: trials,
                shifts: shifts,
                rawSignal: rawSignal,
                rawLength: rawLength,
                displayStride: previewStride,
                averageReference: averageReference,
                baselineCorrected: baselineCorrected,
                badChannels: badChannels
            ) else { continue }

            for channel in outputData.indices {
                outputData[channel].append(contentsOf: averagedChannels[channel])
            }
            outputSegments.append(EpochSegment(
                startSample: cursor,
                endSample: cursor + length - 1,
                stimulusOffsetSamples: Int((Double(averageSegment.stimulusOffsetSamples) / Double(previewStride)).rounded()),
                category: category,
                sourceCode: averageSegment.sourceCode,
                sourceTimeSeconds: averageSegment.sourceTimeSeconds,
                colorIndex: averageSegment.colorIndex,
                contributingEpochCount: trials.count,
                subject: averageSegment.subject
            ))
            cursor += length
        }

        guard !outputSegments.isEmpty else { return nil }
        let signal = MFFSignalData(
            signalURL: rawSignal.signalURL,
            signalType: rawSignal.signalType,
            numberOfChannels: rawSignal.numberOfChannels,
            samplingRate: previewSamplingRate,
            duration: Double(max(cursor - 1, 0)) / max(previewSamplingRate, .leastNonzeroMagnitude),
            recordingStartTime: rawSignal.recordingStartTime,
            events: [],
            data: outputData,
            channelNames: rawSignal.channelNames,
            epochSegments: outputSegments,
            isSegmented: true,
            isAveraged: true,
            impedancesKOhm: rawSignal.impedancesKOhm,
            positiveUpFlags: rawSignal.positiveUpFlags
        )
        return SingleTrialAlignedButterflyPreview(signal: signal, segments: outputSegments)
    }

    private static func alignedAverageAllChannels(
        trials: [EpochSegment],
        shifts: [Int],
        rawSignal: MFFSignalData,
        rawLength: Int,
        displayStride: Int,
        averageReference: Bool,
        baselineCorrected: Bool,
        badChannels: Set<Int>
    ) async -> [[Float]]? {
        guard trials.count == shifts.count, rawSignal.numberOfChannels == rawSignal.data.count else { return nil }
        let displayLength = displayLength(rawLength: rawLength, displayStride: displayStride)
        guard rawLength > 1, displayLength > 1 else { return nil }
        let preparedTrials = preparePreviewTrials(
            trials: trials,
            shifts: shifts,
            rawSignal: rawSignal,
            rawLength: rawLength,
            averageReference: averageReference,
            badChannels: badChannels
        )
        guard !preparedTrials.isEmpty else { return nil }

        let channelCount = rawSignal.numberOfChannels
        let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), max(channelCount, 1))
        let chunkSize = max((channelCount + workerCount - 1) / workerCount, 1)
        var chunks: [(start: Int, data: [[Float]])] = []
        chunks.reserveCapacity((channelCount + chunkSize - 1) / chunkSize)

        await withTaskGroup(of: (Int, [[Float]]).self) { group in
            var start = 0
            while start < channelCount {
                let end = min(start + chunkSize, channelCount)
                let channelRange = start..<end
                group.addTask {
                    let data = alignedAverageChannels(
                        channelRange: channelRange,
                        preparedTrials: preparedTrials,
                        rawSignal: rawSignal,
                        rawLength: rawLength,
                        displayLength: displayLength,
                        displayStride: displayStride,
                        baselineCorrected: baselineCorrected
                    )
                    return (start, data)
                }
                start = end
            }
            for await chunk in group {
                chunks.append(chunk)
            }
        }

        chunks.sort { $0.start < $1.start }
        return chunks.flatMap(\.data)
    }

    private static func alignedAverageChannels(
        channelRange: Range<Int>,
        preparedTrials: [PreparedPreviewTrial],
        rawSignal: MFFSignalData,
        rawLength: Int,
        displayLength: Int,
        displayStride: Int,
        baselineCorrected: Bool
    ) -> [[Float]] {
        channelRange.map { channel in
            var sum = [Double](repeating: 0, count: displayLength)
            var counts = [Int](repeating: 0, count: displayLength)

            for trial in preparedTrials {
                guard rawSignal.data.indices.contains(channel),
                      rawSignal.data[channel].count > trial.segment.endSample else { continue }
                let baseline = baselineCorrected
                    ? channelBaseline(channel: channel, trial: trial, rawSignal: rawSignal)
                    : 0
                for displaySample in 0..<displayLength {
                    let rawSample = displaySample * displayStride
                    let sourceOffset = rawSample + trial.shift
                    guard sourceOffset >= 0, sourceOffset < rawLength else { continue }
                    let absoluteSample = trial.segment.startSample + sourceOffset
                    let referenceMean = trial.referenceMeans?[sourceOffset] ?? 0
                    let value = Double(rawSignal.data[channel][absoluteSample]) - referenceMean - baseline
                    guard value.isFinite else { continue }
                    sum[displaySample] += value
                    counts[displaySample] += 1
                }
            }

            return sum.indices.map { sample in
                counts[sample] > 0 ? Float(sum[sample] / Double(counts[sample])) : 0
            }
        }
    }

    private struct PreparedPreviewTrial: Sendable {
        var segment: EpochSegment
        var shift: Int
        var referenceMeans: [Double]?
    }

    private static func preparePreviewTrials(
        trials: [EpochSegment],
        shifts: [Int],
        rawSignal: MFFSignalData,
        rawLength: Int,
        averageReference: Bool,
        badChannels: Set<Int>
    ) -> [PreparedPreviewTrial] {
        zip(trials, shifts).compactMap { segment, shift in
            guard segment.endSample - segment.startSample + 1 == rawLength,
                  segment.startSample >= 0 else { return nil }
            let referenceMeans = averageReference
                ? referenceMeans(segment: segment, rawLength: rawLength, rawSignal: rawSignal, badChannels: badChannels)
                : nil
            return PreparedPreviewTrial(segment: segment, shift: shift, referenceMeans: referenceMeans)
        }
    }

    private static func referenceMeans(
        segment: EpochSegment,
        rawLength: Int,
        rawSignal: MFFSignalData,
        badChannels: Set<Int>
    ) -> [Double] {
        let referenceIndices = rawSignal.data.indices.filter {
            !badChannels.contains($0) && rawSignal.data[$0].count > segment.endSample
        }
        guard !referenceIndices.isEmpty else { return [Double](repeating: 0, count: rawLength) }

        var means = [Double](repeating: 0, count: rawLength)
        for offset in 0..<rawLength {
            let sample = segment.startSample + offset
            var sum = 0.0
            var count = 0
            for channel in referenceIndices {
                let value = Double(rawSignal.data[channel][sample])
                guard value.isFinite else { continue }
                sum += value
                count += 1
            }
            means[offset] = count > 0 ? sum / Double(count) : 0
        }
        return means
    }

    private static func channelBaseline(
        channel: Int,
        trial: PreparedPreviewTrial,
        rawSignal: MFFSignalData
    ) -> Double {
        let baselineCount = min(max(trial.segment.stimulusOffsetSamples, 0), trial.segment.endSample - trial.segment.startSample + 1)
        guard baselineCount > 0,
              rawSignal.data.indices.contains(channel),
              rawSignal.data[channel].count > trial.segment.endSample else { return 0 }

        var sum = 0.0
        var count = 0
        for offset in 0..<baselineCount {
            let sample = trial.segment.startSample + offset
            let referenceMean = trial.referenceMeans?[offset] ?? 0
            let value = Double(rawSignal.data[channel][sample]) - referenceMean
            guard value.isFinite else { continue }
            sum += value
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func displayStride(forEpochLength length: Int) -> Int {
        max(length / 1_200, 1)
    }

    private static func displayLength(rawLength: Int, displayStride: Int) -> Int {
        guard rawLength > 0 else { return 0 }
        return ((rawLength - 1) / max(displayStride, 1)) + 1
    }
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
    let woodyLatencyShiftSamples: [Int]?
    let showsWoodyAlignedOverlay: Bool
    let woodyAlignmentProgress: Double
    let rideLatencyShiftSamples: [Int]?
    let showsRIDEAlignedOverlay: Bool
    let rideAlignmentProgress: Double

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

                    if isSelected,
                       showsWoodyAlignedOverlay,
                       let woodyLatencyShiftSamples,
                       woodyLatencyShiftSamples.count == bundle.trialTraces.count {
                        for (trace, shiftSamples) in zip(bundle.trialTraces, woodyLatencyShiftSamples) {
                            draw(
                                trace,
                                length: length,
                                sampleStep: sampleStep,
                                size: size,
                                midY: midY,
                                scale: scale,
                                in: &context,
                                color: color,
                                opacity: 0.55,
                                lineWidth: 1.0,
                                style: StrokeStyle(lineWidth: 1.0, dash: [5, 4]),
                                horizontalShiftSamples: -Double(shiftSamples) * min(max(woodyAlignmentProgress, 0), 1)
                            )
                        }
                    }

                    if isSelected,
                       showsRIDEAlignedOverlay,
                       let rideLatencyShiftSamples,
                       rideLatencyShiftSamples.count == bundle.trialTraces.count {
                        for (trace, shiftSamples) in zip(bundle.trialTraces, rideLatencyShiftSamples) {
                            draw(
                                trace,
                                length: length,
                                sampleStep: sampleStep,
                                size: size,
                                midY: midY,
                                scale: scale,
                                in: &context,
                                color: .purple,
                                opacity: 0.48,
                                lineWidth: 1.0,
                                style: StrokeStyle(lineWidth: 1.0, dash: [2, 4]),
                                horizontalShiftSamples: -Double(shiftSamples) * min(max(rideAlignmentProgress, 0), 1)
                            )
                        }
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
        lineWidth: CGFloat,
        style: StrokeStyle? = nil,
        horizontalShiftSamples: Double = 0
    ) {
        let count = min(trace.count, length)
        guard count > 1 else { return }
        var path = Path()
        var moved = false
        for localSample in stride(from: 0, through: count - 1, by: sampleStep) {
            addPoint(
                localSample,
                trace: trace,
                length: length,
                size: size,
                midY: midY,
                scale: scale,
                horizontalShiftSamples: horizontalShiftSamples,
                to: &path,
                moved: &moved
            )
        }
        if (count - 1) % sampleStep != 0 {
            addPoint(
                count - 1,
                trace: trace,
                length: length,
                size: size,
                midY: midY,
                scale: scale,
                horizontalShiftSamples: horizontalShiftSamples,
                to: &path,
                moved: &moved
            )
        }
        if let style {
            context.stroke(path, with: .color(color.opacity(opacity)), style: style)
        } else {
            context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)
        }
    }

    private func addPoint(
        _ localSample: Int,
        trace: [Float],
        length: Int,
        size: CGSize,
        midY: CGFloat,
        scale: Double,
        horizontalShiftSamples: Double = 0,
        to path: inout Path,
        moved: inout Bool
    ) {
        let shiftedSample = Double(localSample) + horizontalShiftSamples
        let x = CGFloat(shiftedSample / Double(length - 1)) * size.width
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
