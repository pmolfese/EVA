//
//  RhythmicBurstView.swift
//  EVA
//
//  Linked burst map, waveform, summaries, duration distribution, and table.
//

import Charts
import SwiftUI

private enum RhythmicBurstSort: String, CaseIterable, Identifiable {
    case time = "Time"
    case frequency = "Frequency"
    case duration = "Duration"
    case power = "Power"
    case wtpl = "WTPL"
    var id: String { rawValue }
}

struct RhythmicBurstView: View {
    let result: RhythmicBurstAnalysisResult
    @Binding var selectedChannelIndex: Int
    @Binding var background: RhythmicBurstBackground
    @Binding var selectedBurstID: String?

    @State private var selectedMapID = ""
    @State private var selectedBandID = "all"
    @State private var sort = RhythmicBurstSort.time

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            if let map = selectedMap {
                ZStack {
                    TFHeatmap(render: render(map))
                    burstOverlay(map)
                        .allowsHitTesting(false)
                }
                .frame(minHeight: 300)
                TFColorBar(render: render(map))
                    .frame(height: 30)
                    .padding(.horizontal, 44)
                waveform(map)
                    .frame(height: 118)
            } else {
                ContentUnavailableView("No burst map", systemImage: "waveform.badge.magnifyingglass")
            }
            lowerPanels
        }
        .onAppear { reconcileSelection() }
        .onChange(of: selectedChannelIndex) { reconcileSelection() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Channel", selection: $selectedChannelIndex) {
                ForEach(channelIndices, id: \.self) { index in
                    Text(result.maps.first(where: { $0.channelIndex == index })?.channelName ?? "E\(index + 1)")
                        .tag(index)
                }
            }
            .frame(maxWidth: 180)
            Picker("Segment", selection: $selectedMapID) {
                ForEach(result.maps.filter { $0.channelIndex == selectedChannelIndex }) { map in
                    Text(map.segmentLabel ?? "Segment \(map.segmentIndex + 1)").tag(map.id)
                }
            }
            .frame(maxWidth: 220)
            Picker("Background", selection: $background) {
                ForEach(RhythmicBurstBackground.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            Picker("Band", selection: $selectedBandID) {
                Text("All bands").tag("all")
                ForEach(result.bandDefinitions) { Text($0.name).tag($0.id) }
                Text("Unassigned").tag("unassigned")
            }
            .frame(maxWidth: 180)
            Spacer()
            Label("Neural analysis annotation", systemImage: "brain.head.profile")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .help("Burst annotations never enter artifact rejection or cleaning.")
        }
    }

    private var lowerPanels: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Band statistics").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredSummaries) { value in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(value.channelName) · \(value.bandName)").font(.caption.weight(.semibold))
                                    Text("\(value.burstCount) bursts · \(format(value.ratePerMinutePerHz)) /min/Hz · \(format(value.occupancyPercent))% occupancy")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(format(value.meanDurationMilliseconds)) ms")
                                    .font(.caption.monospacedDigit())
                            }
                            Divider()
                        }
                    }
                }
                Text("Duration distribution").font(.caption.weight(.semibold))
                Chart(durationBins, id: \.lower) { bin in
                    BarMark(
                        x: .value("Duration", bin.lower),
                        y: .value("Bursts", bin.count),
                        width: .fixed(12)
                    )
                }
                .chartXAxisLabel("Duration (ms)")
                .frame(height: 105)
            }
            .frame(minWidth: 310)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Burst table").font(.headline)
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        ForEach(RhythmicBurstSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 145)
                }
                List(sortedBursts, selection: $selectedBurstID) { burst in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(burst.channelName) · \(burst.bandName ?? "Unassigned")")
                                .font(.caption.weight(.semibold))
                            Text("sample \(burst.peakGlobalSample) · \(format(burst.peakFrequencyHz)) Hz")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(format(burst.durationMilliseconds)) ms")
                            .font(.caption.monospacedDigit())
                        Text("\(format(burst.relativePeakPowerDB)) dB")
                            .font(.caption.monospacedDigit())
                        Text(burst.meanWTPL.map(format) ?? "—")
                            .font(.caption.monospacedDigit())
                    }
                    .tag(burst.id)
                }
            }
            .frame(minWidth: 420)
        }
        .frame(minHeight: 210)
    }

    private func waveform(_ map: RhythmicBurstMap) -> some View {
        Chart {
            ForEach(Array(map.waveform.indices), id: \.self) { index in
                LineMark(
                    x: .value("Time (ms)", map.waveformTimesSeconds[index] * 1_000),
                    y: .value("Signal", map.waveform[index])
                )
                .lineStyle(StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(.secondary)
            }
            ForEach(mapBursts(map)) { burst in
                RectangleMark(
                    xStart: .value("Onset", Double(burst.onsetGlobalSample) / result.samplingRateHz * 1_000),
                    xEnd: .value("Offset", Double(burst.offsetGlobalSample) / result.samplingRateHz * 1_000)
                )
                .foregroundStyle((burst.id == selectedBurstID ? Color.orange : Color.blue).opacity(0.09))
                RuleMark(x: .value("Peak", Double(burst.peakGlobalSample) / result.samplingRateHz * 1_000))
                    .foregroundStyle(burst.id == selectedBurstID ? Color.orange : Color.blue.opacity(0.45))
            }
        }
        .chartXAxisLabel("Linked waveform time (ms)")
        .chartYAxisLabel("Signal")
    }

    private func burstOverlay(_ map: RhythmicBurstMap) -> some View {
        Canvas { context, size in
            guard let firstTime = map.timesSeconds.first,
                  let lastTime = map.timesSeconds.last,
                  let firstFrequency = map.frequenciesHz.first,
                  let lastFrequency = map.frequenciesHz.last,
                  lastTime > firstTime, lastFrequency > firstFrequency else { return }
            let left = 44.0
            let top = 6.0
            let width = max(size.width - left - 26, 1)
            let height = max(size.height - top - 26, 1)
            func x(_ sample: Int) -> CGFloat {
                let seconds = Double(sample) / result.samplingRateHz
                return left + (seconds - firstTime) / (lastTime - firstTime) * width
            }
            func y(_ frequency: Double) -> CGFloat {
                top + (lastFrequency - frequency) / (lastFrequency - firstFrequency) * height
            }
            for burst in mapBursts(map) {
                let selected = burst.id == selectedBurstID
                let rect = CGRect(
                    x: x(burst.onsetGlobalSample),
                    y: y(burst.upperPeakFrequencyHz),
                    width: max(x(burst.offsetGlobalSample) - x(burst.onsetGlobalSample), 1),
                    height: max(y(burst.lowerPeakFrequencyHz) - y(burst.upperPeakFrequencyHz), 3)
                )
                context.stroke(Path(rect), with: .color(selected ? .orange : .white.opacity(0.75)), lineWidth: selected ? 2 : 1)
                let point = CGPoint(x: x(burst.peakGlobalSample), y: y(burst.peakFrequencyHz))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                             with: .color(selected ? .orange : .white))
            }
        }
    }

    private func render(_ map: RhythmicBurstMap) -> TFRender {
        let grid = background == .power ? map.normalizedPower : map.wtpl
        return TFRender(
            grid: grid,
            frequenciesHz: map.frequenciesHz,
            timesMs: map.timesSeconds.map { $0 * 1_000 },
            eventSampleIndex: 0,
            valueRange: background == .power ? 0...max(finiteMaximum(grid), 1) : 0...1,
            isDiverging: false,
            measure: background == .power ? .power : .wtpl,
            isDifference: false,
            unitOverride: background == .power ? "power / P90" : "WTPL",
            trialCountA: 1,
            trialCountB: nil
        )
    }

    private var selectedMap: RhythmicBurstMap? {
        result.maps.first { $0.id == selectedMapID }
            ?? result.maps.first { $0.channelIndex == selectedChannelIndex }
            ?? result.maps.first
    }

    private var channelIndices: [Int] { Array(Set(result.maps.map(\.channelIndex))).sorted() }

    private func mapBursts(_ map: RhythmicBurstMap) -> [RhythmicBurst] {
        filteredBursts.filter { $0.channelIndex == map.channelIndex && $0.segmentIndex == map.segmentIndex }
    }

    private var filteredBursts: [RhythmicBurst] {
        result.bursts.filter { burst in
            selectedBandID == "all" || burst.bandID == selectedBandID ||
                (selectedBandID == "unassigned" && burst.bandID == nil)
        }
    }

    private var sortedBursts: [RhythmicBurst] {
        filteredBursts.sorted { left, right in
            switch sort {
            case .time: return left.peakGlobalSample < right.peakGlobalSample
            case .frequency: return left.peakFrequencyHz < right.peakFrequencyHz
            case .duration: return left.durationMilliseconds > right.durationMilliseconds
            case .power: return left.relativePeakPowerDB > right.relativePeakPowerDB
            case .wtpl: return (left.meanWTPL ?? -.infinity) > (right.meanWTPL ?? -.infinity)
            }
        }
    }

    private var filteredSummaries: [RhythmicBurstBandSummary] {
        result.summaries.filter { value in
            value.channelIndex == selectedChannelIndex &&
                (selectedBandID == "all" || value.bandID == selectedBandID ||
                 (selectedBandID == "unassigned" && value.bandID == nil))
        }
    }

    private var durationBins: [(lower: Double, count: Int)] {
        let durations = filteredBursts.map(\.durationMilliseconds).filter(\.isFinite)
        guard let maximum = durations.max(), maximum > 0 else { return [] }
        let width = max(maximum / 12, 1)
        var counts = [Int](repeating: 0, count: 12)
        for value in durations { counts[min(Int(value / width), 11)] += 1 }
        return counts.indices.map { (Double($0) * width, counts[$0]) }
    }

    private func reconcileSelection() {
        if !result.maps.contains(where: { $0.id == selectedMapID && $0.channelIndex == selectedChannelIndex }) {
            selectedMapID = result.maps.first(where: { $0.channelIndex == selectedChannelIndex })?.id ?? ""
        }
    }

    private func finiteMaximum(_ values: [[Double]]) -> Double {
        values.flatMap { $0 }.filter(\.isFinite).max() ?? 1
    }

    private func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.3g", value) : "—"
    }
}
