//
//  AveragesWorkspaceViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  In-place averaged-category workspace for Butterfly, Topography, and Channel
//  Inspector. This deliberately lives as a WaveformView extension for now so it
//  can reuse the per-window state already owned by WaveformView.
//

import SwiftUI

/// One row of the per-category signal-to-noise table in the Averages workspace.
/// Optional metrics keep their `nil` for display ("n/a"); the `*Sort` keys map
/// `nil` to the smallest value so missing metrics sink to the bottom of an
/// ascending sort.
struct AverageSNRRow: Identifiable {
    let id: String
    let category: String
    let displayCategory: String
    let trials: Int
    let plusMinusSNR: Double?
    let baselineSNR: Double?
    let sme: Double?
    let splitHalf: Double?

    var plusMinusSort: Double { plusMinusSNR ?? -.greatestFiniteMagnitude }
    var baselineSort: Double { baselineSNR ?? -.greatestFiniteMagnitude }
    var smeSort: Double { sme ?? -.greatestFiniteMagnitude }
    var splitHalfSort: Double { splitHalf ?? -.greatestFiniteMagnitude }
}

extension WaveformView {
    @ViewBuilder
    func averagesWorkspace(for signal: MFFSignalData) -> some View {
        let segments = selectedOverlaySegments()
        let showsPlotArea = epoching.showsAveragesButterfly
            || epoching.showsAveragesTopography
            || epoching.showsAveragesInspector
        let showsLeftColumn = epoching.showsAveragesButterfly
            || epoching.showsAveragesInspector
            || epoching.showsAveragesLog

        VStack(spacing: 0) {
            if segments.isEmpty {
                ContentUnavailableView(
                    "No Averages",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Create PSA averages to explore category waveforms, topographies, and channels.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !showsPlotArea && !epoching.showsAveragesLog
                && !epoching.showsAveragesMultiButterfly && !epoching.showsAveragesDifference && !epoching.showsAveragesFilmstrip {
                ContentUnavailableView(
                    "All Average Views Hidden",
                    systemImage: "rectangle.3.group",
                    description: Text("Turn a panel back on from the averages toolbar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let relativeSample = averagesWorkspaceRelativeSample(for: segments)

                GeometryReader { workspace in
                let availableWidth = workspace.size.width

                VStack(spacing: 12) {
                    if showsPlotArea || epoching.showsAveragesLog {
                        HStack(alignment: .top, spacing: 12) {
                            if showsLeftColumn {
                                VStack(spacing: 12) {
                                    if epoching.showsAveragesButterfly {
                                        averagesButterflyPane(signal: signal, segments: segments, relativeSample: relativeSample)
                                            .frame(minHeight: 260)
                                    }

                                    if epoching.showsAveragesInspector {
                                        averagesChannelInspectorPane(signal: signal, segments: segments, relativeSample: relativeSample)
                                            .frame(minHeight: 260)
                                    }

                                    if epoching.showsAveragesLog {
                                        averagesEventsLogPanel(signal: signal, segments: segments)
                                            .frame(
                                                minHeight: 150,
                                                maxHeight: (epoching.showsAveragesButterfly || epoching.showsAveragesInspector) ? 190 : .infinity
                                            )
                                    }
                                }
                                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                            }

                            if epoching.showsAveragesTopography {
                                if showsLeftColumn {
                                    AveragesTopographyResizer(
                                        width: $epoching.averagesTopographyWidth,
                                        available: availableWidth
                                    )
                                }

                                if showsLeftColumn {
                                    averagesTopographyPane(signal: signal, relativeSample: relativeSample)
                                        .frame(width: resolvedTopographyWidth(available: availableWidth))
                                        .frame(maxHeight: .infinity)
                                } else {
                                    averagesTopographyPane(signal: signal, relativeSample: relativeSample)
                                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if showsPlotArea {
                        averagesLatencyScrubber(segment: segments[0], relativeSample: relativeSample)
                    }

                    if epoching.showsAveragesMultiButterfly {
                        averagesMultiButterflyPane(signal: signal, segments: segments)
                            .frame(minHeight: 420)
                    }

                    if epoching.showsAveragesDifference {
                        averagesDifferencePane(signal: signal, segments: segments)
                            .frame(minHeight: 420)
                    }

                    if epoching.showsAveragesFilmstrip {
                        averagesFilmstripPane(signal: signal, segments: segments)
                            .frame(minHeight: 260)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    seedAveragesWorkspaceLatencyIfNeeded(segment: segments[0])
                }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// The Topography pane's width, clamped both to its own range and to the
    /// space this window actually has. Without the second clamp a width dragged
    /// wide on a large display would squeeze the left column off a smaller one.
    func resolvedTopographyWidth(available: CGFloat) -> CGFloat {
        let range = EpochingViewModel.averagesTopographyWidthRange
        let requested = min(max(epoching.averagesTopographyWidth, range.lowerBound), range.upperBound)
        guard available > 0 else { return requested }
        // Leave room for the left column plus the gutter and the drag handle.
        let ceiling = max(range.lowerBound, available - 300)
        return min(requested, ceiling)
    }

    func averagesToolbar(for signal: MFFSignalData) -> some View {
        return HStack(spacing: 12) {
            toolbarScaleControls(showsTimeScale: false)

            // Seven fixed-width buttons were the single biggest contributor to
            // this workspace's minimum width, which is what pushed the window
            // past the edge of smaller displays. ViewThatFits picks the roomiest
            // arrangement that actually fits: full row, compact row, then a
            // two-row grid.
            ViewThatFits(in: .horizontal) {
                averagesViewToggleRow(metrics: .regular)
                averagesViewToggleRow(metrics: .compact)
                averagesViewToggleGrid(metrics: .compact)
            }

            Divider()
                .frame(height: 42)

            Toggle("GFP", isOn: $epoching.showsAveragesGFP)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Show a Global Field Power trace under every butterfly plot.")

            Divider()
                .frame(height: 42)

            overlayConditionsMenu()
            channelInspectorChannelMenu(signal: signal)
            channelInspectorGroupMenu()

            if case .channelSet = channelInspectorSelection {
                Toggle("Members", isOn: $channelInspectorOverlayEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            Spacer(minLength: 12)

            toolbarStatusAndModeControls(for: signal)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The two sizes the view toggles come in. `compact` keeps the same icon and
    /// label but drops the button to roughly two-thirds the width, which is what
    /// lets seven of them fit on a laptop display.
    struct AveragesToggleMetrics {
        let buttonWidth: CGFloat
        let buttonHeight: CGFloat
        let iconSize: CGFloat
        let labelSize: CGFloat

        static let regular = AveragesToggleMetrics(buttonWidth: 77, buttonHeight: 58, iconSize: 22, labelSize: 8)
        static let compact = AveragesToggleMetrics(buttonWidth: 52, buttonHeight: 46, iconSize: 16, labelSize: 7)
    }

    private var averagesViewToggles: [(title: String, image: String, binding: Binding<Bool>)] {
        [
            ("Waveforms", "waveform.path.ecg", $epoching.showsAveragesInspector),
            ("Topomaps", "circle.grid.3x3.fill", $epoching.showsAveragesTopography),
            ("Butterfly", "chart.xyaxis.line", $epoching.showsAveragesButterfly),
            ("Logs", "list.bullet.rectangle", $epoching.showsAveragesLog),
            ("Multi-Butterfly", "rectangle.grid.1x2", $epoching.showsAveragesMultiButterfly),
            ("Difference", "plusminus", $epoching.showsAveragesDifference),
            ("Filmstrip", "square.grid.3x1.below.line.grid.1x2", $epoching.showsAveragesFilmstrip)
        ]
    }

    private func averagesViewToggleRow(metrics: AveragesToggleMetrics) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(averagesViewToggles.enumerated()), id: \.offset) { _, toggle in
                averagesToolbarToggle(
                    title: toggle.title,
                    systemImage: toggle.image,
                    isOn: toggle.binding,
                    metrics: metrics
                )
            }
        }
    }

    /// Last resort: two rows of four and three. Taller than the row forms, but
    /// it never forces the window wider than the screen.
    private func averagesViewToggleGrid(metrics: AveragesToggleMetrics) -> some View {
        let toggles = averagesViewToggles
        let split = (toggles.count + 1) / 2
        return VStack(spacing: 4) {
            ForEach([Array(toggles.prefix(split)), Array(toggles.dropFirst(split))], id: \.first?.title) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, toggle in
                        averagesToolbarToggle(
                            title: toggle.title,
                            systemImage: toggle.image,
                            isOn: toggle.binding,
                            metrics: metrics
                        )
                    }
                }
            }
        }
    }

    private func averagesToolbarToggle(
        title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        metrics: AveragesToggleMetrics = .regular
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: metrics.iconSize, weight: .semibold))
                    .frame(width: metrics.iconSize + 2, height: metrics.iconSize + 2)
                Text(title.uppercased())
                    .font(.system(size: metrics.labelSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: metrics.buttonWidth - 10, height: 10)
            }
            .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
            .frame(width: metrics.buttonWidth, height: metrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(isOn.wrappedValue ? "Hide \(title)" : "Show \(title)")
    }

    private func averagesButterflyPane(signal: MFFSignalData, segments: [EpochSegment], relativeSample currentRelativeSample: Int) -> some View {
        averagesPanel {
            AveragesButterflyPaneContent(
                view: self,
                signal: signal,
                segments: segments,
                currentRelativeSample: currentRelativeSample
            )
        }
        .contextMenu {
            if canFitSourceModel() {
                Button("Fit Source Model…") {
                    fitSourceModel(centeredOnRelativeSample: currentRelativeSample)
                }
            }
        }
    }

    @ViewBuilder
    private func averagesTopographyPane(signal: MFFSignalData, relativeSample: Int) -> some View {
        averagesPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Topography")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $epoching.topographyTopomapScale, in: 0.6...2.2)
                            .frame(width: 90)
                    }
                    .help("Size of the topomaps below.")
                    Text(averagedTopomapLatencyText(relativeSample: relativeSample))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let layout = recording.sensorLayout {
                    let samples = averagedTopomapSamples(relativeSample: relativeSample, in: signal)
                    let autoScale = fixedTopomapScale(for: samples.map(\.sample), in: signal) ?? 1
                    let autoZ = topomapAutoZ(samples: samples, in: signal)
                    let colorRange = topomapColorRange()
                    let zScaling = topomapZScaling(auto: autoZ)
                    let tileScale = epoching.topographyTopomapScale
                    let mapHeight = 135 * tileScale
                    let cardHeight = 170 * tileScale

                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150 * tileScale), spacing: 10)], spacing: 12) {
                                ForEach(samples) { entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(epoching.displayCategory(entry.category))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(epochColor(for: entry.colorIndex))
                                            .lineLimit(1)
                                        TopomapView(
                                            layout: layout,
                                            values: topomapValues(at: entry.sample, in: signal),
                                            timeSeconds: entry.latencySeconds,
                                            fixedScale: autoScale,
                                            colorRange: colorRange,
                                            zScaling: zScaling,
                                            showsHeader: false,
                                            colorBarPlacement: .trailing,
                                            minimumMapHeight: mapHeight,
                                            channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                                            onTapChannel: { channelInspectorSelection = .channel($0) }
                                        )
                                        .frame(height: cardHeight)
                                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .padding(.trailing, isOptionKeyPressed ? 10 : 0)
                        }

                        if isOptionKeyPressed {
                            TopomapScaleControl(
                                mode: $epoching.topomapScaleMode,
                                symmetric: $epoching.topomapSymmetric,
                                minValue: topomapMinBinding,
                                maxValue: topomapMaxBinding,
                                autoScale: autoScale,
                                onAutoMicrovolts: {
                                    if epoching.topomapScaleManual {
                                        epoching.topomapScaleManual = false
                                    }
                                    seedTopomapScale(autoScale: autoScale, autoZ: autoZ)
                                },
                                sigma: $epoching.topomapZSigma,
                                zMean: topomapZMeanBinding,
                                zSD: topomapZSDBinding,
                                onAutoZ: {
                                    if epoching.topomapZManual {
                                        epoching.topomapZManual = false
                                    }
                                    seedTopomapScale(autoScale: autoScale, autoZ: autoZ)
                                }
                            )
                            .padding(.leading, 8)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .onAppear { seedTopomapScale(autoScale: autoScale, autoZ: autoZ) }
                    .onChange(of: epoching.topomapSymmetric) { _, sym in
                        let mirroredMinimum = -epoching.topomapScaleMax
                        if sym, epoching.topomapScaleMin != mirroredMinimum {
                            epoching.topomapScaleMin = mirroredMinimum
                        }
                    }
                    .contextMenu {
                        if canFitSourceModel() {
                            Button("Fit Source Model…") {
                                fitSourceModel(centeredOnRelativeSample: relativeSample)
                            }
                            Divider()
                        }
                        figureSaveMenu(
                            title: "Average Topographies",
                            legend: topomapLegendItems(samples),
                            size: CGSize(width: CGFloat(max(samples.count, 1)) * 300 * tileScale, height: 330 * tileScale)
                        ) {
                            topomapsFigure(samples: samples, layout: layout, scale: autoScale, colorRange: colorRange, zScaling: zScaling, signal: signal, tileScale: tileScale)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Sensor Layout",
                        systemImage: "circle.dashed",
                        description: Text("This package has no readable sensorLayout.xml, so topographic maps can't be drawn.")
                    )
                }
            }
        }
    }

    private func averagesChannelInspectorPane(signal: MFFSignalData, segments: [EpochSegment], relativeSample: Int) -> some View {
        let selection = channelInspectorSelection
        let indices = channelInspectorIndices(for: selection, signal: signal)
        let standardErrorBands = channelInspectorShowsStandardError
            ? channelInspectorStandardErrorBands(for: segments, selection: selection, signal: signal)
            : [:]

        return averagesPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Channel Inspector")
                            .font(.headline)
                        Text(channelInspectorTitle(for: selection, signal: signal))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                if indices.isEmpty {
                    ContentUnavailableView(
                        "No Channel Selected",
                        systemImage: "waveform.path",
                        description: Text("Pick a channel or Channel Set.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ChannelInspectorPlot(
                        signal: signal,
                        segments: segments,
                        indices: indices,
                        showsMembers: channelInspectorOverlayEnabled,
                        amplitudeScale: amplitudeScale,
                        colorFor: { epochColor(for: $0) },
                        channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                        highlightRelativeSample: relativeSample,
                        onScrubRelativeSample: { sample in
                            setAveragesWorkspaceLatency(sample, segment: segments[0])
                        },
                        standardErrorBands: standardErrorBands
                    )
                    .contextMenu {
                        channelInspectorDisplayMenuItems(selection: selection, signal: signal, segments: segments)
                        Divider()
                        figureSaveMenu(
                            title: channelInspectorTitle(for: selection, signal: signal),
                            legend: overlayLegendItems(),
                            size: CGSize(width: 720, height: 320),
                            seconds: figureSeconds(segments, samplingRate: signal.samplingRate)
                        ) {
                            ChannelInspectorPlot(
                                signal: signal,
                                segments: segments,
                                indices: indices,
                                showsMembers: channelInspectorOverlayEnabled,
                                amplitudeScale: amplitudeScale,
                                colorFor: { epochColor(for: $0) },
                                highlightRelativeSample: relativeSample,
                                standardErrorBands: standardErrorBands
                            )
                        }
                    }
                }
            }
        }
    }

    private func averagesLatencyScrubber(segment: EpochSegment, relativeSample: Int) -> some View {
        return averagesPanel(fillHeight: false) {
            AveragesLatencyScrubberControl(
                segment: segment,
                relativeSample: relativeSample,
                samplingRate: epoching.epochedSignal?.samplingRate ?? 0,
                onCommit: { setAveragesWorkspaceLatency($0, segment: segment) }
            )
        }
    }

    private func averagesEventsLogPanel(signal: MFFSignalData, segments: [EpochSegment]) -> some View {
        let showsSNR = !epoching.averageSNRByCategory.isEmpty || epoching.isComputingAverageSNR
        return averagesPanel {
            HStack(alignment: .top, spacing: 16) {
                averagesEventsLogColumn(segments: segments)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                if showsSNR {
                    Divider()
                    averagesSNRSection()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func averagesEventsLogColumn(segments: [EpochSegment]) -> some View {
        let summary = epoching.psaExclusionSummary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Events / Logs")
                    .font(.headline)
                Spacer()
                Text("\(segments.count) visible average\(segments.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    averagesLogMetric("Candidate events", value: summary.candidateEvents)
                    averagesLogMetric("Built epochs", value: summary.acceptedEpochs)
                    averagesLogMetric("Kept epochs", value: summary.keptEpochs)
                    averagesLogMetric("Excluded", value: summary.excludedEpochs)
                }
                GridRow {
                    averagesLogMetric("Labeled bad skips", value: summary.skippedLabeledBadSegments)
                    averagesLogMetric("Artifact skips", value: summary.skippedArtifacts)
                    averagesLogMetric("Missing timing", value: summary.skippedTimingMarkers)
                    averagesLogMetric("Out of bounds", value: summary.skippedOutOfBounds)
                }
                GridRow {
                    averagesLogMetric("Timing adjusted", value: summary.timingAdjusted)
                    averagesLogMetric("Too many bad channels", value: summary.rejectedForTooManyBadChannels)
                }
            }

            if !summary.skippedArtifactBreakdown.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Artifact skip causes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(artifactSkipBreakdownText(summary.skippedArtifactBreakdown))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 18) {
                averagesLogBubbleButton(
                    label: "Summary",
                    title: "PSA Summary",
                    text: epoching.statusMessage ?? "No PSA log message recorded.",
                    isPresented: $showsPSASummaryBubble
                )

                if !epoching.epochBadChannelSummary.isEmpty {
                    averagesLogBubbleButton(
                        label: "Per-epoch bad channels",
                        title: "Per-epoch Bad Channels",
                        text: epoching.epochBadChannelSummary.joined(separator: "\n"),
                        isPresented: $showsPerEpochBadChannelsBubble
                    )
                }
            }
        }
    }

    private var averageSNRRows: [AverageSNRRow] {
        epoching.averageSNRByCategory.map { category, m in
            AverageSNRRow(
                id: category,
                category: category,
                displayCategory: epoching.displayCategory(category),
                trials: m.trialCount,
                plusMinusSNR: m.plusMinusSNR,
                baselineSNR: m.baselineSNR,
                sme: m.standardizedMeasurementError,
                splitHalf: m.splitHalfReliability
            )
        }
        .sorted(using: averageSNRSortOrder)
    }

    /// Per-category signal-to-noise summary for the current average — a sortable,
    /// scrollable table (handles many categories). Columns mirror the Combine
    /// sheet's SNR table; "n/a" appears where a metric needs more trials than the
    /// category has (±/GFP need ≥2; SME and split-half ≥4).
    @ViewBuilder
    private func averagesSNRSection() -> some View {
        let rows = averageSNRRows
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Signal-to-noise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    showsAverageSNRHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("About these signal-to-noise metrics")
                .popover(isPresented: $showsAverageSNRHelp, arrowEdge: .trailing) {
                    averagesSNRHelpPopover()
                }
                if epoching.isComputingAverageSNR {
                    Spacer()
                    ProgressView()
                        .controlSize(.mini)
                    Text("Calculating…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty, epoching.isComputingAverageSNR {
                Text("Measuring signal-to-noise from the single trials…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Table(rows, sortOrder: $averageSNRSortOrder) {
                    TableColumn("Category", value: \.category) { row in
                        Text(row.displayCategory).lineLimit(1)
                    }
                    TableColumn("Trials", value: \.trials) { row in
                        Text("\(row.trials)").monospacedDigit()
                    }
                    .width(46)
                    TableColumn("±SNR", value: \.plusMinusSort) { row in
                        Text(snrText(row.plusMinusSNR)).monospacedDigit()
                    }
                    .width(52)
                    TableColumn("Base", value: \.baselineSort) { row in
                        Text(snrText(row.baselineSNR)).monospacedDigit()
                    }
                    .width(52)
                    TableColumn("SME", value: \.smeSort) { row in
                        Text(snrText(row.sme, digits: 3)).monospacedDigit()
                    }
                    .width(56)
                    TableColumn("r½", value: \.splitHalfSort) { row in
                        Text(snrText(row.splitHalf)).monospacedDigit()
                    }
                    .width(46)
                }
                .font(.caption)
                .frame(minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func averagesSNRHelpPopover() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signal-to-noise metrics")
                .font(.headline)
            Group {
                snrHelpRow("Trials", "Number of single trials that went into the category average.")
                snrHelpRow("±SNR", "RMS(average) ÷ RMS(plus-minus noise). The plus-minus (Schimmel) residual sign-flips alternate trials so the signal cancels and only noise remains. Higher is better.")
                snrHelpRow("Base", "Response-window peak ÷ pre-stimulus baseline RMS. A quick amplitude-over-noise ratio. Higher is better.")
                snrHelpRow("SME", "Standardized Measurement Error — bootstrapped standard error of the mean amplitude (Luck et al. 2021). Lower is better.")
                snrHelpRow("r½", "Split-half reliability across odd/even trials, Spearman-Brown corrected (−1…1). Higher is better.")
            }
            Divider()
            Text("References: Schimmel (1967); Luck, Stewart, Simmons & Rhemtulla (2021); Lehmann & Skrandies (1980). See EpochSNR.swift.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func snrHelpRow(_ term: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(term)
                .font(.caption.monospaced().weight(.semibold))
                .frame(width: 44, alignment: .leading)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func snrText(_ value: Double?, digits: Int = 2) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%.\(digits)f", value)
    }

    private func artifactSkipBreakdownText(_ breakdown: [String: Int]) -> String {
        breakdown
            .sorted {
                if $0.value == $1.value {
                    return $0.key.localizedStandardCompare($1.key) == .orderedAscending
                }
                return $0.value > $1.value
            }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
    }

    /// A labeled control that opens the full log text in a popover bubble,
    /// instead of showing (and clipping) the text inline.
    private func averagesLogBubbleButton(
        label: String,
        title: String,
        text: String,
        isPresented: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                isPresented.wrappedValue = true
            } label: {
                Label("Show", systemImage: "text.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: isPresented, arrowEdge: .bottom) {
                averagesLogBubble(title: title, text: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func averagesLogBubble(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .frame(width: 400)
    }

    private func averagesLogMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }

    @ViewBuilder
    private func averagesWorkspaceFigure(signal: MFFSignalData) -> some View {
        let segments = selectedOverlaySegments()
        if !segments.isEmpty {
            let relativeSample = averagesWorkspaceRelativeSample(for: segments)
            let standardErrorBands = channelInspectorShowsStandardError
                ? channelInspectorStandardErrorBands(for: segments, selection: channelInspectorSelection, signal: signal)
                : [:]
            VStack(alignment: .leading, spacing: 14) {
                OverlayButterflyPlot(
                    data: signal.data,
                    segments: segments,
                    colors: segments.map { epochColor(for: $0.colorIndex) },
                    hiddenChannels: channels.hidden,
                    amplitudeScale: amplitudeScale,
                    samplingRate: signal.samplingRate,
                    highlightRelativeSample: relativeSample
                )
                .frame(height: 260)

                if let layout = recording.sensorLayout {
                    let samples = averagedTopomapSamples(relativeSample: relativeSample, in: signal)
                    let autoScale = fixedTopomapScale(for: samples.map(\.sample), in: signal) ?? 1
                    let autoZ = topomapAutoZ(samples: samples, in: signal)
                    topomapsFigure(
                        samples: samples,
                        layout: layout,
                        scale: autoScale,
                        colorRange: topomapColorRange(),
                        zScaling: topomapZScaling(auto: autoZ),
                        signal: signal
                    )
                    .frame(height: 220)
                }

                ChannelInspectorPlot(
                    signal: signal,
                    segments: segments,
                    indices: channelInspectorIndices(for: channelInspectorSelection, signal: signal),
                    showsMembers: channelInspectorOverlayEnabled,
                    amplitudeScale: amplitudeScale,
                    colorFor: { epochColor(for: $0) },
                    channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                    highlightRelativeSample: relativeSample,
                    onScrubRelativeSample: { sample in
                        setAveragesWorkspaceLatency(sample, segment: segments[0])
                    },
                    standardErrorBands: standardErrorBands
                )
                .frame(height: 260)
            }
        }
    }

    /// Not private: reused by `JointPlotView.swift`'s pane for the same
    /// bordered-card chrome.
    func averagesPanel<Content: View>(fillHeight: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.55)))
    }

    private func seedAveragesWorkspaceLatencyIfNeeded(segment: EpochSegment) {
        guard epoching.butterflyTopomapRelativeSample == nil else { return }
        setAveragesWorkspaceLatency(segment.stimulusOffsetSamples, segment: segment)
    }

    fileprivate func setAveragesWorkspaceLatency(_ value: Int, segment: EpochSegment) {
        let maxIndex = max(segment.endSample - segment.startSample, 0)
        epoching.butterflyTopomapRelativeSample = min(max(value, 0), maxIndex)
        topomapSample = nil
    }

    private func averagesWorkspaceRelativeSample(for segments: [EpochSegment]) -> Int {
        guard let first = segments.first else { return 0 }
        let maxIndex = max(first.endSample - first.startSample, 0)
        if let current = epoching.butterflyTopomapRelativeSample {
            return min(max(current, 0), maxIndex)
        }
        return min(max(first.stimulusOffsetSamples, 0), maxIndex)
    }

    fileprivate func averagesLatencyText(segment: EpochSegment, relativeSample: Int, samplingRate: Double) -> String {
        guard samplingRate > 0 else { return "0 ms" }
        let latencyMilliseconds = Double(relativeSample - segment.stimulusOffsetSamples) / samplingRate * 1_000
        return String(format: "%+.0f ms", latencyMilliseconds)
    }
}

private struct AveragesLatencyScrubberControl: View {
    let segment: EpochSegment
    let relativeSample: Int
    let samplingRate: Double
    let onCommit: (Int) -> Void

    @State private var draftSample: Double?

    private var maxIndex: Int {
        max(segment.endSample - segment.startSample, 0)
    }

    private var range: ClosedRange<Double> {
        0...max(Double(maxIndex), 1)
    }

    private var displayedSample: Int {
        min(max(Int((draftSample ?? Double(relativeSample)).rounded()), 0), maxIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Latency")
                    .font(.caption.weight(.semibold))
                Text(latencyText(relativeSample: displayedSample))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Slider(
                value: Binding(
                    get: { draftSample ?? Double(relativeSample) },
                    set: { draftSample = $0 }
                ),
                in: range,
                step: 1,
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    let committed = displayedSample
                    draftSample = nil
                    onCommit(committed)
                }
            )
            .disabled(maxIndex <= 0)

            // Axis labels positioned to match the slider: the stimulus (0 ms)
            // tick sits at its TRUE fractional location along the track
            // (stimulusOffsetSamples / maxIndex), not the geometric center — the
            // epoch window is usually asymmetric (e.g. −200…+800 ms), so 0 ms is
            // not in the middle.
            GeometryReader { geo in
                let width = geo.size.width
                let clampedStim = min(max(segment.stimulusOffsetSamples, 0), maxIndex)
                let frac = maxIndex > 0 ? CGFloat(clampedStim) / CGFloat(maxIndex) : 0
                ZStack(alignment: .top) {
                    HStack {
                        Text(latencyText(relativeSample: 0))
                        Spacer()
                        Text(latencyText(relativeSample: maxIndex))
                    }
                    VStack(spacing: 1) {
                        Rectangle()
                            .frame(width: 1, height: 4)
                            .foregroundStyle(.secondary)
                        Text(latencyText(relativeSample: clampedStim))
                    }
                    .fixedSize()
                    .position(x: min(max(width * frac, 14), max(width - 14, 14)), y: 9)
                }
            }
            .frame(height: 24)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func latencyText(relativeSample: Int) -> String {
        guard samplingRate > 0 else { return "0 ms" }
        let latencyMilliseconds = Double(relativeSample - segment.stimulusOffsetSamples) / samplingRate * 1_000
        return String(format: "%+.0f ms", latencyMilliseconds)
    }
}

/// The Butterfly pane's actual content — a plain struct (not another
/// `@ViewBuilder` method on `WaveformView`) so it can hold the pointer
/// position needed for "right-click → Add Joint" to place a marker exactly
/// where the user clicked. Joint markers show a box (topomap per selected
/// condition) above the plot, connected by a guide line down through it —
/// see `JointMarkerOverlay.swift`.
private struct AveragesButterflyPaneContent: View {
    let view: WaveformView
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let currentRelativeSample: Int

    @State private var pointerRelativeSample: Int?

    var body: some View {
        let gfpHeight: CGFloat = view.epoching.showsAveragesGFP ? 50 : 0
        // For the export size (must be known before rendering, so it can't
        // wait for a live GeometryReader's width): computed at the export
        // card's own literal width, same call `AveragesButterflyFigure` uses.
        let exportBoxHeight = view.jointMarkerLayout(
            topomapSegments: segments, signal: signal, referenceSegment: segments[0],
            width: 820, orientation: view.epoching.jointBoxOrientation
        ).boxAreaHeight

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Butterfly")
                    .font(.headline)
                Spacer()
                if !view.epoching.jointPlotMarkers.isEmpty {
                    view.jointBoxControls(showsOrientation: segments.count > 1)
                }
                Text(view.averagesLatencyText(segment: segments[0], relativeSample: currentRelativeSample, samplingRate: signal.samplingRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                let markerLayout = view.jointMarkerLayout(
                    topomapSegments: segments, signal: signal, referenceSegment: segments[0],
                    width: width, orientation: view.epoching.jointBoxOrientation
                )
                let boxHeight = markerLayout.boxAreaHeight
                let butterflyHeight = max(proxy.size.height - boxHeight - gfpHeight, 0)

                ZStack(alignment: .topLeading) {
                    if boxHeight > 0 {
                        JointMarkerGuideLines(
                            view: view,
                            topomapSegments: segments,
                            signal: signal,
                            referenceSegment: segments[0],
                            width: width,
                            totalHeight: proxy.size.height
                        )
                    }

                    OverlayButterflyPlot(
                        data: signal.data,
                        segments: segments,
                        colors: segments.map { view.epochColor(for: $0.colorIndex) },
                        hiddenChannels: view.channels.hidden,
                        amplitudeScale: view.amplitudeScale,
                        samplingRate: signal.samplingRate,
                        highlightRelativeSample: currentRelativeSample,
                        channelName: { view.eegChannelDisplayName(index: $0, signal: signal) },
                        onTapChannel: { view.channelInspectorSelection = .channel($0) },
                        onScrubRelativeSample: { sample in
                            view.setAveragesWorkspaceLatency(sample, segment: segments[0])
                        }
                    )
                    .overlay(WaveformVoltageAxisOverlay(amplitudeScale: view.amplitudeScale))
                    .offset(y: boxHeight)
                    .frame(width: width, height: butterflyHeight)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                            .onEnded { value in
                                view.setAveragesWorkspaceLatency(
                                    view.relativeSample(forButterflyX: value.location.x, width: width, segment: segments[0]),
                                    segment: segments[0]
                                )
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            pointerRelativeSample = view.relativeSample(forButterflyX: location.x, width: width, segment: segments[0])
                        case .ended:
                            break
                        }
                    }

                    if view.epoching.showsAveragesGFP {
                        GFPStripView(
                            data: signal.data,
                            segments: segments,
                            colors: segments.map { view.epochColor(for: $0.colorIndex) }
                        )
                        .frame(width: width, height: gfpHeight - 6)
                        .offset(y: boxHeight + butterflyHeight + 6)
                    }

                    if boxHeight > 0 {
                        JointMarkerBoxesLayer(
                            view: view,
                            layout: view.recording.sensorLayout ?? SensorLayout(name: "", positions: []),
                            signal: signal,
                            topomapSegments: segments,
                            referenceSegment: segments[0],
                            width: width,
                            markerLayout: markerLayout,
                            coordinateSpaceName: "averagesButterflyJoint",
                            orientation: view.epoching.jointBoxOrientation
                        )
                    }
                }
                .coordinateSpace(name: "averagesButterflyJoint")
                .contextMenu {
                    view.figureSaveMenu(
                        title: "Averages Butterfly",
                        legend: view.overlayLegendItems(),
                        size: CGSize(width: 820, height: 300 + gfpHeight + exportBoxHeight + AveragesButterflyFigure.timeAxisHeight),
                        seconds: view.figureSeconds(segments, samplingRate: signal.samplingRate),
                        scaleSize: CGSize(width: 820, height: 300)
                    ) {
                        AveragesButterflyFigure(
                            view: view,
                            signal: signal,
                            segments: segments,
                            highlightRelativeSample: currentRelativeSample,
                            gfpHeight: gfpHeight,
                            boxHeight: exportBoxHeight
                        )
                    }
                    Divider()
                    view.addJointMarkerMenuItem(pointerRelativeSample: pointerRelativeSample)
                }
            }
        }
    }
}

/// Static export twin of `AveragesButterflyPaneContent`'s plot area (no
/// hover/drag/tap gestures — export renders a fixed image), used by its
/// "Save Figure As…" menu so exported figures include any joint markers.
private struct AveragesButterflyFigure: View {
    static let timeAxisHeight: CGFloat = 20

    let view: WaveformView
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let highlightRelativeSample: Int
    let gfpHeight: CGFloat
    let boxHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let markerLayout = view.jointMarkerLayout(
                    topomapSegments: segments, signal: signal, referenceSegment: segments[0],
                    width: width, orientation: view.epoching.jointBoxOrientation
                )
                let butterflyHeight = max(proxy.size.height - boxHeight - gfpHeight, 0)

                ZStack(alignment: .topLeading) {
                    if boxHeight > 0 {
                        JointMarkerGuideLines(
                            view: view,
                            topomapSegments: segments,
                            signal: signal,
                            referenceSegment: segments[0],
                            width: width,
                            totalHeight: proxy.size.height
                        )
                    }

                    OverlayButterflyPlot(
                        data: signal.data,
                        segments: segments,
                        colors: segments.map { view.epochColor(for: $0.colorIndex) },
                        hiddenChannels: view.channels.hidden,
                        amplitudeScale: view.amplitudeScale,
                        samplingRate: signal.samplingRate,
                        highlightRelativeSample: highlightRelativeSample
                    )
                    .overlay(WaveformVoltageAxisOverlay(amplitudeScale: view.amplitudeScale))
                    .offset(y: boxHeight)
                    .frame(width: width, height: butterflyHeight)

                    if gfpHeight > 0 {
                        GFPStripView(
                            data: signal.data,
                            segments: segments,
                            colors: segments.map { view.epochColor(for: $0.colorIndex) }
                        )
                        .frame(width: width, height: gfpHeight - 6)
                        .offset(y: boxHeight + butterflyHeight + 6)
                    }

                    if boxHeight > 0, let layout = view.recording.sensorLayout {
                        JointMarkerBoxesLayer(
                            view: view,
                            layout: layout,
                            signal: signal,
                            topomapSegments: segments,
                            referenceSegment: segments[0],
                            width: width,
                            markerLayout: markerLayout,
                            coordinateSpaceName: "averagesButterflyJointExport",
                            isInteractive: false,
                            orientation: view.epoching.jointBoxOrientation
                        )
                    }
                }
                .coordinateSpace(name: "averagesButterflyJointExport")
            }
            WaveformTimeAxisView(segment: segments[0], samplingRate: signal.samplingRate)
                .frame(height: Self.timeAxisHeight)
        }
    }
}

/// Drag handle sitting between the plot column and the Topography pane.
/// Dragging it left widens Topography, dragging right narrows it — the pane is
/// on the right, so its left edge is the grip.
private struct AveragesTopographyResizer: View {
    @Binding var width: Double
    let available: CGFloat

    @State private var widthAtDragStart: Double?

    var body: some View {
        let range = EpochingViewModel.averagesTopographyWidthRange

        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -5))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = widthAtDragStart ?? width
                        if widthAtDragStart == nil { widthAtDragStart = start }
                        // Dragging left (negative translation) grows the pane.
                        let ceiling = available > 0 ? max(range.lowerBound, Double(available) - 300) : range.upperBound
                        let proposed = start - Double(value.translation.width)
                        width = min(max(proposed, range.lowerBound), min(range.upperBound, ceiling))
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            .help("Drag to resize the Topography pane")
            .accessibilityLabel("Topography pane width")
    }
}
