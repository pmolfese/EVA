//
//  TimeFrequencyOverviewView.swift
//  EVA
//
//  Linked, all-channel views for time-frequency data.  The deliberately
//  explicit "Build overview" action keeps a 128/256 channel decomposition
//  from becoming an accidental recomputation on every control change.
//

import SwiftUI
import AppKit

/// Cached all-channel data used only by the overview workspace.  The normal
/// Time-Frequency detail panel remains a compact single-channel computation.
struct TFOverviewRender: Sendable {
    var condition: String
    var channelIndices: [Int]
    var channelNames: [String]
    var grids: [[[Double]]] // channel × frequency × time
    var frequenciesHz: [Double]
    var timesMs: [Double]
    var measure: EpochingViewModel.TFMeasure
    var isDifference: Bool

    var isDiverging: Bool { measure == .power || isDifference }

    func localIndex(for channel: Int) -> Int? {
        channelIndices.firstIndex(of: channel)
    }

    func detailRender(for channel: Int) -> TFRender? {
        guard let local = localIndex(for: channel) else { return nil }
        let grid = grids[local]
        let values = grid.flatMap { $0 }
        let range: ClosedRange<Double>
        if isDiverging {
            let extent = max(values.map(abs).max() ?? 1, 1e-6)
            range = -extent...extent
        } else {
            range = 0...max(values.max() ?? 1, 0.05)
        }
        return TFRender(
            grid: grid, frequenciesHz: frequenciesHz, timesMs: timesMs,
            eventSampleIndex: timesMs.firstIndex(where: { $0 >= 0 }) ?? 0,
            valueRange: range, isDiverging: isDiverging, measure: measure,
            isDifference: isDifference, trialCountA: 0, trialCountB: nil
        )
    }
}

struct TimeFrequencyOverviewView: View {
    let overviews: [TFOverviewRender]
    let layout: SensorLayout?
    @Bindable var epoching: EpochingViewModel
    let samplingRate: Double
    @Binding var selectedChannel: Int
    let groups: [ChannelSet]
    let conditions: [String]
    let build: ([String]) -> Void
    let openDetail: (Int) -> Void
    let isBuilding: Bool
    let progress: Double
    let progressStatus: String
    let setupNeedsRebuild: Bool

    @State private var destination = "Scalp + detail"
    @State private var groupID = "all"
    @State private var bandName = "Alpha"
    @State private var windowStartMs = 0.0
    @State private var windowEndMs = 600.0
    @State private var filmstripStepMs = 50.0

    private let windowPresets: [(String, ClosedRange<Double>)] = [
        ("0–200 ms", 0...200), ("200–500 ms", 200...500),
        ("500–800 ms", 500...800), ("0–500 ms", 0...500),
        ("0–600 ms", 0...600)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("All-channel explorer").font(.headline)
                    Text("Choose conditions and analysis settings, then build a spatial overview. Click a sensor to open its channel detail.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TFOverviewBuildControls(
                    conditions: conditions, builtConditions: Set(overviews.map(\.condition)),
                    hasOverview: !overviews.isEmpty, setupNeedsRebuild: setupNeedsRebuild,
                    isBuilding: isBuilding, progress: progress, progressStatus: progressStatus,
                    build: build
                )
            }

            analysisControls

            if !overviews.isEmpty {
                controls(overviews)
                dashboard
                if isBuilding { prewarmedDashboard }
            } else {
                ContentUnavailableView(
                    "Overview not built",
                    systemImage: "circle.grid.cross",
                    description: Text("Build all-channel maps once to explore the current condition and analysis settings spatially."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var analysisControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Measure").fixedSize()
                    Picker("", selection: $epoching.tfMeasure) {
                        ForEach(EpochingViewModel.TFMeasure.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 145)
                }
                HStack(spacing: 6) {
                    Text("Method").fixedSize()
                    Picker("", selection: $epoching.tfMethod) {
                        ForEach(TFMethod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                }
                if epoching.tfMeasure == .power {
                    HStack(spacing: 6) {
                        Text("Baseline").fixedSize()
                        Picker("", selection: $epoching.tfBaselineMethod) {
                            ForEach(TFBaselineMethod.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 120)
                    }
                }
                LabeledContent("Hz") {
                    HStack(spacing: 3) {
                        Stepper(value: $epoching.tfMinFrequencyHz, in: 1...(epoching.tfMaxFrequencyHz - 1), step: 1) { Text("\(Int(epoching.tfMinFrequencyHz))") }
                        Text("–").foregroundStyle(.secondary)
                        Stepper(value: $epoching.tfMaxFrequencyHz, in: (epoching.tfMinFrequencyHz + 1)...min(120, samplingRate / 2.5), step: 1) { Text("\(Int(epoching.tfMaxFrequencyHz))") }
                    }
                    .monospacedDigit()
                }
                LabeledContent("Bins") { Stepper(value: $epoching.tfFrequencyCount, in: 5...80) { Text("\(epoching.tfFrequencyCount)").monospacedDigit() } }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func controls(_ overviews: [TFOverviewRender]) -> some View {
        HStack(spacing: 12) {
            Picker("Channel group", selection: $groupID) {
                Text("All channels").tag("all")
                ForEach(groups.filter { compatible($0, overview: overviews[0]) }) { group in
                    Text(group.name).tag(group.id.uuidString)
                }
            }
            .frame(maxWidth: 250)
            Picker("Band", selection: $bandName) {
                ForEach(frequencyBands) { band in
                    Text(band.name).tag(band.name)
                }
            }
            .frame(width: 135)
            windowControls
            Text("\(activeChannels(overviews[0]).count) channels · \(overviews.count) conditions shown")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .labelsHidden()
    }

    private var windowControls: some View {
        HStack(spacing: 4) {
            Text("Window").fixedSize()
            TextField("Start", value: windowStartBinding, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 58)
            Text("–").foregroundStyle(.secondary)
            TextField("End", value: windowEndBinding, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 58)
            Text("ms").foregroundStyle(.secondary)
            Menu {
                ForEach(windowPresets, id: \.0) { preset in
                    Button(preset.0) { setWindow(preset.1) }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Choose a time-window preset")
        }
        .font(.caption)
    }

    @ViewBuilder
    private func overviewContent(_ overview: TFOverviewRender, destination: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(overview.condition).font(.headline)
            switch destination ?? self.destination {
        case "Scalp + detail": scalpDetail(overview)
        case "Sensor matrix": sensorMatrix(overview)
        case "Filmstrip": filmstrip(overview)
        case "Ranked gallery": gallery(overview)
        default: clusters(overview)
            }
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All-channel explorer").font(.headline)
            Text("Choose the question you want to answer. Every selected condition stays visible below with the same band, window, and channel group.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                dashboardCard("Scalp + detail", question: "Where is the effect?", symbol: "circle.dotted")
                dashboardCard("Sensor matrix", question: "When does it happen?", symbol: "rectangle.grid.1x2")
                dashboardCard("Filmstrip", question: "How does it move?", symbol: "film")
                dashboardCard("Ranked gallery", question: "Which channels lead?", symbol: "rectangle.grid.2x2")
                dashboardCard("Clusters", question: "Is it spatially coherent?", symbol: "circle.hexagongrid")
            }
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(overviews, id: \.condition) { overview in
                        overviewContent(overview)
                            .frame(width: destination == "Filmstrip" || destination == "Ranked gallery" ? 1_000 : nil,
                                   alignment: .leading)
                            .frame(minWidth: destination == "Sensor matrix" ? 640 : 420,
                                   maxWidth: destination == "Filmstrip" || destination == "Ranked gallery" ? 1_000 : 760,
                                   alignment: .leading)
                    }
                }
            }
        }
    }

    /// Builds the view-specific raster/heatmap caches while the rebuild status
    /// is still visible.  Hidden views retain normal layout so their Canvas and
    /// Topomap `onAppear` work happens now, rather than on the first tab click.
    private var prewarmedDashboard: some View {
        HStack(spacing: 0) {
            ForEach(overviews, id: \.condition) { overview in
                ForEach(["Scalp + detail", "Sensor matrix", "Filmstrip", "Ranked gallery", "Clusters"], id: \.self) { view in
                    overviewContent(overview, destination: view)
                        .frame(width: view == "Filmstrip" || view == "Ranked gallery" ? 1_000 : 640)
                }
            }
        }
        .frame(width: 1, height: 1)
        .hidden()
        .allowsHitTesting(false)
    }

    private func dashboardCard(_ name: String, question: String, symbol: String) -> some View {
        Button { destination = name } label: {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: symbol).font(.title3)
                Text(question).font(.caption.weight(.semibold))
                Text(name).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .padding(8)
            .background(destination == name ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func scalpDetail(_ overview: TFOverviewRender) -> some View {
        if let layout {
            HStack(spacing: 16) {
                TopomapView(
                    layout: layout, values: roiValues(overview), timeSeconds: selectedWindow.upperBound / 1000,
                    fixedScale: overviewScale(overview), unitLabel: unitLabel(overview),
                    usesPositiveSequentialScale: !overview.isDiverging, minimumMapHeight: 190,
                    channelName: { channelName($0, overview: overview) },
                    onTapChannel: selectChannel,
                    visibleChannels: Set(activeChannels(overview))
                )
                .frame(width: 230)
                if let local = overview.localIndex(for: selectedChannel) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(overview.channelNames[local]) · \(windowLabel)").font(.headline)
                            Spacer()
                            Button("Open full detail") { selectChannel(selectedChannel) }
                                .controlSize(.small)
                        }
                        TFHeatmap(render: channelRender(local, overview))
                            .frame(minWidth: 300, maxWidth: .infinity, minHeight: 190)
                        Text("Selected: \(overview.channelNames[local])")
                        Text(String(format: "ROI value: %.3f %@", roiValue(local, overview), unitLabel(overview)))
                            .font(.caption.monospacedDigit())
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(bandName) · \(windowLabel)").font(.headline)
                        Text("Click an electrode to preview and open its full-resolution time-frequency detail.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        } else {
            noLayout
        }
    }

    private func sensorMatrix(_ overview: TFOverviewRender) -> some View {
        let channels = activeChannels(overview)
        let freq = frequencyIndices(overview)
        let values = channels.compactMap { channel -> [Double]? in
            guard let local = overview.localIndex(for: channel) else { return nil }
            return overview.timesMs.indices.map { time in mean(overview.grids[local], frequencies: freq, times: [time]) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(bandName) power/ITPC by sensor and time — Option-hover to identify a row; click it to open that channel’s TF detail.")
                .font(.caption).foregroundStyle(.secondary)
            TFChannelMatrix(
                rows: values, channels: channels, render: overview,
                channelName: { channelName($0, overview: overview) }, onSelect: selectChannel
            )
                .frame(minHeight: 160)
        }
    }

    @ViewBuilder
    private func filmstrip(_ overview: TFOverviewRender) -> some View {
        if let layout {
            let frequencySlices = frequencySliceIndices(overview, count: 6)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Frequency × time scalp maps — all analyzed frequencies.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Stepper("Every \(Int(filmstripStepMs)) ms", value: $filmstripStepMs, in: 10...250, step: 10)
                        .font(.caption).fixedSize()
                }
                GeometryReader { proxy in
                    let maxColumns = max(3, Int((proxy.size.width - 72) / 40))
                    let positions = filmstripTimeIndices(overview, maxColumns: maxColumns)
                    let mapSide = min(68, max(38, (proxy.size.width - 72) / CGFloat(max(positions.count, 1))))
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(frequencySlices, id: \.self) { frequency in
                            HStack(spacing: 4) {
                                Text(String(format: "%.1f Hz", overview.frequenciesHz[frequency]))
                                    .font(.caption.weight(.semibold).monospacedDigit()).frame(width: 64, alignment: .trailing)
                                ForEach(positions, id: \.self) { time in
                                    VStack(spacing: 1) {
                                        TopomapView(
                                            layout: layout, values: values(at: time, frequency: frequency, overview),
                                            timeSeconds: overview.timesMs[time] / 1000,
                                            fixedScale: overviewScale(overview, frequency: frequency), unitLabel: unitLabel(overview),
                                            usesPositiveSequentialScale: !overview.isDiverging,
                                            showsHeader: false, colorBarPlacement: .none, minimumMapHeight: mapSide,
                                            contentPadding: 0, fieldResolution: 40, showsElectrodes: false,
                                            visibleChannels: Set(activeChannels(overview))
                                        )
                                        .frame(width: mapSide, height: mapSide)
                                        if frequency == frequencySlices.first {
                                            Text("\(Int(overview.timesMs[time]))")
                                                .font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: CGFloat(frequencySlices.count) * 76)
            }
        } else { noLayout }
    }

    private func gallery(_ overview: TFOverviewRender) -> some View {
        let top = activeChannels(overview)
            .compactMap { channel -> (Int, Double)? in
                guard let local = overview.localIndex(for: channel) else { return nil }
                return (local, abs(roiValue(local, overview)))
            }
            .sorted { $0.1 > $1.1 }.prefix(12)
        return GeometryReader { proxy in
            let items = Array(top)
            let spacing = CGFloat(max(items.count - 1, 0)) * 10
            let width = min(320, max(220, (proxy.size.width - spacing) / CGFloat(max(items.count, 1))))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(items, id: \.0) { local, _ in
                        Button { selectChannel(overview.channelIndices[local]) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(overview.channelNames[local]).font(.caption.weight(.semibold))
                                TFHeatmap(render: channelRender(local, overview))
                                    .frame(width: width, height: width * 0.76)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(minHeight: 285)
    }

    @ViewBuilder
    private func clusters(_ overview: TFOverviewRender) -> some View {
        if let layout {
            let cluster = exploratoryCluster(overview, layout: layout)
            HStack(spacing: 16) {
                TopomapView(
                    layout: layout, values: roiValues(overview), timeSeconds: selectedWindow.upperBound / 1000,
                    fixedScale: overviewScale(overview), unitLabel: unitLabel(overview),
                    usesPositiveSequentialScale: !overview.isDiverging, minimumMapHeight: 190,
                    channelName: { channelName($0, overview: overview) }, onTapChannel: selectChannel,
                    highlightedChannels: cluster, visibleChannels: Set(activeChannels(overview))
                )
                .frame(width: 250)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exploratory spatial cluster").font(.headline)
                    Text("Largest connected set among the strongest 10% of selected ROI values (4-nearest-sensor graph).")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(cluster.count) sensors highlighted. This is a visual screening aid, not corrected statistical inference.")
                        .font(.caption)
                }
                Spacer()
            }
        } else { noLayout }
    }

    private var noLayout: some View {
        ContentUnavailableView("No Sensor Layout", systemImage: "circle.dashed",
            description: Text("The matrix and gallery remain available, but scalp-linked views need sensorLayout.xml."))
    }

    private func compatible(_ group: ChannelSet, overview: TFOverviewRender) -> Bool {
        group.channelIndices.contains { overview.channelIndices.contains($0) }
    }

    private func activeChannels(_ overview: TFOverviewRender) -> [Int] {
        guard groupID != "all", let id = UUID(uuidString: groupID),
              let group = groups.first(where: { $0.id == id }) else { return overview.channelIndices }
        return group.channelIndices.filter { overview.channelIndices.contains($0) }
    }

    private var selectedBand: EEGFrequencyBand {
        frequencyBands.first(where: { $0.name == bandName }) ?? frequencyBands.first ?? EEGFrequencyBand(name: "All", lowHz: 0, highHz: 120)
    }

    private var frequencyBands: [EEGFrequencyBand] {
        ProcessingDefaults.shared.timeFrequencyBands
    }

    private var availableTimeRange: ClosedRange<Double> {
        guard let times = overviews.first?.timesMs, let lower = times.min(), let upper = times.max(), lower < upper else {
            return -200...800
        }
        return lower...upper
    }

    private var selectedWindow: ClosedRange<Double> {
        let bounds = availableTimeRange
        let lower = min(max(windowStartMs, bounds.lowerBound), bounds.upperBound - 1)
        let upper = max(min(windowEndMs, bounds.upperBound), lower + 1)
        return lower...upper
    }

    private var windowLabel: String {
        "\(Int(selectedWindow.lowerBound))–\(Int(selectedWindow.upperBound)) ms"
    }

    private var windowStartBinding: Binding<Double> {
        Binding(
            get: { windowStartMs },
            set: { value in
                let bounds = availableTimeRange
                windowStartMs = min(max(value, bounds.lowerBound), min(windowEndMs - 1, bounds.upperBound - 1))
            }
        )
    }

    private var windowEndBinding: Binding<Double> {
        Binding(
            get: { windowEndMs },
            set: { value in
                let bounds = availableTimeRange
                windowEndMs = max(min(value, bounds.upperBound), max(windowStartMs + 1, bounds.lowerBound + 1))
            }
        )
    }

    private func setWindow(_ range: ClosedRange<Double>) {
        let bounds = availableTimeRange
        windowStartMs = min(max(range.lowerBound, bounds.lowerBound), bounds.upperBound - 1)
        windowEndMs = max(min(range.upperBound, bounds.upperBound), windowStartMs + 1)
    }
    private func frequencyIndices(_ overview: TFOverviewRender) -> [Int] {
        frequencyIndices(selectedBand, overview)
    }
    private func frequencyIndices(_ band: EEGFrequencyBand, _ overview: TFOverviewRender) -> [Int] {
        overview.frequenciesHz.indices.filter { overview.frequenciesHz[$0] >= band.lowHz && overview.frequenciesHz[$0] <= band.highHz }
    }
    private func windowIndices(_ overview: TFOverviewRender) -> [Int] {
        overview.timesMs.indices.filter { selectedWindow.contains(overview.timesMs[$0]) }
    }
    private func roiValue(_ local: Int, _ overview: TFOverviewRender) -> Double {
        mean(overview.grids[local], frequencies: frequencyIndices(overview), times: windowIndices(overview))
    }
    private func roiValues(_ overview: TFOverviewRender) -> [Double] {
        let n = (overview.channelIndices.max() ?? -1) + 1
        var values = [Double](repeating: 0, count: max(n, 1))
        for local in overview.channelIndices.indices { values[overview.channelIndices[local]] = roiValue(local, overview) }
        return values
    }
    private func values(at time: Int, _ overview: TFOverviewRender) -> [Double] {
        let n = (overview.channelIndices.max() ?? -1) + 1
        var values = [Double](repeating: 0, count: max(n, 1))
        for local in overview.channelIndices.indices { values[overview.channelIndices[local]] = mean(overview.grids[local], frequencies: frequencyIndices(overview), times: [time]) }
        return values
    }
    private func values(at time: Int, frequency: Int, _ overview: TFOverviewRender) -> [Double] {
        let n = (overview.channelIndices.max() ?? -1) + 1
        var values = [Double](repeating: 0, count: max(n, 1))
        for local in overview.channelIndices.indices { values[overview.channelIndices[local]] = mean(overview.grids[local], frequencies: [frequency], times: [time]) }
        return values
    }
    private func overviewScale(_ overview: TFOverviewRender) -> Double {
        let values = activeChannels(overview).compactMap { overview.localIndex(for: $0).map { abs(roiValue($0, overview)) } }.sorted()
        return max(values.dropFirst(Int(Double(values.count) * 0.99)).first ?? values.last ?? 1, 1e-6)
    }
    private func overviewScale(_ overview: TFOverviewRender, frequency: Int) -> Double {
        let times = Array(overview.timesMs.indices)
        let values = activeChannels(overview).compactMap { overview.localIndex(for: $0).map { abs(mean(overview.grids[$0], frequencies: [frequency], times: times)) } }.sorted()
        return max(values.dropFirst(Int(Double(values.count) * 0.99)).first ?? values.last ?? 1, 1e-6)
    }
    private func frequencySliceIndices(_ overview: TFOverviewRender, count: Int) -> [Int] {
        guard !overview.frequenciesHz.isEmpty else { return [] }
        let slices = min(count, overview.frequenciesHz.count)
        guard slices > 1 else { return [0] }
        return (0..<slices).map { Int((Double($0) / Double(slices - 1) * Double(overview.frequenciesHz.count - 1)).rounded()) }
    }

    /// Keeps the requested temporal cadence when it fits. On a narrow pane it
    /// increases the displayed interval just enough to avoid illegibly tiny
    /// scalp maps, while preserving the selected range's endpoints.
    private func filmstripTimeIndices(_ overview: TFOverviewRender, maxColumns: Int) -> [Int] {
        let inWindow = overview.timesMs.indices.filter { selectedWindow.contains(overview.timesMs[$0]) }
        guard let first = inWindow.first, let last = inWindow.last else { return [] }
        let span = max(overview.timesMs[last] - overview.timesMs[first], 1)
        let fittedStep = max(filmstripStepMs, span / Double(max(maxColumns - 1, 1)))
        var positions: [Int] = [first]
        var target = overview.timesMs[first] + fittedStep
        while target < overview.timesMs[last] {
            if let nearest = inWindow.min(by: { abs(overview.timesMs[$0] - target) < abs(overview.timesMs[$1] - target) }), positions.last != nearest {
                positions.append(nearest)
            }
            target += fittedStep
        }
        if positions.last != last { positions.append(last) }
        return positions
    }
    private func channelName(_ channel: Int, overview: TFOverviewRender) -> String {
        overview.localIndex(for: channel).map { overview.channelNames[$0] } ?? "Ch \(channel + 1)"
    }

    private func selectChannel(_ channel: Int) {
        selectedChannel = channel
        openDetail(channel)
    }
    private func unitLabel(_ overview: TFOverviewRender) -> String {
        overview.measure == .power ? (overview.isDifference ? "Δ dB" : "dB") : (overview.isDifference ? "Δ ITPC" : "ITPC")
    }
    private func channelRender(_ local: Int, _ overview: TFOverviewRender) -> TFRender {
        let grid = overview.grids[local]
        let range = valueRange(grid, diverging: overview.isDiverging)
        return TFRender(grid: grid, frequenciesHz: overview.frequenciesHz, timesMs: overview.timesMs,
            eventSampleIndex: overview.timesMs.firstIndex(where: { $0 >= 0 }) ?? 0, valueRange: range,
            isDiverging: overview.isDiverging, measure: overview.measure, isDifference: overview.isDifference,
            trialCountA: 0, trialCountB: nil)
    }
    private func exploratoryCluster(_ overview: TFOverviewRender, layout: SensorLayout) -> Set<Int> {
        let channels = activeChannels(overview)
        let scored = channels.compactMap { channel -> (Int, Double)? in overview.localIndex(for: channel).map { (channel, abs(roiValue($0, overview))) } }
        let sorted = scored.map(\.1).sorted()
        guard let threshold = sorted.dropFirst(Int(Double(sorted.count) * 0.9)).first else { return [] }
        let candidate = Set(scored.filter { $0.1 >= threshold }.map(\.0))
        let adjacency = ClusterSpatialAdjacency.build(channelIndices: channels, layout: layout,
            configuration: ClusterAdjacencyConfiguration(method: .nearestNeighbors, distance: 0.25, neighborCount: 4))
        var best = Set<Int>(), seen = Set<Int>()
        for start in channels where candidate.contains(start) && !seen.contains(start) {
            var component = Set<Int>(), queue = [start]
            seen.insert(start)
            while let current = queue.popLast() {
                component.insert(current)
                guard let local = channels.firstIndex(of: current) else { continue }
                for neighbor in adjacency[local].map({ channels[$0] }) where candidate.contains(neighbor) && !seen.contains(neighbor) {
                    seen.insert(neighbor); queue.append(neighbor)
                }
            }
            if component.count > best.count { best = component }
        }
        return best
    }

    private func mean(_ grid: [[Double]], frequencies: [Int], times: [Int]) -> Double {
        var total = 0.0, count = 0
        for frequency in frequencies where grid.indices.contains(frequency) {
            for time in times where grid[frequency].indices.contains(time) { total += grid[frequency][time]; count += 1 }
        }
        return count > 0 ? total / Double(count) : 0
    }
    private func valueRange(_ grid: [[Double]], diverging: Bool) -> ClosedRange<Double> {
        let values = grid.flatMap { $0 }
        if diverging { let e = max(values.map(abs).max() ?? 1, 1e-6); return -e...e }
        return 0...max(values.max() ?? 1, 0.05)
    }
}

/// Isolated from the dashboard so checking a condition does not invalidate
/// dozens of scalp-map views before the user explicitly chooses Rebuild.
private struct TFOverviewBuildControls: View {
    let conditions: [String]
    let builtConditions: Set<String>
    let hasOverview: Bool
    let setupNeedsRebuild: Bool
    let isBuilding: Bool
    let progress: Double
    let progressStatus: String
    let build: ([String]) -> Void

    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(conditions, id: \.self) { condition in
                        Button {
                            if selected.contains(condition), selected.count > 1 { selected.remove(condition) }
                            else { selected.insert(condition) }
                        } label: {
                            Label(condition, systemImage: selected.contains(condition) ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label(menuTitle, systemImage: "line.3.horizontal.decrease.circle")
                }
                Button { build(selectedList) } label: {
                    Label(hasOverview ? "Rebuild" : "Build", systemImage: needsRebuild ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(needsRebuild ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .foregroundColor(needsRebuild ? .white : nil)
                .disabled(isBuilding)
            }
            if isBuilding {
                HStack(spacing: 8) {
                    ProgressView(value: progress).frame(width: 220)
                    Text(progressStatus).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { if selected.isEmpty, let first = conditions.first { selected = [first] } }
    }

    private var selectedList: [String] { conditions.filter { selected.contains($0) } }
    private var menuTitle: String { selectedList.count == 1 ? "Condition: \(selectedList[0])" : "Conditions: \(selectedList.count)" }
    private var needsRebuild: Bool { setupNeedsRebuild || Set(selectedList) != builtConditions }
}

private struct TFChannelMatrix: View {
    let rows: [[Double]]
    let channels: [Int]
    let render: TFOverviewRender
    let channelName: (Int) -> String
    let onSelect: (Int) -> Void

    @State private var hover: (channel: Int, location: CGPoint)?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard !rows.isEmpty, let timeCount = rows.first?.count, timeCount > 0 else { return }
                let rowHeight = size.height / CGFloat(rows.count), cellWidth = size.width / CGFloat(timeCount)
                let values = rows.flatMap { $0 }
                let extent = max(values.map(abs).max() ?? 1, 1e-6)
                let sequentialMax = max(values.max() ?? 0.05, 0.05)
                let display = TFRender(grid: [], frequenciesHz: [], timesMs: [], eventSampleIndex: 0,
                    valueRange: render.isDiverging ? -extent...extent : 0...sequentialMax,
                    isDiverging: render.isDiverging, measure: render.measure, isDifference: render.isDifference,
                    trialCountA: 0, trialCountB: nil)
                for row in rows.indices {
                    for time in rows[row].indices {
                        let rect = CGRect(x: CGFloat(time) * cellWidth, y: CGFloat(row) * rowHeight,
                                          width: cellWidth + 0.5, height: rowHeight + 0.5)
                        context.fill(Path(rect), with: .color(TFColorMap.color(for: rows[row][time], render: display)))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard NSEvent.modifierFlags.contains(.option) else { hover = nil; return }
                if case .active(let point) = phase, let channel = channel(at: point, height: proxy.size.height) {
                    hover = (channel, point)
                } else { hover = nil }
            }
            .simultaneousGesture(SpatialTapGesture().onEnded { point in
                if let channel = channel(at: point.location, height: proxy.size.height) { onSelect(channel) }
            })
            .overlay(alignment: .topLeading) {
                if let hover {
                    Text(channelName(hover.channel))
                        .font(.caption.weight(.semibold)).padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .offset(x: min(hover.location.x + 10, max(proxy.size.width - 80, 0)), y: max(hover.location.y - 25, 0))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func channel(at point: CGPoint, height: CGFloat) -> Int? {
        guard !channels.isEmpty, height > 0 else { return nil }
        let row = min(max(Int(point.y / height * CGFloat(channels.count)), 0), channels.count - 1)
        return channels[row]
    }
}
