//
//  AveragesWorkspaceViews.swift
//  EVA
//
//  In-place averaged-category workspace for Butterfly, Topography, and Channel
//  Inspector. This deliberately lives as a WaveformView extension for now so it
//  can reuse the per-window state already owned by WaveformView.
//

import SwiftUI

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
            } else if !showsPlotArea && !epoching.showsAveragesLog {
                ContentUnavailableView(
                    "All Average Views Hidden",
                    systemImage: "rectangle.3.group",
                    description: Text("Turn a panel back on from the averages toolbar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let relativeSample = averagesWorkspaceRelativeSample(for: segments)

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
                                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                            }

                            if epoching.showsAveragesTopography {
                                averagesTopographyPane(signal: signal, relativeSample: relativeSample)
                                    .frame(
                                        minWidth: 320,
                                        maxWidth: showsLeftColumn ? 430 : .infinity,
                                        maxHeight: .infinity
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if showsPlotArea {
                        averagesLatencyScrubber(segment: segments[0], relativeSample: relativeSample)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    seedAveragesWorkspaceLatencyIfNeeded(segment: segments[0])
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    func averagesToolbar(for signal: MFFSignalData) -> some View {
        return HStack(spacing: 12) {
            toolbarScaleControls(showsTimeScale: false)

            HStack(spacing: 6) {
                averagesToolbarToggle(
                    title: "Waveforms",
                    systemImage: "waveform.path.ecg",
                    isOn: $epoching.showsAveragesInspector
                )
                averagesToolbarToggle(
                    title: "Topomaps",
                    systemImage: "circle.grid.3x3.fill",
                    isOn: $epoching.showsAveragesTopography
                )
                averagesToolbarToggle(
                    title: "Butterfly",
                    systemImage: "chart.xyaxis.line",
                    isOn: $epoching.showsAveragesButterfly
                )
                averagesToolbarToggle(
                    title: "Logs",
                    systemImage: "list.bullet.rectangle",
                    isOn: $epoching.showsAveragesLog
                )
            }

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

    private func averagesToolbarToggle(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 24, height: 24)
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: 67, height: 10)
            }
            .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
            .frame(width: 77, height: 58)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Butterfly")
                        .font(.headline)
                    Spacer()
                    Text(averagesLatencyText(segment: segments[0], relativeSample: currentRelativeSample, samplingRate: signal.samplingRate))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                GeometryReader { proxy in
                    OverlayButterflyPlot(
                        data: signal.data,
                        segments: segments,
                        colors: segments.map { epochColor(for: $0.colorIndex) },
                        hiddenChannels: channels.hidden,
                        amplitudeScale: amplitudeScale,
                        highlightRelativeSample: currentRelativeSample,
                        channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                        onTapChannel: { channelInspectorSelection = .channel($0) }
                    )
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                            .onEnded { value in
                                setAveragesWorkspaceLatency(
                                    relativeSample(forButterflyX: value.location.x, width: proxy.size.width, segment: segments[0]),
                                    segment: segments[0]
                                )
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .local)
                            .onChanged { value in
                                setAveragesWorkspaceLatency(
                                    relativeSample(forButterflyX: value.location.x, width: proxy.size.width, segment: segments[0]),
                                    segment: segments[0]
                                )
                            }
                    )
                    .overlay {
                        latencyCursorScrubOverlay(segment: segments[0], relativeSample: currentRelativeSample)
                    }
                    .contextMenu {
                        figureSaveMenu(
                            title: "Averages Butterfly",
                            legend: overlayLegendItems(),
                            size: CGSize(width: 820, height: 300)
                        ) {
                            OverlayButterflyPlot(
                                data: signal.data,
                                segments: segments,
                                colors: segments.map { epochColor(for: $0.colorIndex) },
                                hiddenChannels: channels.hidden,
                                amplitudeScale: amplitudeScale,
                                highlightRelativeSample: currentRelativeSample
                            )
                        }
                    }
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

                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 12) {
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
                                            minimumMapHeight: 135,
                                            channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                                            onTapChannel: { channelInspectorSelection = .channel($0) }
                                        )
                                        .frame(height: 170)
                                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .padding(.trailing, isCommandKeyPressed ? 10 : 0)
                        }

                        if isCommandKeyPressed {
                            TopomapScaleControl(
                                mode: $epoching.topomapScaleMode,
                                symmetric: $epoching.topomapSymmetric,
                                minValue: topomapMinBinding,
                                maxValue: topomapMaxBinding,
                                autoScale: autoScale,
                                onAutoMicrovolts: {
                                    epoching.topomapScaleManual = false
                                    seedTopomapScale(autoScale: autoScale, autoZ: autoZ)
                                },
                                sigma: $epoching.topomapZSigma,
                                zMean: topomapZMeanBinding,
                                zSD: topomapZSDBinding,
                                onAutoZ: {
                                    epoching.topomapZManual = false
                                    seedTopomapScale(autoScale: autoScale, autoZ: autoZ)
                                }
                            )
                            .padding(.leading, 8)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .onAppear { seedTopomapScale(autoScale: autoScale, autoZ: autoZ) }
                    .onChange(of: epoching.topomapSymmetric) { _, sym in
                        if sym { epoching.topomapScaleMin = -epoching.topomapScaleMax }
                    }
                    .contextMenu {
                        figureSaveMenu(
                            title: "Average Topographies",
                            legend: [],
                            size: CGSize(width: CGFloat(max(samples.count, 1)) * 300, height: 330)
                        ) {
                            topomapsFigure(samples: samples, layout: layout, scale: autoScale, colorRange: colorRange, zScaling: zScaling, signal: signal)
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
                        highlightRelativeSample: relativeSample,
                        standardErrorBands: standardErrorBands
                    )
                    .overlay {
                        latencyCursorScrubOverlay(segment: segments[0], relativeSample: relativeSample)
                    }
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
        let maxIndex = max(segment.endSample - segment.startSample, 0)
        let range = 0...max(Double(maxIndex), 1)

        return averagesPanel(fillHeight: false) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Latency")
                        .font(.caption.weight(.semibold))
                    Text(averagesLatencyText(
                        segment: segment,
                        relativeSample: relativeSample,
                        samplingRate: epoching.epochedSignal?.samplingRate ?? 0
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Spacer()
                }

                Slider(
                    value: Binding(
                        get: { Double(relativeSample) },
                        set: { setAveragesWorkspaceLatency(Int($0.rounded()), segment: segment) }
                    ),
                    in: range,
                    step: 1
                )
                .disabled(maxIndex <= 0)

                HStack {
                    Text(averagesLatencyText(segment: segment, relativeSample: 0, samplingRate: epoching.epochedSignal?.samplingRate ?? 0))
                    Spacer()
                    Text(averagesLatencyText(segment: segment, relativeSample: segment.stimulusOffsetSamples, samplingRate: epoching.epochedSignal?.samplingRate ?? 0))
                    Spacer()
                    Text(averagesLatencyText(segment: segment, relativeSample: maxIndex, samplingRate: epoching.epochedSignal?.samplingRate ?? 0))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func averagesEventsLogPanel(signal: MFFSignalData, segments: [EpochSegment]) -> some View {
        let summary = epoching.psaExclusionSummary
        return averagesPanel {
            VStack(alignment: .leading, spacing: 10) {
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
                        averagesLogMetric("Accepted epochs", value: summary.acceptedEpochs)
                        averagesLogMetric("Excluded", value: summary.excludedEpochs)
                        averagesLogMetric("Timing adjusted", value: summary.timingAdjusted)
                    }
                    GridRow {
                        averagesLogMetric("Artifact skips", value: summary.skippedArtifacts)
                        averagesLogMetric("Missing timing", value: summary.skippedTimingMarkers)
                        averagesLogMetric("Out of bounds", value: summary.skippedOutOfBounds)
                        averagesLogMetric("Too many bad channels", value: summary.rejectedForTooManyBadChannels)
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Summary")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(epoching.statusMessage ?? "No PSA log message recorded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !epoching.epochBadChannelSummary.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Per-epoch bad channels")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(epoching.epochBadChannelSummary.prefix(5).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
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
                    highlightRelativeSample: relativeSample,
                    standardErrorBands: standardErrorBands
                )
                .frame(height: 260)
            }
        }
    }

    private func averagesPanel<Content: View>(fillHeight: Bool = true, @ViewBuilder content: () -> Content) -> some View {
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

    private func setAveragesWorkspaceLatency(_ value: Int, segment: EpochSegment) {
        let maxIndex = max(segment.endSample - segment.startSample, 0)
        epoching.butterflyTopomapRelativeSample = min(max(value, 0), maxIndex)
        topomapSample = nil
    }

    private func setAveragesWorkspaceLatency(forPlotX x: CGFloat, width: CGFloat, segment: EpochSegment) {
        setAveragesWorkspaceLatency(relativeSample(forButterflyX: x, width: width, segment: segment), segment: segment)
    }

    private func latencyCursorX(relativeSample: Int, segment: EpochSegment, width: CGFloat) -> CGFloat {
        let epochLength = max(segment.endSample - segment.startSample + 1, 1)
        guard epochLength > 1 else { return 0 }
        let clamped = min(max(relativeSample, 0), epochLength - 1)
        return CGFloat(clamped) / CGFloat(epochLength - 1) * width
    }

    private func latencyCursorScrubOverlay(segment: EpochSegment, relativeSample: Int) -> some View {
        GeometryReader { proxy in
            let hitWidth: CGFloat = 54
            let x = latencyCursorX(relativeSample: relativeSample, segment: segment, width: proxy.size.width)
            let centerX = min(max(x, hitWidth / 2), max(proxy.size.width - hitWidth / 2, hitWidth / 2))
            let plotMinX = proxy.frame(in: .global).minX

            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.01))
                    .frame(width: hitWidth, height: proxy.size.height)
                    .position(x: centerX, y: proxy.size.height / 2)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                setAveragesWorkspaceLatency(forPlotX: value.location.x - plotMinX, width: proxy.size.width, segment: segment)
                            }
                            .onEnded { value in
                                setAveragesWorkspaceLatency(forPlotX: value.location.x - plotMinX, width: proxy.size.width, segment: segment)
                            }
                    )
                    .help("Drag to adjust latency across all average views.")
            }
        }
    }

    private func averagesWorkspaceRelativeSample(for segments: [EpochSegment]) -> Int {
        guard let first = segments.first else { return 0 }
        let maxIndex = max(first.endSample - first.startSample, 0)
        if let current = epoching.butterflyTopomapRelativeSample {
            return min(max(current, 0), maxIndex)
        }
        return min(max(first.stimulusOffsetSamples, 0), maxIndex)
    }

    private func averagesLatencyText(segment: EpochSegment, relativeSample: Int, samplingRate: Double) -> String {
        guard samplingRate > 0 else { return "0 ms" }
        let latencyMilliseconds = Double(relativeSample - segment.stimulusOffsetSamples) / samplingRate * 1_000
        return String(format: "%+.0f ms", latencyMilliseconds)
    }
}
