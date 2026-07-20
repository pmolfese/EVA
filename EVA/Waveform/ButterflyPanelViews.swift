//
//  ButterflyPanelViews.swift
//  EVA
//
//  Butterfly (averaged-category) plot panel, overlay/noise-band toggles, and the multi-condition overlay helpers it depends on,
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - Butterfly panel

    @ViewBuilder
    func butterflyPanel(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Butterfly")
                        .font(.headline)
                    Text("Averaged categories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if epoching.isAveraged {
                    overlayConditionsMenu()
                    Toggle("Overlay", isOn: $epoching.showsOverlayButterfly)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Overlay the selected conditions on shared axes, each in its own color.")
                }
                if !recording.noiseCurvesByCategory.isEmpty, !epoching.showsOverlayButterfly {
                    Toggle("Noise band", isOn: $epoching.showsNoiseBand)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Shade the ± grand-average noise band (from the ± residual across contributing files) behind each category.")
                }
                Button {
                    epoching.showsButterflyPlot = false
                    epoching.butterflyTopomapRelativeSample = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if epoching.isAveraged, !epoching.epochSegments.isEmpty {
                let overlaySegments = selectedOverlaySegments()
                ScrollView {
                    if epoching.showsOverlayButterfly {
                        VStack(alignment: .leading, spacing: 10) {
                            FlowLegend(items: overlayLegendItems())
                            GeometryReader { proxy in
                                OverlayButterflyPlot(
                                    data: signal.data,
                                    segments: overlaySegments,
                                    colors: overlaySegments.map { epochColor(for: $0.colorIndex) },
                                    hiddenChannels: channels.hidden,
                                    amplitudeScale: amplitudeScale,
                                    samplingRate: signal.samplingRate,
                                    highlightRelativeSample: epoching.butterflyTopomapRelativeSample,
                                    channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                                    onTapChannel: { scrollToChannelRequest = $0 }
                                )
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    SpatialTapGesture(count: 2, coordinateSpace: .local)
                                        .onEnded { value in
                                            guard let first = overlaySegments.first else { return }
                                            epoching.butterflyTopomapRelativeSample = relativeSample(
                                                forButterflyX: value.location.x, width: proxy.size.width, segment: first)
                                            topomapSample = nil
                                        }
                                )
                                .help("Double-click to compare topographies at this latency.")
                                .contextMenu {
                                    figureSaveMenu(title: "Butterfly Overlay",
                                                   legend: overlayLegendItems(),
                                                   size: CGSize(width: 820, height: 300)) {
                                        OverlayButterflyPlot(
                                            data: signal.data,
                                            segments: overlaySegments,
                                            colors: overlaySegments.map { epochColor(for: $0.colorIndex) },
                                            hiddenChannels: channels.hidden,
                                            amplitudeScale: amplitudeScale,
                                            samplingRate: signal.samplingRate
                                        )
                                    }
                                }
                            }
                            .frame(height: 220)
                        }
                        .padding(16)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(overlaySegments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Label(epoching.displayCategory(segment.category), systemImage: "waveform.path.ecg")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(epochColor(for: segment.colorIndex))
                                    Spacer()
                                    Text("\(segment.contributingEpochCount) avg")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                GeometryReader { proxy in
                                    ButterflyConditionPlot(
                                        data: signal.data,
                                        segment: segment,
                                        hiddenChannels: channels.hidden,
                                        amplitudeScale: amplitudeScale,
                                        samplingRate: signal.samplingRate,
                                        color: epochColor(for: segment.colorIndex),
                                        highlightRelativeSample: epoching.butterflyTopomapRelativeSample,
                                        noiseCurve: (epoching.showsNoiseBand && !recording.noiseCurvesByCategory.isEmpty)
                                            ? recording.noiseCurvesByCategory[segment.category]
                                            : nil,
                                        channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                                        onTapChannel: { scrollToChannelRequest = $0 }
                                    )
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(
                                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                                            .onEnded { value in
                                                epoching.butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: segment
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 6, coordinateSpace: .local)
                                            .onChanged { value in
                                                guard epoching.butterflyTopomapRelativeSample != nil else { return }
                                                epoching.butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: segment
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .help("Double-click to compare topographies at this latency. Drag the yellow line to move it.")
                                    .contextMenu {
                                        figureSaveMenu(title: "\(epoching.displayCategory(segment.category)) Butterfly",
                                                       legend: [(epoching.displayCategory(segment.category), epochColor(for: segment.colorIndex))],
                                                       size: CGSize(width: 820, height: 300)) {
                                            ButterflyConditionPlot(
                                                data: signal.data,
                                                segment: segment,
                                                hiddenChannels: channels.hidden,
                                                amplitudeScale: amplitudeScale,
                                                samplingRate: signal.samplingRate,
                                                color: epochColor(for: segment.colorIndex),
                                                noiseCurve: (epoching.showsNoiseBand && !recording.noiseCurvesByCategory.isEmpty)
                                                    ? recording.noiseCurvesByCategory[segment.category] : nil
                                            )
                                        }
                                    }
                                }
                                .frame(height: 150)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(16)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Averages",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Create PSA averages before showing a butterfly plot.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    func overlaidCategoriesPanel(for signal: MFFSignalData) -> some View {
        let visibleChannels = signal.data.indices.filter { !channels.hidden.contains($0) }
        let overlaySegments = selectedOverlaySegments()
        let colors = overlaySegments.map { epochColor(for: $0.colorIndex) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overlaid Categories")
                        .font(.headline)
                    Text("Selected category averages, per channel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if epoching.isAveraged { overlayConditionsMenu() }
                Button {
                    epoching.showsOverlaidCategories = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if epoching.isAveraged, !epoching.epochSegments.isEmpty {
                // Category color legend (renamed labels for figures).
                FlowLegend(items: overlayLegendItems())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleChannels, id: \.self) { channelIndex in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Ch \(channelIndex + 1)")
                                    .font(.caption.weight(.semibold).monospaced())
                                    .foregroundStyle(channelColor(channelIndex))

                                GeometryReader { proxy in
                                    OverlaidCategoryChannelPlot(
                                        data: signal.data,
                                        channelIndex: channelIndex,
                                        segments: overlaySegments,
                                        colors: colors,
                                        amplitudeScale: amplitudeScale,
                                        highlightRelativeSample: epoching.butterflyTopomapRelativeSample
                                    )
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(
                                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                                            .onEnded { value in
                                                guard let first = epoching.epochSegments.first else { return }
                                                epoching.butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: first
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 6, coordinateSpace: .local)
                                            .onChanged { value in
                                                guard epoching.butterflyTopomapRelativeSample != nil,
                                                      let first = epoching.epochSegments.first else { return }
                                                epoching.butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: first
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .help("Double-click to show a topomap for every category at this latency. Drag the yellow line to move it.")
                                    .contextMenu {
                                        figureSaveMenu(title: "Ch \(channelIndex + 1) Overlay",
                                                       legend: overlayLegendItems(),
                                                       size: CGSize(width: 820, height: 220)) {
                                            OverlaidCategoryChannelPlot(
                                                data: signal.data,
                                                channelIndex: channelIndex,
                                                segments: overlaySegments,
                                                colors: colors,
                                                amplitudeScale: amplitudeScale
                                            )
                                        }
                                    }
                                }
                                .frame(height: 88)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "No Averages",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Create PSA averages before overlaying categories.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    func averagedTopomapPanel(for signal: MFFSignalData, relativeSample: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Topographies")
                        .font(.headline)
                    Text(averagedTopomapLatencyText(relativeSample: relativeSample))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    epoching.butterflyTopomapRelativeSample = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if let layout = recording.sensorLayout {
                let samples = averagedTopomapSamples(relativeSample: relativeSample, in: signal)
                let autoScale = fixedTopomapScale(for: samples.map(\.sample), in: signal) ?? 1
                let autoZ = topomapAutoZ(samples: samples, in: signal)
                let colorRange = topomapColorRange()
                let zScaling = topomapZScaling(auto: autoZ)
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(samples) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(epoching.displayCategory(entry.category))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(epochColor(for: entry.colorIndex))
                                    TopomapView(
                                        layout: layout,
                                        values: topomapValues(at: entry.sample, in: signal),
                                        timeSeconds: entry.latencySeconds,
                                        fixedScale: autoScale,
                                        colorRange: colorRange,
                                        zScaling: zScaling,
                                        channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                                        onTapChannel: { scrollToChannelRequest = $0 }
                                    )
                                    .frame(height: 320)
                                }
                            }
                        }
                        .padding(16)
                        .contextMenu {
                            figureSaveMenu(
                                title: "Average Topographies",
                                legend: [],
                                size: CGSize(width: CGFloat(max(samples.count, 1)) * 300, height: 330)
                            ) {
                                topomapsFigure(samples: samples, layout: layout, scale: autoScale, colorRange: colorRange, zScaling: zScaling, signal: signal)
                            }
                        }
                    }

                    if isCommandKeyPressed {
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
                        .padding(.trailing, 10)
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
            } else {
                ContentUnavailableView(
                    "No Sensor Layout",
                    systemImage: "circle.dashed",
                    description: Text("This package has no readable sensorLayout.xml, so topographic maps can't be drawn.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The manual µV color range (nil to auto-scale). Only in µV mode.
    func topomapColorRange() -> ClosedRange<Double>? {
        guard epoching.topomapScaleMode == .microvolts,
              epoching.topomapScaleManual,
              epoching.topomapScaleMin < epoching.topomapScaleMax else { return nil }
        return epoching.topomapScaleMin...epoching.topomapScaleMax
    }

    /// The effective z-score scaling, or nil when not in Z mode. `auto` is the
    /// mean/SD computed across the displayed maps.
    func topomapZScaling(auto: (mean: Double, sd: Double)) -> TopomapZScaling? {
        guard epoching.topomapScaleMode == .zScore else { return nil }
        let mean = epoching.topomapZManual ? epoching.topomapZMean : auto.mean
        let sd = epoching.topomapZManual ? epoching.topomapZSD : auto.sd
        guard sd > 0, epoching.topomapZSigma > 0 else { return nil }
        return TopomapZScaling(mean: mean, sd: sd, sigma: epoching.topomapZSigma)
    }

    var topomapMinBinding: Binding<Double> {
        Binding(get: { epoching.topomapScaleMin }, set: { value in
            if epoching.topomapScaleMin != value {
                epoching.topomapScaleMin = value
            }
            let mirroredMaximum = -value
            if epoching.topomapSymmetric, epoching.topomapScaleMax != mirroredMaximum {
                epoching.topomapScaleMax = mirroredMaximum
            }
            if !epoching.topomapScaleManual {
                epoching.topomapScaleManual = true
            }
        })
    }

    var topomapMaxBinding: Binding<Double> {
        Binding(get: { epoching.topomapScaleMax }, set: { value in
            if epoching.topomapScaleMax != value {
                epoching.topomapScaleMax = value
            }
            let mirroredMinimum = -value
            if epoching.topomapSymmetric, epoching.topomapScaleMin != mirroredMinimum {
                epoching.topomapScaleMin = mirroredMinimum
            }
            if !epoching.topomapScaleManual {
                epoching.topomapScaleManual = true
            }
        })
    }

    var topomapZMeanBinding: Binding<Double> {
        Binding(get: { epoching.topomapZMean }, set: { value in
            if epoching.topomapZMean != value {
                epoching.topomapZMean = value
            }
            if !epoching.topomapZManual {
                epoching.topomapZManual = true
            }
        })
    }

    var topomapZSDBinding: Binding<Double> {
        Binding(get: { epoching.topomapZSD }, set: { value in
            if epoching.topomapZSD != value {
                epoching.topomapZSD = value
            }
            if !epoching.topomapZManual {
                epoching.topomapZManual = true
            }
        })
    }

    /// Seeds µV min/max and z mean/SD from the data so the ⌘ control opens at the
    /// current auto values (only while the respective mode is still auto).
    func seedTopomapScale(autoScale: Double, autoZ: (mean: Double, sd: Double)) {
        if !epoching.topomapScaleManual {
            if epoching.topomapScaleMax != autoScale {
                epoching.topomapScaleMax = autoScale
            }
            if epoching.topomapScaleMin != -autoScale {
                epoching.topomapScaleMin = -autoScale
            }
        }
        if !epoching.topomapZManual {
            if epoching.topomapZMean != autoZ.mean {
                epoching.topomapZMean = autoZ.mean
            }
            if epoching.topomapZSD != autoZ.sd {
                epoching.topomapZSD = autoZ.sd
            }
        }
    }

    /// Mean and (population) standard deviation of the values feeding the maps.
    func topomapAutoZ(samples: [AveragedTopomapSample], in signal: MFFSignalData) -> (mean: Double, sd: Double) {
        let values = samples.flatMap { topomapValues(at: $0.sample, in: signal) }
        guard !values.isEmpty else { return (0, 1) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sd = variance.squareRoot()
        return (mean, sd > 0 ? sd : 1)
    }

    /// Standalone, side-by-side arrangement of all displayed topomaps for export
    /// (one labeled map per selected condition, shared color scale).
    @ViewBuilder
    func topomapsFigure(
        samples: [AveragedTopomapSample],
        layout: SensorLayout,
        scale: Double?,
        colorRange: ClosedRange<Double>?,
        zScaling: TopomapZScaling?,
        signal: MFFSignalData
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let first = samples.first {
                Text(String(format: "t = %.3f s", first.latencySeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                ForEach(samples.indices, id: \.self) { index in
                    let entry = samples[index]
                    let showsSharedScale = index == samples.index(before: samples.endIndex)

                    VStack(spacing: 6) {
                        Text(epoching.displayCategory(entry.category))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(epochColor(for: entry.colorIndex))
                        TopomapView(
                            layout: layout,
                            values: topomapValues(at: entry.sample, in: signal),
                            timeSeconds: entry.latencySeconds,
                            fixedScale: scale,
                            colorRange: colorRange,
                            zScaling: zScaling,
                            showsHeader: false,
                            showsLayoutName: false,
                            colorBarPlacement: showsSharedScale ? .trailing : .none,
                            minimumMapHeight: 220
                        )
                        .frame(width: showsSharedScale ? 300 : 250, height: 250)
                    }
                }
            }
        }
    }

    func relativeSample(forButterflyX x: CGFloat, width: CGFloat, segment: EpochSegment) -> Int {
        let epochLength = max(segment.endSample - segment.startSample + 1, 1)
        let normalized = min(max(x / max(width, 1), 0), 1)
        return min(max(Int((normalized * CGFloat(epochLength - 1)).rounded()), 0), epochLength - 1)
    }

    func averagedTopomapSamples(relativeSample: Int, in signal: MFFSignalData) -> [AveragedTopomapSample] {
        selectedOverlaySegments().compactMap { segment in
            let epochLength = max(segment.endSample - segment.startSample + 1, 1)
            let localSample = min(max(relativeSample, 0), epochLength - 1)
            let sample = min(segment.startSample + localSample, segment.endSample)
            guard sample >= 0, sample < (signal.data.first?.count ?? 0) else { return nil }
            let latencySeconds = signal.samplingRate > 0
                ? Double(localSample - segment.stimulusOffsetSamples) / signal.samplingRate
                : 0
            return AveragedTopomapSample(
                category: segment.category,
                sample: sample,
                latencySeconds: latencySeconds,
                colorIndex: segment.colorIndex
            )
        }
    }

    func averagedTopomapLatencyText(relativeSample: Int) -> String {
        guard let segment = epoching.epochSegments.first, (epoching.epochedSignal?.samplingRate ?? 0) > 0 else {
            return "Latency"
        }
        let samplingRate = epoching.epochedSignal?.samplingRate ?? 1
        let latency = Double(relativeSample - segment.stimulusOffsetSamples) / samplingRate
        return String(format: "Latency %.3fs", latency)
    }

    func fixedTopomapScale(for samples: [Int], in signal: MFFSignalData) -> Double? {
        let maxAbs = samples
            .flatMap { sample in topomapValues(at: sample, in: signal).map(abs) }
            .max() ?? 0
        return maxAbs > 0 ? maxAbs : nil
    }

    // MARK: - Multi-condition overlay helpers

    /// Distinct categories among the adopted segments, in first-appearance order.
    func overlayAvailableCategories() -> [String] {
        var seen: [String] = []
        for segment in epoching.epochSegments where !seen.contains(segment.category) {
            seen.append(segment.category)
        }
        return seen
    }

    /// Segments whose category is in the current overlay selection.
    func selectedOverlaySegments() -> [EpochSegment] {
        let available = overlayAvailableCategories()
        let selected = epoching.overlayCategories(available: available)
        return epoching.epochSegments.filter { selected.contains($0.category) }
    }

    /// Legend: one entry per selected category (deduped, renamed), in order.
    func overlayLegendItems() -> [(String, Color)] {
        let available = overlayAvailableCategories()
        let selected = epoching.overlayCategories(available: available)
        var seen = Set<String>()
        var items: [(String, Color)] = []
        for segment in epoching.epochSegments
        where selected.contains(segment.category) && seen.insert(segment.category).inserted {
            items.append((epoching.displayCategory(segment.category), epochColor(for: segment.colorIndex)))
        }
        return items
    }

    /// A menu of category toggles for choosing which conditions to overlay.
    @ViewBuilder
    func overlayConditionsMenu() -> some View {
        let available = overlayAvailableCategories()
        Menu {
            ForEach(available, id: \.self) { category in
                Toggle(epoching.displayCategory(category), isOn: Binding(
                    get: { epoching.isOverlaySelected(category, available: available) },
                    set: { _ in epoching.toggleOverlayCategory(category, available: available) }
                ))
            }
        } label: {
            Label("Conditions", systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which conditions to overlay.")
    }

    /// A right-click "Save Figure As…" submenu that renders `figure` (wrapped in a
    /// white FigureCard with title + legend) to PNG / JPEG / PDF.
    @ViewBuilder
    func figureSaveMenu<Figure: View>(
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

    func figureFileName(_ title: String) -> String {
        let base = (recording.packageName as NSString).deletingPathExtension
        let safeTitle = title.replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "/:")).joined()
        return "\(base)-\(safeTitle)"
    }

    func categoryColorIndices(for categories: [String]) -> [String: Int] {
        let uniqueCategories = Array(Set(categories)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: uniqueCategories.enumerated().map { index, category in
            (category, index)
        })
    }

}
