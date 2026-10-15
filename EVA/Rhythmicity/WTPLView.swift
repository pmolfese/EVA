//
//  WTPLView.swift
//  EVA
//
//  Event-related WTPL result canvas. Reuses the Time-Frequency heatmap and
//  ABBA overlay while retaining WTPL-specific labels and baseline semantics.
//

import SwiftUI

struct WTPLView: View {
    let result: WTPLAnalysisResult
    let conditionA: String
    let conditionB: String?
    let showsDifference: Bool
    let displayMeasure: WTPLDisplayMeasure
    let selectedChannelIndex: Int
    let bandResolution: TimeFrequencyBandResolution

    @State private var selectedBandName = ""
    @State private var windowStartMs = 0.0
    @State private var windowEndMs = 500.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            if let render {
                TFHeatmap(render: render, rhythmicityBands: bandResolution.detectedBandSet)
                    .frame(minHeight: 390)
                TFColorBar(render: render)
                    .frame(height: 34)
                    .padding(.horizontal, 44)
                roiControls(render)
            } else {
                ContentUnavailableView(
                    "WTPL map unavailable",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text(unavailableReason)
                )
            }
        }
        .onAppear { if selectedBandName.isEmpty { selectedBandName = bandResolution.bands.first?.name ?? "" } }
        .onChange(of: bandResolution.sourceDescription) {
            if !bandResolution.bands.contains(where: { $0.name == selectedBandName }) {
                selectedBandName = bandResolution.bands.first?.name ?? ""
            }
        }
    }

    private var summary: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Measure", measureSummary)
                chip("Conditions", showsDifference ? "\(conditionA) − \(conditionB ?? "—")" : conditionA)
                chip("Channel", selectedChannel?.channelName ?? "—")
                chip("Trials", trialCount)
                chip("Valid trials/cell", validCountSummary)
                chip("Lags", result.lagCycles.map { String(format: "%+.1f", $0) }.joined(separator: ", ") + " cycles")
            }
        }
    }

    private var render: TFRender? {
        makeRender()
    }

    private var selectedChannel: WTPLChannelResult? {
        result.conditions.first(where: { $0.condition == conditionA })?.channels
            .first(where: { $0.channelIndex == selectedChannelIndex })
    }

    private var trialCount: String {
        guard let a = channel(in: conditionA) else { return "—" }
        if showsDifference, let bName = conditionB, let b = channel(in: bName) {
            return "\(a.trialCount) vs \(b.trialCount)"
        }
        return "\(a.trialCount)"
    }

    private var unavailableReason: String {
        if displayMeasure == .delta, result.baselineWindowMs == nil {
            return "The complete requested baseline is outside the epoch. Choose a valid explicit baseline or view Raw WTPL."
        }
        if showsDifference {
            return "Both selected conditions must have a completed result for this channel and measure."
        }
        return "The selected condition or channel has no completed WTPL result."
    }

    private var measureSummary: String {
        if displayMeasure == .validCounts {
            return showsDifference ? "Minimum valid counts (A, B)" : displayMeasure.rawValue
        }
        return showsDifference ? "A − B \(displayMeasure.rawValue)" : displayMeasure.rawValue
    }

    private var validCountSummary: String {
        guard let selectedChannel else { return "—" }
        let counts = selectedChannel.validTrialCounts.flatMap { $0 }.filter { $0 > 0 }
        guard let minimum = counts.min(), let maximum = counts.max() else { return "0" }
        return minimum == maximum ? "\(minimum)" : "\(minimum)–\(maximum)"
    }

    @ViewBuilder
    private func roiControls(_ render: TFRender) -> some View {
        HStack(spacing: 12) {
            Picker("Band", selection: $selectedBandName) {
                ForEach(bandResolution.bands) { Text($0.name).tag($0.name) }
            }
            .frame(width: 180)
            LabeledContent("Window") {
                HStack(spacing: 4) {
                    TextField("Start", value: $windowStartMs, format: .number).frame(width: 65)
                    Text("to")
                    TextField("End", value: $windowEndMs, format: .number).frame(width: 65)
                    Text("ms")
                }
            }
            if let scalar = scalar(render) {
                Text("ROI mean \(String(format: "%.4f", scalar)) \(render.unitLabel)")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            Spacer()
            if let warning = bandResolution.warning {
                Label(warning, systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .font(.caption)
    }

    private func channel(in condition: String) -> WTPLChannelResult? {
        result.conditions.first(where: { $0.condition == condition })?.channels
            .first(where: { $0.channelIndex == selectedChannelIndex })
    }

    private func makeRender() -> TFRender? {
        guard let a = channel(in: conditionA), let gridA = displayGrid(for: a) else { return nil }
        var grid = gridA
        var bCount: Int?
        if showsDifference {
            guard let conditionB, let b = channel(in: conditionB), let gridB = displayGrid(for: b) else {
                return nil
            }
            grid = displayMeasure == .validCounts ? cellwiseMinimum(gridA, gridB) : subtract(gridA, gridB)
            bCount = b.trialCount
        }
        let diverging = displayMeasure != .validCounts && (showsDifference || displayMeasure == .delta)
        let maximumCount = Double(max(a.trialCount, bCount ?? 0))
        return TFRender(
            grid: grid,
            frequenciesHz: result.frequenciesHz,
            timesMs: result.timesMs,
            eventSampleIndex: result.timesMs.firstIndex(where: { $0 >= 0 }) ?? 0,
            valueRange: diverging ? symmetricRange(grid) : 0...(displayMeasure == .validCounts ? max(maximumCount, 1) : 1),
            isDiverging: diverging,
            measure: .wtpl,
            isDifference: showsDifference && displayMeasure != .validCounts,
            isBaselineSubtracted: displayMeasure == .delta,
            unitOverride: displayMeasure == .validCounts ? "valid trials" : nil,
            trialCountA: a.trialCount,
            trialCountB: bCount
        )
    }

    private func displayGrid(for channel: WTPLChannelResult) -> [[Double]]? {
        switch displayMeasure {
        case .raw: return channel.meanWTPL
        case .delta: return channel.deltaWTPL
        case .validCounts: return channel.validTrialCounts.map { $0.map(Double.init) }
        }
    }

    private func scalar(_ render: TFRender) -> Double? {
        guard let band = bandResolution.bands.first(where: { $0.name == selectedBandName }) else { return nil }
        let frequencies = render.frequenciesHz.indices.filter {
            render.frequenciesHz[$0] >= band.lowHz && render.frequenciesHz[$0] <= band.highHz
        }
        let times = render.timesMs.indices.filter {
            render.timesMs[$0] >= windowStartMs && render.timesMs[$0] <= windowEndMs
        }
        let values = frequencies.flatMap { frequency in
            times.compactMap { time -> Double? in
                let value = render.grid[frequency][time]
                return value.isFinite ? value : nil
            }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func subtract(_ lhs: [[Double]], _ rhs: [[Double]]) -> [[Double]] {
        lhs.indices.map { frequency in
            lhs[frequency].indices.map { time in
                let a = lhs[frequency][time]
                let b = rhs.indices.contains(frequency) && rhs[frequency].indices.contains(time)
                    ? rhs[frequency][time] : .nan
                return a.isFinite && b.isFinite ? a - b : .nan
            }
        }
    }

    private func cellwiseMinimum(_ lhs: [[Double]], _ rhs: [[Double]]) -> [[Double]] {
        lhs.indices.map { frequency in
            lhs[frequency].indices.map { time in
                let a = lhs[frequency][time]
                let b = rhs.indices.contains(frequency) && rhs[frequency].indices.contains(time)
                    ? rhs[frequency][time] : .nan
                return a.isFinite && b.isFinite ? min(a, b) : .nan
            }
        }
    }

    private func symmetricRange(_ grid: [[Double]]) -> ClosedRange<Double> {
        let finite = grid.flatMap { $0 }.filter(\.isFinite).map(abs).sorted()
        guard !finite.isEmpty else { return -1...1 }
        let index = min(finite.count - 1, Int(Double(finite.count) * 0.99))
        let extent = max(finite[index], 1e-6)
        return -extent...extent
    }

    private func chip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
